"""
Loader for NY elections + decennial demographics aggregated to 2020 VTDs (GEOID20).

ELECTIONS + VAP/CVAP SOURCE: Dave's Redistricting App (DRA) vtd_data, NY v07
  - public_data/election_data_NY.v07.csv      (president 2008-2024, senate, governor, AG, etc.)
  - public_data/demographic_data_NY.v07.csv   (used here only for V_20_VAP_Total and V_20_CVAP_Total)
RACE / POP SOURCE: ALARM census-2020 (VEST) NY combined file
  - public_data/ny_2020_vtd_alarm.csv         (clean non-Hispanic race-alone P2 partition + Hispanic)

Why this split:
  * Elections -> DRA: it is the ONLY source here with 2024 (and 2022) president/senate/governor, plus 2008/2012.
    ALARM stops at 2020 and has no 2024.
  * VAP/CVAP -> DRA: ALARM has VAP but no CVAP; DRA provides V_20_CVAP_Total (ACS 2016-2020 CVAP).
  * Race breakdown -> ALARM: VERIFIED that ALARM's pop_white/black/aian/asian/nhpi/other/two are a clean,
    mutually-exclusive NON-HISPANIC race-alone (P2) partition, and
      pop_white+pop_black+pop_aian+pop_asian+pop_nhpi+pop_other+pop_two+pop_hisp == pop_total  EXACTLY (per VTD).
    DRA's race fields are INCONSISTENT: DRA White & Hispanic are non-Hispanic (match ALARM exactly), but DRA
    Black/Asian/Native/Pacific are race-alone-INCLUDING-Hispanic, so DRA's 6 race fields sum to ~100.8%
    (Hispanic double-counted). ALARM gives the clean ~100% partition the contract wants.
"""
import os
import pandas as pd

_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "public_data")

# (office, year) -> (Dem column, Rep column, Total column) in DRA election_data_NY.v07.csv
_ELECTIONS = {
    ("president", 2008): ("E_08_PRES_Dem", "E_08_PRES_Rep", "E_08_PRES_Total"),
    ("president", 2012): ("E_12_PRES_Dem", "E_12_PRES_Rep", "E_12_PRES_Total"),
    ("president", 2016): ("E_16_PRES_Dem", "E_16_PRES_Rep", "E_16_PRES_Total"),
    ("president", 2020): ("E_20_PRES_Dem", "E_20_PRES_Rep", "E_20_PRES_Total"),
    ("president", 2024): ("E_24_PRES_Dem", "E_24_PRES_Rep", "E_24_PRES_Total"),
    ("senate",    2016): ("E_16_SEN_Dem",  "E_16_SEN_Rep",  "E_16_SEN_Total"),
    ("senate",    2018): ("E_18_SEN_Dem",  "E_18_SEN_Rep",  "E_18_SEN_Total"),
    ("senate",    2022): ("E_22_SEN_Dem",  "E_22_SEN_Rep",  "E_22_SEN_Total"),
    ("senate",    2024): ("E_24_SEN_Dem",  "E_24_SEN_Rep",  "E_24_SEN_Total"),
    ("governor",  2018): ("E_18_GOV_Dem",  "E_18_GOV_Rep",  "E_18_GOV_Total"),
    ("governor",  2022): ("E_22_GOV_Dem",  "E_22_GOV_Rep",  "E_22_GOV_Total"),
}


def load_elec_demo_ny():
    """Return {GEOID20: {"elections": {(office,year): {dem,rep,other}}, "demographics": {...}}}."""
    # Race + pop come from ALARM (clean non-Hispanic P2 partition).
    a = pd.read_csv(os.path.join(_DIR, "ny_2020_vtd_alarm.csv"), dtype={"GEOID20": str}).set_index("GEOID20")
    # VAP/CVAP + elections come from DRA.
    dem = pd.read_csv(os.path.join(_DIR, "demographic_data_NY.v07.csv"), dtype={"GEOID20": str}).set_index("GEOID20")
    ele = pd.read_csv(os.path.join(_DIR, "election_data_NY.v07.csv"), dtype={"GEOID20": str}).set_index("GEOID20")

    def _i(v):
        return 0 if pd.isna(v) else int(v)

    out = {}
    for g, ar in a.iterrows():
        # --- demographics: race from ALARM (NH race-alone P2), VAP/CVAP from DRA ---
        dr = dem.loc[g] if g in dem.index else None
        d = {
            "pop_total":    _i(ar["pop"]),
            "vap_total":    _i(ar["vap"]),                              # decennial VAP (matches DRA)
            "cvap":         _i(dr["V_20_CVAP_Total"]) if dr is not None else None,  # ACS 2016-2020 CVAP (DRA)
            "pop_white":    _i(ar["pop_white"]),                        # NH White alone
            "pop_black":    _i(ar["pop_black"]),                        # NH Black alone
            "pop_hispanic": _i(ar["pop_hisp"]),                         # Hispanic, any race
            "pop_asian":    _i(ar["pop_asian"]),                        # NH Asian alone
            "pop_native":   _i(ar["pop_aian"]),                         # NH American Indian/Alaska Native alone
            "pop_pacific":  _i(ar["pop_nhpi"]),                         # NH Native Hawaiian/Pac. Islander alone
            "pop_other":    _i(ar["pop_other"]) + _i(ar["pop_two"]),    # NH Some-Other-Race + NH Two-or-more
        }
        # Contract fields not present in this layer (no ACS income/edu/tenure/age/density at VTD level here):
        for k in ("edu_no_hs", "edu_hs", "edu_bachelors", "edu_graduate",
                  "income_median", "avg_age", "housing_owner", "housing_renter", "pop_density"):
            d[k] = None

        # --- elections (DRA) ---
        elections = {}
        if g in ele.index:
            er = ele.loc[g]
            for (office, year), (dc, rc, tc) in _ELECTIONS.items():
                tot = er.get(tc, 0)
                if pd.isna(tot) or tot == 0:
                    continue
                dvote, rvote = _i(er.get(dc)), _i(er.get(rc))
                elections[(office, year)] = {"dem": dvote, "rep": rvote, "other": int(tot) - dvote - rvote}

        out[g] = {"elections": elections, "demographics": d}
    return out


if __name__ == "__main__":
    data = load_elec_demo_ny()
    print("VTD count:", len(data))

    g = "36061000586"  # a Manhattan (NY County) VTD
    rec = data[g]
    print("\nSample GEOID20:", g)
    print("demographics:", rec["demographics"])
    print("elections:")
    for k in sorted(rec["elections"], key=lambda x: (x[0], x[1])):
        print("  ", k, rec["elections"][k])

    # statewide sanity
    tot_pop = sum(v["demographics"]["pop_total"] for v in data.values())
    bid = sum(v["elections"].get(("president", 2020), {}).get("dem", 0) for v in data.values())
    har = sum(v["elections"].get(("president", 2024), {}).get("dem", 0) for v in data.values())
    print("\nStatewide pop_total:", tot_pop, "(expect 20,201,249)")
    print("Statewide 2020 pres dem:", bid, "| 2024 pres dem:", har)
    # partition check on sample
    d = rec["demographics"]
    part = d["pop_white"]+d["pop_black"]+d["pop_asian"]+d["pop_native"]+d["pop_pacific"]+d["pop_other"]+d["pop_hispanic"]
    print("Sample race partition sum:", part, "vs pop_total:", d["pop_total"])
