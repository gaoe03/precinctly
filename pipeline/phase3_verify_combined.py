#!/usr/bin/env python3
"""Read-only verification of the Phase 3 OR/CO combined evaluation database.

Run from the repository root. The only write is a canonical, reproducible JSON
report after every verification gate has passed.
"""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import subprocess
import tempfile
from typing import Any, Iterable, Sequence

from pyproj import Transformer
from shapely import make_valid, wkb
from shapely.geometry import Point
from shapely.ops import transform as geometry_transform

try:
    from pipeline import phase2b_verify_candidate as phase2b
except ModuleNotFoundError:
    import phase2b_verify_candidate as phase2b  # type: ignore[no-redef]


ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / "PrecinctWeather" / "PrecinctKit" / "Resources" / "nyc_precincts.sqlite"
CANDIDATE_DIR = ROOT / "public_data" / "phase2b_candidates"
OR_CANDIDATE = CANDIDATE_DIR / "or_fallback_candidate.sqlite"
CO_CANDIDATE = CANDIDATE_DIR / "co_fallback_candidate.sqlite"
PHASE2B_REPORT = CANDIDATE_DIR / "verification_report.json"
PROTECTED_SNAPSHOT = CANDIDATE_DIR / "protected_boundary_before.json"
SOURCE = ROOT / "precincts_2026_primary.db"
OUTPUT_DIR = ROOT / "public_data" / "phase3_evaluation"
COMBINED = OUTPUT_DIR / "phase3_full_evaluation.sqlite"
REPORT = OUTPUT_DIR / "verification_report.json"
SWIFT_HARNESS = ROOT / "pipeline" / "phase3_swift_contract_harness.swift"
SWIFT_SOURCES = (
    ROOT / "PrecinctWeather" / "PrecinctKit" / "Sources" / "FunFact.swift",
    ROOT / "PrecinctWeather" / "PrecinctKit" / "Sources" / "PrecinctProfile.swift",
    ROOT / "PrecinctWeather" / "PrecinctKit" / "Sources" / "WKBGeometry.swift",
    ROOT / "PrecinctWeather" / "PrecinctKit" / "Sources" / "PrecinctDB.swift",
)

EXPECTED_HASHES = {
    BASE: "69b69457cce78b6766ec85a725cdbe06a0f651a95234ed489205e2baed839284",
    OR_CANDIDATE: "0d73d3921e9b1d6b0440de530e4ef872c2f52fe79eccc785f6cd30216044826d",
    CO_CANDIDATE: "562ef558227b04a0151f870b72044beaf399ad29fa175f48cdc8627fab321942",
    PHASE2B_REPORT: "575dff51cfb3189150995231d86c2ba33af756e97013a0422cb82fac797882d3",
    PROTECTED_SNAPSHOT: "f7882aa81d43315a2fb4524e10ce2e51c1d38eefe0241bc366075f7e56388f5e",
    SOURCE: "3c62500fd65c536adaa055d17f5075e238754d75a42e7cc10cf238e64119e684",
}

EXPECTED_COUNTS = {
    "precincts": 54_718,
    "precinct_rtree": 54_718,
    "precinct_elections": 370_315,
    "baselines": 511,
    "county_lean_regions": 1_500,
}
EXPECTED_BASE_STATE_COUNTS = {
    "CA": 23_910, "DC": 144, "MA": 2_152, "MD": 586,
    "NY": 14_011, "TX": 8_872, "VA": 580,
}
EXPECTED_ALL_STATES = ("CA", "CO", "DC", "MA", "MD", "NY", "OR", "TX", "VA")
EXPECTED_STATE_COUNTS = {**EXPECTED_BASE_STATE_COUNTS, "OR": 1_300, "CO": 3_163}
EXPECTED_YEARS = {
    "OR": {2020: 1_296, 2016: 1, None: 3},
    "CO": {2024: 3_138, 2020: 21, None: 4},
}
EXPECTED_NULL_UNITS = {
    "OR": {"41005-:-X000", "41027-:-XXXX", "41045-:-0019"},
    "CO": {
        "08005-:-6276103288", "08005-:-4276103350",
        "08005-:-6283603359", "08035-:-4303918103",
    },
}
EXPECTED_APPLICATION_OBJECTS = {
    ("table", "precincts", "precincts"),
    ("table", "precinct_elections", "precinct_elections"),
    ("table", "baselines", "baselines"),
    ("table", "precinct_rtree", "precinct_rtree"),
    ("table", "precinct_rtree_node", "precinct_rtree_node"),
    ("table", "precinct_rtree_parent", "precinct_rtree_parent"),
    ("table", "precinct_rtree_rowid", "precinct_rtree_rowid"),
    ("table", "county_lean_regions", "county_lean_regions"),
    ("index", "idx_precincts_unit", "precincts"),
    ("index", "idx_precincts_state", "precincts"),
    ("index", "idx_pe_unit", "precinct_elections"),
    ("index", "idx_clr_scope", "county_lean_regions"),
    ("index", "sqlite_autoindex_baselines_1", "baselines"),
    ("index", "sqlite_autoindex_precincts_1", "precincts"),
    ("table", "sqlite_stat1", "sqlite_stat1"),
}

EXPECTED_COLUMNS = {
    "precincts": (
        ("rowid", "INTEGER", 0, 1), ("unit_id", "TEXT", 0, 0),
        ("fips", "TEXT", 0, 0), ("state", "TEXT", 0, 0),
        ("borough", "TEXT", 0, 0), ("precinct_name", "TEXT", 0, 0),
        ("min_lon", "REAL", 0, 0), ("min_lat", "REAL", 0, 0),
        ("max_lon", "REAL", 0, 0), ("max_lat", "REAL", 0, 0),
        ("geometry_wkb", "BLOB", 0, 0), ("lean_dem_share", "REAL", 0, 0),
        ("prev_dem_share", "REAL", 0, 0), ("lean_year", "INT", 0, 0),
        ("prev_year", "INT", 0, 0), ("lean_label", "TEXT", 0, 0),
        ("lean_shift", "REAL", 0, 0), ("lean_votes", "INT", 0, 0),
        ("turnout_est", "REAL", 0, 0), ("pop_total", "INT", 0, 0),
        ("vap_total", "INT", 0, 0), ("cvap", "INT", 0, 0),
        ("pct_white", "REAL", 0, 0), ("pct_black", "REAL", 0, 0),
        ("pct_hispanic", "REAL", 0, 0), ("pct_asian", "REAL", 0, 0),
        ("pct_native", "REAL", 0, 0), ("pct_pacific", "REAL", 0, 0),
        ("pct_other", "REAL", 0, 0), ("plurality_group", "TEXT", 0, 0),
        ("pct_no_hs", "REAL", 0, 0), ("pct_hs", "REAL", 0, 0),
        ("pct_bachelors", "REAL", 0, 0), ("pct_graduate", "REAL", 0, 0),
        ("pct_ba_or_higher", "REAL", 0, 0), ("income_median", "INT", 0, 0),
        ("pop_density", "REAL", 0, 0), ("avg_age", "REAL", 0, 0),
        ("pct_renter", "REAL", 0, 0), ("pct_owner", "REAL", 0, 0),
        ("data_complete", "INT", 0, 0),
    ),
    "precinct_elections": (
        ("unit_id", "TEXT", 0, 0), ("office", "TEXT", 0, 0),
        ("year", "INT", 0, 0), ("dem", "INT", 0, 0),
        ("rep", "INT", 0, 0), ("other", "INT", 0, 0),
        ("dem_share", "REAL", 0, 0),
    ),
    "baselines": (
        ("scope", "TEXT", 0, 1), ("pop_total", "INT", 0, 0),
        ("pct_white", "REAL", 0, 0), ("pct_black", "REAL", 0, 0),
        ("pct_hispanic", "REAL", 0, 0), ("pct_asian", "REAL", 0, 0),
        ("pct_native", "REAL", 0, 0), ("pct_pacific", "REAL", 0, 0),
        ("pct_other", "REAL", 0, 0), ("pct_ba_or_higher", "REAL", 0, 0),
        ("income_median", "INT", 0, 0), ("pct_renter", "REAL", 0, 0),
        ("avg_age", "REAL", 0, 0), ("pres24_dem_share", "REAL", 0, 0),
        ("precinct_count", "INTEGER", 0, 0),
        ("political_precinct_count", "INTEGER", 0, 0),
    ),
    "precinct_rtree": (
        ("id", "INT", 0, 0), ("min_lon", "REAL", 0, 0),
        ("max_lon", "REAL", 0, 0), ("min_lat", "REAL", 0, 0),
        ("max_lat", "REAL", 0, 0),
    ),
    "county_lean_regions": (
        ("rowid", "INTEGER", 0, 1), ("state", "TEXT", 0, 0),
        ("borough", "TEXT", 0, 0), ("lean_label", "TEXT", 0, 0),
        ("dem_share", "REAL", 0, 0), ("min_lon", "REAL", 0, 0),
        ("min_lat", "REAL", 0, 0), ("max_lon", "REAL", 0, 0),
        ("max_lat", "REAL", 0, 0), ("geometry_wkb", "BLOB", 0, 0),
    ),
}


class VerificationError(RuntimeError):
    """Raised when the combined artifact violates the approved contract."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_exact_path(raw: str | Path, expected: Path, *, output: bool = False) -> Path:
    path = Path(os.path.abspath(Path(raw).expanduser()))
    exact = Path(os.path.abspath(expected))
    require(path == exact, f"path must be exactly {expected}")
    current = path
    while True:
        require(not current.is_symlink(), f"path component cannot be a symlink: {current}")
        if current == current.parent:
            break
        current = current.parent
    if output:
        require(path.parent == OUTPUT_DIR, "report escaped the Phase 3 output directory")
        require(not path.exists() or path.is_file(), f"report must be a regular file: {path}")
    else:
        require(path.exists(), f"missing required input: {path}")
        mode = path.stat(follow_symlinks=False).st_mode
        require(stat.S_ISREG(mode), f"input must be a regular file: {path}")
    return path


def verify_protected_boundary(snapshot_path: Path) -> dict[str, Any]:
    document = json.loads(snapshot_path.read_text(encoding="utf-8"))
    require(document.get("schema_version") == 1, "protected snapshot schema is unknown")
    files = document.get("files")
    require(isinstance(files, dict) and files, "protected snapshot file set is missing")
    mismatches = []
    root = Path(os.path.abspath(ROOT))
    for relative, expected in sorted(files.items()):
        path = Path(os.path.abspath(ROOT / relative))
        require(path != root and root in path.parents, f"protected path escaped the repository: {relative}")
        safe_exact_path(path, path)
        actual = sha256(path)
        if actual != expected:
            mismatches.append({"path": relative, "expected": expected, "actual": actual})
    require(not mismatches, f"protected boundary changed: {mismatches}")
    return {
        "file_count": len(files),
        "mismatch_count": 0,
        "snapshot_sha256": EXPECTED_HASHES[PROTECTED_SNAPSHOT],
    }


def verify_hash(path: Path, expected: str) -> str:
    actual = sha256(path)
    try:
        label = str(path.relative_to(ROOT))
    except ValueError:
        label = path.name
    require(actual == expected, f"SHA256 mismatch for {label}: {actual}")
    return actual


def connect_read_only(path: Path) -> sqlite3.Connection:
    safe_exact_path(path, path)
    connection = sqlite3.connect(f"file:{path}?mode=ro&immutable=1", uri=True)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only=ON")
    require(connection.execute("PRAGMA query_only").fetchone()[0] == 1, "query_only was not enabled")
    return connection


def table_columns(connection: sqlite3.Connection, table: str) -> tuple[tuple[Any, ...], ...]:
    return tuple((row[1], row[2].upper(), row[3], row[5]) for row in connection.execute(f"PRAGMA table_info({table})"))


def normalize_schema_sql(value: str | None) -> str | None:
    return " ".join(value.split()) if value is not None else None


def verify_schema(connection: sqlite3.Connection, base: sqlite3.Connection | None = None) -> dict[str, Any]:
    integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    quick = connection.execute("PRAGMA quick_check").fetchone()[0]
    require(integrity == "ok", f"combined integrity_check returned {integrity!r}")
    require(quick == "ok", f"combined quick_check returned {quick!r}")
    objects = {(row[0], row[1], row[2]) for row in connection.execute(
        "SELECT type,name,tbl_name FROM sqlite_master ORDER BY type,name"
    )}
    require(objects == EXPECTED_APPLICATION_OBJECTS,
            f"unexpected schema objects: missing={sorted(EXPECTED_APPLICATION_OBJECTS-objects)}, extra={sorted(objects-EXPECTED_APPLICATION_OBJECTS)}")
    for table, expected in EXPECTED_COLUMNS.items():
        actual = table_columns(connection, table)
        require(actual == expected, f"{table} exact column schema mismatch")
    unique_unit = connection.execute("PRAGMA index_list(precincts)").fetchall()
    require(any(row[2] == 1 and row[3] == "u" for row in unique_unit), "precincts.unit_id UNIQUE constraint missing")
    index_columns = {
        "idx_precincts_unit": ("unit_id",),
        "idx_precincts_state": ("state", "borough"),
        "idx_pe_unit": ("unit_id",),
        "idx_clr_scope": ("state", "borough"),
    }
    for name, expected in index_columns.items():
        actual = tuple(row[2] for row in connection.execute(f"PRAGMA index_info({name})"))
        require(actual == expected, f"index {name} column mismatch")
    if base is not None:
        protected_names = {
            "precincts", "precinct_elections", "precinct_rtree",
            "county_lean_regions", "idx_precincts_unit", "idx_precincts_state",
            "idx_pe_unit", "idx_clr_scope",
        }
        base_sql = {
            row[0]: normalize_schema_sql(row[1])
            for row in base.execute(
                "SELECT name,sql FROM sqlite_master WHERE name IN (%s)" %
                ",".join("?" for _ in protected_names), tuple(sorted(protected_names))
            )
        }
        combined_sql = {
            row[0]: normalize_schema_sql(row[1])
            for row in connection.execute(
                "SELECT name,sql FROM sqlite_master WHERE name IN (%s)" %
                ",".join("?" for _ in protected_names), tuple(sorted(protected_names))
            )
        }
        require(combined_sql == base_sql, "a pre-existing application schema definition changed")
        base_baseline_sql = normalize_schema_sql(base.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='baselines'"
        ).fetchone()[0])
        combined_baseline_sql = normalize_schema_sql(connection.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='baselines'"
        ).fetchone()[0])
        expected_baseline_sql = base_baseline_sql[:-1] + ", political_precinct_count INTEGER)"
        require(combined_baseline_sql == expected_baseline_sql,
                "baselines schema is not the exact nullable political_precinct_count additive change")
    return {"integrity_check": integrity, "quick_check": quick,
            "application_objects": [list(value) for value in sorted(objects)]}


def rows(connection: sqlite3.Connection, sql: str, parameters: Sequence[Any] = ()) -> list[tuple[Any, ...]]:
    return [tuple(row) for row in connection.execute(sql, parameters)]


def require_equal_rows(label: str, expected: Iterable[tuple[Any, ...]], actual: Iterable[tuple[Any, ...]]) -> int:
    expected_rows = list(expected)
    actual_rows = list(actual)
    require(len(actual_rows) == len(expected_rows),
            f"{label} row count mismatch: expected {len(expected_rows)}, found {len(actual_rows)}")
    for index, (left, right) in enumerate(zip(expected_rows, actual_rows)):
        require(left == right, f"{label} differs at sorted row {index}: expected {left[:3]!r}, found {right[:3]!r}")
    return len(actual_rows)


def verify_base_preservation(base: sqlite3.Connection, combined: sqlite3.Connection) -> dict[str, Any]:
    base_columns = [row[1] for row in base.execute("PRAGMA table_info(precincts)")]
    select_precincts = ",".join(base_columns)
    precinct_count = require_equal_rows(
        "base precincts",
        rows(base, f"SELECT {select_precincts} FROM precincts ORDER BY rowid"),
        rows(combined, f"SELECT {select_precincts} FROM precincts WHERE state NOT IN ('OR','CO') ORDER BY rowid"),
    )
    election_count = require_equal_rows(
        "base precinct_elections",
        rows(base, "SELECT * FROM precinct_elections ORDER BY unit_id,office,year,dem,rep,other,dem_share"),
        rows(combined, "SELECT e.* FROM precinct_elections e JOIN precincts p USING(unit_id) WHERE p.state NOT IN ('OR','CO') ORDER BY e.unit_id,e.office,e.year,e.dem,e.rep,e.other,e.dem_share"),
    )
    base_baseline_columns = [row[1] for row in base.execute("PRAGMA table_info(baselines)")]
    select_baselines = ",".join(base_baseline_columns)
    baseline_count = require_equal_rows(
        "base baselines",
        rows(base, f"SELECT {select_baselines} FROM baselines ORDER BY scope"),
        rows(combined, f"SELECT {select_baselines} FROM baselines WHERE scope NOT IN ('OR','CO') AND scope NOT LIKE 'county|OR|%' AND scope NOT LIKE 'county|CO|%' ORDER BY scope"),
    )
    nonnull = combined.execute(
        "SELECT COUNT(*) FROM baselines WHERE scope NOT IN ('OR','CO') "
        "AND scope NOT LIKE 'county|OR|%' AND scope NOT LIKE 'county|CO|%' "
        "AND political_precinct_count IS NOT NULL"
    ).fetchone()[0]
    require(nonnull == 0, "a pre-existing baseline has non-NULL political_precinct_count")
    rtree_count = require_equal_rows(
        "base precinct_rtree",
        rows(base, "SELECT * FROM precinct_rtree ORDER BY id"),
        rows(combined, "SELECT r.* FROM precinct_rtree r JOIN precincts p ON p.rowid=r.id WHERE p.state NOT IN ('OR','CO') ORDER BY r.id"),
    )
    region_count = require_equal_rows(
        "base county_lean_regions",
        rows(base, "SELECT * FROM county_lean_regions ORDER BY rowid"),
        rows(combined, "SELECT * FROM county_lean_regions WHERE state NOT IN ('OR','CO') ORDER BY rowid"),
    )
    expected_ids = rows(base, "SELECT state,unit_id FROM precincts ORDER BY state,unit_id")
    actual_ids = rows(combined, "SELECT state,unit_id FROM precincts WHERE state NOT IN ('OR','CO') ORDER BY state,unit_id")
    require(expected_ids == actual_ids, "base state unit ID sets changed")
    actual_state_counts = dict(rows(combined, "SELECT state,COUNT(*) FROM precincts WHERE state NOT IN ('OR','CO') GROUP BY state"))
    require(actual_state_counts == EXPECTED_BASE_STATE_COUNTS, f"base state counts changed: {actual_state_counts}")
    return {
        "precincts": precinct_count, "precinct_elections": election_count,
        "baselines": baseline_count, "precinct_rtree": rtree_count,
        "county_lean_regions": region_count, "state_counts": actual_state_counts,
        "base_baseline_political_precinct_count": None,
    }


def candidate_scope_filter(state: str) -> tuple[str, tuple[str, str]]:
    return "scope=? OR scope LIKE ?", (state, f"county|{state}|%")


def verify_candidate_mapping(candidate: sqlite3.Connection, combined: sqlite3.Connection, state: str) -> dict[str, Any]:
    foreign = candidate.execute("SELECT COUNT(*) FROM precincts WHERE state<>?", (state,)).fetchone()[0]
    require(foreign == 0, f"{state} candidate contains foreign state rows")
    candidate_columns = [row[1] for row in candidate.execute("PRAGMA table_info(precincts)") if row[1] != "rowid"]
    select_columns = ",".join(candidate_columns)
    precinct_count = require_equal_rows(
        f"{state} mapped precincts",
        rows(candidate, f"SELECT {select_columns} FROM precincts ORDER BY unit_id"),
        rows(combined, f"SELECT {select_columns} FROM precincts WHERE state=? ORDER BY unit_id", (state,)),
    )
    candidate_ids = {row[0]: row[1] for row in candidate.execute("SELECT unit_id,rowid FROM precincts")}
    combined_ids = {row[0]: row[1] for row in combined.execute("SELECT unit_id,rowid FROM precincts WHERE state=?", (state,))}
    require(set(candidate_ids) == set(combined_ids), f"{state} unit identity mapping differs")
    election_count = require_equal_rows(
        f"{state} mapped elections",
        rows(candidate, "SELECT * FROM precinct_elections ORDER BY unit_id,office,year,dem,rep,other,dem_share"),
        rows(combined, "SELECT e.* FROM precinct_elections e JOIN precincts p USING(unit_id) WHERE p.state=? ORDER BY e.unit_id,e.office,e.year,e.dem,e.rep,e.other,e.dem_share", (state,)),
    )
    scope_sql, scope_parameters = candidate_scope_filter(state)
    candidate_baseline_columns = [row[1] for row in candidate.execute("PRAGMA table_info(baselines)")]
    baseline_select = ",".join(candidate_baseline_columns)
    baseline_count = require_equal_rows(
        f"{state} mapped baselines",
        rows(candidate, f"SELECT {baseline_select} FROM baselines ORDER BY scope"),
        rows(combined, f"SELECT {baseline_select} FROM baselines WHERE {scope_sql} ORDER BY scope", scope_parameters),
    )
    candidate_regions = rows(candidate, "SELECT state,borough,lean_label,dem_share,min_lon,min_lat,max_lon,max_lat,geometry_wkb FROM county_lean_regions ORDER BY state,borough,lean_label")
    combined_regions = rows(combined, "SELECT state,borough,lean_label,dem_share,min_lon,min_lat,max_lon,max_lat,geometry_wkb FROM county_lean_regions WHERE state=? ORDER BY state,borough,lean_label", (state,))
    region_count = require_equal_rows(f"{state} mapped regions", candidate_regions, combined_regions)
    candidate_rtree = {
        row[0]: tuple(row[1:])
        for row in candidate.execute(
            "SELECT p.unit_id,r.min_lon,r.max_lon,r.min_lat,r.max_lat FROM precinct_rtree r JOIN precincts p ON p.rowid=r.id ORDER BY p.unit_id"
        )
    }
    combined_rtree = {
        row[0]: tuple(row[1:])
        for row in combined.execute(
            "SELECT p.unit_id,r.min_lon,r.max_lon,r.min_lat,r.max_lat FROM precinct_rtree r JOIN precincts p ON p.rowid=r.id WHERE p.state=? ORDER BY p.unit_id", (state,)
        )
    }
    require(candidate_rtree == combined_rtree, f"{state} mapped R-tree values differ")
    collisions = combined.execute(
        "SELECT COUNT(*) FROM precincts WHERE state<>? AND unit_id IN (SELECT unit_id FROM precincts WHERE state=?)",
        (state, state),
    ).fetchone()[0]
    require(collisions == 0, f"{state} unit IDs collide with another state")
    return {
        "precincts": precinct_count, "precinct_elections": election_count,
        "baselines": baseline_count, "county_lean_regions": region_count,
        "precinct_rtree": len(combined_rtree), "rowids_remapped": candidate_ids != combined_ids,
        "state_isolation": "PASS", "scope_isolation": "PASS",
    }


def isolated_state_view(combined: sqlite3.Connection, state: str) -> sqlite3.Connection:
    """Copy combined origin rows into an isolated in-memory state artifact."""
    view = sqlite3.connect(":memory:")
    combined.backup(view)
    view.row_factory = sqlite3.Row
    view.execute("DELETE FROM precinct_rtree WHERE id NOT IN (SELECT rowid FROM precincts WHERE state=?)", (state,))
    view.execute("DELETE FROM precinct_elections WHERE unit_id NOT IN (SELECT unit_id FROM precincts WHERE state=?)", (state,))
    view.execute("DELETE FROM baselines WHERE NOT (scope=? OR scope LIKE ?)", (state, f"county|{state}|%"))
    view.execute("DELETE FROM county_lean_regions WHERE state<>?", (state,))
    view.execute("DELETE FROM precincts WHERE state<>?", (state,))
    return view


def verify_phase2b_invariants(combined: sqlite3.Connection, source: sqlite3.Connection, state: str) -> dict[str, Any]:
    view = isolated_state_view(combined, state)
    try:
        report: dict[str, Any] = {"schema": phase2b.verify_schema(view, state)}
        source_rows, geometries, elections, weights, repairs = phase2b.verify_source_and_rows(view, source, state)
        report["source_and_rows"] = source_rows
        report["elections"] = phase2b.verify_election_table(view, state, elections)
        report["rtree_and_lookup"] = phase2b.verify_rtree_and_lookup(view, state, geometries)
        report["baselines"] = phase2b.verify_baselines(view, state, weights)
        report["lean_regions"] = phase2b.verify_regions(view, state, geometries)
        report["app_shaped_queries"] = phase2b.verify_app_queries(view, state)
        ledger = CANDIDATE_DIR / f"{state.lower()}_geometry_repairs.json"
        safe_exact_path(ledger, ledger)
        report["geometry_repairs"] = phase2b.verify_repair_ledger(ledger, state, repairs)
        report["exact_source_transform_wkb"] = verify_exact_source_wkb(view, source, state)
        return report
    finally:
        view.close()


def verify_exact_source_wkb(
    state_view: sqlite3.Connection,
    source: sqlite3.Connection,
    state: str,
) -> dict[str, Any]:
    source_rows = source.execute(
        """
        SELECT DISTINCT p.unit_id,p.geometry
        FROM precincts p JOIN demographics d ON d.unit_id=p.unit_id
        WHERE p.state_abbr=? AND d.variable='pop_total'
          AND d.vintage LIKE 'decennial%' AND d.value>0
        ORDER BY p.unit_id
        """,
        (state,),
    ).fetchall()
    source_geometries: dict[str, set[bytes | str]] = {}
    for unit_id, geometry in source_rows:
        value = bytes(geometry) if not isinstance(geometry, str) else geometry
        source_geometries.setdefault(unit_id, set()).add(value)
    require(all(len(values) == 1 for values in source_geometries.values()),
            f"{state}: ambiguous source geometry while checking exact WKB")
    combined_rows = state_view.execute(
        "SELECT unit_id,geometry_wkb FROM precincts ORDER BY unit_id"
    ).fetchall()
    require(set(source_geometries) == {row[0] for row in combined_rows},
            f"{state}: exact-WKB source unit set differs")
    transformer = Transformer.from_crs(
        phase2b.SOURCE_CRS, phase2b.DESTINATION_CRS, always_xy=True
    )
    for unit_id, actual_blob in combined_rows:
        geometry = phase2b.parse_geometry(next(iter(source_geometries[unit_id])))
        if not geometry.is_valid:
            geometry = phase2b.polygonal_only(
                make_valid(geometry, method="linework", keep_collapsed=True)
            )
        require(geometry is not None and geometry.is_valid,
                f"{state} {unit_id}: source geometry cannot produce exact WKB")
        transformed = geometry_transform(transformer.transform, geometry)
        simplified = transformed.simplify(
            phase2b.SIMPLIFY_TOLERANCE, preserve_topology=True
        )
        require(bytes(actual_blob) == simplified.wkb,
                f"{state} {unit_id}: exact source transform/simplification WKB differs")
    return {"byte_exact_rows": len(combined_rows), "result": "PASS"}


def verify_phase2b_evidence(phase2b_report: Path) -> dict[str, Any]:
    document = json.loads(phase2b_report.read_text(encoding="utf-8"))
    require(document.get("result") == "PASS", "Phase 2B verification report is not PASS")
    gate = document.get("release_gate", {})
    require(gate.get("status") == "BLOCKED" and gate.get("shipping_authorized") is False,
            "Phase 2B release gate is not blocked")
    require(set(document.get("states", {})) == {"OR", "CO"}, "Phase 2B report state set differs")
    for state in ("OR", "CO"):
        manifest_path = CANDIDATE_DIR / f"{state.lower()}_manifest.json"
        safe_exact_path(manifest_path, manifest_path)
        report_state = document["states"][state]
        require(sha256(manifest_path) == report_state["manifest"]["sha256"],
                f"{state} manifest differs from the immutable Phase 2B report")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest_gate = manifest.get("release_gate", {})
        require(manifest_gate.get("status") == "BLOCKED" and manifest_gate.get("shipping_authorized") is False,
                f"{state} manifest release gate is not blocked")
        require(manifest.get("source", {}).get("sha256") == EXPECTED_HASHES[SOURCE], f"{state} manifest source hash differs")
        ledger_path = CANDIDATE_DIR / manifest["geometry"]["repair_ledger"]
        safe_exact_path(ledger_path, ledger_path)
        require(sha256(ledger_path) == manifest["geometry"]["repair_ledger_sha256"],
                f"{state} repair ledger differs from the verified manifest")
    return {"result": "PASS", "sha256": EXPECTED_HASHES[PHASE2B_REPORT],
            "release_gate": {"status": "BLOCKED", "shipping_authorized": False}}


def verify_whole_counts(connection: sqlite3.Connection) -> dict[str, Any]:
    actual = {table: connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] for table in EXPECTED_COUNTS}
    require(actual == EXPECTED_COUNTS, f"whole combined counts differ: {actual}")
    states = tuple(row[0] for row in connection.execute("SELECT DISTINCT state FROM precincts ORDER BY state"))
    require(states == EXPECTED_ALL_STATES, f"combined state set differs: {states}")
    state_counts = dict(rows(connection, "SELECT state,COUNT(*) FROM precincts GROUP BY state ORDER BY state"))
    require(state_counts == EXPECTED_STATE_COUNTS, f"combined state counts differ: {state_counts}")
    years = {
        state: Counter({row[0]: row[1] for row in connection.execute(
            "SELECT lean_year,COUNT(*) FROM precincts WHERE state=? GROUP BY lean_year", (state,)
        )})
        for state in ("OR", "CO")
    }
    for state in ("OR", "CO"):
        require(dict(years[state]) == EXPECTED_YEARS[state], f"{state} selected-year counts differ")
    null_units = {
        state: {row[0] for row in connection.execute("SELECT unit_id FROM precincts WHERE state=? AND lean_year IS NULL", (state,))}
        for state in ("OR", "CO")
    }
    require(null_units == EXPECTED_NULL_UNITS, f"combined political null unit set differs: {null_units}")
    null_violations = connection.execute(
        "SELECT COUNT(*) FROM precincts WHERE state IN ('OR','CO') AND lean_year IS NULL AND "
        "(lean_dem_share IS NOT NULL OR prev_dem_share IS NOT NULL OR prev_year IS NOT NULL OR "
        "lean_label IS NOT NULL OR lean_shift IS NOT NULL OR lean_votes IS NOT NULL OR turnout_est IS NOT NULL OR data_complete<>0)"
    ).fetchone()[0]
    require(null_violations == 0, "a political-null profile has synthesized political fields")
    null_elections = connection.execute(
        "SELECT COUNT(*) FROM precinct_elections WHERE unit_id IN "
        "(SELECT unit_id FROM precincts WHERE state IN ('OR','CO') AND lean_year IS NULL)"
    ).fetchone()[0]
    require(null_elections == 0, "a political-null profile has election rows")
    fake_even = connection.execute(
        "SELECT COUNT(*) FROM precincts WHERE state IN ('OR','CO') AND lean_year IS NULL AND "
        "(lean_label='Even' OR lean_dem_share=0.5)"
    ).fetchone()[0]
    require(fake_even == 0, "a political-null profile was converted to fake Even/0.5")
    queryable = connection.execute(
        "SELECT COUNT(*) FROM precincts WHERE state IN ('OR','CO') AND lean_year IS NULL "
        "AND geometry_wkb IS NOT NULL AND pop_total>0 AND precinct_name IS NOT NULL"
    ).fetchone()[0]
    require(queryable == 7, "not all political-null profiles retain queryable demographics and geometry")
    return {**actual, "states": list(states), "state_counts": state_counts,
            "selected_years": {state: {"null" if key is None else str(key): value for key, value in sorted(years[state].items(), key=lambda item: str(item[0]))} for state in ("OR", "CO")},
            "political_null_count": 7, "political_null_units": {state: sorted(value) for state, value in null_units.items()}}


def parse_geometry(blob: Any):
    return wkb.loads(bytes(blob))


def strict_lookup(connection: sqlite3.Connection, lon: float, lat: float) -> sqlite3.Row | None:
    point = Point(lon, lat)
    candidates = connection.execute(
        "SELECT p.* FROM precinct_rtree r JOIN precincts p ON p.rowid=r.id "
        "WHERE ? BETWEEN r.min_lon AND r.max_lon AND ? BETWEEN r.min_lat AND r.max_lat "
        "ORDER BY p.data_complete DESC,(p.lean_dem_share IS NOT NULL) DESC,"
        "(p.pop_total IS NOT NULL AND p.pop_total>0) DESC,"
        "((p.max_lon-p.min_lon)*(p.max_lat-p.min_lat)) ASC,r.id ASC",
        (lon, lat),
    ).fetchall()
    return next((row for row in candidates if parse_geometry(row["geometry_wkb"]).contains(point)), None)


def representative_lookup_checks(connection: sqlite3.Connection) -> dict[str, Any]:
    candidate_counties = 0
    for state in ("OR", "CO"):
        county_rows = connection.execute(
            "SELECT borough,MIN(unit_id) FROM precincts WHERE state=? GROUP BY borough ORDER BY borough", (state,)
        ).fetchall()
        require(len(county_rows) == phase2b.EXPECTED[state]["counties"], f"{state} county count differs in lookup sample")
        candidate_counties += len(county_rows)
        for county, unit_id in county_rows:
            row = connection.execute("SELECT geometry_wkb FROM precincts WHERE unit_id=?", (unit_id,)).fetchone()
            point = parse_geometry(row[0]).representative_point()
            hit = strict_lookup(connection, point.x, point.y)
            require(hit is not None and hit["state"] == state and hit["borough"] == county,
                    f"{state} {county}: representative lookup did not resolve within county")
    existing_samples = 0
    for state in EXPECTED_BASE_STATE_COUNTS:
        state_rows = connection.execute(
            "SELECT unit_id,geometry_wkb FROM precincts WHERE state=? ORDER BY unit_id", (state,)
        ).fetchall()
        indexes = sorted({0, len(state_rows) // 2, len(state_rows) - 1})
        for index in indexes:
            unit_id, blob = state_rows[index]
            point = parse_geometry(blob).representative_point()
            hit = strict_lookup(connection, point.x, point.y)
            require(hit is not None and hit["unit_id"] == unit_id,
                    f"existing-state representative lookup differs for {unit_id}")
            existing_samples += 1
    return {"or_co_counties_resolved": candidate_counties, "existing_state_stratified_samples_resolved": existing_samples}


def swift_lookup_samples(connection: sqlite3.Connection) -> list[dict[str, Any]]:
    samples = []
    for state in ("OR", "CO"):
        county_rows = connection.execute(
            "SELECT borough,MIN(unit_id) FROM precincts WHERE state=? GROUP BY borough ORDER BY borough",
            (state,),
        ).fetchall()
        for county, unit_id in county_rows:
            blob = connection.execute(
                "SELECT geometry_wkb FROM precincts WHERE unit_id=?", (unit_id,)
            ).fetchone()[0]
            point = parse_geometry(blob).representative_point()
            samples.append({
                "mode": "county", "state": state, "county": county, "unitID": None,
                "longitude": point.x, "latitude": point.y,
            })
    for state in EXPECTED_BASE_STATE_COUNTS:
        state_rows = connection.execute(
            "SELECT unit_id,borough,geometry_wkb FROM precincts WHERE state=? ORDER BY unit_id",
            (state,),
        ).fetchall()
        indexes = sorted({0, len(state_rows) // 2, len(state_rows) - 1})
        for index in indexes:
            unit_id, county, blob = state_rows[index]
            point = parse_geometry(blob).representative_point()
            samples.append({
                "mode": "unit", "state": state, "county": county, "unitID": unit_id,
                "longitude": point.x, "latitude": point.y,
            })
    return samples


def verify_swift_app_contract(connection: sqlite3.Connection) -> dict[str, Any]:
    xcrun = shutil.which("xcrun")
    require(xcrun is not None, "xcrun is required for the Swift app-contract verification")
    for path in (*SWIFT_SOURCES, SWIFT_HARNESS):
        safe_exact_path(path, path)
    samples = swift_lookup_samples(connection)
    with tempfile.TemporaryDirectory(prefix="precinct-phase3-swift-") as directory:
        temporary = Path(directory).resolve()
        sample_path = temporary / "lookup_samples.json"
        executable = temporary / "phase3-swift-contract"
        sample_path.write_bytes(canonical_json(samples))
        compile_result = subprocess.run(
            [
                xcrun, "swiftc", "-O", "-module-name", "Phase3SwiftContract",
                *(str(path) for path in SWIFT_SOURCES), str(SWIFT_HARNESS),
                "-framework", "CoreLocation", "-lsqlite3", "-o", str(executable),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        require(
            compile_result.returncode == 0,
            f"Swift app-contract harness did not compile: {compile_result.stderr[-2000:]}",
        )
        run_result = subprocess.run(
            [str(executable), str(COMBINED), str(sample_path)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        require(
            run_result.returncode == 0,
            f"Swift app-contract harness failed: {run_result.stderr[-2000:]}",
        )
        try:
            result = json.loads(run_result.stdout)
        except json.JSONDecodeError as error:
            raise VerificationError(f"Swift app-contract output is invalid JSON: {error}") from error
    expected = {
        "candidate_county_samples": 100,
        "candidate_geometry_rows_decoded": 4_463,
        "candidate_political_null_profiles": 7,
        "candidate_region_rows_decoded": 310,
        "dmv_precinct_count": 1_310,
        "existing_state_samples": 21,
        "midway_search_fallback": "PASS",
        "result": "PASS",
    }
    require(result == expected, f"Swift app-contract summary differs: {result}")
    return result


def verify_baseline_and_query_behavior(connection: sqlite3.Connection) -> dict[str, Any]:
    resolution = {}
    for state in ("OR", "CO"):
        normal = connection.execute(
            "SELECT unit_id,borough FROM precincts WHERE state=? AND lean_year IS NOT NULL ORDER BY unit_id LIMIT 1", (state,)
        ).fetchone()
        null = connection.execute(
            "SELECT unit_id,borough FROM precincts WHERE state=? AND lean_year IS NULL ORDER BY unit_id LIMIT 1", (state,)
        ).fetchone()
        for kind, profile in (("normal", normal), ("null", null)):
            require(profile is not None, f"{state} lacks a {kind} profile")
            scopes = (state, f"county|{state}|{profile['borough']}")
            found = connection.execute("SELECT COUNT(*) FROM baselines WHERE scope IN (?,?)", scopes).fetchone()[0]
            require(found == 2, f"{state} {kind} profile baseline resolution failed")
            resolution[f"{state}_{kind}"] = profile["unit_id"]
        for field in ("lean_dem_share", "income_median", "pct_renter"):
            result = connection.execute(
                f"SELECT state,unit_id FROM precincts WHERE state=? AND {field} IS NOT NULL ORDER BY {field} DESC,unit_id LIMIT 100", (state,)
            ).fetchall()
            require(all(row[0] == state for row in result), f"{state} {field} leaderboard leaked another state")
    return {"baseline_resolution_profiles": resolution, "state_scoped_leaderboards": 6}


def midway_checks(connection: sqlite3.Connection) -> dict[str, Any]:
    lon, lat = -117.9863579, 33.7447024
    require(strict_lookup(connection, lon, lat) is None, "Midway City unexpectedly resolves by strict containment")
    max_meters = 10.0
    lat_delta = max_meters / 111_320.0
    lon_delta = max_meters / (111_320.0 * max(0.01, math.cos(math.radians(lat))))
    nearby = connection.execute(
        "SELECT p.unit_id,p.state,p.borough,p.geometry_wkb FROM precinct_rtree r "
        "JOIN precincts p ON p.rowid=r.id WHERE r.min_lon<=? AND r.max_lon>=? "
        "AND r.min_lat<=? AND r.max_lat>=? ORDER BY p.unit_id",
        (lon + lon_delta, lon - lon_delta, lat + lat_delta, lat - lat_delta),
    ).fetchall()
    origin = Point(0, 0)
    lon_scale = 111_320.0 * max(0.01, math.cos(math.radians(lat)))
    distances = []
    for row in nearby:
        geometry = parse_geometry(row["geometry_wkb"])
        local = geometry_transform(lambda x, y, z=None: ((x-lon)*lon_scale, (y-lat)*111_320.0), geometry)
        distance = local.boundary.distance(origin)
        if distance <= max_meters:
            distances.append((distance, row["unit_id"], row["state"], row["borough"]))
    distances.sort()
    require(len(distances) >= 2, "Midway City does not have two boundaries within 10 meters")
    require(len({entry[1] for entry in distances}) >= 2, "Midway City nearby boundaries are not distinct precincts")
    require(all(entry[2] == "CA" and entry[3] == "Orange" for entry in distances),
            "Midway City fallback candidates leak outside Orange County, CA")
    return {"strict_lookup": "MISS", "nearby_distinct_boundaries": len(distances),
            "nearest_distance_meters": distances[0][0], "maximum_snap_meters": max_meters,
            "fallback_preconditions": "PASS"}


def verify_dmv(connection: sqlite3.Connection, base: sqlite3.Connection) -> dict[str, Any]:
    count = connection.execute(
        "SELECT COUNT(*) FROM precincts WHERE unit_id LIKE '11001-%' OR unit_id LIKE '24031-%' "
        "OR unit_id LIKE '24033-%' OR unit_id LIKE '51013-%' OR unit_id LIKE '51059-%' "
        "OR unit_id LIKE '51107-%' OR unit_id LIKE '51153-%' OR unit_id LIKE '51510-%' "
        "OR unit_id LIKE '51600-%' OR unit_id LIKE '51610-%' OR unit_id LIKE '51683-%' "
        "OR unit_id LIKE '51685-%'"
    ).fetchone()[0]
    require(count == 1_310, f"DMV count changed: {count}")
    base_row = tuple(base.execute("SELECT * FROM baselines WHERE scope='region|DMV'").fetchone())
    combined_row = tuple(connection.execute(
        "SELECT scope,pop_total,pct_white,pct_black,pct_hispanic,pct_asian,pct_native,pct_pacific,pct_other,"
        "pct_ba_or_higher,income_median,pct_renter,avg_age,pres24_dem_share,precinct_count "
        "FROM baselines WHERE scope='region|DMV'"
    ).fetchone())
    require(combined_row == base_row, "region|DMV baseline changed")
    null_count = connection.execute(
        "SELECT political_precinct_count FROM baselines WHERE scope='region|DMV'"
    ).fetchone()[0]
    require(null_count is None, "region|DMV political_precinct_count must remain NULL")
    return {"precinct_count": count, "baseline_scope": "region|DMV", "baseline_unchanged": True}


def build_report(combined_hash: str, sections: dict[str, Any]) -> dict[str, Any]:
    return {
        "artifact_kind": "phase3_combined_evaluation_independent_verification",
        "authoritative": False,
        "combined_database": {
            "path": "public_data/phase3_evaluation/phase3_full_evaluation.sqlite",
            "sha256": combined_hash,
        },
        "input_hashes": {
            str(path.relative_to(ROOT)): digest
            for path, digest in sorted(EXPECTED_HASHES.items(), key=lambda item: str(item[0]))
        },
        "release_gate": {
            "reason": "Official 2024 polygon lineage and affirmative redistribution and App Store bundling rights remain unverified.",
            "shipping_authorized": False,
            "status": "BLOCKED",
        },
        "result": "PASS",
        "reproducible": True,
        "schema_version": 1,
        "verification": sections,
    }


def canonical_json(document: dict[str, Any]) -> bytes:
    return (json.dumps(document, indent=2, sort_keys=True, allow_nan=False) + "\n").encode("utf-8")


def write_report_atomic(path: Path, document: dict[str, Any]) -> None:
    safe_exact_path(path, REPORT, output=True)
    require(path.parent.is_dir(), f"missing Phase 3 output directory: {path.parent}")
    temporary = path.with_suffix(path.suffix + ".tmp")
    require(temporary == OUTPUT_DIR / "verification_report.json.tmp", "unexpected report staging path")
    require(not temporary.is_symlink(), "report staging path cannot be a symlink")
    require(not temporary.exists() or temporary.is_file(), "report staging path must be a regular file")
    with temporary.open("wb") as handle:
        handle.write(canonical_json(document))
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def verify_all() -> dict[str, Any]:
    require(Path.cwd().resolve() == ROOT, f"run from repository root: {ROOT}")
    for path, expected in EXPECTED_HASHES.items():
        safe_exact_path(path, path)
        verify_hash(path, expected)
    safe_exact_path(COMBINED, COMBINED)
    safe_exact_path(REPORT, REPORT, output=True)
    combined_hash = sha256(COMBINED)
    base = connect_read_only(BASE)
    combined = connect_read_only(COMBINED)
    source = connect_read_only(SOURCE)
    candidates = {"OR": connect_read_only(OR_CANDIDATE), "CO": connect_read_only(CO_CANDIDATE)}
    try:
        sections: dict[str, Any] = {}
        sections["protected_boundary"] = verify_protected_boundary(PROTECTED_SNAPSHOT)
        sections["schema"] = verify_schema(combined, base)
        sections["base_preservation"] = verify_base_preservation(base, combined)
        sections["candidate_mapping"] = {
            state: verify_candidate_mapping(candidates[state], combined, state) for state in ("OR", "CO")
        }
        sections["whole_artifact"] = verify_whole_counts(combined)
        sections["phase2b_evidence"] = verify_phase2b_evidence(PHASE2B_REPORT)
        sections["phase2b_invariants_recomputed_from_combined"] = {
            state: verify_phase2b_invariants(combined, source, state) for state in ("OR", "CO")
        }
        sections["representative_lookup"] = representative_lookup_checks(combined)
        sections["swift_app_contract"] = verify_swift_app_contract(combined)
        sections["app_query_behavior"] = verify_baseline_and_query_behavior(combined)
        sections["dmv"] = verify_dmv(combined, base)
        sections["midway_city"] = midway_checks(combined)
        return build_report(combined_hash, sections)
    finally:
        for candidate in candidates.values():
            candidate.close()
        source.close()
        combined.close()
        base.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", default=str(COMBINED))
    parser.add_argument("--report", default=str(REPORT))
    args = parser.parse_args()
    try:
        safe_exact_path(args.database, COMBINED)
        report_path = safe_exact_path(args.report, REPORT, output=True)
        document = verify_all()
        write_report_atomic(report_path, document)
    except VerificationError as error:
        parser.error(str(error))
    print(f"verification report: {report_path}")
    print("PHASE 3 COMBINED VERIFICATION PASS")


if __name__ == "__main__":
    main()
