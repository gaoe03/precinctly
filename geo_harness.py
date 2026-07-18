#!/usr/bin/env python3
"""Geospatial correctness harness for Precinct.

Replicates the iOS lookup EXACTLY:
  1) R-tree bbox prefilter:
       candidates containing (lon, lat), ordered by profile usability,
       geometry specificity, then stable row id
  2) For each candidate (in order) load geometry_wkb, shapely.wkb.loads it,
     and test geom.contains(Point(lon,lat)). Return the FIRST containing precinct.

This mirrors PrecinctDB.lookup + candidateIDs + WKBGeometry.contains.
"""
import hashlib
import os
import sqlite3
import sys
import shapely
from shapely import wkb as shp_wkb
from shapely.geometry import Point

# The app ships this bundled copy.
DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "PrecinctWeather/PrecinctKit/Resources/nyc_precincts.sqlite")
REVIEWED_SHAPELY_VERSION = "2.1.2"
REVIEWED_OVERLAP_REDIRECT_COUNT = 30
REVIEWED_OVERLAP_REDIRECT_SHA256 = "7b6ee8edcf3c64ffca0a9be49a6067c8895bf1925ee13614c059aded96faf2cc"

conn = sqlite3.connect(f"file:{DB}?mode=ro&immutable=1", uri=True)
conn.row_factory = sqlite3.Row


def candidate_ids(lon, lat):
    """R-tree bbox prefilter, exactly as candidateIDs() does (bind lon then lat)."""
    cur = conn.execute(
        "SELECT r.id FROM precinct_rtree AS r "
        "JOIN precincts AS p ON p.rowid = r.id "
        "WHERE ? BETWEEN r.min_lon AND r.max_lon "
        "AND ? BETWEEN r.min_lat AND r.max_lat "
        "ORDER BY p.data_complete DESC, "
        "(p.lean_dem_share IS NOT NULL) DESC, "
        "(p.pop_total IS NOT NULL AND p.pop_total > 0) DESC, "
        "((p.max_lon - p.min_lon) * (p.max_lat - p.min_lat)) ASC, "
        "r.id ASC",
        (lon, lat),
    )
    return [r[0] for r in cur.fetchall()]


def row(rowid):
    """Mirror PrecinctDB.row(id): load by rowid, return (unit_id, borough, wkb)."""
    cur = conn.execute(
        "SELECT unit_id, borough, geometry_wkb FROM precincts WHERE rowid = ?",
        (rowid,),
    )
    r = cur.fetchone()
    if r is None:
        return None
    unit_id, borough, blob = r[0], r[1], r[2]
    if unit_id is None or blob is None:   # Swift guards: unit_id and wkb must be non-null
        return None
    return unit_id, borough, blob


def lookup(lon, lat):
    """Mirror PrecinctDB.lookup: first candidate whose geometry contains the point."""
    pt = Point(lon, lat)
    for rid in candidate_ids(lon, lat):
        rr = row(rid)
        if rr is None:
            continue
        unit_id, borough, blob = rr
        geom = shp_wkb.loads(bytes(blob))
        if geom.contains(pt):
            return {"rowid": rid, "unit_id": unit_id, "borough": borough}
    return None


# ---- Named coordinate tests (lat, lon, expected borough or None for water/outside) ----
CASES = [
    ("Times Square",        40.758, -73.985, "Manhattan"),
    ("Wall Street",         40.706, -74.009, "Manhattan"),
    ("Chinatown",           40.716, -73.997, "Manhattan"),
    ("Harlem",              40.811, -73.946, "Manhattan"),
    ("Williamsburg Bklyn",  40.708, -73.957, "Brooklyn"),
    ("Coney Island",        40.575, -73.979, "Brooklyn"),
    ("Borough Park",        40.633, -73.990, "Brooklyn"),
    ("Crown Heights",       40.668, -73.943, "Brooklyn"),
    ("Flushing Queens",     40.759, -73.830, "Queens"),
    ("Jackson Heights",     40.748, -73.889, "Queens"),
    ("JFK area",            40.645, -73.785, "Queens"),
    ("Yankee Stadium Bronx",40.829, -73.926, "Bronx"),
    ("South Bronx",         40.816, -73.918, "Bronx"),
    ("St George SI",        40.644, -74.078, "Staten Island"),
    ("Great Kills SI",      40.554, -74.151, "Staten Island"),
    ("Yonkers",              40.950, -73.870, "Westchester"),
    ("San Francisco",        37.7793, -122.4193, "San Francisco"),
    ("Los Angeles",          34.0537, -118.2428, "Los Angeles"),
    ("Boston Common",        42.3550, -71.0650, "Suffolk"),
    ("Texas Capitol",        30.2747, -97.7404, "Travis"),
    ("Houston City Hall",    29.7604, -95.3698, "Harris"),
    ("Hudson River (water)",40.760, -74.020, None),
    # Queried against the bundled DB: this offshore point has zero R-tree candidates.
    ("Atlantic Ocean",      40.000, -72.500, None),
    ("Newark NJ (outside)", 40.735, -74.172, None),
]

print("=" * 78)
print("NAMED COORDINATE TESTS")
print("=" * 78)
print(f"{'place':<22} {'lat':>8} {'lon':>9} {'cand':>4} {'expected':<14} {'got':<14} verdict")
print("-" * 78)

failures = []
for name, lat, lon, expected in CASES:
    cands = candidate_ids(lon, lat)
    res = lookup(lon, lat)
    got = res["borough"] if res else None
    got_uid = res["unit_id"] if res else "-"
    ok = (got == expected)
    if not ok:
        failures.append((name, lat, lon, expected, got, got_uid))
    verdict = "OK" if ok else "*** FAIL ***"
    exp_s = expected if expected is not None else "NULL"
    got_s = got if got is not None else "NULL"
    print(f"{name:<22} {lat:>8.3f} {lon:>9.3f} {len(cands):>4} "
          f"{exp_s:<14} {got_s:<14} {verdict}  uid={got_uid}")

print("-" * 78)
print(f"named cases: {len(CASES)}  passed: {len(CASES)-len(failures)}  failed: {len(failures)}")

# ---- Artifact-wide geometry and lookup health ----
print()
print("=" * 78)
print("FULL GEOMETRY AND LOOKUP HEALTH (every precinct representative point)")
print("=" * 78)

all_rows = conn.execute(
    "SELECT rowid, unit_id, borough, geometry_wkb "
    "FROM precincts"
).fetchall()
print(f"total precincts: {len(all_rows)}")

geometry_fail = []
inside_null = []
inside_other = []
for r in all_rows:
    rid, uid, boro = r["rowid"], r["unit_id"], r["borough"]
    try:
        geom = shp_wkb.loads(bytes(r["geometry_wkb"]))
    except Exception as error:
        geometry_fail.append((rid, uid, f"parse error: {error}"))
        continue
    if geom.is_empty or not geom.is_valid:
        geometry_fail.append((rid, uid, "empty" if geom.is_empty else "invalid"))
        continue
    pt = geom.representative_point()
    res = lookup(pt.x, pt.y)
    if res is None:
        inside_null.append((rid, uid, boro, pt.x, pt.y))
    elif res["rowid"] != rid:
        inside_other.append((rid, uid, res["unit_id"]))

print(f"checked: {len(all_rows)}   malformed geometries: {len(geometry_fail)}")
print(f"  representative point -> NULL: {len(inside_null)}")
print(f"  representative point -> overlapping precinct: {len(inside_other)}")
redirect_lines = sorted({f"{uid}->{resolved_uid}" for _, uid, resolved_uid in inside_other})
redirect_digest = hashlib.sha256("\n".join(redirect_lines).encode()).hexdigest()
shapely_version_changed = shapely.__version__ != REVIEWED_SHAPELY_VERSION
overlap_set_changed = (
    len(inside_other) != REVIEWED_OVERLAP_REDIRECT_COUNT
    or redirect_digest != REVIEWED_OVERLAP_REDIRECT_SHA256
)
if shapely_version_changed:
    print(f"  FAIL: reviewed Shapely version is {REVIEWED_SHAPELY_VERSION}, "
          f"but the active version is {shapely.__version__}")
if overlap_set_changed:
    print(f"  FAIL: reviewed overlap count/hash is {REVIEWED_OVERLAP_REDIRECT_COUNT}/"
          f"{REVIEWED_OVERLAP_REDIRECT_SHA256}")
    print(f"  actual overlap count/hash is {len(inside_other)}/{redirect_digest}")
if geometry_fail:
    print("  malformed examples (rowid, unit_id, detail):")
    for rid, uid, detail in geometry_fail[:15]:
        print(f"    rowid={rid} uid={uid}: {detail}")
if inside_null:
    print("  unresolved examples (rowid, unit_id, borough, lon/lat):")
    for rid, uid, boro, lon, lat in inside_null[:15]:
        print(f"    rowid={rid} uid={uid} {boro} point=({lon:.5f},{lat:.5f})")
if inside_other:
    print("  Overlap redirects are expected where nested source geometries compete.")
    print("  The app intentionally chooses the more usable profile first.")
    for rid, uid, resolved_uid in inside_other[:5]:
        print(f"    rowid={rid} uid={uid} -> {resolved_uid}")

# ---- Diagnostics for any named failures (esp. NULLs that should hit) ----
if failures:
    print()
    print("=" * 78)
    print("FAILURE DIAGNOSTICS")
    print("=" * 78)
    for name, lat, lon, expected, got, uid in failures:
        cands = candidate_ids(lon, lat)
        print(f"\n{name} (lat={lat}, lon={lon}) expected={expected} got={got}")
        print(f"  candidate ids from r-tree: {cands}")
        for rid in cands[:10]:
            rr = row(rid)
            if rr is None:
                print(f"    rowid={rid}: row() returned None (null unit_id/wkb)")
                continue
            ruid, rboro, blob = rr
            geom = shp_wkb.loads(bytes(blob))
            cont = geom.contains(Point(lon, lat))
            # distance to geom for context (degrees)
            d = geom.distance(Point(lon, lat))
            print(f"    rowid={rid} uid={ruid} {rboro} contains={cont} dist={d:.6f}")

# ---- Summary line for parsing ----
print()
print("=" * 78)
print(f"SUMMARY named_run={len(CASES)} named_pass={len(CASES)-len(failures)} "
      f"named_fail={len(failures)} geometry_run={len(all_rows)} "
      f"geometry_fail={len(geometry_fail)} unresolved={len(inside_null)} "
      f"overlap_redirects={len(inside_other)} overlap_sha256={redirect_digest} "
      f"shapely={shapely.__version__}")
print("=" * 78)
conn.close()
sys.exit(1 if failures or geometry_fail or inside_null or overlap_set_changed or shapely_version_changed else 0)
