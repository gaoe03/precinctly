#!/usr/bin/env python3
"""Build the guarded Phase 3 OR/CO full-database evaluation artifact.

This script never writes either repository SQLite. It copies the current shipping
database to a same-directory staging file, adds the already verified Oregon and
Colorado Phase 2B candidates in one transaction, verifies the staged result, and
atomically installs one disposable evaluation database.

Run from the repository root:

    python3 pipeline/phase3_build_full_evaluation.py
    python3 pipeline/phase3_build_full_evaluation.py --replace
"""

from __future__ import annotations

import argparse
from itertools import zip_longest
import hashlib
import os
from pathlib import Path
import shutil
import sqlite3
from typing import Callable, Iterable, Sequence


ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / "PrecinctWeather" / "PrecinctKit" / "Resources" / "nyc_precincts.sqlite"
PHASE2B_DIR = ROOT / "public_data" / "phase2b_candidates"
OR_CANDIDATE = PHASE2B_DIR / "or_fallback_candidate.sqlite"
CO_CANDIDATE = PHASE2B_DIR / "co_fallback_candidate.sqlite"
PHASE2B_REPORT = PHASE2B_DIR / "verification_report.json"
OUTPUT_DIR = ROOT / "public_data" / "phase3_evaluation"
OUTPUT = OUTPUT_DIR / "phase3_full_evaluation.sqlite"
STAGING = OUTPUT_DIR / ".phase3_full_evaluation.sqlite.tmp"

EXPECTED_HASHES = {
    BASE: "69b69457cce78b6766ec85a725cdbe06a0f651a95234ed489205e2baed839284",
    OR_CANDIDATE: "0d73d3921e9b1d6b0440de530e4ef872c2f52fe79eccc785f6cd30216044826d",
    CO_CANDIDATE: "562ef558227b04a0151f870b72044beaf399ad29fa175f48cdc8627fab321942",
    PHASE2B_REPORT: "575dff51cfb3189150995231d86c2ba33af756e97013a0422cb82fac797882d3",
}

CANDIDATES = (("OR", OR_CANDIDATE), ("CO", CO_CANDIDATE))
BASE_STATES = ("CA", "DC", "MA", "MD", "NY", "TX", "VA")
ALL_STATES = ("CA", "CO", "DC", "MA", "MD", "NY", "OR", "TX", "VA")
EXPECTED_COUNTS = {
    "base": {
        "precincts": 50_255,
        "precinct_elections": 343_640,
        "baselines": 409,
        "precinct_rtree": 50_255,
        "county_lean_regions": 1_190,
    },
    "OR": {
        "precincts": 1_300,
        "precinct_elections": 7_769,
        "baselines": 37,
        "precinct_rtree": 1_300,
        "county_lean_regions": 120,
        "counties": 36,
    },
    "CO": {
        "precincts": 3_163,
        "precinct_elections": 18_906,
        "baselines": 65,
        "precinct_rtree": 3_163,
        "county_lean_regions": 190,
        "counties": 64,
    },
    "combined": {
        "precincts": 54_718,
        "precinct_elections": 370_315,
        "baselines": 511,
        "precinct_rtree": 54_718,
        "county_lean_regions": 1_500,
    },
}

PRECINCT_COLUMNS = (
    "rowid", "unit_id", "fips", "state", "borough", "precinct_name",
    "min_lon", "min_lat", "max_lon", "max_lat", "geometry_wkb",
    "lean_dem_share", "prev_dem_share", "lean_year", "prev_year",
    "lean_label", "lean_shift", "lean_votes", "turnout_est", "pop_total",
    "vap_total", "cvap", "pct_white", "pct_black", "pct_hispanic",
    "pct_asian", "pct_native", "pct_pacific", "pct_other",
    "plurality_group", "pct_no_hs", "pct_hs", "pct_bachelors",
    "pct_graduate", "pct_ba_or_higher", "income_median", "pop_density",
    "avg_age", "pct_renter", "pct_owner", "data_complete",
)
PRECINCT_VALUE_COLUMNS = PRECINCT_COLUMNS[1:]
ELECTION_COLUMNS = ("unit_id", "office", "year", "dem", "rep", "other", "dem_share")
RTREE_COLUMNS = ("id", "min_lon", "max_lon", "min_lat", "max_lat")
REGION_COLUMNS = (
    "rowid", "state", "borough", "lean_label", "dem_share",
    "min_lon", "min_lat", "max_lon", "max_lat", "geometry_wkb",
)
REGION_VALUE_COLUMNS = REGION_COLUMNS[1:]
BASELINE_BASE_COLUMNS = (
    "scope", "pop_total", "pct_white", "pct_black", "pct_hispanic",
    "pct_asian", "pct_native", "pct_pacific", "pct_other",
    "pct_ba_or_higher", "income_median", "pct_renter", "avg_age",
    "pres24_dem_share", "precinct_count",
)
BASELINE_CANDIDATE_COLUMNS = (
    "scope", "precinct_count", "political_precinct_count", "pop_total",
    "pct_white", "pct_black", "pct_hispanic", "pct_asian", "pct_native",
    "pct_pacific", "pct_other", "pct_ba_or_higher", "income_median",
    "pct_renter", "avg_age", "pres24_dem_share",
)
BASELINE_COMBINED_COLUMNS = (*BASELINE_BASE_COLUMNS, "political_precinct_count")

BASE_TABLE_INFO = {
    "precincts": (
        ("rowid", "INTEGER", 0, None, 1),
        *((name, "TEXT", 0, None, 0) for name in ("unit_id", "fips", "state", "borough", "precinct_name")),
        *((name, "REAL", 0, None, 0) for name in ("min_lon", "min_lat", "max_lon", "max_lat")),
        ("geometry_wkb", "BLOB", 0, None, 0),
        *((name, "REAL", 0, None, 0) for name in ("lean_dem_share", "prev_dem_share")),
        *((name, "INT", 0, None, 0) for name in ("lean_year", "prev_year")),
        ("lean_label", "TEXT", 0, None, 0),
        ("lean_shift", "REAL", 0, None, 0),
        ("lean_votes", "INT", 0, None, 0),
        ("turnout_est", "REAL", 0, None, 0),
        *((name, "INT", 0, None, 0) for name in ("pop_total", "vap_total", "cvap")),
        *((name, "REAL", 0, None, 0) for name in (
            "pct_white", "pct_black", "pct_hispanic", "pct_asian", "pct_native",
            "pct_pacific", "pct_other",
        )),
        ("plurality_group", "TEXT", 0, None, 0),
        *((name, "REAL", 0, None, 0) for name in (
            "pct_no_hs", "pct_hs", "pct_bachelors", "pct_graduate",
            "pct_ba_or_higher",
        )),
        ("income_median", "INT", 0, None, 0),
        *((name, "REAL", 0, None, 0) for name in ("pop_density", "avg_age", "pct_renter", "pct_owner")),
        ("data_complete", "INT", 0, None, 0),
    ),
    "precinct_elections": tuple(
        (name, "TEXT" if name in {"unit_id", "office"} else "REAL" if name == "dem_share" else "INT", 0, None, 0)
        for name in ELECTION_COLUMNS
    ),
    "precinct_rtree": (
        ("id", "INT", 0, None, 0),
        ("min_lon", "REAL", 0, None, 0),
        ("max_lon", "REAL", 0, None, 0),
        ("min_lat", "REAL", 0, None, 0),
        ("max_lat", "REAL", 0, None, 0),
    ),
    "county_lean_regions": (
        ("rowid", "INTEGER", 0, None, 1),
        ("state", "TEXT", 0, None, 0),
        ("borough", "TEXT", 0, None, 0),
        ("lean_label", "TEXT", 0, None, 0),
        ("dem_share", "REAL", 0, None, 0),
        ("min_lon", "REAL", 0, None, 0),
        ("min_lat", "REAL", 0, None, 0),
        ("max_lon", "REAL", 0, None, 0),
        ("max_lat", "REAL", 0, None, 0),
        ("geometry_wkb", "BLOB", 0, None, 0),
    ),
}
BASE_BASELINE_INFO = tuple(
    (
        name,
        "TEXT" if name == "scope" else "INTEGER" if name == "precinct_count" else "INT" if name in {"pop_total", "income_median"} else "REAL",
        0,
        None,
        1 if name == "scope" else 0,
    )
    for name in BASELINE_BASE_COLUMNS
)
CANDIDATE_BASELINE_INFO = tuple(
    (
        name,
        "TEXT" if name == "scope" else "INT" if name in {"precinct_count", "political_precinct_count", "pop_total", "income_median"} else "REAL",
        0,
        None,
        1 if name == "scope" else 0,
    )
    for name in BASELINE_CANDIDATE_COLUMNS
)
COMBINED_BASELINE_INFO = (*BASE_BASELINE_INFO, ("political_precinct_count", "INTEGER", 0, None, 0))

EXPECTED_SCHEMA_OBJECTS = {
    ("index", "idx_clr_scope", "county_lean_regions"),
    ("index", "idx_pe_unit", "precinct_elections"),
    ("index", "idx_precincts_state", "precincts"),
    ("index", "idx_precincts_unit", "precincts"),
    ("index", "sqlite_autoindex_baselines_1", "baselines"),
    ("index", "sqlite_autoindex_precincts_1", "precincts"),
    ("table", "baselines", "baselines"),
    ("table", "county_lean_regions", "county_lean_regions"),
    ("table", "precinct_elections", "precinct_elections"),
    ("table", "precinct_rtree", "precinct_rtree"),
    ("table", "precinct_rtree_node", "precinct_rtree_node"),
    ("table", "precinct_rtree_parent", "precinct_rtree_parent"),
    ("table", "precinct_rtree_rowid", "precinct_rtree_rowid"),
    ("table", "precincts", "precincts"),
    ("table", "sqlite_stat1", "sqlite_stat1"),
}
EXPECTED_INDEX_COLUMNS = {
    "idx_clr_scope": ("state", "borough"),
    "idx_pe_unit": ("unit_id",),
    "idx_precincts_state": ("state", "borough"),
    "idx_precincts_unit": ("unit_id",),
    "sqlite_autoindex_baselines_1": ("scope",),
    "sqlite_autoindex_precincts_1": ("unit_id",),
}


class Phase3MergeError(RuntimeError):
    """Raised before an unverified Phase 3 database can be installed."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise Phase3MergeError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_regular_hash(path: Path, expected: str) -> None:
    require(not path.is_symlink(), f"refusing symlinked input: {path}")
    require(path.is_file(), f"missing regular input: {path}")
    actual = sha256(path)
    require(actual == expected, f"input hash mismatch for {path}: expected {expected}, found {actual}")


def _existing_path_has_symlink(path: Path) -> bool:
    current = path
    while current != current.parent:
        if current.exists() and current.is_symlink():
            return True
        current = current.parent
    return False


def safe_output(raw: str) -> Path:
    path = Path(os.path.abspath(Path(raw).expanduser()))
    expected = Path(os.path.abspath(OUTPUT))
    if path != expected:
        raise argparse.ArgumentTypeError(f"unsafe output path. Only {OUTPUT} is permitted")
    if _existing_path_has_symlink(path.parent) or path.is_symlink():
        raise argparse.ArgumentTypeError("Phase 3 output path cannot contain a symlink")
    return path


def connect_read_only(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(f"file:{path}?mode=ro&immutable=1", uri=True)
    connection.execute("PRAGMA query_only=ON")
    return connection


def table_info(connection: sqlite3.Connection, table: str) -> tuple[tuple[object, ...], ...]:
    return tuple(tuple(row[1:6]) for row in connection.execute(f"PRAGMA table_info({table})"))


def verify_schema(connection: sqlite3.Connection, kind: str) -> None:
    objects = {
        (row[0], row[1], row[2])
        for row in connection.execute(
            "SELECT type,name,tbl_name FROM sqlite_master ORDER BY type,name"
        )
    }
    require(objects == EXPECTED_SCHEMA_OBJECTS, f"{kind}: unexpected schema objects: {sorted(objects ^ EXPECTED_SCHEMA_OBJECTS)}")
    for table, expected in BASE_TABLE_INFO.items():
        require(table_info(connection, table) == expected, f"{kind}: {table} schema mismatch")
    expected_baselines = (
        BASE_BASELINE_INFO if kind == "base"
        else CANDIDATE_BASELINE_INFO if kind == "candidate"
        else COMBINED_BASELINE_INFO
    )
    require(table_info(connection, "baselines") == expected_baselines, f"{kind}: baselines schema mismatch")
    for index, expected in EXPECTED_INDEX_COLUMNS.items():
        actual = tuple(row[2] for row in connection.execute(f"PRAGMA index_info({index})"))
        require(actual == expected, f"{kind}: {index} definition mismatch")
    rtree_sql = connection.execute(
        "SELECT lower(replace(replace(replace(sql,char(10),' '),'  ',' '),'  ',' ')) "
        "FROM sqlite_master WHERE name='precinct_rtree'"
    ).fetchone()[0]
    require("using rtree" in rtree_sql and all(name in rtree_sql for name in RTREE_COLUMNS), f"{kind}: precinct_rtree definition mismatch")


def table_counts(connection: sqlite3.Connection) -> dict[str, int]:
    return {
        table: int(connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])
        for table in EXPECTED_COUNTS["combined"]
    }


def verify_input_database(connection: sqlite3.Connection, kind: str, expected_counts: dict[str, int]) -> None:
    verify_schema(connection, kind)
    require(connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok", f"{kind}: integrity_check failed")
    require(connection.execute("PRAGMA quick_check").fetchone()[0] == "ok", f"{kind}: quick_check failed")
    require(table_counts(connection) == {key: expected_counts[key] for key in EXPECTED_COUNTS["combined"]}, f"{kind}: table counts drifted")


def allocate_rowids(old_ids: Iterable[int], start: int) -> dict[int, int]:
    mapping: dict[int, int] = {}
    next_id = start
    for old_id in old_ids:
        require(old_id not in mapping, f"duplicate source rowid: {old_id}")
        mapping[old_id] = next_id
        next_id += 1
    return mapping


def placeholders(count: int) -> str:
    return ",".join("?" for _ in range(count))


def verify_candidate_contract(connection: sqlite3.Connection, state: str) -> None:
    verify_input_database(connection, "candidate", EXPECTED_COUNTS[state])
    actual_states = tuple(row[0] for row in connection.execute("SELECT DISTINCT state FROM precincts ORDER BY state"))
    require(actual_states == (state,), f"{state}: candidate contains foreign states {actual_states}")
    require(
        connection.execute("SELECT COUNT(DISTINCT borough) FROM precincts").fetchone()[0]
        == EXPECTED_COUNTS[state]["counties"],
        f"{state}: county count drifted",
    )
    require(
        connection.execute("SELECT COUNT(*)-COUNT(DISTINCT unit_id) FROM precincts").fetchone()[0] == 0,
        f"{state}: duplicate unit_id",
    )
    require(
        connection.execute(
            "SELECT COUNT(*) FROM precinct_elections e LEFT JOIN precincts p USING(unit_id) WHERE p.unit_id IS NULL"
        ).fetchone()[0] == 0,
        f"{state}: orphan election row",
    )
    scopes = {row[0] for row in connection.execute("SELECT scope FROM baselines")}
    require(
        all(scope == state or scope.startswith(f"county|{state}|") for scope in scopes),
        f"{state}: candidate baseline scope leakage",
    )
    require(state in scopes, f"{state}: missing state baseline")
    require(
        connection.execute("SELECT COUNT(*) FROM county_lean_regions WHERE state<>?", (state,)).fetchone()[0] == 0,
        f"{state}: county region state leakage",
    )


def _query_equal(
    left: sqlite3.Connection,
    left_sql: str,
    right: sqlite3.Connection,
    right_sql: str,
    context: str,
    left_params: Sequence[object] = (),
    right_params: Sequence[object] = (),
) -> None:
    marker = object()
    for index, (before, after) in enumerate(
        zip_longest(
            left.execute(left_sql, left_params),
            right.execute(right_sql, right_params),
            fillvalue=marker,
        )
    ):
        require(before is not marker and after is not marker, f"{context}: row count mismatch near row {index}")
        require(tuple(before) == tuple(after), f"{context}: value mismatch near row {index}")


def verify_preservation_and_insertions(
    combined: sqlite3.Connection,
    base: sqlite3.Connection,
    candidates: Sequence[tuple[str, sqlite3.Connection]],
) -> None:
    verify_schema(combined, "combined")
    require(combined.execute("PRAGMA integrity_check").fetchone()[0] == "ok", "combined: integrity_check failed")
    require(combined.execute("PRAGMA quick_check").fetchone()[0] == "ok", "combined: quick_check failed")
    require(table_counts(combined) == EXPECTED_COUNTS["combined"], "combined: table counts mismatch")
    actual_states = tuple(row[0] for row in combined.execute("SELECT DISTINCT state FROM precincts ORDER BY state"))
    require(actual_states == ALL_STATES, f"combined: state set mismatch {actual_states}")
    require(combined.execute("SELECT COUNT(*)-COUNT(DISTINCT rowid) FROM precincts").fetchone()[0] == 0, "combined: duplicate precinct rowid")
    require(combined.execute("SELECT COUNT(*)-COUNT(DISTINCT unit_id) FROM precincts").fetchone()[0] == 0, "combined: duplicate unit_id")
    require(combined.execute("SELECT COUNT(*)-COUNT(DISTINCT id) FROM precinct_rtree").fetchone()[0] == 0, "combined: duplicate R-tree id")
    require(combined.execute("SELECT COUNT(*)-COUNT(DISTINCT rowid) FROM county_lean_regions").fetchone()[0] == 0, "combined: duplicate region rowid")
    require(combined.execute("SELECT COUNT(*) FROM precinct_elections e LEFT JOIN precincts p USING(unit_id) WHERE p.unit_id IS NULL").fetchone()[0] == 0, "combined: orphan election row")
    require(combined.execute("SELECT COUNT(*) FROM precinct_rtree r LEFT JOIN precincts p ON p.rowid=r.id WHERE p.rowid IS NULL").fetchone()[0] == 0, "combined: orphan R-tree row")
    require(combined.execute("PRAGMA foreign_key_check").fetchall() == [], "combined: foreign_key_check failed")

    precinct_select = ",".join(PRECINCT_COLUMNS)
    _query_equal(
        base,
        f"SELECT {precinct_select} FROM precincts ORDER BY rowid",
        combined,
        f"SELECT {precinct_select} FROM precincts WHERE state IN ({placeholders(len(BASE_STATES))}) ORDER BY rowid",
        "base precinct preservation",
        right_params=BASE_STATES,
    )
    election_select = ",".join(ELECTION_COLUMNS)
    election_order = ",".join(ELECTION_COLUMNS)
    _query_equal(
        base,
        f"SELECT {election_select} FROM precinct_elections ORDER BY {election_order}",
        combined,
        f"SELECT e.{',e.'.join(ELECTION_COLUMNS)} FROM precinct_elections e JOIN precincts p USING(unit_id) WHERE p.state IN ({placeholders(len(BASE_STATES))}) ORDER BY {',e.'.join(ELECTION_COLUMNS)}",
        "base election preservation",
        right_params=BASE_STATES,
    )
    rtree_select = ",".join(RTREE_COLUMNS)
    _query_equal(
        base,
        f"SELECT {rtree_select} FROM precinct_rtree ORDER BY id",
        combined,
        f"SELECT r.{',r.'.join(RTREE_COLUMNS)} FROM precinct_rtree r JOIN precincts p ON p.rowid=r.id WHERE p.state IN ({placeholders(len(BASE_STATES))}) ORDER BY r.id",
        "base R-tree preservation",
        right_params=BASE_STATES,
    )
    baseline_select = ",".join(BASELINE_BASE_COLUMNS)
    _query_equal(
        base,
        f"SELECT {baseline_select} FROM baselines ORDER BY scope",
        combined,
        f"SELECT {baseline_select} FROM baselines WHERE political_precinct_count IS NULL ORDER BY scope",
        "base baseline preservation",
    )
    region_select = ",".join(REGION_COLUMNS)
    _query_equal(
        base,
        f"SELECT {region_select} FROM county_lean_regions ORDER BY rowid",
        combined,
        f"SELECT {region_select} FROM county_lean_regions WHERE state IN ({placeholders(len(BASE_STATES))}) ORDER BY rowid",
        "base region preservation",
        right_params=BASE_STATES,
    )

    candidate_precinct_select = ",".join(PRECINCT_VALUE_COLUMNS)
    candidate_region_select = ",".join(REGION_VALUE_COLUMNS)
    candidate_baseline_select = ",".join(BASELINE_CANDIDATE_COLUMNS)
    combined_baseline_select = ",".join(BASELINE_CANDIDATE_COLUMNS)
    for state, candidate in candidates:
        _query_equal(
            candidate,
            f"SELECT {candidate_precinct_select} FROM precincts ORDER BY unit_id",
            combined,
            f"SELECT {candidate_precinct_select} FROM precincts WHERE state=? ORDER BY unit_id",
            f"{state} precinct insertion",
            right_params=(state,),
        )
        _query_equal(
            candidate,
            f"SELECT {election_select} FROM precinct_elections ORDER BY {election_order}",
            combined,
            f"SELECT e.{',e.'.join(ELECTION_COLUMNS)} FROM precinct_elections e JOIN precincts p USING(unit_id) WHERE p.state=? ORDER BY {',e.'.join(ELECTION_COLUMNS)}",
            f"{state} election insertion",
            right_params=(state,),
        )
        _query_equal(
            candidate,
            f"SELECT p.unit_id,r.min_lon,r.max_lon,r.min_lat,r.max_lat FROM precinct_rtree r JOIN precincts p ON p.rowid=r.id ORDER BY p.unit_id",
            combined,
            f"SELECT p.unit_id,r.min_lon,r.max_lon,r.min_lat,r.max_lat FROM precinct_rtree r JOIN precincts p ON p.rowid=r.id WHERE p.state=? ORDER BY p.unit_id",
            f"{state} R-tree insertion",
            right_params=(state,),
        )
        _query_equal(
            candidate,
            f"SELECT {candidate_baseline_select} FROM baselines ORDER BY scope",
            combined,
            f"SELECT {combined_baseline_select} FROM baselines WHERE scope=? OR scope LIKE ? ORDER BY scope",
            f"{state} baseline insertion",
            right_params=(state, f"county|{state}|%"),
        )
        _query_equal(
            candidate,
            f"SELECT {candidate_region_select} FROM county_lean_regions ORDER BY state,borough,lean_label,rowid",
            combined,
            f"SELECT {candidate_region_select} FROM county_lean_regions WHERE state=? ORDER BY state,borough,lean_label,rowid",
            f"{state} region insertion",
            right_params=(state,),
        )


def _insert_candidate(
    target: sqlite3.Connection,
    candidate: sqlite3.Connection,
    state: str,
    next_precinct_id: int,
    next_region_id: int,
) -> tuple[int, int]:
    old_precinct_ids = [row[0] for row in candidate.execute("SELECT rowid FROM precincts ORDER BY unit_id")]
    precinct_map = allocate_rowids(old_precinct_ids, next_precinct_id)
    precinct_select = ",".join(PRECINCT_COLUMNS)
    precinct_insert = f"INSERT INTO precincts ({precinct_select}) VALUES ({placeholders(len(PRECINCT_COLUMNS))})"
    for row in candidate.execute(f"SELECT {precinct_select} FROM precincts ORDER BY unit_id"):
        values = list(row)
        values[0] = precinct_map[row[0]]
        target.execute(precinct_insert, values)

    election_select = ",".join(ELECTION_COLUMNS)
    target.executemany(
        f"INSERT INTO precinct_elections ({election_select}) VALUES ({placeholders(len(ELECTION_COLUMNS))})",
        candidate.execute(f"SELECT {election_select} FROM precinct_elections ORDER BY {election_select}"),
    )
    target.executemany(
        f"INSERT INTO precinct_rtree ({','.join(RTREE_COLUMNS)}) VALUES ({placeholders(len(RTREE_COLUMNS))})",
        (
            (precinct_map[row[0]], row[1], row[2], row[3], row[4])
            for row in candidate.execute(
                f"SELECT {','.join(RTREE_COLUMNS)} FROM precinct_rtree ORDER BY id"
            )
        ),
    )

    candidate_baseline_select = ",".join(BASELINE_CANDIDATE_COLUMNS)
    candidate_baselines = list(
        candidate.execute(f"SELECT {candidate_baseline_select} FROM baselines ORDER BY scope")
    )
    scopes = [row[0] for row in candidate_baselines]
    require(len(scopes) == len(set(scopes)), f"{state}: duplicate baseline scope")
    for scope in scopes:
        require(
            target.execute("SELECT 1 FROM baselines WHERE scope=?", (scope,)).fetchone() is None,
            f"{state}: baseline scope collision {scope}",
        )
    target.executemany(
        f"INSERT INTO baselines ({candidate_baseline_select}) VALUES ({placeholders(len(BASELINE_CANDIDATE_COLUMNS))})",
        candidate_baselines,
    )

    old_region_ids = [row[0] for row in candidate.execute("SELECT rowid FROM county_lean_regions ORDER BY rowid")]
    region_map = allocate_rowids(old_region_ids, next_region_id)
    region_select = ",".join(REGION_COLUMNS)
    region_insert = f"INSERT INTO county_lean_regions ({region_select}) VALUES ({placeholders(len(REGION_COLUMNS))})"
    for row in candidate.execute(f"SELECT {region_select} FROM county_lean_regions ORDER BY rowid"):
        values = list(row)
        values[0] = region_map[row[0]]
        target.execute(region_insert, values)
    return next_precinct_id + len(precinct_map), next_region_id + len(region_map)


def merge_to_staging(staging: Path) -> None:
    base = connect_read_only(BASE)
    candidates = [(state, connect_read_only(path)) for state, path in CANDIDATES]
    try:
        verify_input_database(base, "base", EXPECTED_COUNTS["base"])
        for state, candidate in candidates:
            verify_candidate_contract(candidate, state)
        or_ids = {row[0] for row in candidates[0][1].execute("SELECT unit_id FROM precincts")}
        co_ids = {row[0] for row in candidates[1][1].execute("SELECT unit_id FROM precincts")}
        require(not (or_ids & co_ids), "OR and CO candidates share unit IDs")

        shutil.copy2(BASE, staging)
        target = sqlite3.connect(staging)
        try:
            target.execute("PRAGMA journal_mode=DELETE")
            target.execute("PRAGMA synchronous=FULL")
            target.execute("PRAGMA temp_store=MEMORY")
            target.execute("PRAGMA foreign_keys=ON")
            verify_schema(target, "base")
            target.execute("BEGIN IMMEDIATE")
            try:
                require(
                    target.execute("SELECT COUNT(*) FROM precincts WHERE state IN ('OR','CO')").fetchone()[0] == 0,
                    "target already contains OR or CO precincts",
                )
                require(
                    target.execute("SELECT COUNT(*) FROM county_lean_regions WHERE state IN ('OR','CO')").fetchone()[0] == 0,
                    "target already contains OR or CO regions",
                )
                require(
                    target.execute(
                        "SELECT COUNT(*) FROM baselines WHERE scope IN ('OR','CO') OR scope LIKE 'county|OR|%' OR scope LIKE 'county|CO|%'"
                    ).fetchone()[0] == 0,
                    "target already contains OR or CO baselines",
                )
                for state, candidate in candidates:
                    for (unit_id,) in candidate.execute("SELECT unit_id FROM precincts ORDER BY unit_id"):
                        require(
                            target.execute("SELECT 1 FROM precincts WHERE unit_id=?", (unit_id,)).fetchone() is None,
                            f"{state}: unit_id collision {unit_id}",
                        )
                target.execute("ALTER TABLE baselines ADD COLUMN political_precinct_count INTEGER")
                require(table_info(target, "baselines") == COMBINED_BASELINE_INFO, "combined baselines migration mismatch")
                next_precinct_id = int(target.execute("SELECT COALESCE(MAX(rowid),0)+1 FROM precincts").fetchone()[0])
                next_region_id = int(target.execute("SELECT COALESCE(MAX(rowid),0)+1 FROM county_lean_regions").fetchone()[0])
                for state, candidate in candidates:
                    next_precinct_id, next_region_id = _insert_candidate(
                        target, candidate, state, next_precinct_id, next_region_id
                    )
                require(table_counts(target) == EXPECTED_COUNTS["combined"], "transaction produced wrong table totals")
                require(target.execute("PRAGMA foreign_key_check").fetchall() == [], "transaction foreign_key_check failed")
                target.commit()
            except BaseException:
                target.rollback()
                raise
            target.execute("ANALYZE")
            target.commit()
            target.execute("VACUUM")
            target.close()
            target = None
        finally:
            if target is not None:
                target.close()

        staged = connect_read_only(staging)
        try:
            verify_preservation_and_insertions(staged, base, candidates)
            database_list = list(staged.execute("PRAGMA database_list"))
            require(
                database_list[0][1] == "main"
                and all(row[1] == "temp" and not row[2] for row in database_list[1:]),
                f"staged DB has attached file databases: {database_list}",
            )
        finally:
            staged.close()
    finally:
        for _, candidate in candidates:
            candidate.close()
        base.close()


def fsync_file(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def install_verified_database(
    staged: Path,
    target: Path,
    failpoint: Callable[[str], None] | None = None,
) -> None:
    require(staged.is_file() and not staged.is_symlink(), "verified staging database is missing")
    require(not target.is_symlink(), "refusing symlinked Phase 3 target")
    fsync_file(staged)
    if failpoint:
        failpoint("before_replace")
    os.replace(staged, target)
    if failpoint:
        failpoint("after_replace")
    fsync_directory(target.parent)


def clean_exact_staging(path: Path) -> None:
    for candidate in (path, Path(str(path) + "-journal"), Path(str(path) + "-shm"), Path(str(path) + "-wal")):
        require(not candidate.is_symlink(), f"refusing symlinked staging residue: {candidate}")
        if candidate.exists():
            require(candidate.is_file(), f"refusing non-file staging residue: {candidate}")
            candidate.unlink()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default=str(OUTPUT), type=safe_output)
    parser.add_argument("--replace", action="store_true", help="Atomically replace an existing evaluation DB")
    args = parser.parse_args()
    if Path.cwd().resolve() != ROOT:
        parser.error(f"run this script from the repository root: {ROOT}")
    output: Path = args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        output.parent.chmod(0o755)
    except PermissionError:
        pass
    if output.is_symlink() or (output.exists() and not output.is_file()):
        parser.error("Phase 3 target must be a regular file or be absent")
    if output.exists() and not args.replace:
        parser.error("evaluation DB already exists. Use --replace for an atomic replacement")
    for path, expected in EXPECTED_HASHES.items():
        verify_regular_hash(path, expected)
    clean_exact_staging(STAGING)
    try:
        merge_to_staging(STAGING)
        install_verified_database(STAGING, output)
    finally:
        clean_exact_staging(STAGING)
    print(f"Phase 3 evaluation DB: {output}")
    print(f"size_bytes={output.stat().st_size}")
    print(f"sha256={sha256(output)}")
    print("release_gate=BLOCKED shipping_authorized=false")


if __name__ == "__main__":
    main()
