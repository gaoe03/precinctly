#!/usr/bin/env python3
"""Focused tests for the Phase 2B baseline and lean-region contracts."""

from __future__ import annotations

import sqlite3
import unittest

try:
    from pipeline.phase2b_aggregate_contract import (
        CertifiedZero,
        ElectionVote,
        NO_DATA_LABEL,
        Phase2BContractError,
        PrecinctAggregateInput,
        compute_scope_baselines,
        county_lean_region_buckets,
        load_aggregate_inputs,
        ranked_precincts,
        select_latest_usable_president,
        write_scope_baselines,
    )
except ModuleNotFoundError:  # Supports the repo convention: python3 pipeline/<script>.py.
    from phase2b_aggregate_contract import (  # type: ignore[no-redef]
        CertifiedZero,
        ElectionVote,
        NO_DATA_LABEL,
        Phase2BContractError,
        PrecinctAggregateInput,
        compute_scope_baselines,
        county_lean_region_buckets,
        load_aggregate_inputs,
        ranked_precincts,
        select_latest_usable_president,
        write_scope_baselines,
    )


DEMO_DEFAULTS = {
    "pct_white": 0.5,
    "pct_black": 0.1,
    "pct_hispanic": 0.2,
    "pct_asian": 0.1,
    "pct_native": 0.01,
    "pct_pacific": 0.01,
    "pct_other": 0.08,
    "pct_ba_or_higher": 0.4,
    "income_median": 60_000,
    "pct_renter": 0.4,
    "avg_age": 38.0,
}


def precinct(
    unit_id: str,
    state: str = "OR",
    county: str = "Alpha",
    pop_total: int | None = 100,
    demographic_complete: bool = True,
    **changes,
) -> PrecinctAggregateInput:
    values = dict(DEMO_DEFAULTS)
    values.update(changes)
    values.setdefault("education_total", pop_total)
    values.setdefault("household_total", pop_total)
    return PrecinctAggregateInput(
        unit_id=unit_id,
        state=state,
        county=county,
        pop_total=pop_total,
        demographic_complete=demographic_complete,
        **values,
    )


class ElectionSelectionTests(unittest.TestCase):
    def test_latest_year_requires_both_parties_and_positive_two_party_total(self):
        rows = [
            ElectionVote("mixed", "president", 2024, "dem", 70),
            ElectionVote("mixed", "president", 2020, "dem", 40),
            ElectionVote("mixed", "president", 2020, "rep", 60),
            ElectionVote("zero", "president", 2024, "dem", 0),
            ElectionVote("zero", "president", 2024, "rep", 0),
            ElectionVote("zero", "president", 2016, "dem", 25),
            ElectionVote("zero", "president", 2016, "rep", 75),
            ElectionVote("current", "president", 2024, "dem", 55),
            ElectionVote("current", "president", 2024, "rep", 45),
            ElectionVote("current", "governor", 2026, "dem", 500),
        ]

        selected = select_latest_usable_president(rows)

        self.assertEqual(selected["mixed"].year, 2020)
        self.assertEqual(selected["zero"].year, 2016)
        self.assertEqual(selected["current"].year, 2024)
        self.assertAlmostEqual(selected["current"].dem_share, 0.55)

    def test_absent_party_stays_unknown_without_explicit_certified_zero(self):
        rows = [ElectionVote("rep_only", "president", 2020, "rep", 90)]
        self.assertNotIn("rep_only", select_latest_usable_president(rows))

        selected = select_latest_usable_president(
            rows,
            [CertifiedZero("rep_only", "president", 2020, "dem")],
        )
        self.assertEqual(selected["rep_only"].dem, 0)
        self.assertEqual(selected["rep_only"].rep, 90)
        self.assertEqual(selected["rep_only"].dem_share, 0.0)

    def test_absent_other_stays_unknown_unless_explicitly_supplied(self):
        rows = [
            ElectionVote("unknown_other", "president", 2024, "dem", 60),
            ElectionVote("unknown_other", "president", 2024, "rep", 40),
            ElectionVote("known_other", "president", 2024, "dem", 60),
            ElectionVote("known_other", "president", 2024, "rep", 40),
            ElectionVote("known_other", "president", 2024, "other", 0),
            ElectionVote("certified_other", "president", 2024, "dem", 60),
            ElectionVote("certified_other", "president", 2024, "rep", 40),
        ]
        selected = select_latest_usable_president(
            rows,
            [CertifiedZero("certified_other", "president", 2024, "other")],
        )
        self.assertIsNone(selected["unknown_other"].other)
        self.assertEqual(selected["known_other"].other, 0)
        self.assertEqual(selected["certified_other"].other, 0)

    def test_literal_zero_row_is_known_but_two_zero_rows_are_not_usable(self):
        rows = [
            ElectionVote("known_zero", "president", 2024, "dem", 0),
            ElectionVote("known_zero", "president", 2024, "rep", 12),
            ElectionVote("no_votes", "president", 2024, "dem", 0),
            ElectionVote("no_votes", "president", 2024, "rep", 0),
        ]
        selected = select_latest_usable_president(rows)
        self.assertEqual(selected["known_zero"].dem_share, 0.0)
        self.assertNotIn("no_votes", selected)


class BaselineTests(unittest.TestCase):
    def test_demographic_and_political_denominators_are_separate_with_mixed_years(self):
        records = [
            precinct(
                "or-1",
                pop_total=100,
                lean_year=2024,
                dem=60,
                rep=40,
                lean_label="D+20",
                pct_white=0.2,
            ),
            precinct(
                "or-2",
                pop_total=300,
                lean_year=2020,
                dem=20,
                rep=80,
                lean_label="R+60",
                pct_white=0.6,
            ),
            precinct("or-demo-only", pop_total=100, pct_white=1.0),
            precinct("or-incomplete", pop_total=500, demographic_complete=False, pct_white=None),
            precinct("or-zero-pop", pop_total=0, pct_white=0.0),
            precinct(
                "co-leak",
                state="CO",
                county="Alpha",
                pop_total=10_000,
                lean_year=2024,
                dem=10_000,
                rep=0,
                lean_label="D+100",
                pct_white=0.0,
            ),
        ]

        rows = {row.scope: row for row in compute_scope_baselines(records, meaningful_count=3)}
        state = rows["OR"]

        self.assertEqual(state.precinct_count, 5)
        self.assertEqual(state.political_precinct_count, 2)
        self.assertEqual(state.pop_total, 1000)
        self.assertAlmostEqual(state.pct_white or 0, 0.6)
        self.assertAlmostEqual(state.pres24_dem_share or 0, 80 / 200)
        self.assertIn("county|OR|Alpha", rows)
        self.assertNotIn("county|CO|Alpha", rows)
        self.assertEqual(rows["CO"].pres24_dem_share, 1.0)

    def test_every_meaningful_county_is_present_and_small_county_is_omitted(self):
        records = [
            precinct("a-1", county="Alpha"),
            precinct("a-2", county="Alpha"),
            precinct("b-1", county="Beta"),
        ]
        scopes = {row.scope for row in compute_scope_baselines(records, meaningful_count=2)}
        self.assertEqual(scopes, {"OR", "county|OR|Alpha"})

    def test_same_named_counties_in_different_states_never_share_totals(self):
        records = [
            precinct("or-1", state="OR", county="Shared", lean_year=2024, dem=80, rep=20, lean_label="D+60"),
            precinct("or-2", state="OR", county="Shared", lean_year=2020, dem=60, rep=40, lean_label="D+20"),
            precinct("co-1", state="CO", county="Shared", lean_year=2024, dem=20, rep=80, lean_label="R+60"),
            precinct("co-2", state="CO", county="Shared", lean_year=2024, dem=40, rep=60, lean_label="R+20"),
        ]
        rows = {row.scope: row for row in compute_scope_baselines(records, meaningful_count=2)}
        self.assertAlmostEqual(rows["county|OR|Shared"].pres24_dem_share or 0, 0.7)
        self.assertAlmostEqual(rows["county|CO|Shared"].pres24_dem_share or 0, 0.3)
        self.assertEqual(rows["county|OR|Shared"].political_precinct_count, 2)
        self.assertEqual(rows["county|CO|Shared"].political_precinct_count, 2)

    def test_each_demographic_field_uses_its_own_non_null_population_denominator(self):
        records = [
            precinct(
                "complete",
                pop_total=100,
                pct_white=0.2,
                pct_ba_or_higher=0.5,
                pct_renter=0.25,
                income_median=50_000,
            ),
            precinct(
                "zero-edu-denominator",
                pop_total=300,
                demographic_complete=False,
                pct_white=0.6,
                pct_ba_or_higher=None,
                pct_renter=0.75,
                income_median=100_000,
            ),
            precinct(
                "zero-housing-denominator",
                pop_total=600,
                demographic_complete=False,
                pct_white=1.0,
                pct_ba_or_higher=0.25,
                pct_renter=None,
                income_median=-1,
            ),
        ]
        baseline = compute_scope_baselines(records)[0]
        self.assertEqual(baseline.precinct_count, 3)
        self.assertEqual(baseline.pop_total, 1000)
        self.assertAlmostEqual(baseline.pct_white or 0, 0.8)
        self.assertAlmostEqual(baseline.pct_ba_or_higher or 0, 0.2857142857142857)
        self.assertAlmostEqual(baseline.pct_renter or 0, 0.625)
        self.assertEqual(baseline.income_median, 87_500)

    def test_education_and_household_metrics_use_source_denominators_not_population(self):
        records = [
            precinct(
                "large-pop-small-denominators",
                pop_total=900,
                education_total=10,
                household_total=10,
                pct_ba_or_higher=1.0,
                pct_renter=1.0,
                income_median=200_000,
            ),
            precinct(
                "small-pop-large-denominators",
                pop_total=100,
                education_total=90,
                household_total=90,
                pct_ba_or_higher=0.0,
                pct_renter=0.0,
                income_median=100_000,
            ),
        ]

        baseline = compute_scope_baselines(records)[0]

        self.assertEqual(baseline.pop_total, 1000)
        self.assertAlmostEqual(baseline.pct_ba_or_higher or 0, 0.1)
        self.assertAlmostEqual(baseline.pct_renter or 0, 0.1)
        self.assertEqual(baseline.income_median, 110_000)

    def test_writer_keeps_app_precinct_count_and_adds_political_count(self):
        connection = sqlite3.connect(":memory:")
        connection.execute(
            """
            CREATE TABLE baselines (
              scope TEXT PRIMARY KEY, precinct_count INT, pop_total INT,
              pct_white REAL, pct_black REAL, pct_hispanic REAL, pct_asian REAL,
              pct_native REAL, pct_pacific REAL, pct_other REAL,
              pct_ba_or_higher REAL, income_median INT, pct_renter REAL, avg_age REAL,
              pres24_dem_share REAL
            )
            """
        )
        computed = compute_scope_baselines(
            [
                precinct("one", lean_year=2024, dem=70, rep=30, lean_label="D+40"),
                precinct("two"),
            ],
            meaningful_count=2,
        )

        self.assertTrue(write_scope_baselines(connection, computed))
        row = connection.execute(
            "SELECT precinct_count, political_precinct_count FROM baselines WHERE scope = 'OR'"
        ).fetchone()
        self.assertEqual(row, (2, 1))
        app_columns = connection.execute(
            "SELECT scope, precinct_count, pop_total, pres24_dem_share FROM baselines WHERE scope = 'OR'"
        ).fetchone()
        self.assertEqual(app_columns[:3], ("OR", 2, 200))
        self.assertAlmostEqual(app_columns[3], 0.7)


class LeanRegionTests(unittest.TestCase):
    def test_no_data_bucket_uses_sql_null_and_never_fake_even(self):
        records = [
            precinct("known", lean_year=2024, dem=50, rep=50, lean_label="Even"),
            precinct("unknown-1"),
            precinct("unknown-2"),
        ]
        buckets = {bucket.lean_label: bucket for bucket in county_lean_region_buckets(records)}

        self.assertEqual(buckets["Even"].dem_share, 0.5)
        self.assertEqual(buckets[NO_DATA_LABEL].unit_ids, ("unknown-1", "unknown-2"))
        self.assertIsNone(buckets[NO_DATA_LABEL].dem_share)
        self.assertEqual(buckets[NO_DATA_LABEL].political_precinct_count, 0)

        connection = sqlite3.connect(":memory:")
        connection.execute("CREATE TABLE regions (lean_label TEXT, dem_share REAL)")
        connection.execute(
            "INSERT INTO regions VALUES (?, ?)",
            (NO_DATA_LABEL, buckets[NO_DATA_LABEL].dem_share),
        )
        self.assertEqual(
            connection.execute("SELECT lean_label FROM regions WHERE dem_share IS NULL").fetchone()[0],
            NO_DATA_LABEL,
        )


class SQLiteHelperTests(unittest.TestCase):
    def setUp(self):
        self.connection = sqlite3.connect(":memory:")
        demo_sql = ", ".join(f"{name} REAL" for name in DEMO_DEFAULTS)
        self.connection.executescript(
            f"""
            CREATE TABLE precincts (
              unit_id TEXT PRIMARY KEY, state TEXT, borough TEXT, pop_total INT,
              lean_year INT, lean_label TEXT, lean_dem_share REAL,
              demographic_complete INT, {demo_sql}
            );
            CREATE TABLE precinct_elections (
              unit_id TEXT, office TEXT, year INT, dem INT, rep INT, other INT, dem_share REAL
            );
            """
        )

    def tearDown(self):
        self.connection.close()

    def insert_precinct(self, unit_id, state, lean_year, lean_share, *, county="Alpha"):
        columns = [
            "unit_id", "state", "borough", "pop_total", "lean_year", "lean_label",
            "lean_dem_share", "demographic_complete", *DEMO_DEFAULTS,
        ]
        values = [
            unit_id, state, county, 100, lean_year,
            "D+20" if lean_share is not None else None,
            lean_share, 1, *DEMO_DEFAULTS.values(),
        ]
        self.connection.execute(
            f"INSERT INTO precincts ({','.join(columns)}) VALUES ({','.join('?' for _ in columns)})",
            values,
        )

    def test_loader_joins_only_selected_year_and_state_filter_prevents_leakage(self):
        self.insert_precinct("or-old", "OR", 2020, 0.4)
        self.insert_precinct("or-new", "OR", 2024, 0.6)
        self.insert_precinct("co", "CO", 2024, 0.99)
        self.connection.executemany(
            "INSERT INTO precinct_elections VALUES (?, 'president', ?, ?, ?, 0, ?)",
            [
                ("or-old", 2020, 40, 60, 0.4),
                ("or-old", 2024, 99, 1, 0.99),
                ("or-new", 2024, 60, 40, 0.6),
                ("co", 2024, 99, 1, 0.99),
            ],
        )

        records = load_aggregate_inputs(self.connection, ["OR"])
        self.assertEqual([record.unit_id for record in records], ["or-new", "or-old"])
        by_id = {record.unit_id: record for record in records}
        self.assertEqual((by_id["or-old"].lean_year, by_id["or-old"].dem, by_id["or-old"].rep), (2020, 40, 60))
        baseline = compute_scope_baselines(records, meaningful_count=2)[0]
        self.assertAlmostEqual(baseline.pres24_dem_share or 0, 100 / 200)

    def test_rankings_exclude_nulls_and_are_state_scoped(self):
        self.insert_precinct("or-high", "OR", 2024, 0.8)
        self.insert_precinct("or-null", "OR", None, None)
        self.insert_precinct("or-low", "OR", 2020, 0.2)
        self.insert_precinct("co-higher", "CO", 2024, 0.99)

        rows = ranked_precincts(self.connection, "lean_dem_share", "OR")
        self.assertEqual([row[0] for row in rows], ["or-high", "or-low"])
        self.assertTrue(all(row[1] == "OR" and row[3] is not None for row in rows))


if __name__ == "__main__":
    unittest.main()
