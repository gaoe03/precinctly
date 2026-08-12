#!/usr/bin/env python3
"""NY/TX 2024-precinct loader: public precinct boundaries + 2024 results, with a
block-centroid -> precinct SPATIAL crosswalk (no official block-assignment file exists
for actual 2024 precincts, unlike CA's SWDB crosswalk).

Per state: a 2024 precinct shapefile (geometry + PresDem/PresRep), the 2020 census block
shapefile tl_2020_<fips>_tabblock20 (block centroid + GEOID), and PL94 P1/P2 race by block.
Each 2020 block is assigned to whichever 2024 precinct polygon contains its centroid (shapely
STRtree). Race aggregates block->precinct; ACS apportions block-group->precinct. Reuses the
load_vtd ACS/income machinery and load_ca24's sliver-safe geometry + PL94 race reader.
"""
import csv
import os

import shapefile
from shapely.geometry import Point
from shapely.strtree import STRtree
from shapely.ops import transform as shp_transform
from pyproj import CRS, Transformer

from load_vtd import (_read_acs_table, _median_from_hist,
                      _EDU_NO_HS, _EDU_HS, _EDU_BACH, _EDU_GRAD, INCOME_TOPCODE)
from load_ca24 import _shape_to_geom, _P1_TOTAL, _P2

DATA = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "public_data", "2024")

# Per-state: precinct shapefile (no ext), id field, (Dem,Rep) result fields, FIPS, PL94 prefix.
STATES = {
    "NY": dict(shp="ny_2024_metcalf/NY_24", idf="GEOID", pres=("PresDem", "PresRep"),
               fips="36", prefix="ny"),
    "TX": dict(shp="TX24/TX24", idf="CNTYVTD", pres=("PresDem", "PresRep"),
               fips="48", prefix="tx"),
}

RACE = ["pop_total", "pop_white", "pop_black", "pop_hispanic", "pop_asian",
        "pop_native", "pop_pacific", "pop_other"]


def _load_geometry(cfg):
    base = os.path.join(DATA, cfg["shp"])
    sf = shapefile.Reader(base)
    fi = {f[0]: i for i, f in enumerate(sf.fields[1:])}
    # 2024 precinct shapefiles are in PROJECTED CRS (NY=UTM18N, TX=TX statewide mapping);
    # block centroids are lon/lat, so reproject precinct geometry to EPSG:4326 for the join.
    reproj = None
    try:
        src = CRS.from_wkt(open(base + ".prj").read())
        if not src.is_geographic:
            reproj = Transformer.from_crs(src, "EPSG:4326", always_xy=True).transform
    except Exception:
        pass
    geo, elec = {}, {}
    for i in range(len(sf)):
        rec = sf.record(i)
        g = _shape_to_geom(sf.shape(i))
        if g is None:
            continue
        if reproj is not None:
            g = shp_transform(reproj, g)
        pid = str(rec[fi[cfg["idf"]]])
        geo[pid] = g
        try:
            dem, rep = int(float(rec[fi[cfg["pres"][0]]])), int(float(rec[fi[cfg["pres"][1]]]))
            if dem + rep > 0:
                elec[pid] = {("president", 2024): {"dem": dem, "rep": rep, "other": 0}}
        except (ValueError, TypeError, KeyError):
            pass
    return geo, elec


def _load_block_centroids(prefix):
    """{block_geoid15: (lon, lat)} from the PL94 geo header (fields 92=INTPTLAT, 93=INTPTLON).
    Avoids the separate (flaky, 400MB) tabblock shapefile — the PL94 files are already local."""
    parent = os.path.dirname(DATA)
    geo_path = next((os.path.join(d, f"{prefix}geo2020.pl") for d in (DATA, parent)
                     if os.path.exists(os.path.join(d, f"{prefix}geo2020.pl"))), None)
    out = {}
    with open(geo_path, encoding="latin-1") as f:
        for line in f:
            p = line.rstrip("\n").split("|")
            if p[2] != "750":
                continue
            try:
                out[p[9][-15:]] = (float(p[93]), float(p[92]))
            except (ValueError, IndexError):
                pass
    return out


def _spatial_block_to_precinct(geo, centroids):
    """Assign each 2020 block to the precinct polygon containing its centroid (PL94 lon/lat).
    Returns {block_geoid15: precinct_id} and the precinct's county FIPS (block-derived)."""
    pids = list(geo.keys())
    geoms = [geo[p] for p in pids]
    tree = STRtree(geoms)                      # shapely 2.x: query returns integer indices
    blk2prec, prec_county = {}, {}
    for blk, (lon, lat) in centroids.items():
        pt = Point(lon, lat)
        for idx in tree.query(pt):
            if geoms[idx].contains(pt):
                pid = pids[idx]
                blk2prec[blk] = pid
                prec_county.setdefault(pid, {})
                c = blk[:5]
                prec_county[pid][c] = prec_county[pid].get(c, 0) + 1
                break
    county = {p: max(cc, key=cc.get) for p, cc in prec_county.items()}
    return blk2prec, county


def _load_block_race(prefix):
    """{block_geoid15: {pop_total, race...}} from PL94 P1/P2 (reuses load_ca24's index map).
    PL94 files may live in public_data/2024/ (CA) or public_data/ (NY/MA/TX, from the VTD work)."""
    import zipfile
    parent = os.path.dirname(DATA)
    def find(name):
        for d in (DATA, parent):
            p = os.path.join(d, name)
            if os.path.exists(p):
                return p
        return os.path.join(DATA, name)
    geo_path = find(f"{prefix}geo2020.pl")
    seg_path = find(f"{prefix}000012020.pl")
    if not (os.path.exists(geo_path) and os.path.exists(seg_path)):
        for d in (DATA, parent):
            z = os.path.join(d, f"{prefix}2020.pl.zip")
            if os.path.exists(z):
                with zipfile.ZipFile(z) as zf:
                    zf.extractall(d)
                geo_path = os.path.join(d, f"{prefix}geo2020.pl")
                seg_path = os.path.join(d, f"{prefix}000012020.pl")
                break
    logrec_to_block = {}
    with open(geo_path, encoding="latin-1") as f:
        for line in f:
            p = line.rstrip("\n").split("|")
            if p[2] == "750":
                logrec_to_block[p[7]] = p[9][-15:]
    out = {}
    with open(seg_path, encoding="latin-1") as f:
        for line in f:
            p = line.rstrip("\n").split("|")
            blk = logrec_to_block.get(p[4])
            if blk is None:
                continue
            def g(i):
                try: return int(p[i])
                except (ValueError, IndexError): return 0
            out[blk] = {"pop_total": g(_P1_TOTAL), "pop_other": g(85) + g(86),
                        **{var: g(idx) for var, idx in _P2.items()}}
    return out


def load_p24(state):
    cfg = STATES[state]
    fips = cfg["fips"]
    geo, elec = _load_geometry(cfg)
    centroids = _load_block_centroids(cfg["prefix"])
    blk2prec, pcounty = _spatial_block_to_precinct(geo, centroids)
    blkrace = _load_block_race(cfg["prefix"])

    incb, incb_c = _read_acs_table("b19001", fips)
    edu, edu_c = _read_acs_table("b15003", fips)
    ten, ten_c = _read_acs_table("b25003", fips)
    inc, inc_c = _read_acs_table("b19013", fips)
    age, age_c = _read_acs_table("b01002", fips)

    # race/pop block -> precinct; bg -> precinct pop weights (each block in one precinct, w=1)
    pdemo = {k: {r: 0.0 for r in RACE} for k in geo}
    bg_total, bg_prec = {}, {}
    for blk, prec in blk2prec.items():
        br = blkrace.get(blk)
        if not br:
            continue
        for r in RACE:
            pdemo[prec][r] += br[r]
        bg = blk[:12]
        bg_total[bg] = bg_total.get(bg, 0) + br["pop_total"]
        bg_prec.setdefault(bg, {})
        bg_prec[bg][prec] = bg_prec[bg].get(prec, 0) + br["pop_total"]

    acc = {}
    def A(p):
        return acc.setdefault(p, dict(no_hs=0.0, hs=0.0, bach=0.0, grad=0.0, owner=0.0,
                                      renter=0.0, inc_hist=[0.0] * 16, inc_num=0.0,
                                      inc_den=0.0, age_num=0.0, age_den=0.0))
    for bg, precs in bg_prec.items():
        tot = bg_total.get(bg, 0)
        weights = ({p: 1.0 / len(precs) for p in precs} if tot <= 0
                   else {p: pp / tot for p, pp in precs.items()})
        cf = fips + bg[2:5]
        e_edu, e_ten, e_incb = edu.get(bg), ten.get(bg), incb.get(bg)
        e_inc, e_age = inc.get(bg) or inc_c.get(cf), age.get(bg) or age_c.get(cf)
        if e_edu is None and tot:
            cc = edu_c.get(cf)
            if cc and cc[0]: e_edu = [(x or 0) * tot / cc[0] for x in cc]
        if e_ten is None and tot:
            cc = ten_c.get(cf); dn = (edu_c.get(cf) or [None])[0]
            if cc and dn: e_ten = [(x or 0) * tot / dn for x in cc]
        if e_incb is None and tot:
            cc = incb_c.get(cf)
            if cc and cc[0]: e_incb = [(x or 0) * tot / cc[0] for x in cc]
        for p, w in weights.items():
            a = A(p)
            if e_edu:
                a["no_hs"] += w * sum(e_edu[i] or 0 for i in _EDU_NO_HS)
                a["hs"] += w * sum(e_edu[i] or 0 for i in _EDU_HS)
                a["bach"] += w * sum(e_edu[i] or 0 for i in _EDU_BACH)
                a["grad"] += w * sum(e_edu[i] or 0 for i in _EDU_GRAD)
            if e_ten:
                a["owner"] += w * (e_ten[1] or 0); a["renter"] += w * (e_ten[2] or 0)
            if e_incb:
                for i in range(16): a["inc_hist"][i] += w * (e_incb[i + 1] or 0)
            pp = precs[p]
            if e_inc and e_inc[0] is not None and pp > 0:
                m = INCOME_TOPCODE if e_inc[0] >= 250000 else e_inc[0]
                a["inc_num"] += m * pp; a["inc_den"] += pp
            if e_age and e_age[0] is not None and pp > 0:
                a["age_num"] += e_age[0] * pp; a["age_den"] += pp

    out = {}
    for pid, g in geo.items():
        d = {r: int(round(pdemo[pid][r])) for r in RACE}
        d["vap_total"] = None; d["cvap"] = None; d["pop_density"] = None
        a = acc.get(pid)
        if a:
            im = _median_from_hist(a["inc_hist"])
            if im == INCOME_TOPCODE and a["inc_den"] > 0:
                ref = round(a["inc_num"] / a["inc_den"])
                im = INCOME_TOPCODE if ref >= 250000 else max(200000, ref)
            d.update(income_median=im,
                     avg_age=(round(a["age_num"] / a["age_den"], 1) if a["age_den"] > 0 else None),
                     edu_no_hs=int(round(a["no_hs"])), edu_hs=int(round(a["hs"])),
                     edu_bachelors=int(round(a["bach"])), edu_graduate=int(round(a["grad"])),
                     housing_owner=int(round(a["owner"])), housing_renter=int(round(a["renter"])))
        else:
            for k in ("income_median", "avg_age", "edu_no_hs", "edu_hs", "edu_bachelors",
                      "edu_graduate", "housing_owner", "housing_renter"):
                d[k] = None
        out[pid] = {"geometry": g, "county_fips": pcounty.get(pid, fips + "000"),
                    "name": pid, "demographics": d, "elections": elec.get(pid, {})}
    return out


if __name__ == "__main__":
    import sys
    st = sys.argv[1] if len(sys.argv) > 1 else "NY"
    rec = load_p24(st)
    pop = sum(r["demographics"]["pop_total"] for r in rec.values())
    dem = sum(r["elections"].get(("president", 2024), {}).get("dem", 0) for r in rec.values())
    rep = sum(r["elections"].get(("president", 2024), {}).get("rep", 0) for r in rec.values())
    print(f"{st} 2024 precincts: {len(rec)}  pop={pop:,}  2024 pres dem_share={dem/(dem+rep):.3f}")
    k = next(iter(rec))
    print("sample", k, rec[k]["county_fips"], {kk: rec[k]["demographics"][kk] for kk in ("pop_total","pop_white","pop_hispanic","income_median","avg_age")})
