#!/usr/bin/env python3
"""Focused mutation tests for the independent Phase 2B candidate verifier."""

from __future__ import annotations

import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
import argparse
import os
from unittest import mock

from shapely.geometry import GeometryCollection, LineString, Polygon

try:
    from pipeline.phase2b_aggregate_contract import (
        PrecinctAggregateInput,
        compute_scope_baselines,
    )
    from pipeline.phase2b_verify_candidate import (
        DEFAULT_REPORT,
        VerificationError,
        canonical_states,
        expected_label,
        polygonal_only,
        safe_report,
        usable_elections,
        verify_app_queries,
        verify_repair_ledger,
        verify_rtree_and_lookup,
        verify_schema,
    )
    from pipeline.phase2b_build_fallback_candidates import (
        SAFE_OUTPUT_DIR,
        SOURCE,
        safe_output_dir,
        safe_source,
        write_json_atomic,
        require_regular_or_missing,
    )
except ModuleNotFoundError:
    from phase2b_aggregate_contract import (  # type: ignore[no-redef]
        PrecinctAggregateInput,
        compute_scope_baselines,
    )
    from phase2b_verify_candidate import (  # type: ignore[no-redef]
        DEFAULT_REPORT,
        VerificationError,
        canonical_states,
        expected_label,
        polygonal_only,
        safe_report,
        usable_elections,
        verify_app_queries,
        verify_repair_ledger,
        verify_rtree_and_lookup,
        verify_schema,
    )
    from phase2b_build_fallback_candidates import (  # type: ignore[no-redef]
        SAFE_OUTPUT_DIR,
        SOURCE,
        safe_output_dir,
        safe_source,
        write_json_atomic,
        require_regular_or_missing,
    )


class ElectionContractTests(unittest.TestCase):
    def test_latest_candidate_pool_requires_explicit_dem_and_rep(self):
        usable = usable_elections({
            ("president", 2024): {"dem": 20},
            ("president", 2020): {"dem": 30, "rep": 70},
            ("president", 2016): {"dem": 0, "rep": 0},
        })
        self.assertNotIn(("president", 2024), usable)
        self.assertNotIn(("president", 2016), usable)
        self.assertEqual(usable[("president", 2020)]["dem_share"], 0.3)

    def test_missing_other_remains_unknown(self):
        usable = usable_elections({
            ("president", 2024): {"dem": 60, "rep": 40},
        })
        self.assertIsNone(usable[("president", 2024)]["other"])

    def test_lean_labels_match_app_buckets_at_boundaries(self):
        self.assertIsNone(expected_label(None))
        self.assertEqual(expected_label(0.349999), "Solid Rep")
        self.assertEqual(expected_label(0.35), "Lean Rep")
        self.assertEqual(expected_label(0.45), "Even")
        self.assertEqual(expected_label(0.55), "Lean Dem")
        self.assertEqual(expected_label(0.65), "Solid Dem")


class GeometryContractTests(unittest.TestCase):
    def test_polygonal_only_discards_nonpolygon_collection_members(self):
        polygon = Polygon([(0, 0), (2, 0), (2, 2), (0, 2)])
        collection = GeometryCollection([polygon, LineString([(0, 0), (4, 4)])])
        result = polygonal_only(collection)
        self.assertIsNotNone(result)
        self.assertTrue(result.equals(polygon))

    def test_rtree_must_conservatively_contain_exact_bounds(self):
        connection = sqlite3.connect(":memory:")
        connection.row_factory = sqlite3.Row
        connection.executescript(
            """
            CREATE TABLE precincts (
              rowid INTEGER PRIMARY KEY, unit_id TEXT, data_complete INT,
              lean_dem_share REAL, pop_total INT,
              min_lon REAL, min_lat REAL, max_lon REAL, max_lat REAL
            );
            CREATE VIRTUAL TABLE precinct_rtree USING rtree(
              id, min_lon, max_lon, min_lat, max_lat
            );
            """
        )
        polygon = Polygon([(0, 0), (1, 0), (1, 1), (0, 1)])
        connection.execute(
            "INSERT INTO precincts VALUES (1,'one',1,0.6,100,0,0,1,1)"
        )
        connection.execute("INSERT INTO precinct_rtree VALUES (1,0,1,0,1)")
        report = verify_rtree_and_lookup(connection, "OR", {1: polygon})
        self.assertEqual(report["representative_points_resolving_to_self"], 1)

        connection.execute("DELETE FROM precinct_rtree")
        connection.execute("INSERT INTO precinct_rtree VALUES (1,0.1,1,0,1)")
        with self.assertRaisesRegex(VerificationError, "does not conservatively contain"):
            verify_rtree_and_lookup(connection, "OR", {1: polygon})


class QueryAndArtifactContractTests(unittest.TestCase):
    def make_query_fixture(self):
        connection = sqlite3.connect(":memory:")
        connection.row_factory = sqlite3.Row
        connection.execute(
            """
            CREATE TABLE precincts (
              unit_id TEXT, state TEXT, lean_dem_share REAL, lean_year INT,
              lean_label TEXT, lean_votes INT, pop_total INT, income_median INT,
              precinct_name TEXT
            )
            """
        )
        connection.executemany(
            "INSERT INTO precincts VALUES (?,?,?,?,?,?,?,?,?)",
            [
                ("known", "OR", 0.6, 2020, "Lean Dem", 500, 800, 70000, "Known"),
                ("unknown", "OR", None, None, None, None, 900, 80000, "Unknown"),
            ],
        )
        return connection

    def test_app_queries_keep_null_politics_out_of_political_ranges(self):
        connection = self.make_query_fixture()
        report = verify_app_queries(connection, "OR")
        self.assertEqual(report["geographic_profiles"], 2)
        self.assertEqual(report["political_profiles"], 1)
        self.assertEqual(report["political_null_profiles"], 1)
        self.assertEqual(report["election_null_profiles_eligible_for_demographic_queries"], 1)

    def test_fake_even_mutation_is_rejected(self):
        connection = self.make_query_fixture()
        connection.execute(
            "UPDATE precincts SET lean_label='Even',lean_dem_share=0.5 WHERE unit_id='unknown'"
        )
        with self.assertRaisesRegex(VerificationError, "converted to Even"):
            verify_app_queries(connection, "OR")

    def test_incomplete_schema_is_rejected(self):
        connection = sqlite3.connect(":memory:")
        connection.row_factory = sqlite3.Row
        with self.assertRaisesRegex(VerificationError, "missing tables"):
            verify_schema(connection, "OR")

    def test_report_path_cannot_escape_candidate_directory(self):
        self.assertEqual(safe_report(str(DEFAULT_REPORT)), DEFAULT_REPORT.resolve())
        with self.assertRaisesRegex(VerificationError, "report path must be"):
            safe_report("/tmp/phase2b-report.json")
        with self.assertRaisesRegex(VerificationError, "report path must be"):
            safe_report(str(DEFAULT_REPORT.with_name("or_manifest.json")))

    def test_verifier_requires_the_complete_two_state_set(self):
        self.assertEqual(canonical_states("CO,OR"), ("OR", "CO"))
        for value in ("OR", "CO", "OR,OR", "OR,WA", ""):
            with self.subTest(value=value):
                with self.assertRaisesRegex(VerificationError, "complete OR,CO"):
                    canonical_states(value)

    def test_symlinked_report_path_is_rejected(self):
        with mock.patch.object(Path, "is_symlink", return_value=True):
            with self.assertRaisesRegex(VerificationError, "cannot be a symlink"):
                safe_report(str(DEFAULT_REPORT))

    def test_partial_education_and_household_denominators_stay_unknown(self):
        partial_source = PrecinctAggregateInput(
            unit_id="partial-source",
            state="OR",
            county="Alpha",
            pop_total=100,
            demographic_complete=False,
            education_total=None,
            household_total=None,
            pct_ba_or_higher=0.75,
            pct_renter=0.25,
            income_median=80_000,
        )
        baseline = compute_scope_baselines([partial_source])[0]
        self.assertIsNone(baseline.pct_ba_or_higher)
        self.assertIsNone(baseline.pct_renter)
        self.assertIsNone(baseline.income_median)

    def test_builder_paths_are_exactly_guarded(self):
        self.assertEqual(safe_source(str(SOURCE)), SOURCE.resolve())
        self.assertEqual(safe_output_dir(str(SAFE_OUTPUT_DIR)), SAFE_OUTPUT_DIR.resolve())
        with self.assertRaises(argparse.ArgumentTypeError):
            safe_source("/tmp/not-the-private-source.sqlite")
        with self.assertRaises(argparse.ArgumentTypeError):
            safe_output_dir("/tmp/not-the-candidate-directory")

    def test_atomic_sidecar_writer_leaves_complete_json(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            write_json_atomic(path, {"status": "BLOCKED", "shipping": False})
            self.assertEqual(
                json.loads(path.read_text(encoding="utf-8")),
                {"status": "BLOCKED", "shipping": False},
            )
            self.assertFalse(path.with_suffix(".json.tmp").exists())

    def test_symlinked_candidate_target_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            external = Path(directory) / "external.json"
            external.write_text("protected", encoding="utf-8")
            link = Path(directory) / "manifest.json"
            os.symlink(external, link)
            with self.assertRaisesRegex(RuntimeError, "symlinked candidate path"):
                require_regular_or_missing(link)
            self.assertEqual(external.read_text(encoding="utf-8"), "protected")

    def test_repair_ledger_unit_set_is_enforced(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ledger.json"
            path.write_text(
                json.dumps({
                    "schema_version": 1,
                    "state": "CO",
                    "repair_count": 0,
                    "repairs": [],
                }),
                encoding="utf-8",
            )
            self.assertEqual(verify_repair_ledger(path, "CO", {})["repair_count"], 0)
            document = json.loads(path.read_text(encoding="utf-8"))
            document["state"] = "OR"
            path.write_text(json.dumps(document), encoding="utf-8")
            with self.assertRaisesRegex(VerificationError, "repair unit set mismatch"):
                verify_repair_ledger(path, "OR", {})


if __name__ == "__main__":
    unittest.main()
