#!/usr/bin/env python3
"""Post-process: dissolve each county's precincts into a handful of LEAN REGIONS so the
always-on county tint is clean and small.

For every (state, county, lean_label) group, snap-union the precinct geometries into one
(multi)polygon and store a vote-weighted representative Dem share for its color.
Adds a `county_lean_regions` table to the bundled DB IN PLACE — no full rebuild needed.

Cleaning (fixes the glitchy tint):
  1. set_precision(g, 1e-6) on every precinct polygon BEFORE union, so the independently
     Douglas-Peucker-simplified shared edges of adjacent precincts snap to the same grid
     and WELD instead of leaving sliver holes/overlaps.
  2. unary_union the snapped geoms.
  3. drop interior rings whose area < 1e-7 deg^2 (~976 m^2) — deletes residual snap slivers
     while keeping genuine holes (reservoirs, real enclaves); the hole-area histogram has a
     clean gap there.
  4. make_valid as a safety net for the rare 'nested shells' left by a dropped hole.

No-lean handling: the ~5,862 precincts with no 2024 presidential result get their OWN
'No data' bucket per county with dem_share = SQL NULL, so the county tiles to 100% coverage
(no gaps) and the app paints them gray automatically — Palette.lean(nil) -> .gray, no Swift
change. (Do NOT store 0.5: that would paint them 'Even' purple and misrepresent them.)

Usage: python add_lean_regions.py [path-to.sqlite]   (default: the app bundle DB)
"""
import os
import sqlite3
import sys
from collections import defaultdict

from shapely import wkb, set_precision, make_valid
from shapely.ops import unary_union
from shapely.geometry import Polygon, MultiPolygon

DB = sys.argv[1] if len(sys.argv) > 1 else \
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "PrecinctWeather/PrecinctKit/Resources/nyc_precincts.sqlite")

GRID = 1e-6              # snap shared edges to this grid (deg) so adjacent precincts weld exactly
MIN_HOLE_AREA = 1e-7    # drop interior rings smaller than ~976 m^2 (snap slivers), keep real holes
NO_DATA_LABEL = "No data"   # bucket for precincts with no 2024 presidential result


def _keep_polygons(geom):
    """make_valid can emit lines/points/collections; keep only the polygonal area."""
    if geom.geom_type in ("Polygon", "MultiPolygon"):
        return geom
    if geom.geom_type == "GeometryCollection":
        ps = [g for g in geom.geoms if g.geom_type in ("Polygon", "MultiPolygon")]
        return unary_union(ps) if ps else geom
    return geom


def clean_union(geoms):
    """Dissolve a bucket of precinct polygons into one clean shape:
    grid-snap so shared edges match, union, drop sliver interior holes, then re-validate."""
    snapped = [set_precision(g, GRID) for g in geoms]
    snapped = [g for g in snapped if g is not None and not g.is_empty]
    merged = unary_union(snapped)
    if merged.is_empty:
        return merged
    polys = merged.geoms if merged.geom_type == "MultiPolygon" else (
        [merged] if merged.geom_type == "Polygon" else [])
    rebuilt = []
    for p in polys:
        kept = [r for r in p.interiors if Polygon(r).area >= MIN_HOLE_AREA]
        rebuilt.append(Polygon(p.exterior.coords, [r.coords for r in kept]))
    if not rebuilt:
        return merged
    res = MultiPolygon(rebuilt) if len(rebuilt) > 1 else rebuilt[0]
    if not res.is_valid:                       # fixes rare 'nested shells' from dropped holes
        res = _keep_polygons(make_valid(res))
    return res


def main():
    con = sqlite3.connect(DB)
    rows = con.execute("""
        SELECT state, borough, lean_label, lean_dem_share, lean_votes, geometry_wkb
        FROM precincts
        WHERE geometry_wkb IS NOT NULL
    """).fetchall()                            # NOTE: no longer filters out NULL-lean precincts
    print(f"precincts with geometry: {len(rows)}")

    groups = defaultdict(lambda: {"geoms": [], "num": 0.0, "den": 0.0})
    for state, county, label, share, votes, blob in rows:
        key = (state, county, label if label is not None else NO_DATA_LABEL)
        g = groups[key]
        try:
            g["geoms"].append(wkb.loads(bytes(blob)))
        except Exception:
            continue
        if label is not None and share is not None:
            w = (votes or 0) + 1   # weight color by votes so big precincts dominate the hue
            g["num"] += share * w
            g["den"] += w

    con.execute("DROP TABLE IF EXISTS county_lean_regions")
    con.execute("""
        CREATE TABLE county_lean_regions (
            rowid INTEGER PRIMARY KEY,
            state TEXT, borough TEXT, lean_label TEXT, dem_share REAL,
            min_lon REAL, min_lat REAL, max_lon REAL, max_lat REAL,
            geometry_wkb BLOB
        )
    """)
    con.execute("CREATE INDEX idx_clr_scope ON county_lean_regions(state, borough)")

    out = []
    for (state, county, label), g in groups.items():
        if not g["geoms"]:
            continue
        merged = clean_union(g["geoms"])         # clean dissolve replaces raw unary_union
        if merged.is_empty:
            continue
        share = (g["num"] / g["den"]) if g["den"] else None   # NULL -> app renders 'No data' gray
        mnx, mny, mxx, mxy = merged.bounds
        out.append((state, county, label, share, mnx, mny, mxx, mxy, wkb.dumps(merged)))

    con.executemany("""
        INSERT INTO county_lean_regions
        (state, borough, lean_label, dem_share, min_lon, min_lat, max_lon, max_lat, geometry_wkb)
        VALUES (?,?,?,?,?,?,?,?,?)
    """, out)
    con.commit()
    con.execute("VACUUM"); con.commit()
    sz = con.execute("SELECT COUNT(*) FROM county_lean_regions").fetchone()[0]
    con.close()
    print(f"wrote {sz} clean lean regions across all counties")


if __name__ == "__main__":
    main()
