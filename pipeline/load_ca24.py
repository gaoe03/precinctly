#!/usr/bin/env python3
"""CA 2024-precinct loader: public UC Berkeley Statewide Database (SWDB) 2024 General.

Makes the project's biggest gap (CA had no public 2020 VTDs) fully public:
  - geometry + ids:  srprec_state_g24_v01_shp  (SRPREC_KEY = 11-char FIPS+SRPREC, lon/lat)
  - 2024 president:  state_g24_sov_data_by_g24_srprec.csv (PRSDEM01 / PRSREP01)
  - block->precinct: state_g24_sr_blk_map.csv (BLOCK_KEY 15-digit -> SRPREC_KEY, PCTBLK share)
  - block race/pop:  CA PL94 (ca000012020.pl P1/P2 by block) aggregated via the crosswalk
  - ACS income/edu/tenure/age: national .dat, block-group -> precinct via the same crosswalk

Yields the same demographics/elections shape the pipeline's build() consumes. Reuses the
load_vtd helpers (ACS table reader, income-bracket median, edu bucket ranges).
"""
import csv
import os
import zipfile

import shapefile
from shapely.geometry import Polygon
from shapely.ops import unary_union, transform as shp_transform
from pyproj import Transformer

# Equal-area (US Albers, metres) for computing precinct land area -> density.
_AREA_TF = Transformer.from_crs("EPSG:4326", "EPSG:5070", always_xy=True).transform
_SQM_PER_SQMI = 2589988.110336

from load_vtd import (_read_acs_table, _median_from_hist, _acs_jam,
                      _EDU_NO_HS, _EDU_HS, _EDU_BACH, _EDU_GRAD, INCOME_TOPCODE)


def _signed_area(ring):
    s = 0.0
    for i in range(len(ring) - 1):
        x1, y1 = ring[i]; x2, y2 = ring[i + 1]
        s += (x2 - x1) * (y2 + y1)
    return s


def _shape_to_geom(shape):
    """Build a shapely geometry from a pyshp shape's raw rings — sliver-safe (skips
    degenerate rings instead of crashing pyshp's __geo_interface__ ring organizer).
    Exterior rings (CW, positive signed area) minus hole rings (CCW) that fall inside."""
    pts, parts = shape.points, list(shape.parts) + [len(shape.points)]
    exts, holes = [], []
    for i in range(len(shape.parts)):
        ring = pts[parts[i]:parts[i + 1]]
        if len(ring) < 4:
            continue
        try:
            poly = Polygon(ring).buffer(0)
        except Exception:
            continue
        if poly.is_empty or poly.area == 0:
            continue
        (exts if _signed_area(ring) > 0 else holes).append(poly)
    if not exts:
        return None
    geom = unary_union(exts)
    for h in holes:
        if geom.intersects(h):
            geom = geom.difference(h)
    return geom if not geom.is_empty else None

DATA = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "public_data", "2024")
CA_FIPS = "06"

# PL94 segment-1 field indices (0-based): 5 header + P1(71) + P2(73).
_P1_TOTAL = 5      # P1_001N total population
_P2 = {            # the clean non-Hispanic-by-race partition (P2) -> contract race vars
    "pop_hispanic": 77,   # P2_002N Hispanic or Latino (any race)
    "pop_white": 80,      # P2_005N NH White alone
    "pop_black": 81,      # P2_006N NH Black alone
    "pop_native": 82,     # P2_007N NH American Indian/Alaska Native alone
    "pop_asian": 83,      # P2_008N NH Asian alone
    "pop_pacific": 84,    # P2_009N NH Native Hawaiian/Pacific Islander alone
    # pop_other = NH Some Other Race alone (P2_010N, idx 85) + NH Two-or-more (P2_011N, idx 86)
}


def load_geometry_ca():
    sf = shapefile.Reader(os.path.join(DATA, "srprec_state_g24_shp", "srprec_state_g24_v01_shp"))
    fi = {f[0]: i for i, f in enumerate(sf.fields[1:])}
    out = {}
    for i in range(len(sf)):
        rec = sf.record(i)
        geom = _shape_to_geom(sf.shape(i))   # sliver-safe (raw rings, not __geo_interface__)
        if geom is None:
            continue
        key = rec[fi["SRPREC_KEY"]]
        out[key] = {"geometry": geom,
                    "county_fips": rec[fi["FIPS_CODE"]], "name": rec[fi["SRPREC"]]}
    return out


def load_elec_ca():
    out = {}
    with open(os.path.join(DATA, "sov_srprec", "state_g24_sov_data_by_g24_srprec.csv"), newline="") as f:
        for row in csv.DictReader(f):
            key = row.get("SRPREC_KEY")
            try:
                dem, rep = int(float(row["PRSDEM01"])), int(float(row["PRSREP01"]))
            except (ValueError, TypeError, KeyError):
                continue
            if key:
                out[key] = {("president", 2024): {"dem": dem, "rep": rep, "other": 0}}
    _merge_prior_years_ca(out)
    return out


# A crosswalked prior-year reading needs at least this many two-party votes AND at least
# this fraction of the 2024 electorate to be a real precinct (not a new-construction /
# redistricting fragment). See build_ca_prioryear.py and the project guide.
_PRIOR_ABS_FLOOR = 25
_PRIOR_REL_FLOOR = 0.25


def _merge_prior_years_ca(out):
    """Add 2016/2020 president (from the spatial prior-year crosswalk) to each 2024 precinct
    where the prior electorate is large enough to be reliable. build() then derives the
    trajectory (prev_year / lean_shift) from whichever prior years survive."""
    path = os.path.join(DATA, "ca_prioryear_by_srprec.csv")
    if not os.path.exists(path):
        return
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            key = row["SRPREC_KEY"]
            cur = out.get(key)
            if not cur:
                continue
            v24 = cur[("president", 2024)]["dem"] + cur[("president", 2024)]["rep"]
            for yr, dc, rc in ((2016, "dem16", "rep16"), (2020, "dem20", "rep20")):
                d, r = int(row[dc]), int(row[rc])
                if d + r >= _PRIOR_ABS_FLOOR and (d + r) >= _PRIOR_REL_FLOOR * v24 and d + r > 0:
                    cur[("president", yr)] = {"dem": d, "rep": r, "other": 0}


def _load_block_to_precinct():
    """{block_geoid15: [(precinct_key, weight), ...]} from the SWDB sr_blk crosswalk.
    Weight = PCTBLK/100 (share of the block assigned to that precinct)."""
    out = {}
    with open(os.path.join(DATA, "state_g24_sr_blk_map.csv"), newline="") as f:
        for row in csv.DictReader(f):
            blk, prec = row.get("BLOCK_KEY"), row.get("SRPREC_KEY")
            try:
                w = float(row.get("PCTBLK", 0)) / 100.0
            except (ValueError, TypeError):
                w = 0.0
            if blk and prec and w > 0:
                out.setdefault(blk, []).append((prec, w))
    return out


def _load_block_race():
    """{block_geoid15: {pop_total, pop_white, ...}} from CA PL94 P1/P2 by block."""
    geo_path, seg_path = os.path.join(DATA, "cageo2020.pl"), os.path.join(DATA, "ca000012020.pl")
    if not (os.path.exists(geo_path) and os.path.exists(seg_path)):
        with zipfile.ZipFile(os.path.join(DATA, "ca2020.pl.zip")) as z:
            z.extractall(DATA)
    logrec_to_block = {}
    with open(geo_path, encoding="latin-1") as f:
        for line in f:
            p = line.rstrip("\n").split("|")
            if p[2] == "750":                      # block summary level
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
            other = g(85) + g(86)                  # NH Some-Other-Race + NH Two-or-more
            out[blk] = {"pop_total": g(_P1_TOTAL), "pop_other": other,
                        **{var: g(idx) for var, idx in _P2.items()}}
    return out


def load_ca24():
    """{SRPREC_KEY: SourceRecord-ish {geometry, county_fips, name, elections, demographics}}."""
    geo = load_geometry_ca()
    elec = load_elec_ca()
    blk2prec = _load_block_to_precinct()
    blkrace = _load_block_race()

    # ACS tables (national .dat), CA only.
    incb, incb_c = _read_acs_table("b19001", CA_FIPS)
    edu, edu_c = _read_acs_table("b15003", CA_FIPS)
    ten, ten_c = _read_acs_table("b25003", CA_FIPS)
    inc, inc_c = _read_acs_table("b19013", CA_FIPS)
    age, age_c = _read_acs_table("b01002", CA_FIPS)

    # --- aggregate block race/pop -> precinct via the crosswalk ---
    RACE = ["pop_total", "pop_white", "pop_black", "pop_hispanic", "pop_asian",
            "pop_native", "pop_pacific", "pop_other"]
    pdemo = {k: {r: 0.0 for r in RACE} for k in geo}
    # bg -> {precinct: pop} for the ACS apportionment, and bg total pop
    bg_total, bg_prec = {}, {}
    for blk, parts in blk2prec.items():
        br = blkrace.get(blk)
        if not br:
            continue
        bg = blk[:12]
        for prec, w in parts:
            if prec in pdemo:
                for r in RACE:
                    pdemo[prec][r] += br[r] * w
            pop = br["pop_total"] * w
            bg_total[bg] = bg_total.get(bg, 0) + pop
            bg_prec.setdefault(bg, {})
            bg_prec[bg][prec] = bg_prec[bg].get(prec, 0) + pop

    # --- ACS block-group -> precinct (population-weighted), reusing the bracket median ---
    acc = {}
    def A(p):
        return acc.setdefault(p, dict(no_hs=0.0, hs=0.0, bach=0.0, grad=0.0, owner=0.0,
                                      renter=0.0, inc_hist=[0.0] * 16, inc_num=0.0,
                                      inc_den=0.0, age_num=0.0, age_den=0.0))
    for bg, precs in bg_prec.items():
        tot = bg_total.get(bg, 0)
        weights = ({p: 1.0 / len(precs) for p in precs} if tot <= 0
                   else {p: pp / tot for p, pp in precs.items()})
        cf = CA_FIPS + bg[2:5]
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

    # --- assemble per-precinct records ---
    out = {}
    for key, gv in geo.items():
        d = {r: int(round(pdemo[key][r])) for r in RACE}
        d["vap_total"] = None; d["cvap"] = None
        a = acc.get(key)
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
        try:
            area_sqmi = shp_transform(_AREA_TF, gv["geometry"]).area / _SQM_PER_SQMI
            d["pop_density"] = round(d["pop_total"] / area_sqmi, 1) if (area_sqmi > 0 and d["pop_total"]) else None
        except Exception:
            d["pop_density"] = None
        out[key] = {"geometry": gv["geometry"], "county_fips": gv["county_fips"],
                    "name": gv["name"], "demographics": d,
                    "elections": elec.get(key, {})}
    return out


if __name__ == "__main__":
    rec = load_ca24()
    print("CA 2024 precincts:", len(rec))
    tot_pop = sum(r["demographics"]["pop_total"] for r in rec.values())
    dem = sum(r["elections"].get(("president", 2024), {}).get("dem", 0) for r in rec.values())
    rep = sum(r["elections"].get(("president", 2024), {}).get("rep", 0) for r in rec.values())
    print(f"statewide pop={tot_pop:,} (CA ~39.5M)  2024 pres dem={dem:,} rep={rep:,}  "
          f"dem_share={dem/(dem+rep):.3f} (CA 2024 ~0.585)")
    k = next(iter(rec))
    print("sample", k, {kk: rec[k]["demographics"][kk] for kk in ("pop_total", "pop_white", "pop_hispanic", "income_median", "avg_age")})
