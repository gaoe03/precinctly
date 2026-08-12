#!/usr/bin/env python3
"""State-parameterized public-VTD loaders (generalized from the NY-specific versions).

Three layers, all keyed to the 11-char Census GEOID20 ("<fips2><county3><vtd6>"):
  load_geometry(fips)       -> TIGER 2020 VTD shapefile (lon/lat geometry + land area)
  load_elec_demo(abbr)      -> DRA elections (pres/sen/gov) + CVAP/VAP, ALARM non-Hispanic race
  load_acs(abbr, fips)      -> income/edu/tenure/median-age via block-group -> VTD crosswalk

Works for any state whose raw files are cached under public_data/ (NY/MA/TX). Files are
discovered by glob so per-state DRA version suffixes (v07 etc.) don't need hardcoding.
National ACS .dat (acsdt5y2023-*) cover every state.
"""
import csv
import glob
import os
import re
import zipfile

import shapefile  # pyshp
from shapely.geometry import shape as shapely_shape

DATA = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "public_data")
SQM_PER_SQMI = 2589988.110336
INCOME_TOPCODE = 250001
JAM_NEG = -666666666


def _find(pattern):
    """Newest file matching a glob under public_data/ (handles version suffixes)."""
    m = sorted(glob.glob(os.path.join(DATA, pattern)))
    return m[-1] if m else None


# ---------------------------------------------------------------------------
# Layer 1: geometry
# ---------------------------------------------------------------------------
def load_geometry(fips):
    shp = os.path.join(DATA, f"tl_2020_{fips}_vtd20", f"tl_2020_{fips}_vtd20")
    sf = shapefile.Reader(shp)
    out = {}
    for sr in sf.iterShapeRecords():
        rec = sr.record
        out[rec["GEOID20"]] = {
            "geometry": shapely_shape(sr.shape.__geo_interface__),
            "name": rec["NAME20"],
            "county_fips": rec["STATEFP20"] + rec["COUNTYFP20"],
            "aland_sqmi": rec["ALAND20"] / SQM_PER_SQMI,
        }
    return out


# ---------------------------------------------------------------------------
# Layer 2: elections + decennial race/VAP/CVAP
# ---------------------------------------------------------------------------
_ELEC_COL = re.compile(r"^E_(\d{2})_(PRES|SEN|GOV)_(Dem|Rep|Total)$")
_OFFICE = {"PRES": "president", "SEN": "senate", "GOV": "governor"}
# ALARM non-Hispanic race-alone partition -> contract race vars.
_ALARM_RACE = {
    "pop_white": ["pop_white"], "pop_black": ["pop_black"], "pop_hispanic": ["pop_hisp"],
    "pop_asian": ["pop_asian"], "pop_native": ["pop_aian"], "pop_pacific": ["pop_nhpi"],
    "pop_other": ["pop_other", "pop_two"],   # Some-Other-Race + Two-or-more
}


def _i(v):
    try:
        return 0 if v in (None, "", ".") else int(float(v))
    except (ValueError, TypeError):
        return 0


def load_elec_demo(abbr):
    import pandas as pd
    a_path = _find(f"{abbr.lower()}_2020_vtd_alarm.csv") or _find(f"*{abbr.lower()}*alarm*.csv")
    d_path = _find(f"demographic_data_{abbr}.v*.csv")
    e_path = _find(f"election_data_{abbr}.v*.csv")
    if not (a_path and d_path and e_path):
        raise FileNotFoundError(f"{abbr}: missing ALARM/DRA files "
                                f"(alarm={a_path}, dra_demo={d_path}, dra_elec={e_path})")
    alarm = pd.read_csv(a_path, dtype={"GEOID20": str}).set_index("GEOID20")
    dem = pd.read_csv(d_path, dtype={"GEOID20": str}).set_index("GEOID20")
    ele = pd.read_csv(e_path, dtype={"GEOID20": str}).set_index("GEOID20")

    # Discover president/senate/governor year columns generically from the DRA header.
    year_offices = {}   # (office, year) -> {"dem":col,"rep":col,"tot":col}
    for col in ele.columns:
        m = _ELEC_COL.match(col)
        if not m:
            continue
        yy, off, part = m.group(1), _OFFICE[m.group(2)], m.group(3)
        year = 2000 + int(yy) if int(yy) < 50 else 1900 + int(yy)
        slot = year_offices.setdefault((off, year), {})
        slot[part.lower()[:3] if part != "Total" else "tot"] = col

    cvap_col = "V_22_CVAP_Total" if "V_22_CVAP_Total" in dem.columns else (
        "V_20_CVAP_Total" if "V_20_CVAP_Total" in dem.columns else None)

    out = {}
    for g, ar in alarm.iterrows():
        d = {"pop_total": _i(ar.get("pop")), "vap_total": _i(ar.get("vap")),
             "cvap": (_i(dem.loc[g][cvap_col]) if (cvap_col and g in dem.index) else None)}
        for var, srcs in _ALARM_RACE.items():
            d[var] = sum(_i(ar.get(s)) for s in srcs)
        for k in ("edu_no_hs", "edu_hs", "edu_bachelors", "edu_graduate",
                  "income_median", "avg_age", "housing_owner", "housing_renter", "pop_density"):
            d[k] = None
        elections = {}
        if g in ele.index:
            er = ele.loc[g]
            for (off, year), slot in year_offices.items():
                tot = er.get(slot.get("tot"))
                if tot is None or (isinstance(tot, float) and tot != tot) or _i(tot) == 0:
                    continue
                dv, rv = _i(er.get(slot.get("dem"))), _i(er.get(slot.get("rep")))
                elections[(off, year)] = {"dem": dv, "rep": rv, "other": _i(tot) - dv - rv}
        out[g] = {"elections": elections, "demographics": d}
    return out


# ---------------------------------------------------------------------------
# Layer 3: ACS (income/edu/tenure/median-age) via block-group -> VTD crosswalk
# ---------------------------------------------------------------------------
_EDU_NO_HS, _EDU_HS, _EDU_BACH, _EDU_GRAD = range(1, 16), range(16, 21), [21], range(22, 25)
_INC_LOWER = [0, 10000, 15000, 20000, 25000, 30000, 35000, 40000, 45000,
              50000, 60000, 75000, 100000, 125000, 150000, 200000]
_INC_WIDTH = [10000, 5000, 5000, 5000, 5000, 5000, 5000, 5000, 5000,
              10000, 15000, 25000, 25000, 25000, 50000, None]


def _acs_jam(v):
    if v in (None, "", "."):
        return None
    try:
        f = float(v)
    except ValueError:
        return None
    return None if (f <= JAM_NEG or f < 0) else f


def _read_acs_table(table, fips):
    """{bg12: [estimates]}, {county5: [estimates]} for one ACS table, this state only."""
    path = os.path.join(DATA, f"acsdt5y2023-{table}.dat")
    bg_out, cty_out = {}, {}
    with open(path, newline="") as f:
        r = csv.reader(f, delimiter="|")
        header = next(r)
        e_idx = [i for i, h in enumerate(header) if "_E" in h]
        for row in r:
            geo = row[0]
            if geo.startswith(f"1500000US{fips}"):
                bg_out[geo.split("US", 1)[1]] = [_acs_jam(row[i]) for i in e_idx]
            elif geo.startswith(f"0500000US{fips}"):
                cty_out[geo.split("US", 1)[1]] = [_acs_jam(row[i]) for i in e_idx]
    return bg_out, cty_out


def _load_block_pop(abbr):
    pre = abbr.lower()
    geo_path = os.path.join(DATA, f"{pre}geo2020.pl")
    seg_path = os.path.join(DATA, f"{pre}000012020.pl")
    if not (os.path.exists(geo_path) and os.path.exists(seg_path)):
        z = _find(f"{pre}2020.pl.zip")
        if z:
            with zipfile.ZipFile(z) as zf:
                zf.extractall(DATA)
    logrec_to_block = {}
    with open(geo_path, encoding="latin-1") as f:
        for line in f:
            p = line.rstrip("\n").split("|")
            if p[2] != "750":
                continue
            logrec_to_block[p[7]] = p[9][-15:]
    block_pop = {}
    with open(seg_path, encoding="latin-1") as f:
        for line in f:
            p = line.rstrip("\n").split("|")
            blk = logrec_to_block.get(p[4])
            if blk is None:
                continue
            try:
                block_pop[blk] = int(p[5])
            except ValueError:
                block_pop[blk] = 0
    return block_pop


def _load_baf(abbr, fips):
    out = {}
    z = _find(f"BlockAssign_ST{fips}_{abbr}.zip")
    with zipfile.ZipFile(z) as zf:
        with zf.open(f"BlockAssign_ST{fips}_{abbr}_VTD.txt") as fh:
            for ln in fh.read().decode("latin-1").splitlines()[1:]:
                blockid, countyfp, district = ln.split("|")
                if not district or district == "ZZZZZZ":
                    continue
                out[blockid] = fips + countyfp + district
    return out


def _load_cvap_from_dra(abbr):
    out = {}
    p = _find(f"demographic_data_{abbr}.v*.csv")
    with open(p, newline="") as f:
        for row in csv.DictReader(f):
            v = row.get("V_22_CVAP_Total") or row.get("V_20_CVAP_Total")
            try:
                out[row["GEOID20"]] = int(round(float(v)))
            except (ValueError, TypeError):
                pass
    return out


def _median_from_hist(hist):
    total = sum(hist)
    if total <= 0:
        return None
    half = total / 2.0
    cum = 0.0
    for i in range(16):
        if cum + hist[i] >= half:
            if _INC_WIDTH[i] is None:
                return INCOME_TOPCODE
            return int(round(_INC_LOWER[i] + (half - cum) / hist[i] * _INC_WIDTH[i]))
        cum += hist[i]
    return INCOME_TOPCODE


def load_acs(abbr, fips):
    block_pop = _load_block_pop(abbr)
    baf = _load_baf(abbr, fips)
    incb, incb_c = _read_acs_table("b19001", fips)
    inc, inc_c = _read_acs_table("b19013", fips)
    edu, edu_c = _read_acs_table("b15003", fips)
    ten, ten_c = _read_acs_table("b25003", fips)
    age, age_c = _read_acs_table("b01002", fips)
    cvap = _load_cvap_from_dra(abbr)

    bg_total, bg_vtd = {}, {}
    for blk, pop in block_pop.items():
        vtd = baf.get(blk)
        if vtd is None:
            continue
        bg = blk[:12]
        bg_total[bg] = bg_total.get(bg, 0) + pop
        bg_vtd.setdefault(bg, {})
        bg_vtd[bg][vtd] = bg_vtd[bg].get(vtd, 0) + pop

    acc = {}
    def A(vtd):
        return acc.setdefault(vtd, dict(no_hs=0.0, hs=0.0, bach=0.0, grad=0.0, owner=0.0,
                                        renter=0.0, inc_hist=[0.0] * 16, inc_num=0.0,
                                        inc_den=0.0, age_num=0.0, age_den=0.0))

    for bg, vtds in bg_vtd.items():
        tot = bg_total.get(bg, 0)
        weights = ({v: 1.0 / len(vtds) for v in vtds} if tot <= 0
                   else {v: p / tot for v, p in vtds.items()})
        cf = fips + bg[2:5]
        e_edu, e_ten, e_incb = edu.get(bg), ten.get(bg), incb.get(bg)
        if e_edu is None and tot:
            cc = edu_c.get(cf)
            if cc and cc[0]:
                e_edu = [(x or 0) * tot / cc[0] for x in cc]
        if e_ten is None and tot:
            cc = ten_c.get(cf); denom = (edu_c.get(cf) or [None])[0]
            if cc and denom:
                e_ten = [(x or 0) * tot / denom for x in cc]
        if e_incb is None and tot:
            cc = incb_c.get(cf)
            if cc and cc[0]:
                e_incb = [(x or 0) * tot / cc[0] for x in cc]
        e_inc = inc.get(bg) or inc_c.get(cf)
        e_age = age.get(bg) or age_c.get(cf)
        for vtd, w in weights.items():
            a = A(vtd)
            if e_edu:
                a["no_hs"] += w * sum(e_edu[i] or 0 for i in _EDU_NO_HS)
                a["hs"] += w * sum(e_edu[i] or 0 for i in _EDU_HS)
                a["bach"] += w * sum(e_edu[i] or 0 for i in _EDU_BACH)
                a["grad"] += w * sum(e_edu[i] or 0 for i in _EDU_GRAD)
            if e_ten:
                a["owner"] += w * (e_ten[1] or 0)
                a["renter"] += w * (e_ten[2] or 0)
            if e_incb:
                for i in range(16):
                    a["inc_hist"][i] += w * (e_incb[i + 1] or 0)
            bgpop = vtds[vtd]
            if e_inc and e_inc[0] is not None and bgpop > 0:
                m = INCOME_TOPCODE if e_inc[0] >= 250000 else e_inc[0]
                a["inc_num"] += m * bgpop; a["inc_den"] += bgpop
            if e_age and e_age[0] is not None and bgpop > 0:
                a["age_num"] += e_age[0] * bgpop; a["age_den"] += bgpop

    result = {}
    for vtd, a in acc.items():
        income_median = _median_from_hist(a["inc_hist"])
        if income_median == INCOME_TOPCODE and a["inc_den"] > 0:
            ref = round(a["inc_num"] / a["inc_den"])
            income_median = INCOME_TOPCODE if ref >= 250000 else max(200000, ref)
        result[vtd] = dict(
            income_median=income_median,
            avg_age=(round(a["age_num"] / a["age_den"], 1) if a["age_den"] > 0 else None),
            edu_no_hs=int(round(a["no_hs"])), edu_hs=int(round(a["hs"])),
            edu_bachelors=int(round(a["bach"])), edu_graduate=int(round(a["grad"])),
            housing_owner=int(round(a["owner"])), housing_renter=int(round(a["renter"])),
            cvap=cvap.get(vtd))
    for vtd, c in cvap.items():
        result.setdefault(vtd, dict(income_median=None, avg_age=None, edu_no_hs=0, edu_hs=0,
                                    edu_bachelors=0, edu_graduate=0, housing_owner=0,
                                    housing_renter=0, cvap=c))
    return result


if __name__ == "__main__":
    import sys
    abbr = sys.argv[1] if len(sys.argv) > 1 else "NY"
    fips = {"NY": "36", "MA": "25", "TX": "48"}[abbr]
    geo = load_geometry(fips)
    ed = load_elec_demo(abbr)
    acs = load_acs(abbr, fips)
    print(f"{abbr}: geo={len(geo)} elec_demo={len(ed)} acs={len(acs)}")
    g = next(iter(geo))
    print("sample", g, geo[g]["county_fips"], ed.get(g, {}).get("demographics", {}).get("pop_total"),
          {k: acs.get(g, {}).get(k) for k in ("income_median", "avg_age", "cvap")})
