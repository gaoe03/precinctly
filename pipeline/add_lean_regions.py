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

Usage: python add_lean_regions.py path-to.sqlite
"""
import sqlite3
import sys
from collections import defaultdict
from pathlib import Path

from shapely import wkb, set_precision, make_valid
from shapely.ops import unary_union
from shapely.geometry import Polygon, MultiPolygon

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
    if any(g is None or g.is_empty for g in snapped):
        raise ValueError("precinct geometry collapsed during precision snapping")
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


def rebuild_lean_regions(db_path):
    path = Path(db_path).expanduser()
    if not path.is_file():
        raise FileNotFoundError(f"database does not exist: {path}")
    uri = f"{path.resolve().as_uri()}?mode=rw"
    con = sqlite3.connect(uri, uri=True)
    try:
        con.execute("BEGIN IMMEDIATE")
        rows = con.execute("""
        SELECT state, borough, lean_label, lean_dem_share, lean_votes, geometry_wkb
        FROM precincts
        ORDER BY state, borough, lean_label, rowid
    """).fetchall()                            # NOTE: includes NULL-lean precincts
        print(f"precincts: {len(rows)}")
        if not rows:
            raise ValueError("precincts table has no rows")

        groups = defaultdict(lambda: {"geoms": [], "num": 0.0, "den": 0.0})
        for row_number, (state, county, label, share, votes, blob) in enumerate(rows, 1):
            key = (state, county, label if label is not None else NO_DATA_LABEL)
            if state is None or county is None:
                raise ValueError(f"precinct row {row_number} has no state or county")
            if blob is None:
                raise ValueError(f"precinct row {row_number} in {key!r} has no geometry")
            try:
                geom = wkb.loads(bytes(blob))
            except Exception as exc:
                raise ValueError(
                    f"precinct row {row_number} in {key!r} has corrupt WKB"
                ) from exc
            if geom.is_empty:
                raise ValueError(f"precinct row {row_number} in {key!r} has empty geometry")
            if geom.geom_type not in ("Polygon", "MultiPolygon"):
                raise ValueError(
                    f"precinct row {row_number} in {key!r} has nonpolygon geometry "
                    f"{geom.geom_type}"
                )
            if not geom.is_valid:
                raise ValueError(f"precinct row {row_number} in {key!r} has invalid geometry")

            g = groups[key]
            g["geoms"].append(geom)
            if label is not None and share is not None:
                weight = (votes or 0) + 1   # weight color by votes so big precincts dominate the hue
                g["num"] += share * weight
                g["den"] += weight

        out = []
        for state, county, label in sorted(groups):
            group = groups[(state, county, label)]
            merged = clean_union(group["geoms"])   # clean dissolve replaces raw unary_union
            if merged.is_empty:
                raise ValueError(f"lean region {(state, county, label)!r} is empty after cleaning")
            if merged.geom_type not in ("Polygon", "MultiPolygon") or not merged.is_valid:
                raise ValueError(f"lean region {(state, county, label)!r} is not a valid polygon")
            share = (
                group["num"] / group["den"] if group["den"] else None
            )                                       # NULL -> app renders 'No data' gray
            mnx, mny, mxx, mxy = merged.bounds
            out.append((
                state, county, label, share, mnx, mny, mxx, mxy, wkb.dumps(merged)
            ))

        expected_groups = set(groups)
        output_groups = {(row[0], row[1], row[2]) for row in out}
        if len(out) != len(expected_groups) or output_groups != expected_groups:
            raise ValueError("lean-region output does not cover every source group exactly once")

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
        con.executemany("""
            INSERT INTO county_lean_regions
            (state, borough, lean_label, dem_share, min_lon, min_lat, max_lon, max_lat, geometry_wkb)
            VALUES (?,?,?,?,?,?,?,?,?)
        """, out)

        inserted = con.execute("""
            SELECT state, borough, lean_label, COUNT(*)
            FROM county_lean_regions
            GROUP BY state, borough, lean_label
        """).fetchall()
        inserted_groups = {(state, county, label) for state, county, label, count in inserted}
        if (
            len(inserted) != len(expected_groups)
            or any(count != 1 for _, _, _, count in inserted)
            or inserted_groups != expected_groups
        ):
            raise ValueError("replacement table does not cover every source group exactly once")
        con.commit()
        return len(out)
    except Exception:
        if con.in_transaction:
            con.rollback()
        raise
    finally:
        con.close()


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        raise SystemExit("Usage: python add_lean_regions.py path-to.sqlite")
    count = rebuild_lean_regions(args[0])
    print(f"wrote {count} clean lean regions across all counties")


if __name__ == "__main__":
    main()
