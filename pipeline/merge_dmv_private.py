#!/usr/bin/env python3
"""Merge the curated private DMV precinct rows into a copy of the shipped DB.

This is intentionally a local-only bridge for the private source DB.  It never
writes either source database.  The private DC shapes use an undocumented local
coordinate frame, so DC is normalized through a checked public DC control layer
in Maryland State Plane meters (EPSG:26985).  Pass ``--exclude-dc`` only for a
Maryland/Virginia trial copy.
"""
import argparse
import json
import os
import re
import shutil
import sqlite3
import tempfile
from collections import defaultdict

from shapely import wkb
from shapely.affinity import affine_transform
from shapely.geometry import shape
from shapely.ops import transform as shp_transform
from pyproj import Transformer

from build_region_precincts import adapter_josh, build
from add_lean_regions import clean_union

CURATED_FIPS = {
    "11001": "DC",
    "24031": "MD", "24033": "MD",
    "51013": "VA", "51510": "VA", "51059": "VA", "51600": "VA",
    "51610": "VA", "51107": "VA", "51153": "VA", "51683": "VA",
    "51685": "VA",
}
STATE_ENVELOPES = {
    "DC": (-77.20, -76.85, 38.70, 39.10),
    "MD": (-80.5, -74.5, 37.5, 40.5),
    "VA": (-84.5, -75.0, 35.0, 40.0),
}

# The private DC geometry is a rotated/translated local grid. These constants
# map it into the public DCGIS Maryland State Plane meter frame. They were fit
# against 144 matching precinct controls and leave sub-centimetre centroid error.
DC_TO_MD_STATEPLANE = (
    0.983539095257801, 0.208688133134032,
    -0.208688474955971, 0.983538358117722,
    -1233848.314951345, 319433.037233266,
)


def _dc_control_geometries(path):
    """Load public DC precinct controls as WGS84 polygons keyed by number."""
    try:
        with open(path, encoding="utf-8") as fh:
            obj = json.load(fh)
    except OSError as exc:
        raise SystemExit("Refusing DC merge: missing control layer %s (%s)" % (path, exc))
    to_wgs84 = Transformer.from_crs(26985, 4326, always_xy=True).transform
    controls = {}
    for feature in obj.get("features", []):
        props = feature.get("properties") or {}
        label = props.get("NAME") or props.get("name") or props.get("precinct")
        match = re.search(r"(\d+)\s*$", str(label or ""))
        if not match or not feature.get("geometry"):
            continue
        geom = shape(feature["geometry"])
        if geom.is_empty or not geom.is_valid or max(abs(v) for v in geom.bounds) < 1000:
            raise SystemExit("Refusing DC merge: control layer is not valid EPSG:26985 data")
        controls[int(match.group(1))] = shp_transform(to_wgs84, geom)
    if len(controls) != 144:
        raise SystemExit("Refusing DC merge: expected 144 control precincts, found %d" % len(controls))
    return controls


def _normalize_dc_records(records, controls):
    """Apply the proven DC local-grid transform and fail closed on mismatches."""
    to_wgs84 = Transformer.from_crs(26985, 4326, always_xy=True).transform
    seen = set()
    for rec in records:
        match = re.search(r"(\d+)\s*$", rec["precinct_name"] or "")
        if not match:
            raise SystemExit("Refusing DC merge: cannot identify precinct %s" % rec["unit_id"])
        number = int(match.group(1))
        if number in seen or number not in controls:
            raise SystemExit("Refusing DC merge: missing or duplicate control for precinct %s" % number)
        seen.add(number)
        raw = rec["geometry"]
        if raw is None or raw.is_empty:
            raise SystemExit("Refusing DC merge: missing private geometry for %s" % rec["unit_id"])
        projected = affine_transform(raw, DC_TO_MD_STATEPLANE)
        normalized = shp_transform(to_wgs84, projected)
        if normalized.is_empty or not normalized.is_valid:
            raise SystemExit("Refusing DC merge: normalized geometry invalid for %s" % rec["unit_id"])
        control = controls[number]
        overlap = normalized.intersection(control).area / normalized.union(control).area
        centroid_error = normalized.centroid.distance(control.centroid)
        if overlap < 0.95 or centroid_error > 0.002:
            raise SystemExit(
                "Refusing DC merge: geometry %s does not match its public control "
                "(IoU %.4f, centroid error %.6f degrees)" %
                (rec["unit_id"], overlap, centroid_error)
            )
        rec["geometry"] = normalized
    if seen != set(controls):
        raise SystemExit("Refusing DC merge: private/control precinct sets differ")


def _upsert_dmv_baseline(con):
    """Persist a population-weighted DMV-core comparison row in the target DB."""
    fips = tuple(CURATED_FIPS)
    rows = con.execute(
        "SELECT pop_total, pct_white, pct_black, pct_hispanic, pct_asian, pct_native, "
        "pct_pacific, pct_other, pct_ba_or_higher, income_median, pct_renter, avg_age, "
        "lean_dem_share, lean_votes FROM precincts WHERE fips IN (%s)" % ",".join("?" * len(fips)),
        fips,
    ).fetchall()
    if not rows:
        raise SystemExit("Refusing merge: DMV baseline has no precinct rows")
    pop = sum((r[0] or 0) for r in rows)
    if pop <= 0:
        raise SystemExit("Refusing merge: DMV baseline has no population")

    def weighted(index):
        values = [(r[index], r[0] or 0) for r in rows if r[index] is not None and (r[0] or 0) > 0]
        return sum(v * w for v, w in values) / sum(w for _, w in values) if values else None

    values = {
        "scope": "region|DMV",
        "precinct_count": len(rows),
        "pop_total": pop,
        "pct_white": weighted(1), "pct_black": weighted(2), "pct_hispanic": weighted(3),
        "pct_asian": weighted(4), "pct_native": weighted(5), "pct_pacific": weighted(6),
        "pct_other": weighted(7), "pct_ba_or_higher": weighted(8),
        "income_median": int(round(weighted(9))) if weighted(9) is not None else None,
        "pct_renter": weighted(10), "avg_age": weighted(11),
        "pres24_dem_share": weighted(12),
    }
    columns = [d[1] for d in con.execute("PRAGMA table_info(baselines)").fetchall()]
    if "region|DMV" in {r[0] for r in con.execute("SELECT scope FROM baselines") }:
        con.execute("DELETE FROM baselines WHERE scope = 'region|DMV'")
    usable = [c for c in columns if c in values]
    con.execute(
        "INSERT INTO baselines (%s) VALUES (%s)" % (",".join(usable), ",".join("?" * len(usable))),
        [values[c] for c in usable],
    )


def _source_fips(src_path):
    con = sqlite3.connect(f"file:{src_path}?mode=ro&immutable=1", uri=True)
    rows = con.execute(
        "SELECT DISTINCT fips FROM precincts WHERE fips IN (%s)"
        % ",".join("?" * len(CURATED_FIPS)), tuple(CURATED_FIPS)
    ).fetchall()
    con.close()
    return {r[0] for r in rows}


def _merge(target_path, add_path):
    con = sqlite3.connect(target_path)
    add = sqlite3.connect(add_path)
    target_baseline_columns = {row[1] for row in con.execute("PRAGMA table_info(baselines)")}
    if "precinct_count" not in target_baseline_columns:
        # Older public bundles predate the count field. Add it before copying the
        # generated DMV row so the comparison floor remains durable after a merge.
        con.execute("ALTER TABLE baselines ADD COLUMN precinct_count INTEGER")
    # Existing rows are untouched.  Allocate fresh rowids for the R-tree.
    add_uids = [r[0] for r in add.execute("SELECT unit_id FROM precincts")]
    duplicate = None
    for i in range(0, len(add_uids), 900):
        chunk = add_uids[i:i + 900]
        duplicate = con.execute(
            "SELECT unit_id FROM precincts WHERE unit_id IN (%s) LIMIT 1"
            % ",".join("?" * len(chunk)), chunk
        ).fetchone()
        if duplicate:
            break
    if duplicate:
        con.close(); add.close()
        raise SystemExit("Refusing merge: target already contains unit_id %s" % duplicate[0])
    add_dupe = add.execute(
        "SELECT unit_id FROM precincts GROUP BY unit_id HAVING COUNT(*) > 1 LIMIT 1"
    ).fetchone()
    if add_dupe:
        con.close(); add.close()
        raise SystemExit("Refusing merge: generated DMV DB duplicates unit_id %s" % add_dupe[0])
    next_id = con.execute("SELECT COALESCE(MAX(rowid), 0) FROM precincts").fetchone()[0] + 1
    rows = add.execute("SELECT * FROM precincts ORDER BY rowid").fetchall()
    cols = [d[1] for d in con.execute("PRAGMA table_info(precincts)").fetchall()]
    id_map = {}
    for row in rows:
        old_id = row[0]
        vals = list(row)
        vals[0] = next_id
        con.execute(
            "INSERT INTO precincts (%s) VALUES (%s)"
            % (",".join(cols), ",".join("?" * len(cols))),
            vals,
        )
        id_map[old_id] = next_id
        next_id += 1

    elections = add.execute(
        "SELECT unit_id,office,year,dem,rep,other,dem_share FROM precinct_elections"
    ).fetchall()
    con.executemany("INSERT INTO precinct_elections VALUES (?,?,?,?,?,?,?)", elections)
    # Add only the new baseline scopes.  Existing state/county/metro rows win if
    # a future source overlaps one, preserving the authoritative comparisons.
    bcols = [d[1] for d in con.execute("PRAGMA table_info(baselines)").fetchall()]
    for row in add.execute("SELECT %s FROM baselines" % ",".join(bcols)):
        scope = row[0]
        if con.execute("SELECT 1 FROM baselines WHERE scope=?", (scope,)).fetchone():
            continue
        con.execute(
            "INSERT INTO baselines (%s) VALUES (%s)"
            % (",".join(bcols), ",".join("?" * len(bcols))),
            row,
        )
    # Build lean-region dissolves for the added rows only.  Existing regions are
    # retained, and a duplicate scope/label is skipped rather than replaced.
    try:
        con.execute("SELECT 1 FROM county_lean_regions LIMIT 1")
        add_rows = add.execute(
            "SELECT state,borough,lean_label,lean_dem_share,lean_votes,geometry_wkb "
            "FROM precincts WHERE geometry_wkb IS NOT NULL"
        ).fetchall()
        groups = defaultdict(lambda: [[], 0.0, 0.0])
        for state, borough, label, share, votes, blob in add_rows:
            key = (state, borough, label or "No data")
            groups[key][0].append(wkb.loads(bytes(blob)))
            if label and share is not None:
                wt = (votes or 0) + 1
                groups[key][1] += share * wt
                groups[key][2] += wt
        for (state, borough, label), (geoms, num, den) in groups.items():
            if con.execute(
                "SELECT 1 FROM county_lean_regions WHERE state=? AND borough=? AND lean_label=?",
                (state, borough, label),
            ).fetchone():
                continue
            merged = clean_union(geoms)
            mnx, mny, mxx, mxy = merged.bounds
            con.execute(
                "INSERT INTO county_lean_regions "
                "(state,borough,lean_label,dem_share,min_lon,min_lat,max_lon,max_lat,geometry_wkb) "
                "VALUES (?,?,?,?,?,?,?,?,?)",
                (state, borough, label, num / den if den else None, mnx, mny, mxx, mxy, wkb.dumps(merged)),
            )
    except sqlite3.OperationalError:
        pass
    # R-tree ids must match the newly assigned precinct rowids.
    add_rtree = add.execute(
        "SELECT id,min_lon,max_lon,min_lat,max_lat FROM precinct_rtree"
    ).fetchall()
    con.executemany(
        "INSERT INTO precinct_rtree (id,min_lon,max_lon,min_lat,max_lat) VALUES (?,?,?,?,?)",
        [(id_map[i], a, b, c, d) for i, a, b, c, d in add_rtree],
    )
    _upsert_dmv_baseline(con)
    con.commit()
    con.execute("ANALYZE")
    con.close(); add.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.join(os.path.dirname(os.path.dirname(__file__)), "precincts_2026_primary.db"))
    ap.add_argument("--base", default=os.path.join(os.path.dirname(os.path.dirname(__file__)), "PrecinctWeather/PrecinctKit/Resources/nyc_precincts.sqlite"))
    ap.add_argument("--out", required=True, help="new merged SQLite path")
    ap.add_argument("--dc-control", default=os.path.join(os.path.dirname(os.path.dirname(__file__)), "public_data/dc_precincts_2019.geojson"), help="public DCGIS EPSG:26985 control GeoJSON")
    ap.add_argument("--exclude-dc", action="store_true", help="allow MD/VA trial merge without DC")
    args = ap.parse_args()
    if os.path.exists(args.out):
        raise SystemExit("Refusing merge: output already exists, choose a fresh path: %s" % args.out)
    found = _source_fips(args.src)
    missing = set(CURATED_FIPS) - found
    if missing:
        raise SystemExit("Refusing merge: source is missing curated FIPS %s" % ",".join(sorted(missing)))
    wanted = [f for f in CURATED_FIPS if f != "11001" or not args.exclude_dc]
    states = sorted({CURATED_FIPS[f] for f in wanted})
    with tempfile.TemporaryDirectory(prefix="dmv-merge-") as td:
        add_db = os.path.join(td, "dmv.sqlite")
        records = [r for r in adapter_josh(states, args.src, dc_passthrough=True) if r["fips"] in wanted]
        if "11001" in wanted:
            controls = _dc_control_geometries(args.dc_control)
            _normalize_dc_records([r for r in records if r["state_abbr"] == "DC"], controls)
        for rec in records:
            env = STATE_ENVELOPES[rec["state_abbr"]]
            if rec["geometry"] is None:
                raise SystemExit("Refusing merge: missing geometry for %s" % rec["unit_id"])
            minx, miny, maxx, maxy = rec["geometry"].bounds
            if not (env[0] <= minx <= maxx <= env[1] and env[2] <= miny <= maxy <= env[3]):
                raise SystemExit("Refusing merge: %s geometry outside %s envelope: %s" %
                                 (rec["unit_id"], rec["state_abbr"], rec["geometry"].bounds))
        build(records, add_db)
        shutil.copy2(args.base, args.out)
        _merge(args.out, add_db)
    print("Merged %d curated fips into %s" % (len(wanted), args.out))


if __name__ == "__main__":
    main()
