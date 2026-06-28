#!/usr/bin/env python3
"""Geospatial correctness harness for Precinct.

Replicates the iOS lookup EXACTLY:
  1) R-tree bbox prefilter:
       SELECT id FROM precinct_rtree
       WHERE ? BETWEEN min_lon AND max_lon AND ? BETWEEN min_lat AND max_lat
     (bind order: lon, lat)  -> candidate ids in SQLite return order
  2) For each candidate (in order) load geometry_wkb, shapely.wkb.loads it,
     and test geom.contains(Point(lon,lat)). Return the FIRST containing precinct.

This mirrors PrecinctDB.lookup + candidateIDs + WKBGeometry.contains.
"""
import os
import sqlite3
import random
import sys
from shapely import wkb as shp_wkb
from shapely.geometry import Point

# The app ships the bundled copy; it is byte-identical to the source output.
DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "PrecinctWeather/PrecinctKit/Resources/nyc_precincts.sqlite")

conn = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
conn.row_factory = sqlite3.Row


def candidate_ids(lon, lat):
    """R-tree bbox prefilter, exactly as candidateIDs() does (bind lon then lat)."""
    cur = conn.execute(
        "SELECT id FROM precinct_rtree "
        "WHERE ? BETWEEN min_lon AND max_lon AND ? BETWEEN min_lat AND max_lat",
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
    ("Harlem",              40.811, -73.946, "Manhattan"),
    ("Williamsburg Bklyn",  40.708, -73.957, "Brooklyn"),
    ("Coney Island",        40.575, -73.979, "Brooklyn"),
    ("Borough Park",        40.633, -73.990, "Brooklyn"),
    ("Flushing Queens",     40.759, -73.830, "Queens"),
    ("Jackson Heights",     40.748, -73.889, "Queens"),
    ("JFK area",            40.645, -73.785, "Queens"),
    ("Yankee Stadium Bronx",40.829, -73.926, "Bronx"),
    ("South Bronx",         40.816, -73.918, "Bronx"),
    ("St George SI",        40.644, -74.078, "Staten Island"),
    ("Great Kills SI",      40.554, -74.151, "Staten Island"),
    ("Hudson River (water)",40.760, -74.020, None),
    ("Atlantic Ocean",      40.50,  -73.90,  None),
    ("Newark NJ (outside)", 40.735, -74.172, None),
    ("Yonkers (outside)",   40.95,  -73.87,  None),
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

# ---- Self-resolution proxy: bbox CENTER of 300 random precincts ----
print()
print("=" * 78)
print("SELF-RESOLUTION HEALTH (bbox center of 300 random precincts)")
print("=" * 78)

all_rows = conn.execute(
    "SELECT rowid, unit_id, borough, min_lon, min_lat, max_lon, max_lat "
    "FROM precincts"
).fetchall()
print(f"total precincts: {len(all_rows)}")

random.seed(42)
sample = random.sample(all_rows, 300)

self_fail = []          # center did not resolve to ITSELF
center_null = []        # center resolved to nothing at all
center_other = []       # center resolved to a DIFFERENT precinct
for r in sample:
    rid, uid, boro = r["rowid"], r["unit_id"], r["borough"]
    clon = (r["min_lon"] + r["max_lon"]) / 2.0
    clat = (r["min_lat"] + r["max_lat"]) / 2.0
    res = lookup(clon, clat)
    if res is None:
        self_fail.append((rid, uid, boro, clon, clat, None))
        center_null.append((rid, uid))
    elif res["rowid"] != rid:
        self_fail.append((rid, uid, boro, clon, clat, res["unit_id"]))
        center_other.append((rid, uid, res["unit_id"]))

print(f"sampled: 300   self-resolve failures: {len(self_fail)} "
      f"({100*len(self_fail)/300:.1f}%)")
print(f"  of which center->NULL: {len(center_null)}   center->other precinct: {len(center_other)}")
if self_fail:
    print("  examples (rowid, unit_id, borough, center lon/lat, resolved_uid):")
    for rid, uid, boro, clon, clat, ruid in self_fail[:15]:
        print(f"    rowid={rid} uid={uid} {boro} center=({clon:.5f},{clat:.5f}) -> {ruid}")

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
      f"named_fail={len(failures)} self_run=300 self_fail={len(self_fail)}")
print("=" * 78)
