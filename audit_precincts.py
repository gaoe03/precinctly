#!/usr/bin/env python3
"""Read-only comprehensive anomaly audit for a slice of precincts (one or more counties).
Prints every flagged precinct by category so an auditor can judge + research. Alters nothing.

Usage: python3 audit_precincts.py STATE "County A,County B,..."   (counties optional = whole state)
"""
import os
import sqlite3
import sys
from shapely import wkb

DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "PrecinctWeather/PrecinctKit/Resources/nyc_precincts.sqlite")
US = dict(min_lon=-125.0, max_lon=-66.0, min_lat=24.0, max_lat=50.0)

state = sys.argv[1] if len(sys.argv) > 1 else "CA"
spec = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None

con = sqlite3.connect(f"file:{DB}?mode=ro&immutable=1", uri=True)
counties = None
if spec and "/" in spec:
    # "i/n" -> chunk i of n, counties round-robin by precinct count (balances big+small)
    i, n = (int(x) for x in spec.split("/"))
    ordered = [r[0] for r in con.execute(
        "SELECT borough FROM precincts WHERE state=? GROUP BY borough ORDER BY COUNT(*) DESC", (state,))]
    counties = [c for idx, c in enumerate(ordered) if idx % n == (i - 1)]
elif spec:
    counties = [c.strip() for c in spec.split(",")]

scope = "state = ?"
args = [state]
if counties:
    scope += " AND borough IN (%s)" % ",".join("?" * len(counties))
    args += counties
    print(f"(chunk counties: {counties})")

cols = ("unit_id, borough, precinct_name, lean_label, lean_dem_share, lean_shift, lean_votes, "
        "turnout_est, pop_total, vap_total, cvap, pct_white, pct_black, pct_hispanic, pct_asian, "
        "pct_native, pct_pacific, pct_other, plurality_group, pct_ba_or_higher, income_median, "
        "pop_density, avg_age, pct_renter, pct_owner, data_complete, geometry_wkb")
rows = con.execute(f"SELECT {cols} FROM precincts WHERE {scope}", args).fetchall()
C = {name: i for i, name in enumerate(cols.replace(" ", "").split(","))}
print(f"AUDIT {state} {counties or 'ALL'} — {len(rows)} precincts\n")

flags = {}
def flag(cat, uid, detail):
    flags.setdefault(cat, []).append(f"{uid}: {detail}")

for r in rows:
    uid = r[C["unit_id"]]
    pop = r[C["pop_total"]]
    lean = r[C["lean_dem_share"]]

    # --- GEOMETRY ---
    blob = r[C["geometry_wkb"]]
    if blob is None:
        flag("geom_missing", uid, "no geometry")
    else:
        try:
            g = wkb.loads(bytes(blob))
            if g.is_empty:
                flag("geom_empty", uid, "empty geometry")
            elif not g.is_valid:
                flag("geom_invalid", uid, "invalid (self-intersecting?)")
            else:
                holes = sum(len(p.interiors) for p in (g.geoms if g.geom_type == "MultiPolygon" else [g]))
                if holes > 5:
                    flag("geom_many_holes", uid, f"{holes} interior holes")
                b = g.bounds
                if not (US["min_lon"] <= b[0] and b[2] <= US["max_lon"] and US["min_lat"] <= b[1] and b[3] <= US["max_lat"]):
                    flag("geom_out_of_us", uid, f"bounds {tuple(round(x,2) for x in b)}")
        except Exception as e:
            flag("geom_parse_error", uid, str(e)[:50])

    # --- ELECTIONS / LEAN ---
    if r[C["lean_label"]] is None or lean is None:
        flag("no_lean", uid, f"no 2024 lean (pop={pop})")
    else:
        if lean < 0 or lean > 1:
            flag("lean_out_of_range", uid, f"lean_dem_share={lean}")
        lv = r[C["lean_votes"]]
        if lv is not None and pop and lv > pop * 1.2:
            flag("votes_gt_pop", uid, f"votes {lv} > pop {pop}")
        sh = r[C["lean_shift"]]
        if sh is not None and abs(sh) > 0.6:
            flag("shift_extreme", uid, f"shift {sh:.2f}")

    # --- DEMOGRAPHICS ---
    if pop is None or pop == 0:
        flag("pop_zero", uid, "pop_total 0/null (ghost precinct?)")
    else:
        races = [r[C[k]] or 0 for k in ("pct_white","pct_black","pct_hispanic","pct_asian","pct_native","pct_pacific","pct_other")]
        s = sum(races)
        if abs(s - 1.0) > 0.05:
            flag("race_sum_off", uid, f"race shares sum to {s:.2f}")
        for k in ("pct_white","pct_black","pct_hispanic","pct_asian","pct_ba_or_higher","pct_renter","pct_owner"):
            v = r[C[k]]
            if v is not None and (v < 0 or v > 1.0001):
                flag("pct_out_of_range", uid, f"{k}={v}")
        # plurality matches max race?
        plur = r[C["plurality_group"]]
        if plur and s > 0:
            rmap = dict(zip(["White","Black","Hispanic","Asian","Native","Pacific Islander","Other"], races))
            top = max(rmap, key=rmap.get)
            if rmap.get(plur, -1) < rmap[top] - 1e-6:
                flag("plurality_mismatch", uid, f"plurality={plur} but max is {top}")
    age = r[C["avg_age"]]
    if age is not None and (age < 1 or age > 100):
        flag("age_range", uid, f"avg_age={age}")
    inc = r[C["income_median"]]
    if inc is not None and inc < 5000:
        flag("income_low_artifact", uid, f"income {inc}")
    dens = r[C["pop_density"]]
    if dens is not None and dens > 150000:
        flag("density_extreme", uid, f"{dens:.0f}/mi2")
    cvap, vap = r[C["cvap"]], r[C["vap_total"]]
    if cvap is not None and vap is not None and vap > 0 and cvap > vap * 1.05:
        flag("cvap_gt_vap", uid, f"cvap {cvap} > vap {vap}")

    # --- CONSISTENCY ---
    dc = r[C["data_complete"]]
    has_pres = lean is not None
    has_demo = pop is not None and pop > 0
    if dc == 1 and not (has_pres and has_demo):
        flag("data_complete_wrong", uid, f"flagged complete but pres={has_pres} demo={has_demo}")

# --- summary ---
print("ANOMALY COUNTS:")
for cat in sorted(flags, key=lambda k: -len(flags[k])):
    print(f"  {cat}: {len(flags[cat])}")
print("\nDETAIL (first 25 per category):")
for cat in sorted(flags, key=lambda k: -len(flags[k])):
    print(f"\n[{cat}] ({len(flags[cat])})")
    for line in flags[cat][:25]:
        print("   " + line)
con.close()
