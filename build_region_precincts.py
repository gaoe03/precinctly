#!/usr/bin/env python3
"""Build a slim, on-device precinct dataset for one or more STATES.

Hybrid sourcing (see plan): each state flows through a SOURCE ADAPTER that yields a
common intermediate record; the compute/output stage (`build`) is source-agnostic, so
the bundled SQLite schema — the contract the iOS app reads — is identical regardless
of source.
  - adapter_josh: the original private precincts_2026_primary.db (used for CA).
  - adapter_vtd : public Census VTDs + VEST/ALARM elections + PL94/ACS demographics
                  (NY/MA/TX). [implemented in a later step]

Reads sources READ-ONLY and emits a compact SQLite with, per precinct:
  - geometry (reprojected WGS84, simplified) + an R-tree spatial index
  - precomputed display fields (lean, race %, education, income, housing, age,
    density, turnout estimate)
  - precinct_elections: Dem/Rep/Other + Dem two-party share per office x year
  - baselines: one row per state (for "vs <state>" comparisons)

Usage:
    python build_region_precincts.py                          # CA,NY,MA,TX (routed per state)
    python build_region_precincts.py --states NY --source josh --out /tmp/ny.sqlite
"""
import argparse
import os
import sqlite3
from collections import defaultdict

from shapely import wkb, wkt
from shapely.ops import transform as shp_transform
from shapely.validation import make_valid
from pyproj import Transformer

SRC = "/Users/gaoe/dev/josh/precincts_2026_primary.db"
DATA_DIR = "/Users/gaoe/dev/josh/public_data"

# Which adapter sources each state by default. CA has no public Census 2020 VTDs, so it
# stays on Josh's private DB. NY/MA/TX are migrated to public Census VTDs.
SOURCE_BY_STATE = {"CA": "josh", "NY": "vtd", "MA": "vtd", "TX": "vtd"}

# Nice display names for the 5 NYC boroughs; everywhere else uses the county name.
NYC_FIPS = {"36061": "Manhattan", "36047": "Brooklyn", "36081": "Queens",
            "36005": "Bronx", "36085": "Staten Island"}

SRC_CRS, DST_CRS = 3857, 4326
# Josh's source DB stores each state's geometry in its OWN projection. Known mappings
# (geometries already in lon/lat are auto-detected and passed through):
STATE_CRS = {"NY": 3857, "CA": 3310, "MA": 4326}
SIMPLIFY_TOL = 0.00005  # ~5.5 m
US_ENV = dict(min_lon=-125.0, max_lon=-66.0, min_lat=24.0, max_lat=50.0)

OFFICES = ("president", "senate", "governor")
RACE_VARS = ["pop_white", "pop_black", "pop_hispanic", "pop_asian",
             "pop_native", "pop_pacific", "pop_other"]
RACE_LABEL = {"pop_white": "White", "pop_black": "Black", "pop_hispanic": "Hispanic",
              "pop_asian": "Asian", "pop_native": "Native",
              "pop_pacific": "Pacific Islander", "pop_other": "Other"}
EDU_VARS = ["edu_no_hs", "edu_hs", "edu_bachelors", "edu_graduate"]
DECENNIAL_VARS = set(RACE_VARS) | {"pop_total", "vap_total", "cvap"}
ACS_VARS = set(EDU_VARS) | {"income_median", "pop_density", "avg_age",
                            "housing_owner", "housing_renter"}
ALL_VARS = DECENNIAL_VARS | ACS_VARS


def chunks(seq, n=900):
    for i in range(0, len(seq), n):
        yield seq[i:i + n]


def get_var(varmap, var):
    vv = varmap.get(var)
    if not vv:
        return None
    pref = "decennial" if var in DECENNIAL_VARS else ("acs" if var in ACS_VARS else None)
    if pref:
        for vint, val in vv.items():
            if pref in vint:
                return val
    return next(iter(vv.values()))


def two_party(dem, rep):
    if dem is None or rep is None or (dem + rep) <= 0:
        return None
    return dem / (dem + rep)


def lean_label(share):
    if share is None:
        return None
    if share >= 0.65: return "Solid Dem"
    if share >= 0.55: return "Lean Dem"
    if share >= 0.45: return "Even"
    if share >= 0.35: return "Lean Rep"
    return "Solid Rep"


def parse_geometry(raw):
    if raw is None:
        return None
    return wkt.loads(raw) if isinstance(raw, str) else wkb.loads(bytes(raw))


SCHEMA = """
CREATE TABLE precincts (
  rowid INTEGER PRIMARY KEY,
  unit_id TEXT UNIQUE, fips TEXT, state TEXT, borough TEXT, precinct_name TEXT,
  min_lon REAL, min_lat REAL, max_lon REAL, max_lat REAL,
  geometry_wkb BLOB,
  lean_dem_share REAL, prev_dem_share REAL, lean_year INT, prev_year INT,
  lean_label TEXT, lean_shift REAL, lean_votes INT, turnout_est REAL,
  pop_total INT, vap_total INT, cvap INT,
  pct_white REAL, pct_black REAL, pct_hispanic REAL, pct_asian REAL,
  pct_native REAL, pct_pacific REAL, pct_other REAL, plurality_group TEXT,
  pct_no_hs REAL, pct_hs REAL, pct_bachelors REAL, pct_graduate REAL, pct_ba_or_higher REAL,
  income_median INT, pop_density REAL, avg_age REAL, pct_renter REAL, pct_owner REAL,
  data_complete INT
);
CREATE INDEX idx_precincts_unit ON precincts(unit_id);
CREATE INDEX idx_precincts_state ON precincts(state, borough);   -- keeps state/county-scoped "By the Numbers" fast as states grow

CREATE TABLE precinct_elections (
  unit_id TEXT, office TEXT, year INT, dem INT, rep INT, other INT, dem_share REAL
);
CREATE INDEX idx_pe_unit ON precinct_elections(unit_id);

CREATE TABLE baselines (
  scope TEXT PRIMARY KEY, pop_total INT,
  pct_white REAL, pct_black REAL, pct_hispanic REAL, pct_asian REAL,
  pct_native REAL, pct_pacific REAL, pct_other REAL,
  pct_ba_or_higher REAL, income_median INT, pct_renter REAL, avg_age REAL,
  pres24_dem_share REAL
);

CREATE VIRTUAL TABLE precinct_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
"""

PRECINCT_COLS = [
    "rowid", "unit_id", "fips", "state", "borough", "precinct_name",
    "min_lon", "min_lat", "max_lon", "max_lat", "geometry_wkb",
    "lean_dem_share", "prev_dem_share", "lean_year", "prev_year",
    "lean_label", "lean_shift", "lean_votes", "turnout_est",
    "pop_total", "vap_total", "cvap",
    "pct_white", "pct_black", "pct_hispanic", "pct_asian", "pct_native",
    "pct_pacific", "pct_other", "plurality_group",
    "pct_no_hs", "pct_hs", "pct_bachelors", "pct_graduate", "pct_ba_or_higher",
    "income_median", "pop_density", "avg_age", "pct_renter", "pct_owner",
    "data_complete",
]


class Baseline:
    def __init__(self):
        self.pop = 0
        self.race = defaultdict(float)
        self.ba = 0.0; self.edu_total = 0.0
        self.owner = 0.0; self.renter = 0.0
        self.income_num = 0.0; self.income_den = 0.0
        self.age_num = 0.0; self.age_den = 0.0
        self.dem24 = 0; self.rep24 = 0

    def finish(self, scope):
        def frac(n, d): return (n / d) if d else None
        return {
            "scope": scope, "pop_total": int(self.pop),
            "pct_white": frac(self.race["pop_white"], self.pop),
            "pct_black": frac(self.race["pop_black"], self.pop),
            "pct_hispanic": frac(self.race["pop_hispanic"], self.pop),
            "pct_asian": frac(self.race["pop_asian"], self.pop),
            "pct_native": frac(self.race["pop_native"], self.pop),
            "pct_pacific": frac(self.race["pop_pacific"], self.pop),
            "pct_other": frac(self.race["pop_other"], self.pop),
            "pct_ba_or_higher": frac(self.ba, self.edu_total),
            "income_median": int(self.income_num / self.income_den) if self.income_den else None,
            "pct_renter": frac(self.renter, self.owner + self.renter),
            "avg_age": frac(self.age_num, self.age_den),
            "pres24_dem_share": two_party(self.dem24, self.rep24),
        }


# ---------------------------------------------------------------------------
# SOURCE ADAPTERS — each yields a common SourceRecord:
#   {unit_id, fips, county, precinct_name, state_abbr,
#    geometry: shapely geom ALREADY in lon/lat (EPSG:4326), or None,
#    demographics: {var: value} flat dict (contract var names, vintage resolved),
#    elections: {(office, year): {"dem","rep","other"}}}
# ---------------------------------------------------------------------------

def adapter_josh(states, src_path):
    """Yield SourceRecords from Josh's private DB. Used for CA (and NY verification)."""
    src = sqlite3.connect(f"file:{src_path}?mode=ro&immutable=1", uri=True)
    ph = ",".join("?" * len(states))
    spine = src.execute(
        f"SELECT unit_id, fips, county, precinct_sos, geometry, state_abbr "
        f"FROM precincts WHERE state_abbr IN ({ph})", states).fetchall()
    print(f"  adapter_josh: {len(spine)} precincts for {states}")
    unit_ids = [r[0] for r in spine]

    demo = defaultdict(lambda: defaultdict(dict))
    for ch in chunks(unit_ids):
        q = (f"SELECT unit_id, variable, value, vintage FROM demographics "
             f"WHERE unit_id IN ({','.join('?' * len(ch))})")
        for uid, var, val, vint in src.execute(q, ch):
            demo[uid][var][vint] = val

    elec = defaultdict(lambda: defaultdict(dict))
    for ch in chunks(unit_ids):
        q = (f"SELECT unit_id, race, year, party, SUM(votes) FROM election_results "
             f"WHERE unit_id IN ({','.join('?' * len(ch))}) "
             f"AND election_type='general' AND vote_type='total' "
             f"AND race IN ({','.join('?' * len(OFFICES))}) "
             f"GROUP BY unit_id, race, year, party")
        for uid, office, yr, party, v in src.execute(q, list(ch) + list(OFFICES)):
            elec[uid][(office, yr)][party] = v
    src.close()

    transformers = {}
    def reproject(geom, state):
        b = geom.bounds
        if -180 <= b[0] <= 180 and -90 <= b[1] <= 90 and -180 <= b[2] <= 180 and -90 <= b[3] <= 90:
            return geom                          # already lon/lat (e.g., MA)
        crs = STATE_CRS.get(state, 3857)         # NY 3857, CA 3310, default 3857
        if crs not in transformers:
            transformers[crs] = Transformer.from_crs(crs, DST_CRS, always_xy=True).transform
        return shp_transform(transformers[crs], geom)

    for unit_id, fips, county, pname, raw_geom, state_abbr in spine:
        geom_src = parse_geometry(raw_geom)
        geom = (reproject(geom_src, state_abbr)
                if (geom_src is not None and not geom_src.is_empty) else None)
        dm = demo.get(unit_id, {})
        flat_demo = {var: get_var(dm, var) for var in ALL_VARS}
        ev = {}
        for (office, yr), parties in elec.get(unit_id, {}).items():
            ev[(office, yr)] = {"dem": parties.get("dem"), "rep": parties.get("rep"),
                                "other": parties.get("other")}
        yield {
            "unit_id": unit_id, "fips": fips, "county": county,
            "precinct_name": pname, "state_abbr": state_abbr,
            "geometry": geom, "demographics": flat_demo, "elections": ev,
        }


_COUNTY_SUFFIXES = (" County", " Parish", " Borough", " Census Area",
                    " Municipality", " city", " City")


def county_names(data_dir):
    """{5-digit FIPS: bare county name} from Census 2020 national_county2020.txt.
    Bare name (suffix stripped) matches Josh's `county` convention; the app's
    countyDisplay() re-appends ' County', and NYC_FIPS overrides the 5 boroughs."""
    out = {}
    with open(os.path.join(data_dir, "national_county2020.txt"), encoding="latin-1") as f:
        next(f)  # header: STATE|STATEFP|COUNTYFP|COUNTYNS|COUNTYNAME|CLASSFP|FUNCSTAT
        for line in f:
            p = line.rstrip("\n").split("|")
            if len(p) < 5:
                continue
            name = p[4]
            for suf in _COUNTY_SUFFIXES:
                if name.endswith(suf):
                    name = name[:-len(suf)]
                    break
            out[p[1] + p[2]] = name
    return out


def adapter_ca24(states, data_dir):
    """Yield SourceRecords for CA from public 2024 SWDB precincts (the public-CA path)."""
    assert states == ["CA"], "adapter_ca24 is CA-only"
    from load_ca24 import load_ca24
    counties = county_names(data_dir)
    recs = load_ca24()
    print(f"  adapter_ca24: {len(recs)} CA 2024 precincts")
    for key, r in recs.items():
        cf = r["county_fips"]
        yield {
            "unit_id": f"{cf}-:-{key}", "fips": cf,
            "county": counties.get(cf, cf), "precinct_name": r["name"],
            "state_abbr": "CA", "geometry": r["geometry"],
            "demographics": r["demographics"], "elections": r["elections"],
        }


def adapter_p24(states, data_dir):
    """Yield SourceRecords for NY/TX from public 2024 precincts (block-centroid crosswalk)."""
    from load_p24 import load_p24
    counties = county_names(data_dir)
    for st in states:
        recs = load_p24(st)
        print(f"  adapter_p24[{st}]: {len(recs)} 2024 precincts")
        for pid, r in recs.items():
            cf = r["county_fips"]
            yield {
                "unit_id": f"{cf}-:-{st}_{pid}", "fips": cf,
                "county": counties.get(cf, cf), "precinct_name": r["name"],
                "state_abbr": st, "geometry": r["geometry"],
                "demographics": r["demographics"], "elections": r["elections"],
            }


# Fully-public sourcing. CA via SWDB 2024 precincts (no public CA VTDs exist). NY/MA/TX via
# public Census VTDs carrying DRA's 2008-2024 results — the VTD path keeps the multi-year
# trajectory + shift + density + turnout that the 2024-only precinct files lack. All public.
SOURCE_2024 = {"CA": "ca24", "NY": "vtd", "MA": "vtd", "TX": "vtd"}

VTD_FIPS = {"NY": "36", "MA": "25", "TX": "48"}


def adapter_vtd(state, data_dir):
    """Yield SourceRecords from public Census VTDs (NY/MA/TX) via the generalized loaders."""
    fips = VTD_FIPS.get(state)
    if fips is None:
        raise NotImplementedError(f"adapter_vtd has no FIPS mapping for {state}")
    from load_vtd import load_geometry, load_elec_demo, load_acs

    geo = load_geometry(fips)
    ed = load_elec_demo(state)
    acs = load_acs(state, fips)
    counties = county_names(data_dir)
    print(f"  adapter_vtd[{state}]: geo={len(geo)}  elec+demo={len(ed)}  acs={len(acs)}")

    ACS_OVERLAY = ("income_median", "avg_age", "edu_no_hs", "edu_hs",
                   "edu_bachelors", "edu_graduate", "housing_owner", "housing_renter")
    for geoid, gv in geo.items():
        cf = gv["county_fips"]
        edr = ed.get(geoid, {})
        demo = dict(edr.get("demographics", {}))      # pop/vap/cvap + NH race partition
        av = acs.get(geoid, {})
        for k in ACS_OVERLAY:                          # income/edu/tenure/age from crosswalk
            if av.get(k) is not None:
                demo[k] = av[k]
        pt = demo.get("pop_total")
        demo["pop_density"] = (pt / gv["aland_sqmi"]) if (pt and gv["aland_sqmi"] > 0) else None
        yield {
            "unit_id": f"{cf}-:-{geoid}", "fips": cf,
            "county": counties.get(cf, cf), "precinct_name": gv["name"],
            "state_abbr": state, "geometry": gv["geometry"],
            "demographics": demo, "elections": edr.get("elections", {}),
        }


# ---------------------------------------------------------------------------
# COMPUTE + OUTPUT — source-agnostic. Lifted verbatim from the original main()
# per-row loop + writer; reads SourceRecords instead of querying the DB inline.
# ---------------------------------------------------------------------------

def build(records, out_path):
    out_records, election_rows = [], []
    bases = defaultdict(Baseline)
    skipped_no_geom = n_no_pres = n_no_demo = skipped_empty = 0
    g = [float("inf"), float("inf"), float("-inf"), float("-inf")]  # min_lon,min_lat,max_lon,max_lat

    for rowid, rec in enumerate(records, start=1):
        unit_id, fips, state_abbr = rec["unit_id"], rec["fips"], rec["state_abbr"]
        county, pname = rec["county"], rec["precinct_name"]
        geom = rec["geometry"]
        if geom is None or geom.is_empty:
            skipped_no_geom += 1
            continue
        simp = geom.simplify(SIMPLIFY_TOL, preserve_topology=True)
        if simp.is_empty or not simp.is_valid:
            simp = geom if geom.is_valid else make_valid(geom)
        if simp.is_empty:
            skipped_no_geom += 1
            continue

        min_lon, min_lat, max_lon, max_lat = simp.bounds
        g[0], g[1] = min(g[0], min_lon), min(g[1], min_lat)
        g[2], g[3] = max(g[2], max_lon), max(g[3], max_lat)
        borough = NYC_FIPS.get(fips, county)

        ev = rec["elections"]
        for (office, yr), parties in sorted(ev.items()):
            d, r, o = parties.get("dem"), parties.get("rep"), parties.get("other")
            election_rows.append((unit_id, office, yr, d, r, o, two_party(d, r)))
        # Most recent president election available for this precinct (CA tops out at 2020).
        pres_years = sorted(
            (yr for (off, yr) in ev if off == "president"
             and two_party(ev[(off, yr)].get("dem"), ev[(off, yr)].get("rep")) is not None),
            reverse=True)
        lean_year = pres_years[0] if pres_years else None
        prev_year = pres_years[1] if len(pres_years) > 1 else None
        latest = ev.get(("president", lean_year), {}) if lean_year is not None else {}
        dL, rL, oL = latest.get("dem"), latest.get("rep"), latest.get("other")
        lean_share = two_party(dL, rL)
        prev = ev.get(("president", prev_year), {}) if prev_year is not None else {}
        prev_share = two_party(prev.get("dem"), prev.get("rep"))
        lean_votes = sum(x for x in (dL, rL, oL) if x is not None) if latest else None
        lean_shift = (lean_share - prev_share) if (lean_share is not None and prev_share is not None) else None
        has_pres = lean_share is not None
        if not has_pres:
            n_no_pres += 1

        dm = rec["demographics"]
        pop_total = dm.get("pop_total")
        cvap = dm.get("cvap")
        vap_total = dm.get("vap_total")
        race_counts = {v: dm.get(v) for v in RACE_VARS}
        has_demo = pop_total is not None and pop_total > 0
        if not has_demo:
            n_no_demo += 1

        # Drop shape-only precincts with NO election results AND no demographics: they'd
        # render as blank cards and leave untyped gaps on the map. Precincts with EITHER
        # signal are kept (the app degrades each field gracefully).
        if not ev and not has_demo:
            skipped_empty += 1
            continue

        def pct(num, den):
            return (num / den) if (num is not None and den and den > 0) else None

        race_pct = {v: pct(race_counts[v], pop_total) for v in RACE_VARS}
        if has_demo and any(race_counts.values()):
            top = max((v for v in RACE_VARS if race_counts[v] is not None),
                      key=lambda v: race_counts[v])
            plurality = RACE_LABEL[top]
        else:
            plurality = None

        edu = {v: dm.get(v) for v in EDU_VARS}
        edu_total = sum(c for c in edu.values() if c is not None) \
            if any(c is not None for c in edu.values()) else None
        ba_grad = sum(c for c in (edu["edu_bachelors"], edu["edu_graduate"]) if c is not None) \
            if edu_total else None
        owner, renter = dm.get("housing_owner"), dm.get("housing_renter")
        households = (owner or 0) + (renter or 0)
        income = dm.get("income_median")
        if income is not None and income <= 0:
            income = None
        avg_age = dm.get("avg_age")
        turnout = (lean_votes / cvap) if (lean_votes is not None and cvap and cvap >= 50) else None
        if turnout is not None and turnout > 1.15:
            turnout = None

        out_records.append({
            "rowid": rowid, "unit_id": unit_id, "fips": fips, "state": state_abbr,
            "borough": borough, "precinct_name": pname,
            "min_lon": min_lon, "min_lat": min_lat, "max_lon": max_lon, "max_lat": max_lat,
            "geometry_wkb": wkb.dumps(simp),
            "lean_dem_share": lean_share, "prev_dem_share": prev_share,
            "lean_year": lean_year, "prev_year": prev_year,
            "lean_label": lean_label(lean_share), "lean_shift": lean_shift,
            "lean_votes": lean_votes, "turnout_est": turnout,
            "pop_total": int(pop_total) if pop_total is not None else None,
            "vap_total": int(vap_total) if vap_total is not None else None,
            "cvap": int(cvap) if cvap is not None else None,
            "pct_white": race_pct["pop_white"], "pct_black": race_pct["pop_black"],
            "pct_hispanic": race_pct["pop_hispanic"], "pct_asian": race_pct["pop_asian"],
            "pct_native": race_pct["pop_native"], "pct_pacific": race_pct["pop_pacific"],
            "pct_other": race_pct["pop_other"], "plurality_group": plurality,
            "pct_no_hs": pct(edu["edu_no_hs"], edu_total), "pct_hs": pct(edu["edu_hs"], edu_total),
            "pct_bachelors": pct(edu["edu_bachelors"], edu_total),
            "pct_graduate": pct(edu["edu_graduate"], edu_total),
            "pct_ba_or_higher": pct(ba_grad, edu_total),
            "income_median": int(round(income)) if income is not None else None,
            "pop_density": dm.get("pop_density"), "avg_age": avg_age,
            "pct_renter": pct(renter, households) if households else None,
            "pct_owner": pct(owner, households) if households else None,
            "data_complete": 1 if (has_pres and has_demo) else 0,
        })

        b = bases[state_abbr]
        if has_demo:
            b.pop += pop_total
            for v in RACE_VARS:
                if race_counts[v] is not None:
                    b.race[v] += race_counts[v]
            if edu_total:
                b.ba += ba_grad or 0; b.edu_total += edu_total
            b.owner += owner or 0; b.renter += renter or 0
            if income is not None and households:
                b.income_num += income * households; b.income_den += households
            if avg_age is not None:
                b.age_num += avg_age * pop_total; b.age_den += pop_total
        if dL is not None: b.dem24 += dL
        if rL is not None: b.rep24 += rL

    print(f"Built records: {len(out_records)}   election rows: {len(election_rows)}")
    print(f"Skipped(no geom): {skipped_no_geom}   dropped(empty): {skipped_empty}   missing pres24: {n_no_pres}   missing demo: {n_no_demo}")

    print("\n-- CRS validation gate (US envelope) --")
    assert US_ENV["min_lon"] <= g[0] and g[2] <= US_ENV["max_lon"], f"lon out of US env: [{g[0]}, {g[2]}]"
    assert US_ENV["min_lat"] <= g[1] and g[3] <= US_ENV["max_lat"], f"lat out of US env: [{g[1]}, {g[3]}]"
    print(f"global bbox OK: lon [{g[0]:.3f}, {g[2]:.3f}] lat [{g[1]:.3f}, {g[3]:.3f}]")

    tmp = out_path + ".tmp"
    if os.path.exists(tmp):
        os.remove(tmp)
    out = sqlite3.connect(tmp)
    out.executescript(SCHEMA)
    out.executemany(
        f"INSERT INTO precincts ({','.join(PRECINCT_COLS)}) "
        f"VALUES ({','.join(':' + c for c in PRECINCT_COLS)})", out_records)
    out.executemany(
        "INSERT INTO precinct_elections (unit_id, office, year, dem, rep, other, dem_share) "
        "VALUES (?,?,?,?,?,?,?)", election_rows)
    base_cols = ["scope", "pop_total", "pct_white", "pct_black", "pct_hispanic",
                 "pct_asian", "pct_native", "pct_pacific", "pct_other",
                 "pct_ba_or_higher", "income_median", "pct_renter", "avg_age", "pres24_dem_share"]
    out.executemany(
        f"INSERT INTO baselines ({','.join(base_cols)}) VALUES ({','.join(':' + c for c in base_cols)})",
        [bases[s].finish(s) for s in bases])
    out.executemany(
        "INSERT INTO precinct_rtree (id, min_lon, max_lon, min_lat, max_lat) VALUES (?,?,?,?,?)",
        [(r["rowid"], r["min_lon"], r["max_lon"], r["min_lat"], r["max_lat"]) for r in out_records])
    out.commit()
    out.execute("ANALYZE"); out.execute("VACUUM"); out.commit(); out.close()
    os.replace(tmp, out_path)

    size_mb = os.path.getsize(out_path) / 1e6
    complete = sum(1 for r in out_records if r["data_complete"] == 1)
    print(f"\nWrote {out_path}  ({size_mb:.1f} MB)")
    print(f"  precincts: {len(out_records)}   data_complete=1: {complete}   states/baselines: {len(bases)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=SRC)
    ap.add_argument("--states", default="CA,NY,MA,TX", help="comma-separated state_abbr")
    ap.add_argument("--source", default="auto", choices=["auto", "josh", "vtd", "ca24", "p24"],
                    help="force an adapter for all states (default: route per SOURCE_BY_STATE)")
    ap.add_argument("--mode", default="vtd", choices=["vtd", "p2024"],
                    help="vtd = current 2020-VTD sourcing; p2024 = fully-public 2024 precincts")
    ap.add_argument("--data-dir", default=DATA_DIR)
    ap.add_argument("--out", default="/Users/gaoe/dev/josh/nyc_precincts.sqlite")
    args = ap.parse_args()

    states = [s.strip().upper() for s in args.states.split(",") if s.strip()]
    print(f"Source : {args.src}\nStates : {states}\nSourceMode: {args.source}\nOutput : {args.out}")

    routing = SOURCE_2024 if args.mode == "p2024" else SOURCE_BY_STATE
    def adapter_for(st):
        return args.source if args.source != "auto" else routing.get(st, "josh")

    josh_states = [s for s in states if adapter_for(s) == "josh"]
    vtd_states = [s for s in states if adapter_for(s) == "vtd"]
    ca24_states = [s for s in states if adapter_for(s) == "ca24"]
    p24_states = [s for s in states if adapter_for(s) == "p24"]

    def all_records():
        if josh_states:
            yield from adapter_josh(josh_states, args.src)
        for st in vtd_states:
            yield from adapter_vtd(st, args.data_dir)
        if ca24_states:
            yield from adapter_ca24(ca24_states, args.data_dir)
        if p24_states:
            yield from adapter_p24(p24_states, args.data_dir)

    build(all_records(), args.out)


if __name__ == "__main__":
    main()
