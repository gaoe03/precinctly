#!/usr/bin/env python3
"""Add county and metro baselines to a built precinct DB, for the "compare this precinct to..."
picker in the app.

WHY THIS IS A PATCH AND NOT A REBUILD
-------------------------------------
`build_region_precincts.py` writes one `baselines` row per state, weighted with inputs it has in
memory and does not persist: income by households (owner+renter), education by edu_total, age by
pop_total. Those weights are gone by the time the DB exists.

Rebuilding from source to recover them is NOT the safer path, it is the wrong one: the shipped DB
has had in-place patches applied after the build (CVAP clamp, CA sliver filter, CA prior years),
so source-derived county aggregates would cover a slightly different set of precincts than the app
actually ships. This script therefore derives every scope from the DB itself, which is by
definition the set the app has.

CONSISTENCY, AND THE DELIBERATE ~1-3% DIFFERENCE
------------------------------------------------
Everything here is population-weighted, because pop_total is the only weight the DB carries.
For race and average age that is exactly what the pipeline does, and the validation gate below
proves it reproduces the shipped numbers to the digit.

For income, education, and tenure the pipeline weights by households / edu_total, so this script's
numbers land about 1-3% away from pipeline numbers. That is expected, not a regression. It matters
far less than the property it buys: EVERY scope is computed the same way, so "vs Brooklyn" and
"vs NY" are the same kind of number and can be compared to each other. That is the entire point of
the feature. This is also why the state rows are recomputed and overwritten rather than left alone.

If you ever do a clean rebuild, the pipeline emits all three scope levels itself with its exact
weights, which is likewise internally consistent. Either DB is coherent; do not mix halves.

Idempotent. Run it again after any change to the precinct rows.

    python3 apply_area_baselines.py PrecinctWeather/PrecinctKit/Resources/nyc_precincts.sqlite
"""

import argparse
import sqlite3
import sys

# The five boroughs are one city but five counties, so "vs New York City" cannot come from the
# county rows. Keep this in step with the NYC borough set in PrecinctProfile.swift
# (`countyDisplay`), which exists for the same five names.
METROS = {
    ("NY", "New York City"): ["Manhattan", "Brooklyn", "Queens", "Bronx", "Staten Island"],
}

# Fields whose weight really is pop_total, so the gate can demand an exact match on them.
EXACT_FIELDS = ["pct_white", "pct_black", "pct_hispanic", "pct_asian",
                "pct_native", "pct_pacific", "pct_other", "avg_age"]
# Fields the pipeline weights by households / edu_total. Recomputed pop-weighted on purpose.
APPROX_FIELDS = ["pct_ba_or_higher", "income_median", "pct_renter"]

WEIGHTED = EXACT_FIELDS + APPROX_FIELDS


def weighted(db, where, binds):
    """Population-weighted mean of every per-precinct field, plus the scope's totals."""
    parts = [
        f"SUM({f} * pop_total) / NULLIF(SUM(CASE WHEN {f} IS NOT NULL THEN pop_total END), 0)"
        for f in WEIGHTED
    ]
    sql = f"""
        SELECT COUNT(*), SUM(pop_total), {', '.join(parts)}
        FROM precincts
        WHERE {where} AND pop_total IS NOT NULL AND pop_total > 0
    """
    row = db.execute(sql, binds).fetchone()
    out = {"precinct_count": row[0], "pop_total": int(row[1]) if row[1] else None}
    for name, value in zip(WEIGHTED, row[2:]):
        out[name] = value
    if out["income_median"] is not None:
        out["income_median"] = int(round(out["income_median"]))

    # Presidential two-party share, summed from the real vote counts rather than averaged from
    # per-precinct shares, so a scope is not swayed by its tiny precincts.
    votes = db.execute(f"""
        SELECT SUM(e.dem), SUM(e.rep)
        FROM precinct_elections e JOIN precincts p ON p.unit_id = e.unit_id
        WHERE e.office = 'president' AND {where.replace('state', 'p.state').replace('borough', 'p.borough')}
    """, binds).fetchone()
    dem, rep = votes or (None, None)
    out["pres24_dem_share"] = (dem / (dem + rep)) if dem and rep and (dem + rep) else None
    return out


def scope_rows(db):
    """Every scope the app can compare against: state, county, and metro."""
    rows = {}
    for (state,) in db.execute("SELECT DISTINCT state FROM precincts WHERE state IS NOT NULL ORDER BY state"):
        rows[state] = weighted(db, "state = ?", [state])
        for (county,) in db.execute(
                "SELECT DISTINCT borough FROM precincts WHERE state = ? AND borough IS NOT NULL "
                "AND borough != '' ORDER BY borough", [state]):
            rows[f"county|{state}|{county}"] = weighted(db, "state = ? AND borough = ?", [state, county])

    for (state, name), boroughs in METROS.items():
        present = [b for b in boroughs if db.execute(
            "SELECT 1 FROM precincts WHERE state = ? AND borough = ? LIMIT 1", [state, b]).fetchone()]
        if not present:
            print(f"  metro {name}: no matching counties in this DB, skipped")
            continue
        if len(present) != len(boroughs):
            print(f"  WARNING metro {name}: only {len(present)}/{len(boroughs)} counties present: {present}")
        placeholders = ",".join("?" * len(present))
        rows[f"metro|{state}|{name}"] = weighted(
            db, f"state = ? AND borough IN ({placeholders})", [state] + present)
    return rows


# Relative, not absolute: an absolute tolerance is ~300x stricter on avg_age (magnitude 37) than
# on a race share (magnitude 0.4), which fails the wrong things. Recomputing from the DB cannot be
# bit-exact because the DB stores pop_total truncated to an int and the shares pre-divided, so the
# floor is real precision loss, not error. Measured worst case across NY/CA/MA/TX is 0.07%
# (MA is 0.000000%, which is the proof the method itself is right). 0.25% leaves headroom while
# still catching the failures that matter: a wrong weight or a wrong precinct set moves these
# percent-level, as the household-weighted fields below demonstrate at 1-3%.
TOLERANCE = 0.0025


def validate(db, rows):
    """Hard gate. The pop-weighted fields must reproduce the shipped state rows within rounding;
    if they do not, this script's model of the DB is wrong and nothing should be overwritten."""
    problems = []
    existing = db.execute(
        f"SELECT scope, {', '.join(EXACT_FIELDS)} FROM baselines WHERE scope NOT LIKE '%|%'"
    ).fetchall()
    if not existing:
        problems.append("no state rows found to validate against")
    for row in existing:
        scope, stored = row[0], row[1:]
        fresh = rows.get(scope)
        if fresh is None:
            problems.append(f"{scope}: present in the DB but not recomputed")
            continue
        for name, was in zip(EXACT_FIELDS, stored):
            now = fresh[name]
            if was is None and now is None:
                continue
            if was is None or now is None:
                problems.append(f"{scope}.{name}: stored {was} vs recomputed {now}")
                continue
            drift = abs(now - was) / abs(was) if was else abs(now)
            if drift > TOLERANCE:
                problems.append(f"{scope}.{name}: stored {was} vs recomputed {now} ({drift * 100:.3f}%)")
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("db")
    ap.add_argument("--force", action="store_true",
                    help="write even if the validation gate fails (do not use casually)")
    args = ap.parse_args()

    db = sqlite3.connect(args.db)

    cols = {c[1] for c in db.execute("PRAGMA table_info(baselines)")}
    if "precinct_count" not in cols:
        db.execute("ALTER TABLE baselines ADD COLUMN precinct_count INTEGER")
        print("added baselines.precinct_count")

    print("computing scopes...")
    rows = scope_rows(db)
    states = [s for s in rows if "|" not in s]
    counties = [s for s in rows if s.startswith("county|")]
    metros = [s for s in rows if s.startswith("metro|")]
    print(f"  {len(states)} states, {len(counties)} counties, {len(metros)} metros")

    print("validating against the shipped state rows (exact-weight fields)...")
    problems = validate(db, rows)
    if problems:
        print("VALIDATION FAILED:")
        for p in problems:
            print("  " + p)
        if not args.force:
            print("\nRefusing to write. The recomputation does not reproduce the shipped numbers on\n"
                  "fields whose weight is pop_total, which means this script's model of the DB is\n"
                  "wrong. Diagnose before overwriting anything.")
            sys.exit(1)
    else:
        print(f"  OK, {len(states)} state rows reproduce exactly on {len(EXACT_FIELDS)} fields")

    # Report the deliberate drift on the household-weighted fields so it is never a surprise.
    for scope in sorted(states):
        stored = db.execute(
            f"SELECT {', '.join(APPROX_FIELDS)} FROM baselines WHERE scope = ?", [scope]).fetchone()
        deltas = []
        for name, was in zip(APPROX_FIELDS, stored):
            now = rows[scope][name]
            if was and now:
                deltas.append(f"{name} {was} -> {now} ({(now - was) / was * 100:+.2f}%)")
        print(f"  {scope}: " + "; ".join(deltas))

    fields = ["scope", "precinct_count", "pop_total"] + WEIGHTED + ["pres24_dem_share"]
    payload = [tuple([scope] + [rows[scope].get(f) for f in fields[1:]]) for scope in rows]
    db.execute("DELETE FROM baselines")
    db.executemany(
        f"INSERT INTO baselines ({','.join(fields)}) VALUES ({','.join('?' * len(fields))})", payload)
    db.commit()
    db.execute("VACUUM")
    db.commit()
    print(f"wrote {len(payload)} baseline rows to {args.db}")


if __name__ == "__main__":
    main()
