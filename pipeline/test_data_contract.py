#!/usr/bin/env python3
"""Regression tests for CVAP, selected-year baseline, builder, and migration contracts."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from shapely.geometry import Polygon

from pipeline import apply_area_baselines
from pipeline import build_region_precincts
from pipeline.data_contract import (
    DataContractError,
    aggregate_two_party_votes,
    cap_cvap_to_vap,
    selected_president_aggregate,
    turnout_from_cvap,
)
from pipeline.migrate_data_contract import MigrationError, migrate, repair, sha256


def schema(connection: sqlite3.Connection) -> None:
    connection.executescript(
        """
        CREATE TABLE precincts (
          unit_id TEXT PRIMARY KEY, fips TEXT, state TEXT, borough TEXT, pop_total INT,
          vap_total INT, cvap INT, lean_votes INT, turnout_est REAL, lean_year INT,
          pct_white REAL, pct_black REAL, pct_hispanic REAL, pct_asian REAL,
          pct_native REAL, pct_pacific REAL, pct_other REAL, pct_ba_or_higher REAL,
          income_median INT, pct_renter REAL, avg_age REAL
        );
        CREATE TABLE precinct_elections (
          unit_id TEXT, office TEXT, year INT, dem INT, rep INT, other INT, dem_share REAL
        );
        CREATE TABLE baselines (
          scope TEXT PRIMARY KEY, pop_total INT, pct_white REAL, pct_black REAL,
          pct_hispanic REAL, pct_asian REAL, pct_native REAL, pct_pacific REAL,
          pct_other REAL, pct_ba_or_higher REAL, income_median INT, pct_renter REAL,
          avg_age REAL, pres24_dem_share REAL, precinct_count INTEGER,
          political_precinct_count INTEGER
        );
        CREATE TABLE untouched (value TEXT);
        """
    )


def add_precinct(
    connection: sqlite3.Connection,
    unit_id: str,
    year: int | None,
    dem: int | None,
    rep: int | None,
    *,
    fips: str = "99001",
    vap: int | None = 100,
    cvap: int | None = 80,
    votes: int | None = 50,
) -> None:
    connection.execute(
        "INSERT INTO precincts VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (unit_id, fips, "ZZ", "Alpha", 100, vap, cvap, votes,
         turnout_from_cvap(votes, cvap), year, 0.5, 0.1, 0.2, 0.1, 0.01, 0.01,
         0.08, 0.4, 60_000, 0.4, 38.0),
    )
    if year is not None:
        share = dem / (dem + rep) if dem is not None and rep is not None and dem + rep else None
        connection.execute(
            "INSERT INTO precinct_elections VALUES (?,?,?,?,?,?,?)",
            (unit_id, "president", year, dem, rep, 0, share),
        )


class CVAPContractTests(unittest.TestCase):
    def test_cap_preserves_unknowns_and_only_caps_known_overage(self):
        self.assertIsNone(cap_cvap_to_vap(None, 90))
        self.assertEqual(cap_cvap_to_vap(100, None), 100)
        self.assertEqual(cap_cvap_to_vap(80, 90), 80)
        self.assertEqual(cap_cvap_to_vap(100, 90), 90)

    def test_turnout_recomputed_after_cap_with_existing_null_guards(self):
        self.assertAlmostEqual(turnout_from_cvap(45, 90) or 0, 0.5)
        self.assertIsNone(turnout_from_cvap(45, 49))
        self.assertIsNone(turnout_from_cvap(None, 90))
        self.assertIsNone(turnout_from_cvap(116, 100))


class PoliticalBaselineTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        schema(self.db)

    def tearDown(self):
        self.db.close()

    def test_mixed_year_null_and_zero_fixture_is_vote_weighted(self):
        add_precinct(self.db, "2024", 2024, 60, 40)
        add_precinct(self.db, "2020", 2020, 20, 80)
        add_precinct(self.db, "all-dem", 2016, 10, 0)
        add_precinct(self.db, "zero", 2024, 0, 0)
        add_precinct(self.db, "null", None, None, None)
        self.db.execute("INSERT INTO precinct_elections VALUES ('2020','president',2016,1000,0,0,1.0)")
        aggregate = selected_president_aggregate(self.db, "p.state=?", ("ZZ",))
        self.assertEqual((aggregate.dem, aggregate.rep, aggregate.precinct_count), (90, 120, 3))
        self.assertAlmostEqual(aggregate.dem_share or 0, 90 / 210)

    def test_unknown_vote_pair_is_excluded_and_negative_votes_fail(self):
        result = aggregate_two_party_votes([(None, 20), (10, None), (0, 0), (0, 25)])
        self.assertEqual((result.dem, result.rep, result.precinct_count), (0, 25, 1))
        with self.assertRaisesRegex(DataContractError, "negative"):
            aggregate_two_party_votes([(-1, 5)])

    def test_duplicate_selected_election_fails_closed(self):
        add_precinct(self.db, "duplicate", 2024, 60, 40)
        self.db.execute("INSERT INTO precinct_elections VALUES ('duplicate','president',2024,60,40,0,0.6)")
        with self.assertRaisesRegex(DataContractError, "2 presidential rows"):
            selected_president_aggregate(self.db, "p.state=?", ("ZZ",))

    def test_area_baseline_uses_selected_year_and_preserves_demographic_weighting(self):
        add_precinct(self.db, "one", 2024, 60, 40)
        add_precinct(self.db, "two", 2020, 20, 80)
        self.db.execute("INSERT INTO precinct_elections VALUES ('two','president',2016,1000,0,0,1.0)")
        row = apply_area_baselines.weighted(self.db, "p.state=?", ("ZZ",))
        self.assertAlmostEqual(row["pres24_dem_share"] or 0, 0.4)
        self.assertEqual(row["political_precinct_count"], 2)
        self.assertEqual(row["pop_total"], 200)
        self.assertAlmostEqual(row["pct_white"], 0.5)


class BuilderArgumentTests(unittest.TestCase):
    def test_output_is_required_before_source_loading(self):
        with self.assertRaises(SystemExit):
            build_region_precincts.parse_args([])

    def test_existing_output_is_rejected_and_current_mode_is_default(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "already.sqlite"
            output.write_bytes(b"existing")
            with self.assertRaises(SystemExit):
                build_region_precincts.parse_args(["--out", str(output)])
            fresh = Path(directory) / "fresh.sqlite"
            args = build_region_precincts.parse_args(["--out", str(fresh)])
            self.assertEqual(args.mode, "p2024")

    def test_builder_caps_cvap_before_storing_and_computing_turnout(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "built.sqlite"
            record = {
                "unit_id": "synthetic",
                "fips": "99001",
                "county": "Alpha",
                "precinct_name": "One",
                "state_abbr": "ZZ",
                "geometry": Polygon([(-100, 40), (-99.9, 40), (-99.9, 40.1), (-100, 40.1)]),
                "demographics": {"pop_total": 100, "vap_total": 100, "cvap": 120},
                "elections": {("president", 2024): {"dem": 30, "rep": 20, "other": 0}},
            }
            build_region_precincts.build([record], str(output))
            db = sqlite3.connect(output)
            self.assertEqual(
                db.execute("SELECT cvap,turnout_est FROM precincts").fetchone(),
                (100, 0.5),
            )
            self.assertAlmostEqual(
                db.execute("SELECT pres24_dem_share FROM baselines WHERE scope='ZZ'").fetchone()[0],
                0.6,
            )
            db.close()


class MigrationTests(unittest.TestCase):
    def make_source(self, directory: Path) -> Path:
        source = directory / "source.sqlite"
        db = sqlite3.connect(source)
        schema(db)
        add_precinct(db, "over", 2024, 30, 20, vap=100, cvap=120, votes=50)
        add_precinct(db, "under-50", 2020, 20, 10, vap=40, cvap=80, votes=30)
        add_precinct(db, "unknown", None, None, None, vap=None, cvap=70, votes=None)
        db.execute("INSERT INTO baselines(scope,pres24_dem_share) VALUES ('ZZ',0.99)")
        db.execute("INSERT INTO untouched VALUES ('keep')")
        db.commit(); db.close()
        return source

    def test_disposable_migration_has_exact_ledger_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory_name:
            directory = Path(directory_name)
            source = self.make_source(directory)
            output, report = directory / "candidate.sqlite", directory / "report.json"
            source_hash = sha256(source)
            result = migrate(source, output, report, source_hash)
            self.assertEqual(sha256(source), source_hash)
            self.assertEqual(result["second_pass_changed_cell_count"], 0)
            self.assertEqual(result["allowed_changed_cell_counts"], {
                "baselines.pres24_dem_share": 1,
                "precincts.cvap": 2,
                "precincts.turnout_est": 2,
            })
            written = json.loads(report.read_text())
            self.assertEqual(written["changes"], result["changes"])
            candidate = sqlite3.connect(output)
            self.assertEqual(candidate.execute("SELECT value FROM untouched").fetchone()[0], "keep")
            self.assertEqual(candidate.execute("SELECT cvap,turnout_est FROM precincts WHERE unit_id='over'").fetchone(), (100, 0.5))
            self.assertEqual(candidate.execute("SELECT cvap,turnout_est FROM precincts WHERE unit_id='under-50'").fetchone(), (40, None))
            candidate.close()

    def test_opt_in_turnout_migration_changes_only_turnout_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory_name:
            directory = Path(directory_name)
            source = self.make_source(directory)
            source_db = sqlite3.connect(source)
            source_db.execute("UPDATE precincts SET cvap=100,turnout_est=0.9 WHERE unit_id='over'")
            source_db.execute(
                "UPDATE precincts SET cvap=40,turnout_est=0.75 WHERE unit_id='under-50'"
            )
            source_db.commit(); source_db.close()
            output, report = directory / "turnout.sqlite", directory / "turnout.json"

            result = migrate(
                source,
                output,
                report,
                sha256(source),
                recompute_turnout=True,
            )

            self.assertEqual(result["mode"], "recompute_turnout")
            self.assertEqual(result["allowed_changed_cell_counts"], {
                "precincts.turnout_est": 2,
            })
            self.assertEqual(result["second_pass_changed_cell_count"], 0)
            candidate = sqlite3.connect(output)
            self.assertEqual(
                candidate.execute(
                    "SELECT cvap,turnout_est FROM precincts WHERE unit_id='over'"
                ).fetchone(),
                (100, 0.5),
            )
            self.assertEqual(
                candidate.execute(
                    "SELECT cvap,turnout_est FROM precincts WHERE unit_id='under-50'"
                ).fetchone(),
                (40, None),
            )
            self.assertEqual(
                candidate.execute(
                    "SELECT pres24_dem_share FROM baselines WHERE scope='ZZ'"
                ).fetchone()[0],
                0.99,
            )
            candidate.close()

    def test_rejects_existing_output_hash_mismatch_and_nonempty_sidecar(self):
        with tempfile.TemporaryDirectory() as directory_name:
            directory = Path(directory_name)
            source = self.make_source(directory)
            output, report = directory / "candidate.sqlite", directory / "report.json"
            output.write_bytes(b"occupied")
            with self.assertRaisesRegex(MigrationError, "output already exists"):
                migrate(source, output, report, sha256(source))
            output.unlink()
            with self.assertRaisesRegex(MigrationError, "hash mismatch"):
                migrate(source, output, report, "0" * 64)
            Path(str(source) + "-wal").write_bytes(b"pending")
            with self.assertRaisesRegex(MigrationError, "nonempty SQLite sidecar"):
                migrate(source, output, report, sha256(source))

    def test_exact_ledger_rejects_an_unlisted_allowed_column_mutation(self):
        from pipeline.migrate_data_contract import verify_only_allowed_changes

        with tempfile.TemporaryDirectory() as directory_name:
            directory = Path(directory_name)
            source = self.make_source(directory)
            candidate_path = directory / "candidate.sqlite"
            candidate_path.write_bytes(source.read_bytes())
            source_db = sqlite3.connect(source)
            candidate_db = sqlite3.connect(candidate_path)
            changes = repair(candidate_db)
            candidate_db.execute("UPDATE precincts SET turnout_est=0.1 WHERE unit_id='unknown'")
            candidate_db.commit()
            with self.assertRaisesRegex(MigrationError, "ledger does not exactly match"):
                verify_only_allowed_changes(source_db, candidate_db, changes)
            candidate_db.close(); source_db.close()


if __name__ == "__main__":
    unittest.main()
