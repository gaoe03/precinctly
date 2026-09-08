#!/usr/bin/env python3
"""Copy a reviewed precinct DB and repair only CVAP-derived and political cells.

The source is opened read-only and must match the caller-supplied SHA-256. The output and report
must be new paths. The tool rejects symlinked sources and aliases, compares every table cell after
the repair, and records every allowed old/new value in the JSON report.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
from itertools import zip_longest

try:
    from pipeline.data_contract import (
        DataContractError,
        baseline_scope_filter,
        cap_cvap_to_vap,
        selected_president_aggregate,
        turnout_from_cvap,
    )
except ModuleNotFoundError:  # Supports python3 pipeline/migrate_data_contract.py.
    from data_contract import (  # type: ignore[no-redef]
        DataContractError,
        baseline_scope_filter,
        cap_cvap_to_vap,
        selected_president_aggregate,
        turnout_from_cvap,
    )


class MigrationError(RuntimeError):
    """Raised before a candidate with an ambiguous or broad mutation can survive."""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise MigrationError(message)


def validate_paths(source: Path, output: Path, report: Path, expected_hash: str) -> str:
    require(len(expected_hash) == 64 and all(c in "0123456789abcdef" for c in expected_hash),
            "expected SHA-256 must be 64 lowercase hexadecimal characters")
    require(source.exists() and source.is_file(), f"source is not a regular file: {source}")
    require(not source.is_symlink(), f"refusing symlinked source: {source}")
    for suffix in ("-wal", "-journal"):
        sidecar = Path(str(source) + suffix)
        require(not sidecar.exists() or sidecar.stat().st_size == 0,
                f"refusing source with a nonempty SQLite sidecar: {sidecar}")
    require(not os.path.lexists(output), f"output already exists: {output}")
    require(not os.path.lexists(report), f"report already exists: {report}")
    require(output.parent.is_dir() and not output.parent.is_symlink(),
            f"output parent must be an existing non-symlink directory: {output.parent}")
    require(report.parent.is_dir() and not report.parent.is_symlink(),
            f"report parent must be an existing non-symlink directory: {report.parent}")
    resolved = {source.resolve(), output.resolve(), report.resolve()}
    require(len(resolved) == 3, "source, output, and report must be distinct paths")
    actual_hash = sha256(source)
    require(actual_hash == expected_hash,
            f"source hash mismatch: expected {expected_hash}, found {actual_hash}")
    return actual_hash


def _table_columns(connection: sqlite3.Connection, table: str) -> list[str]:
    return [row[1] for row in connection.execute(f"PRAGMA table_info({table})")]


def repair(
    connection: sqlite3.Connection,
    recompute_turnout: bool = False,
) -> list[dict[str, object]]:
    """Repair allowed cells in one transaction and return their complete old/new ledger."""
    changes: list[dict[str, object]] = []
    required_precinct = {"unit_id", "vap_total", "cvap", "lean_votes", "turnout_est", "lean_year"}
    precinct_columns = set(_table_columns(connection, "precincts"))
    require(required_precinct <= precinct_columns,
            f"precincts is missing columns: {', '.join(sorted(required_precinct - precinct_columns))}")
    baseline_columns = set(_table_columns(connection, "baselines"))
    require({"scope", "pres24_dem_share"} <= baseline_columns,
            "baselines is missing scope or pres24_dem_share")

    connection.execute("BEGIN IMMEDIATE")
    try:
        rows = connection.execute(
            "SELECT unit_id,vap_total,cvap,lean_votes,turnout_est FROM precincts ORDER BY unit_id"
        ).fetchall()
        for unit_id, vap_total, old_cvap, lean_votes, old_turnout in rows:
            if recompute_turnout:
                new_turnout = turnout_from_cvap(lean_votes, old_cvap)
                if old_turnout != new_turnout:
                    connection.execute(
                        "UPDATE precincts SET turnout_est=? WHERE unit_id=?",
                        (new_turnout, unit_id),
                    )
                    changes.append({"table": "precincts", "key": unit_id,
                                    "column": "turnout_est", "before": old_turnout,
                                    "after": new_turnout})
                continue
            new_cvap = cap_cvap_to_vap(old_cvap, vap_total)
            if new_cvap == old_cvap:
                continue
            new_turnout = turnout_from_cvap(lean_votes, new_cvap)
            connection.execute(
                "UPDATE precincts SET cvap=?,turnout_est=? WHERE unit_id=?",
                (new_cvap, new_turnout, unit_id),
            )
            changes.append({"table": "precincts", "key": unit_id, "column": "cvap",
                            "before": old_cvap, "after": new_cvap})
            if old_turnout != new_turnout:
                changes.append({"table": "precincts", "key": unit_id, "column": "turnout_est",
                                "before": old_turnout, "after": new_turnout})

        if not recompute_turnout:
            for scope, old_share in connection.execute(
                "SELECT scope,pres24_dem_share FROM baselines ORDER BY scope"
            ).fetchall():
                where, parameters = baseline_scope_filter(scope)
                aggregate = selected_president_aggregate(connection, where, parameters)
                new_share = aggregate.dem_share
                if old_share != new_share:
                    connection.execute(
                        "UPDATE baselines SET pres24_dem_share=? WHERE scope=?", (new_share, scope)
                    )
                    changes.append({"table": "baselines", "key": scope,
                                    "column": "pres24_dem_share", "before": old_share,
                                    "after": new_share})
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    return changes


def _rows_equal(left: sqlite3.Connection, right: sqlite3.Connection, table: str, columns: list[str]) -> bool:
    projection = ",".join(f'"{column}"' for column in columns)
    sentinel = object()
    left_rows = left.execute(f"SELECT rowid,{projection} FROM {table} ORDER BY rowid")
    right_rows = right.execute(f"SELECT rowid,{projection} FROM {table} ORDER BY rowid")
    return all(before == after for before, after in zip_longest(left_rows, right_rows, fillvalue=sentinel))


def verify_only_allowed_changes(
    source: sqlite3.Connection,
    candidate: sqlite3.Connection,
    changes: list[dict[str, object]],
    recompute_turnout: bool = False,
) -> None:
    source_schema = source.execute(
        "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name"
    ).fetchall()
    candidate_schema = candidate.execute(
        "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name"
    ).fetchall()
    require(source_schema == candidate_schema, "database schema changed")
    tables = [row[0] for row in source.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
    )]
    for table in tables:
        columns = _table_columns(source, table)
        if table == "precincts":
            allowed = {"turnout_est"} if recompute_turnout else {"cvap", "turnout_est"}
            columns = [column for column in columns if column not in allowed]
        elif table == "baselines" and not recompute_turnout:
            columns = [column for column in columns if column != "pres24_dem_share"]
        require(_rows_equal(source, candidate, table, columns), f"disallowed cell changed in {table}")
    expected = {
        (str(change["table"]), str(change["key"]), str(change["column"])):
            (change["before"], change["after"])
        for change in changes
    }
    require(len(expected) == len(changes), "change ledger contains duplicate cells")
    actual: dict[tuple[str, str, str], tuple[object, object]] = {}
    allowed_cells = (
        (("precincts", "unit_id", ("turnout_est",)),)
        if recompute_turnout else
        (
            ("precincts", "unit_id", ("cvap", "turnout_est")),
            ("baselines", "scope", ("pres24_dem_share",)),
        )
    )
    for table, key_column, columns in allowed_cells:
        projection = ",".join((key_column, *columns))
        before = {str(row[0]): row[1:] for row in source.execute(f"SELECT {projection} FROM {table}")}
        after = {str(row[0]): row[1:] for row in candidate.execute(f"SELECT {projection} FROM {table}")}
        require(before.keys() == after.keys(), f"allowed table keys changed in {table}")
        for key in before:
            for index, column in enumerate(columns):
                if before[key][index] != after[key][index]:
                    actual[(table, key, column)] = (before[key][index], after[key][index])
    require(actual == expected, "change ledger does not exactly match allowed cell differences")
    require(candidate.execute("PRAGMA integrity_check").fetchone()[0] == "ok", "integrity_check failed")
    require(candidate.execute(
        "SELECT COUNT(*) FROM precincts WHERE cvap IS NOT NULL AND vap_total IS NOT NULL AND cvap>vap_total"
    ).fetchone()[0] == 0, "candidate still has CVAP above VAP")
    if recompute_turnout:
        require(candidate.execute(
            """
            SELECT COUNT(*) FROM precincts
            WHERE CASE
              WHEN lean_votes IS NULL OR cvap IS NULL OR cvap < 50
                   OR lean_votes * 1.0 / cvap > 1.15
                THEN turnout_est IS NOT NULL
              ELSE turnout_est IS NULL
                   OR ABS(turnout_est - lean_votes * 1.0 / cvap) > 1e-12
            END
            """
        ).fetchone()[0] == 0, "candidate still has turnout values outside the shared contract")


def summarize(changes: list[dict[str, object]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for change in changes:
        label = f"{change['table']}.{change['column']}"
        counts[label] = counts.get(label, 0) + 1
    return dict(sorted(counts.items()))


def migrate(
    source: Path,
    output: Path,
    report: Path,
    expected_hash: str,
    recompute_turnout: bool = False,
) -> dict[str, object]:
    input_hash = validate_paths(source, output, report, expected_hash)
    source_db = candidate_db = None
    output_created = False
    try:
        output_fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        output_created = True
        with os.fdopen(output_fd, "wb") as destination, source.open("rb") as origin:
            shutil.copyfileobj(origin, destination, length=1024 * 1024)
        source_db = sqlite3.connect(f"file:{source}?mode=ro&immutable=1", uri=True)
        candidate_db = sqlite3.connect(output)
        changes = repair(candidate_db, recompute_turnout=recompute_turnout)
        verify_only_allowed_changes(
            source_db, candidate_db, changes, recompute_turnout=recompute_turnout
        )
        second_pass = repair(candidate_db, recompute_turnout=recompute_turnout)
        require(not second_pass, f"migration is not idempotent: {len(second_pass)} second-pass changes")
        verify_only_allowed_changes(
            source_db, candidate_db, changes, recompute_turnout=recompute_turnout
        )
        candidate_db.close(); candidate_db = None
        source_db.close(); source_db = None
        require(sha256(source) == input_hash, "source hash changed during migration")
        result: dict[str, object] = {
            "source": str(source),
            "source_sha256_before": input_hash,
            "source_sha256_after": sha256(source),
            "output": str(output),
            "output_sha256": sha256(output),
            "mode": "recompute_turnout" if recompute_turnout else "cvap_and_political_baselines",
            "allowed_changed_cell_counts": summarize(changes),
            "changed_cell_count": len(changes),
            "second_pass_changed_cell_count": len(second_pass),
            "changes": changes,
        }
        with report.open("x") as stream:
            stream.write(json.dumps(result, indent=2, sort_keys=True) + "\n")
        return result
    except Exception:
        if candidate_db is not None:
            candidate_db.close(); candidate_db = None
        if source_db is not None:
            source_db.close(); source_db = None
        if output_created and output.exists():
            output.unlink()
        raise
    finally:
        if candidate_db is not None:
            candidate_db.close()
        if source_db is not None:
            source_db.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--expected-sha256", required=True)
    parser.add_argument(
        "--recompute-turnout",
        action="store_true",
        help="recompute turnout_est for every precinct and permit no other cell changes",
    )
    args = parser.parse_args()
    try:
        result = migrate(args.source.absolute(), args.output.absolute(), args.report.absolute(),
                         args.expected_sha256, recompute_turnout=args.recompute_turnout)
    except (DataContractError, MigrationError, OSError, sqlite3.Error) as error:
        parser.error(str(error))
    print(json.dumps({key: value for key, value in result.items() if key != "changes"}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
