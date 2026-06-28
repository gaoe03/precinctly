#!/usr/bin/env python3
"""Prove the on-device lookup contract against the SHIPPED artifact only.

Opens nyc_precincts.sqlite read-only and, for each test coordinate, runs the
exact two-step lookup the iOS app will use:
  1. R-tree bbox prefilter -> a few candidate precincts
  2. exact point-in-polygon on each candidate's WKB geometry
then prints the resolved precinct's profile. This mirrors the Swift R-tree query
+ ray-casting PIP path.
"""
import sqlite3
import sys

from shapely import wkb
from shapely.geometry import Point

OUT = "/Users/gaoe/dev/josh/nyc_precincts.sqlite"

# (label, lat, lon) -- well-known spots, several are classic ethnic enclaves.
TESTS = [
    ("Times Square, Manhattan",      40.758, -73.985),
    ("Chinatown, Manhattan",         40.716, -73.997),
    ("Jackson Heights, Queens",      40.748, -73.889),
    ("Crown Heights, Brooklyn",      40.668, -73.943),
    ("Borough Park, Brooklyn",       40.633, -73.990),
    ("Ocean (off Coney Island)",     40.560, -73.980),  # expect: no precinct (water)
]


def pct(x):
    return f"{x*100:4.1f}%" if x is not None else "  n/a"


def lookup(con, lat, lon):
    pt = Point(lon, lat)
    cand = con.execute(
        "SELECT id FROM precinct_rtree "
        "WHERE ? BETWEEN min_lon AND max_lon AND ? BETWEEN min_lat AND max_lat",
        (lon, lat)).fetchall()
    for (rid,) in cand:
        row = con.execute(
            "SELECT * FROM precincts WHERE rowid=?", (rid,)).fetchone()
        geom = wkb.loads(row["geometry_wkb"])
        if geom.contains(pt):
            return len(cand), row
    return len(cand), None


def main():
    con = sqlite3.connect(f"file:{OUT}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    for label, lat, lon in TESTS:
        n_cand, row = lookup(con, lat, lon)
        print(f"\n=== {label}  ({lat}, {lon})  candidates={n_cand} ===")
        if row is None:
            print("  -> no precinct contains this point (water / gap / outside region)")
            continue
        races = [("White", row["pct_white"]), ("Black", row["pct_black"]),
                 ("Hispanic", row["pct_hispanic"]), ("Asian", row["pct_asian"])]
        races.sort(key=lambda kv: (kv[1] is None, -(kv[1] or 0)))
        top = "  ".join(f"{n} {pct(v)}" for n, v in races)
        inc = f"${row['income_median']:,}" if row["income_median"] is not None else "n/a"
        print(f"  {row['borough']} / {row['precinct_name']}  (unit {row['unit_id']})")
        print(f"  lean        : {row['lean_label']}  "
              f"(2024 Dem 2-party {pct(row['pres24_dem_share'])}, "
              f"2020 {pct(row['pres20_dem_share'])}, shift {pct(row['lean_shift_24_20'])})")
        print(f"  plurality   : {row['plurality_group']}   diversity {row['diversity_index']:.2f}"
              if row["diversity_index"] is not None else
              f"  plurality   : {row['plurality_group']}")
        print(f"  race mix    : {top}")
        print(f"  income      : {inc}   BA+ {pct(row['pct_ba_or_higher'])}   "
              f"renters {pct(row['pct_renter'])}")
        print(f"  pop {row['pop_total']}   density {row['pop_density']:.0f}/sq mi   "
              f"avg age {row['avg_age']:.0f}" if row["pop_density"] is not None
              else f"  pop {row['pop_total']}")
    con.close()


if __name__ == "__main__":
    main()
