#!/usr/bin/env python3
"""
load_acs_ny() — NY ACS fields apportioned to 2020 VTDs (GEOID20) via a
population-weighted block-group -> VTD crosswalk.

Source data (all cached under public_data/, all keyless bulk downloads):
  1. ACS 2019-2023 5-year, table-based Summary File (block-group level), tables:
       B19013  median household income
       B15003  educational attainment (pop 25+)
       B25003  housing tenure (owner/renter)
       B01002  median age
     URL: https://www2.census.gov/programs-surveys/acs/summary_file/2023/
          table-based-SF/data/5YRData/acsdt5y2023-<table>.dat
  2. 2020 Census Block Assignment File (block -> VTD):
       https://www2.census.gov/geo/docs/maps-data/data/baf2020/BlockAssign_ST36_NY.zip
       -> BlockAssign_ST36_NY_VTD.txt  (BLOCKID|COUNTYFP|DISTRICT)
  3. 2020 PL94-171 redistricting file (block total population P1_001N):
       https://www2.census.gov/programs-surveys/decennial/2020/data/
          01-Redistricting_File--PL_94-171/New_York/ny2020.pl.zip
       -> nygeo2020.pl (geo header) + ny000012020.pl (segment 1)
  4. CVAP at VTD level comes straight from DRA's turnkey VTD demographic file
     (no crosswalk needed): public_data/demographic_data_NY.v07.csv,
     column V_22_CVAP_Total (2018-2022 ACS CVAP; closest to the 2019-2023 vintage).

Crosswalk method:
  - A block's block-group GEOID = first 12 chars of its 15-digit block GEOID.
  - A block's VTD GEOID20 = "36" + COUNTYFP(3) + DISTRICT(6)  (11 chars; matches DRA).
  - Weight w[bg -> vtd] = (pop of bg's blocks falling in vtd) / (total pop of bg).
  - Additive ACS counts (education buckets, owner, renter) are apportioned by w and
    summed per VTD.  Median income and median age (non-additive) are taken as the
    population-weighted average of the contributing block groups' medians.
  - Income top-code / jam value (250001) is preserved as the 250001 sentinel
    ("$250k+"); negative jam values (-666666666) are dropped as missing.

Returns: { GEOID20(str) : {
    income_median, avg_age,
    edu_no_hs, edu_hs, edu_bachelors, edu_graduate,
    housing_owner, housing_renter, cvap } }
"""
import csv
import os
import zipfile

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "public_data")

INCOME_TOPCODE = 250001          # contract sentinel for "$250k+"
JAM_NEG = -666666666             # ACS jam / "not computable" -> missing


def _acs_jam(v):
    """Parse an ACS .dat cell; return float or None for jam/blank/negative jam."""
    if v is None or v == "" or v == ".":
        return None
    try:
        f = float(v)
    except ValueError:
        return None
    if f <= JAM_NEG or f < 0:          # -666666666 and other negative jams
        return None
    return f


def _read_acs_table(table):
    """Read one ACS table-based .dat.  Returns (bg, county) dicts of estimate
    lists.  bg keyed by 12-digit block-group FIPS, county keyed by 5-digit
    county FIPS (used as fallback for the ~40 BGs whose 2020 tract code was
    revised between the 2020 Census and the ACS 2019-2023 tract vintage)."""
    path = os.path.join(DATA, f"acsdt5y2023-{table}.dat")
    bg_out, cty_out = {}, {}
    with open(path, newline="") as f:
        r = csv.reader(f, delimiter="|")
        header = next(r)
        e_idx = [i for i, h in enumerate(header) if "_E" in h]
        for row in r:
            geo = row[0]
            if geo.startswith("1500000US36"):          # NY block groups
                bg_out[geo.split("US", 1)[1]] = [_acs_jam(row[i]) for i in e_idx]
            elif geo.startswith("0500000US36"):         # NY counties (fallback)
                cty_out[geo.split("US", 1)[1]] = [_acs_jam(row[i]) for i in e_idx]
    return bg_out, cty_out


def _load_block_pop():
    """{block_geoid15: pop} from the 2020 PL94 file (P1_001N)."""
    geo_path = os.path.join(DATA, "nygeo2020.pl")
    seg_path = os.path.join(DATA, "ny000012020.pl")
    if not (os.path.exists(geo_path) and os.path.exists(seg_path)):
        with zipfile.ZipFile(os.path.join(DATA, "ny2020.pl.zip")) as z:
            z.extractall(DATA)
    # geo header: SUMLEV(f3), LOGRECNO(f8), GEOID(f10) -> last 15 = block fips
    logrec_to_block = {}
    with open(geo_path, encoding="latin-1") as f:
        for line in f:
            p = line.rstrip("\n").split("|")
            if p[2] != "750":                # block summary level
                continue
            logrec_to_block[p[7]] = p[9][-15:]   # GEOID field, last 15 chars
    # segment 1: LOGRECNO(f5), P1_001N(f6)
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


def _load_baf():
    """{block_geoid15: vtd_geoid20} from the 2020 Block Assignment File."""
    out = {}
    with zipfile.ZipFile(os.path.join(DATA, "BlockAssign_ST36_NY.zip")) as z:
        with z.open("BlockAssign_ST36_NY_VTD.txt") as fh:
            for ln in fh.read().decode("latin-1").splitlines()[1:]:
                blockid, countyfp, district = ln.split("|")
                if not district or district == "ZZZZZZ":
                    continue                          # block not assigned to a VTD
                out[blockid] = "36" + countyfp + district
    return out


def _load_cvap_from_dra():
    """{vtd_geoid20: cvap} straight from DRA's VTD demographic CSV."""
    out = {}
    path = os.path.join(DATA, "demographic_data_NY.v07.csv")
    with open(path, newline="") as f:
        r = csv.DictReader(f)
        for row in r:
            v = row.get("V_22_CVAP_Total", "")
            try:
                out[row["GEOID20"]] = int(round(float(v)))
            except (ValueError, TypeError):
                pass
    return out


# B15003 (education, pop 25+) estimate columns are E001..E025 in order.
# index 0 = total(001).  Buckets (1-based detail var -> 0-based list index):
#   no_hs     : 002..016  -> idx 1..15   (none .. 12th grade no diploma)
#   hs        : 017..021  -> idx 16..20  (HS diploma, GED, some college, associate)
#   bachelors : 022       -> idx 21
#   graduate  : 023..025  -> idx 22..24  (master, professional, doctorate)
_EDU_NO_HS = range(1, 16)
_EDU_HS = range(16, 21)
_EDU_BACH = [21]
_EDU_GRAD = range(22, 25)

# B19001 household-income brackets E002..E017 (list idx 1..16). Lower edge + width of
# each of the 16 bins; the last ($200k+) is open-ended.
_INC_LOWER = [0, 10000, 15000, 20000, 25000, 30000, 35000, 40000, 45000,
              50000, 60000, 75000, 100000, 125000, 150000, 200000]
_INC_WIDTH = [10000, 5000, 5000, 5000, 5000, 5000, 5000, 5000, 5000,
              10000, 15000, 25000, 25000, 25000, 50000, None]  # None = open top bin


def _median_from_hist(hist):
    """True median household income by linear interpolation of the 16-bin B19001
    histogram (more accurate than averaging block-group medians, which skews a
    right-tailed distribution high). Median landing in the open $200k+ bin -> the
    250001 '$250k+' sentinel."""
    total = sum(hist)
    if total <= 0:
        return None
    half = total / 2.0
    cum = 0.0
    for i in range(16):
        if cum + hist[i] >= half:
            if _INC_WIDTH[i] is None:           # median is in the $200k+ open bin
                return INCOME_TOPCODE
            return int(round(_INC_LOWER[i] + (half - cum) / hist[i] * _INC_WIDTH[i]))
        cum += hist[i]
    return INCOME_TOPCODE


def load_acs_ny():
    block_pop = _load_block_pop()
    baf = _load_baf()
    incb, incb_c = _read_acs_table("b19001")  # E001 total + E002..E017 = 16 income bins
    inc, inc_c = _read_acs_table("b19013")  # E001 = median hh income (refines the $200k+ bin)
    edu, edu_c = _read_acs_table("b15003")  # E001..E025
    ten, ten_c = _read_acs_table("b25003")  # E001 total, E002 owner, E003 renter
    age, age_c = _read_acs_table("b01002")  # E001 = median age
    cvap = _load_cvap_from_dra()

    # The ~40 block groups whose 2020 tract code was revised before the ACS
    # 2019-2023 vintage have no BG-level ACS row; the apportionment loop below
    # falls back to county-level ACS (medians directly; counts scaled by the
    # missing BG's 2020 population over the county's ACS universe).

    # --- build bg -> {vtd: pop} and bg total pop from blocks we can place ---
    bg_total = {}                       # bg -> summed block pop
    bg_vtd = {}                         # bg -> {vtd: summed block pop}
    for blk, pop in block_pop.items():
        vtd = baf.get(blk)
        if vtd is None:
            continue
        bg = blk[:12]
        bg_total[bg] = bg_total.get(bg, 0) + pop
        d = bg_vtd.setdefault(bg, {})
        d[vtd] = d.get(vtd, 0) + pop

    # --- accumulate per-VTD ---
    # additive buckets
    acc = {}   # vtd -> dict of running sums
    def A(vtd):
        return acc.setdefault(vtd, dict(
            no_hs=0.0, hs=0.0, bach=0.0, grad=0.0, owner=0.0, renter=0.0,
            inc_hist=[0.0] * 16, inc_num=0.0, inc_den=0.0, age_num=0.0, age_den=0.0))

    for bg, vtds in bg_vtd.items():
        tot = bg_total.get(bg, 0)
        if tot <= 0:
            # bg has no 2020 population in placed blocks: spread equally so we
            # don't silently lose its ACS data (rare; tiny counts).
            n = len(vtds)
            weights = {v: 1.0 / n for v in vtds}
        else:
            weights = {v: p / tot for v, p in vtds.items()}

        cf = "36" + bg[2:5]                 # county FIPS5 for fallback
        e_edu = edu.get(bg)
        e_ten = ten.get(bg)
        e_incb = incb.get(bg)
        e_age = age.get(bg)

        # --- county fallback for the ~40 BGs whose tract code changed ---
        # Synthesize a BG-sized estimate from county per-capita rates so we
        # don't drop real population.  Scaled by this BG's 2020 block pop.
        if e_edu is None and bg in bg_total:
            cc = edu_c.get(cf)
            if cc and cc[0]:
                scale = tot / cc[0]        # bg pop / county pop25+  (rough)
                e_edu = [(x or 0) * scale for x in cc]
        if e_ten is None and bg in bg_total:
            cc = ten_c.get(cf)
            if cc and cc[0]:
                # scale county households by bg-pop share of county pop25+ proxy
                denom = (edu_c.get(cf) or [None])[0]
                if denom:
                    scale = tot / denom
                    e_ten = [(x or 0) * scale for x in cc]
        if e_incb is None and bg in bg_total:
            cc = incb_c.get(cf)            # county income histogram, scaled to BG size
            if cc and cc[0]:
                scale = tot / cc[0]
                e_incb = [(x or 0) * scale for x in cc]
        e_inc = inc.get(bg)
        if e_inc is None:
            e_inc = inc_c.get(cf)          # county median income (top-bin refinement)
        if e_age is None:
            e_age = age_c.get(cf)          # county median age

        for vtd, w in weights.items():
            a = A(vtd)
            if e_edu:
                a["no_hs"] += w * sum(e_edu[i] or 0 for i in _EDU_NO_HS)
                a["hs"]    += w * sum(e_edu[i] or 0 for i in _EDU_HS)
                a["bach"]  += w * sum(e_edu[i] or 0 for i in _EDU_BACH)
                a["grad"]  += w * sum(e_edu[i] or 0 for i in _EDU_GRAD)
            if e_ten:
                a["owner"]  += w * (e_ten[1] or 0)   # E002 owner
                a["renter"] += w * (e_ten[2] or 0)   # E003 renter
            if e_incb:
                # Income BRACKETS are additive -> apportion each of the 16 bins by w
                # and sum into the VTD histogram; the true median is interpolated below.
                for i in range(16):
                    a["inc_hist"][i] += w * (e_incb[i + 1] or 0)   # +1: skip E001 total
            # Median age + median income (non-additive) -> population-weighted average of
            # BG medians. Income's weighted-mean only REFINES the open $200k+ bracket below.
            bgpop_in_vtd = vtds[vtd]
            if e_inc and e_inc[0] is not None and bgpop_in_vtd > 0:
                m = e_inc[0]
                if m >= 250000:
                    m = INCOME_TOPCODE
                a["inc_num"] += m * bgpop_in_vtd
                a["inc_den"] += bgpop_in_vtd
            if e_age and e_age[0] is not None and bgpop_in_vtd > 0:
                a["age_num"] += e_age[0] * bgpop_in_vtd
                a["age_den"] += bgpop_in_vtd

    # --- finalize ---
    result = {}
    for vtd, a in acc.items():
        income_median = _median_from_hist(a["inc_hist"])   # interpolated true median
        # The B19001 top bin is open at $200k+; when the median lands there, refine with
        # the B19013 weighted median (which distinguishes $200-250k from true $250k+).
        if income_median == INCOME_TOPCODE and a["inc_den"] > 0:
            ref = round(a["inc_num"] / a["inc_den"])
            income_median = INCOME_TOPCODE if ref >= 250000 else max(200000, ref)
        avg_age = (round(a["age_num"] / a["age_den"], 1)
                   if a["age_den"] > 0 else None)
        result[vtd] = dict(
            income_median=income_median,
            avg_age=avg_age,
            edu_no_hs=int(round(a["no_hs"])),
            edu_hs=int(round(a["hs"])),
            edu_bachelors=int(round(a["bach"])),
            edu_graduate=int(round(a["grad"])),
            housing_owner=int(round(a["owner"])),
            housing_renter=int(round(a["renter"])),
            cvap=cvap.get(vtd),
        )
    # attach CVAP for VTDs that exist in DRA but somehow got no blocks (rare)
    for vtd, c in cvap.items():
        if vtd not in result:
            result[vtd] = dict(income_median=None, avg_age=None,
                               edu_no_hs=0, edu_hs=0, edu_bachelors=0,
                               edu_graduate=0, housing_owner=0,
                               housing_renter=0, cvap=c)
    return result


if __name__ == "__main__":
    d = load_acs_ny()
    print(f"VTDs loaded: {len(d)}")
    # spot-check known NY VTDs
    samples = [k for k in d if k.startswith("36061")][:1]  # Manhattan
    samples += [k for k in d if k.startswith("36005")][:1]  # Bronx
    samples += [k for k in d if k.startswith("36103")][:1]  # Suffolk (suburban)
    for k in samples:
        print(k, d[k])
    # aggregate sanity
    incs = [v["income_median"] for v in d.values() if v["income_median"]]
    import statistics
    print("median of VTD median incomes:", statistics.median(incs))
    print("topcoded VTDs ($250k+):", sum(1 for i in incs if i == INCOME_TOPCODE))
