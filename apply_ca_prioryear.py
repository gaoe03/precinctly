#!/usr/bin/env python3
"""Patch CA prior-year president (2016, 2020) into the bundled DB and recompute
CA's trajectory fields (prev_year / prev_dem_share / lean_shift) exactly as
build_region_precincts.build() does. Idempotent: re-running first clears any CA
president 2016/2020 rows it previously added.

Reads public_data/2024/ca_prioryear_by_srprec.csv (from build_ca_prioryear.py).
Run AFTER backing up the DB. Prints a before/after verification summary.
"""
import csv, os, sqlite3, sys

DB = sys.argv[1] if len(sys.argv) > 1 else \
    "PrecinctWeather/PrecinctKit/Resources/nyc_precincts.sqlite"
CSV = "public_data/2024/ca_prioryear_by_srprec.csv"


ABS_FLOOR = 25      # a prior-year reading needs at least this many two-party votes
REL_FLOOR = 0.25    # ...and at least this fraction of the 2024 two-party electorate.
# Rationale: 2020 had record turnout, so a precinct that genuinely existed in 2020 has
# 2020 votes >= 2024 votes. A precinct with far fewer prior votes than 2024 did not exist
# as this geography back then (new construction / redistricting), so its crosswalked prior
# lean is an artifact (e.g. "0% -> 94%"). Drop those years instead of charting noise.


def two_party(dem, rep):
    if dem is None or rep is None or (dem + rep) <= 0:
        return None
    return dem / (dem + rep)


def reliable(prior_votes, votes24):
    return prior_votes >= ABS_FLOOR and prior_votes >= REL_FLOOR * votes24


def main():
    con = sqlite3.connect(DB)
    c = con.cursor()

    # CA unit_ids actually present, with their existing 2024 lean + 2024 two-party vote count.
    ca = {}
    for uid, lds in c.execute("SELECT unit_id, lean_dem_share FROM precincts WHERE state='CA'"):
        ca[uid] = [lds, 0]
    for uid, v in c.execute("""SELECT p.unit_id, e.dem+e.rep FROM precincts p
                               JOIN precinct_elections e ON e.unit_id=p.unit_id
                               WHERE p.state='CA' AND e.office='president' AND e.year=2024"""):
        if uid in ca:
            ca[uid][1] = v or 0
    print(f"CA precincts in DB: {len(ca):,}")

    rows = list(csv.DictReader(open(CSV)))
    print(f"prior-year CSV rows: {len(rows):,}")

    # Idempotent: drop CA's 2016/2020 president rows from any prior run.
    ca_ids = list(ca)
    c.execute("CREATE TEMP TABLE _caids(uid TEXT PRIMARY KEY)")
    c.executemany("INSERT OR IGNORE INTO _caids VALUES (?)", [(u,) for u in ca_ids])
    c.execute("""DELETE FROM precinct_elections
                 WHERE office='president' AND year IN (2016,2020)
                   AND unit_id IN (SELECT uid FROM _caids)""")

    ins = []          # rows to insert into precinct_elections
    traj = {}         # unit_id -> (prev_year, prev_share, lean_shift)
    n16 = n20 = drop16 = drop20 = 0
    for r in rows:
        key = r["SRPREC_KEY"]
        uid = f"{key[:5]}-:-{key}"
        if uid not in ca:
            continue
        lds, v24 = ca[uid]
        d16, r16 = int(r["dem16"]), int(r["rep16"])
        d20, r20 = int(r["dem20"]), int(r["rep20"])
        s16, s20 = two_party(d16, r16), two_party(d20, r20)
        # Insert a prior year only if its electorate is large enough to be a real reading.
        if s16 is not None:
            if reliable(d16 + r16, v24):
                ins.append((uid, "president", 2016, d16, r16, 0, s16)); n16 += 1
            else:
                s16 = None; drop16 += 1
        if s20 is not None:
            if reliable(d20 + r20, v24):
                ins.append((uid, "president", 2020, d20, r20, 0, s20)); n20 += 1
            else:
                s20 = None; drop20 += 1
        # prev_year = most-recent surviving prior year (2020, else 2016); matches build().
        if s20 is not None:
            traj[uid] = (2020, s20, (lds - s20) if lds is not None else None)
        elif s16 is not None:
            traj[uid] = (2016, s16, (lds - s16) if lds is not None else None)
        else:
            traj[uid] = (None, None, None)

    c.executemany("INSERT INTO precinct_elections VALUES (?,?,?,?,?,?,?)", ins)
    c.executemany("""UPDATE precincts SET prev_year=?, prev_dem_share=?, lean_shift=?
                     WHERE unit_id=?""",
                  [(py, ps, sh, uid) for uid, (py, ps, sh) in traj.items()])
    con.commit()

    # ---- verification ----
    print(f"\ninserted: president 2016 rows={n16:,} (dropped {drop16:,} sub-floor)"
          f"  2020 rows={n20:,} (dropped {drop20:,} sub-floor)")
    got_prev = sum(1 for v in traj.values() if v[0] is not None)
    print(f"CA precincts now with a trajectory (prev_year set): {got_prev:,} / {len(ca):,}")

    def statewide(year):
        d, r = c.execute("""SELECT SUM(e.dem), SUM(e.rep) FROM precinct_elections e
                            JOIN precincts p ON p.unit_id=e.unit_id
                            WHERE p.state='CA' AND e.office='president' AND e.year=?""",
                         (year,)).fetchone()
        return d, r, (100 * d / (d + r) if d and r else None)
    for y, cert in [(2016, 66.13), (2020, 64.91), (2024, None)]:
        d, r, pct = statewide(y)
        cs = f"  (certified {cert}%)" if cert else ""
        print(f"  CA {y} two-party D = {pct:.2f}%   D={d:,} R={r:,}{cs}")

    print("\nbiggest CA shifts after flooring (these now feed 'Biggest shift' superlatives):")
    for row in c.execute("""SELECT p.precinct_name, p.borough, p.prev_year, p.prev_dem_share,
                                   p.lean_dem_share, p.lean_shift, e.dem+e.rep AS pv
                            FROM precincts p JOIN precinct_elections e ON e.unit_id=p.unit_id
                               AND e.office='president' AND e.year=p.prev_year
                            WHERE p.state='CA' AND p.lean_shift IS NOT NULL
                            ORDER BY ABS(p.lean_shift) DESC LIMIT 8"""):
        nm, bo, py, p, l, s, pv = row
        print(f"  {bo} {nm}: {py} D {p*100:.0f}% -> 2024 D {l*100:.0f}%  "
              f"(shift {s*100:+.0f}, {py} votes={pv})")

    con.close()
    print("\ndone.")


if __name__ == "__main__":
    main()
