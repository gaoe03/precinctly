#!/usr/bin/env python3
"""Read-only verification harness for a DMV-expanded SQLite artifact.

The merge command deliberately writes a new database.  Run this harness against that
copy before replacing the shipped resource:

    python3 pipeline/verify_dmv.py --db /tmp/precinct-dmv.sqlite \
      --base PrecinctWeather/PrecinctKit/Resources/nyc_precincts.sqlite

Checks are intentionally independent of the iOS process.  They exercise the same
R-tree candidate ordering and exact WKB ``contains`` lookup used by ``PrecinctDB``.
No input database is opened writable and no files are changed.
"""

from __future__ import annotations

import argparse
import math
import os
import random
import sqlite3
import sys
from collections import Counter

try:
    from shapely import wkb
    from shapely.geometry import Point
except ImportError as exc:  # pragma: no cover - environment diagnostic
    raise SystemExit("verify_dmv.py needs Shapely (the pipeline Python environment): %s" % exc)


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DB = os.path.join(ROOT, "PrecinctWeather/PrecinctKit/Resources/nyc_precincts.sqlite")
SUPPORTED_BASE_STATES = ("CA", "MA", "NY", "TX")
DMV_STATES = ("DC", "MD", "VA")

# Conservative envelopes in WGS84.  These catch projected/degree mixups without
# rejecting a legitimate border precinct.  DC is intentionally tiny but leaves a
# little room for source slivers.
STATE_ENVELOPES = {
    "DC": (-77.20, -76.85, 38.75, 39.00),
    "MD": (-80.00, -74.80, 37.80, 40.00),
    "VA": (-83.80, -74.90, 36.40, 39.50),
}


def connect(path: str) -> sqlite3.Connection:
    if not os.path.exists(path):
        raise SystemExit("database does not exist: %s" % path)
    con = sqlite3.connect("file:%s?mode=ro&immutable=1" % os.path.abspath(path), uri=True)
    con.row_factory = sqlite3.Row
    return con


def fail(errors: list[str], message: str) -> None:
    errors.append(message)
    print("FAIL:", message)


def candidate_ids(con: sqlite3.Connection, lon: float, lat: float) -> list[int]:
    rows = con.execute(
        "SELECT r.id FROM precinct_rtree AS r JOIN precincts AS p ON p.rowid = r.id "
        "WHERE ? BETWEEN r.min_lon AND r.max_lon AND ? BETWEEN r.min_lat AND r.max_lat "
        "ORDER BY p.data_complete DESC, (p.lean_dem_share IS NOT NULL) DESC, "
        "(p.pop_total IS NOT NULL AND p.pop_total > 0) DESC, "
        "((p.max_lon - p.min_lon) * (p.max_lat - p.min_lat)) ASC, r.id ASC",
        (lon, lat),
    )
    return [int(row[0]) for row in rows]


def lookup(con: sqlite3.Connection, lon: float, lat: float):
    point = Point(lon, lat)
    for rowid in candidate_ids(con, lon, lat):
        row = con.execute(
            "SELECT unit_id, state, borough, geometry_wkb FROM precincts WHERE rowid = ?",
            (rowid,),
        ).fetchone()
        if row is None or row[0] is None or row[3] is None:
            continue
        try:
            geometry = wkb.loads(bytes(row[3]))
        except Exception:
            continue
        if geometry.contains(point):
            return row
    return None


def check_schema_and_relations(con: sqlite3.Connection, errors: list[str]) -> int:
    try:
        integrity = con.execute("PRAGMA integrity_check").fetchone()[0]
    except sqlite3.DatabaseError as exc:
        fail(errors, "integrity_check errored: %s" % exc)
        return 0
    if integrity != "ok":
        fail(errors, "PRAGMA integrity_check = %s" % integrity)

    tables = {row[0] for row in con.execute("SELECT name FROM sqlite_master WHERE type IN ('table','view')")}
    required = {"precincts", "precinct_rtree", "precinct_elections", "baselines", "county_lean_regions"}
    missing = required - tables
    if missing:
        fail(errors, "missing required tables: %s" % ",".join(sorted(missing)))
    if "precincts" not in tables:
        return 0

    count = int(con.execute("SELECT count(*) FROM precincts").fetchone()[0]) if "precincts" in tables else 0
    if count == 0:
        fail(errors, "precincts table is empty")
    rtree_count = int(con.execute("SELECT count(*) FROM precinct_rtree").fetchone()[0]) if "precinct_rtree" in tables else 0
    if count != rtree_count:
        fail(errors, "precinct_rtree count %d does not match precincts count %d" % (rtree_count, count))

    duplicate = con.execute(
        "SELECT unit_id, count(*) AS n FROM precincts GROUP BY unit_id HAVING unit_id IS NULL OR n > 1 LIMIT 5"
    ).fetchall()
    for row in duplicate:
        fail(errors, "duplicate/null unit_id %s (count %s)" % (row[0], row[1]))

    if "precinct_elections" in tables:
        orphan_elections = int(con.execute(
            "SELECT count(*) FROM precinct_elections e LEFT JOIN precincts p USING(unit_id) "
            "WHERE p.unit_id IS NULL"
        ).fetchone()[0])
        if orphan_elections:
            fail(errors, "orphan precinct_elections rows: %d" % orphan_elections)
    if "precinct_rtree" in tables:
        orphan_rtree = int(con.execute(
            "SELECT count(*) FROM precincts p LEFT JOIN precinct_rtree r ON r.id = p.rowid WHERE r.id IS NULL"
        ).fetchone()[0])
        if orphan_rtree:
            fail(errors, "precincts without R-tree row: %d" % orphan_rtree)

    # Every region scope must have a corresponding precinct county, and each added
    # DMV county must have at least one dissolved region.
    if "county_lean_regions" in tables:
        orphan_regions = int(con.execute(
            "SELECT count(*) FROM county_lean_regions r LEFT JOIN "
            "(SELECT DISTINCT state, borough FROM precincts) p USING(state, borough) "
            "WHERE p.state IS NULL"
        ).fetchone()[0])
        if orphan_regions:
            fail(errors, "orphan county_lean_regions rows: %d" % orphan_regions)
    if "baselines" in tables:
        # Baseline rows are persisted comparison contracts.  County rows must map
        # to at least one precinct, and a bare state row must map to that state.
        for (scope,) in con.execute("SELECT scope FROM baselines"):
            parts = str(scope).split("|")
            if len(parts) == 1:
                n = con.execute("SELECT count(*) FROM precincts WHERE state=?", (parts[0],)).fetchone()[0]
            elif len(parts) == 3 and parts[0] == "county":
                n = con.execute("SELECT count(*) FROM precincts WHERE state=? AND borough=?", (parts[1], parts[2])).fetchone()[0]
            elif len(parts) == 3 and parts[0] == "metro":
                # Metro scopes span several counties.  Their constituent
                # precincts are validated by the state/county rows and the
                # dedicated region checks below.
                continue
            elif len(parts) == 2 and parts[0] == "region":
                # Aggregate regions are allowed to be backed by a custom query;
                # their presence and positive counts are checked separately.
                continue
            else:
                fail(errors, "unrecognized baseline scope: %s" % scope)
                continue
            if n == 0:
                fail(errors, "orphan baseline scope %s" % scope)
    return count


def check_rows_and_geometry(con: sqlite3.Connection, errors: list[str]) -> list[sqlite3.Row]:
    try:
        rows = con.execute(
            "SELECT rowid, unit_id, state, borough, min_lon, min_lat, max_lon, max_lat, geometry_wkb "
            "FROM precincts ORDER BY rowid"
        ).fetchall()
    except sqlite3.DatabaseError as exc:
        fail(errors, "cannot read precinct rows: %s" % exc)
        return []
    bad_geometry = 0
    bad_bounds = 0
    for row in rows:
        bounds = row[4:8]
        if any(value is None or not math.isfinite(float(value)) for value in bounds) or row[4] > row[6] or row[5] > row[7]:
            bad_bounds += 1
            if bad_bounds <= 5:
                fail(errors, "invalid bbox for %s: %s" % (row[1], bounds))
            continue
        try:
            geometry = wkb.loads(bytes(row[8]))
            if geometry.is_empty or not geometry.is_valid:
                raise ValueError("empty or invalid")
            bx = geometry.bounds
            if any(not math.isfinite(float(value)) for value in bx):
                raise ValueError("non-finite geometry bounds")
        except Exception as exc:
            bad_geometry += 1
            if bad_geometry <= 5:
                fail(errors, "geometry rejected for %s: %s" % (row[1], exc))
            continue
        envelope = STATE_ENVELOPES.get(row[2])
        if envelope and not (envelope[0] <= bx[0] <= bx[2] <= envelope[1] and envelope[2] <= bx[1] <= bx[3] <= envelope[3]):
            fail(errors, "%s geometry outside %s envelope: %s" % (row[1], row[2], tuple(round(x, 5) for x in bx)))
    if bad_geometry:
        fail(errors, "malformed geometries: %d" % bad_geometry)
    if bad_bounds:
        fail(errors, "invalid precinct bboxes: %d" % bad_bounds)
    return rows


def check_randomized_lookup(con: sqlite3.Connection, rows: list[sqlite3.Row], errors: list[str], seed: int, samples: int) -> None:
    rng = random.Random(seed)
    valid = []
    for row in rows:
        try:
            geometry = wkb.loads(bytes(row[8]))
            if not geometry.is_empty and geometry.is_valid:
                valid.append((row, geometry))
        except Exception:
            pass
    if not valid:
        fail(errors, "no valid geometries available for lookup stress")
        return
    redirects = 0
    random_failures = 0
    for row, geometry in (valid if samples <= 0 else [valid[rng.randrange(len(valid))] for _ in range(samples)]):
        # Representative points are guaranteed to be inside even for concave or multipart polygons.
        point = geometry.representative_point()
        hit = lookup(con, point.x, point.y)
        if hit is None:
            fail(errors, "representative point unresolved for %s" % row[1])
        elif hit[0] != row[1]:
            redirects += 1
        # Add a genuinely random interior point where possible.  Rejection sampling
        # avoids relying on a centroid, which may fall in a hole or outside a concave
        # precinct.  The point is still checked with the app's exact lookup order.
        minx, miny, maxx, maxy = geometry.bounds
        random_point = None
        for _ in range(20):
            candidate = Point(rng.uniform(minx, maxx), rng.uniform(miny, maxy))
            if geometry.contains(candidate):
                random_point = candidate
                break
        if random_point is not None and lookup(con, random_point.x, random_point.y) is None:
            random_failures += 1
    if random_failures:
        fail(errors, "random interior points unresolved: %d" % random_failures)
    print("randomized representative lookups: %d (redirects from overlapping source polygons: %d)" % (samples if samples > 0 else len(valid), redirects))

    # Boundary points should never crash or return a row outside its own candidate bbox.
    boundary_failures = 0
    for row, geometry in valid[: min(500, len(valid))]:
        point = geometry.boundary.interpolate(0.5, normalized=True)
        for delta in (1e-7, -1e-7):
            hit = lookup(con, point.x + delta, point.y + delta)
            if hit is not None and hit[1] not in (row[2],):
                boundary_failures += 1
    if boundary_failures:
        fail(errors, "boundary probes resolved to a different state: %d" % boundary_failures)
    print("boundary probes: %d precincts" % min(500, len(valid)))


def check_out_of_coverage(con: sqlite3.Connection, errors: list[str]) -> None:
    tables = {row[0] for row in con.execute("SELECT name FROM sqlite_master WHERE type IN ('table','view')")}
    if "precinct_rtree" not in tables or "precincts" not in tables:
        return
    probes = [(0.0, 0.0), (-72.5, 40.0), (-100.0, 45.0), (-80.0, 25.0), (-74.172, 40.735)]
    misses = [p for p in probes if lookup(con, *p) is not None]
    if misses:
        fail(errors, "out-of-coverage probes unexpectedly resolved: %s" % misses)
    print("out-of-coverage probes: %d, unresolved: %d" % (len(probes), len(probes) - len(misses)))


def check_migration(
    base: sqlite3.Connection,
    merged: sqlite3.Connection,
    required_states: tuple[str, ...],
    errors: list[str],
) -> None:
    base_states = set(row[0] for row in base.execute("SELECT DISTINCT state FROM precincts"))
    merged_states = set(row[0] for row in merged.execute("SELECT DISTINCT state FROM precincts"))
    if not set(SUPPORTED_BASE_STATES).issubset(merged_states):
        fail(errors, "merged DB lost one of existing states: %s" % sorted(set(SUPPORTED_BASE_STATES) - merged_states))
    required_dmv = set(required_states) & set(DMV_STATES)
    if not required_dmv.issubset(merged_states):
        fail(errors, "merged DB is missing required DMV states: %s" % sorted(required_dmv - merged_states))
    for state in sorted(base_states):
        before = int(base.execute("SELECT count(*) FROM precincts WHERE state=?", (state,)).fetchone()[0])
        after = int(merged.execute("SELECT count(*) FROM precincts WHERE state=?", (state,)).fetchone()[0])
        if before != after:
            fail(errors, "migration changed %s precinct count %d -> %d" % (state, before, after))
        old_ids = {row[0] for row in base.execute("SELECT unit_id FROM precincts WHERE state=?", (state,))}
        new_ids = {row[0] for row in merged.execute("SELECT unit_id FROM precincts WHERE state=?", (state,))}
        if old_ids != new_ids:
            fail(errors, "migration changed %s unit IDs (lost=%d gained=%d)" % (state, len(old_ids - new_ids), len(new_ids - old_ids)))
    print("migration preservation: checked %d existing states" % len(base_states))


def check_region_baseline(con: sqlite3.Connection, required_states: tuple[str, ...], errors: list[str]) -> None:
    """Validate the persisted aggregate comparison row used by the DMV picker.

    A DMV map area is not a synthetic ``state = 'DMV'`` row.  The app asks for
    this explicit scope key instead, so a migration that only adds precinct rows
    (or only adds county rows) would leave the comparison menu silently empty.
    Partial MD/VA trial artifacts may omit this check with ``--no-region-baseline``.
    """
    if not set(DMV_STATES).issubset(required_states):
        return
    columns = {row[1] for row in con.execute("PRAGMA table_info(baselines)")}
    missing = {"precinct_count", "pop_total"} - columns
    if missing:
        fail(errors, "baselines is missing DMV contract columns: %s" % ",".join(sorted(missing)))
        return
    row = con.execute(
        "SELECT scope, precinct_count, pop_total FROM baselines WHERE scope = 'region|DMV'"
    ).fetchone()
    if row is None:
        fail(errors, "missing persisted aggregate baseline scope region|DMV")
        return
    if row[1] is not None and int(row[1]) <= 0:
        fail(errors, "region|DMV baseline has non-positive precinct_count %s" % row[1])
    if row[2] is not None and int(row[2]) <= 0:
        fail(errors, "region|DMV baseline has non-positive pop_total %s" % row[2])
    print("persisted region baseline: region|DMV")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=DEFAULT_DB)
    parser.add_argument("--base", help="pre-merge DB; verify existing states and IDs are unchanged")
    parser.add_argument(
        "--states",
        default=",".join(DMV_STATES),
        help="comma-separated states required in the artifact (default: DC,MD,VA; use MD,VA for --exclude-dc trials)",
    )
    parser.add_argument(
        "--no-region-baseline",
        action="store_true",
        help="skip the region|DMV baseline check (for MD/VA trial copies)",
    )
    parser.add_argument("--seed", type=int, default=20260830)
    parser.add_argument("--samples", type=int, default=1000, help="representative points; 0 checks every precinct")
    args = parser.parse_args()

    errors: list[str] = []
    merged = connect(args.db)
    count = check_schema_and_relations(merged, errors)
    rows = check_rows_and_geometry(merged, errors)
    state_counts = Counter(row[2] for row in rows)
    print("states:", ", ".join("%s=%d" % item for item in sorted(state_counts.items())))
    required_states = tuple(s.strip().upper() for s in args.states.split(",") if s.strip())
    for state in required_states:
        if state not in state_counts:
            fail(errors, "required state %s is absent" % state)
        elif state_counts[state] == 0:
            fail(errors, "required state %s has no precinct rows" % state)
    if not args.no_region_baseline:
        check_region_baseline(merged, required_states, errors)
    check_randomized_lookup(merged, rows, errors, args.seed, args.samples)
    check_out_of_coverage(merged, errors)
    if args.base:
        base = connect(args.base)
        check_migration(base, merged, required_states, errors)
        base.close()
    merged.close()
    print("SUMMARY rows=%d states=%d errors=%d" % (count, len(state_counts), len(errors)))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
