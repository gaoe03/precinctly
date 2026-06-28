#!/usr/bin/env python3
"""CA prior-year president (2016, 2020) onto 2024 SRPREC precincts.

Source: ALARM census-2020 VEST file (per-2020-census-block president, GEOID20).
Method: assign each 2020 census block to the 2024 SRPREC whose polygon contains the
block centroid (tabblock20 INTPTLAT/LON, NAD83 lon/lat = same CRS as the srprec shp),
then sum block votes per precinct. Whole-block assignment (blocks are small); this is
the same spatial crosswalk used for NY/TX in load_p24. The SWDB registration crosswalk
is NOT used here because VEST's vote surface puts ~14% of votes in zero-population
blocks the registration map omits.

Writes ca_prioryear_by_srprec.csv: SRPREC_KEY,dem16,rep16,dem20,rep20
"""
import csv, os, sys
from shapely.geometry import Point
from shapely.strtree import STRtree
from load_ca24 import load_geometry_ca, DATA

ALARM = os.path.join(DATA, "alarm_ca_2020_block.csv")
TABBLK = os.path.join(DATA, "tl_2020_06_tabblock20", "tl_2020_06_tabblock20")
OUT = os.path.join(DATA, "ca_prioryear_by_srprec.csv")


def fv(x):
    x = (x or "").strip()
    return 0.0 if x in ("", "NA", "NaN") else float(x)


def build():
    print("loading 2024 srprec polygons ...")
    geo = load_geometry_ca()
    keys = list(geo)
    geoms = [geo[k]["geometry"] for k in keys]
    tree = STRtree(geoms)
    print(f"  {len(keys):,} precincts")

    print("loading block centroids (tabblock20 DBF) ...")
    import shapefile
    r = shapefile.Reader(TABBLK)
    fi = {f[0]: i for i, f in enumerate(r.fields[1:])}
    centroids = []
    for rec in r.iterRecords():
        centroids.append((rec[fi["GEOID20"]],
                          float(rec[fi["INTPTLON20"]]), float(rec[fi["INTPTLAT20"]])))
    print(f"  {len(centroids):,} blocks")

    print("spatial assign block -> precinct ...")
    blk2prec = {}
    unassigned = 0
    for blk, lon, lat in centroids:
        pt = Point(lon, lat)
        hit = None
        for idx in tree.query(pt):
            if geoms[idx].contains(pt):
                hit = keys[idx]
                break
        if hit is None:
            unassigned += 1
        else:
            blk2prec[blk] = hit
    print(f"  assigned {len(blk2prec):,}  unassigned {unassigned:,}")

    print("apportion ALARM votes ...")
    srp = {k: [0.0, 0.0, 0.0, 0.0] for k in keys}
    tot = [0.0, 0.0, 0.0, 0.0]
    lost = [0.0, 0.0, 0.0, 0.0]
    with open(ALARM) as f:
        for row in csv.DictReader(f):
            v = (fv(row["pre_16_dem_cli"]), fv(row["pre_16_rep_tru"]),
                 fv(row["pre_20_dem_bid"]), fv(row["pre_20_rep_tru"]))
            for i in range(4):
                tot[i] += v[i]
            prec = blk2prec.get(row["GEOID20"])
            if prec is None:
                for i in range(4):
                    lost[i] += v[i]
                continue
            acc = srp[prec]
            for i in range(4):
                acc[i] += v[i]

    have = sum(1 for k in srp if sum(srp[k]) > 0)
    print(f"\nprecincts with prior-year votes: {have:,} / {len(keys):,}")
    lab = ["2016 D", "2016 R", "2020 D", "2020 R"]
    for i in range(4):
        pct = 100 * lost[i] / tot[i] if tot[i] else 0
        print(f"  {lab[i]}: total={tot[i]:,.0f}  lost(unassigned)={lost[i]:,.0f} ({pct:.3f}%)")
    a = sum(srp[k][0] for k in srp); b = sum(srp[k][1] for k in srp)
    c = sum(srp[k][2] for k in srp); d = sum(srp[k][3] for k in srp)
    print(f"  re-agg two-party D  2016={100*a/(a+b):.2f}%  2020={100*c/(c+d):.2f}%")
    print(f"  (certified CA 2016 D 66.13%  2020 D 64.91%)")

    with open(OUT, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["SRPREC_KEY", "dem16", "rep16", "dem20", "rep20"])
        for k in keys:
            a, b, c, d = srp[k]
            w.writerow([k, round(a), round(b), round(c), round(d)])
    print(f"wrote {OUT}")


if __name__ == "__main__":
    build()
