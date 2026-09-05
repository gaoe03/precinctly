#!/usr/bin/env python3
"""Focused mutation and safety tests for the Phase 3 combined verifier."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest import mock

try:
    from pipeline import phase3_verify_combined as verifier
except ModuleNotFoundError:
    import phase3_verify_combined as verifier  # type: ignore[no-redef]


PRECINCT_COLUMNS = """
  rowid INTEGER PRIMARY KEY,
  unit_id TEXT UNIQUE, fips TEXT, state TEXT, borough TEXT, precinct_name TEXT,
  min_lon REAL, min_lat REAL, max_lon REAL, max_lat REAL, geometry_wkb BLOB,
  lean_dem_share REAL, prev_dem_share REAL, lean_year INT, prev_year INT,
  lean_label TEXT, lean_shift REAL, lean_votes INT, turnout_est REAL,
  pop_total INT, vap_total INT, cvap INT,
  pct_white REAL, pct_black REAL, pct_hispanic REAL, pct_asian REAL,
  pct_native REAL, pct_pacific REAL, pct_other REAL, plurality_group TEXT,
  pct_no_hs REAL, pct_hs REAL, pct_bachelors REAL, pct_graduate REAL,
  pct_ba_or_higher REAL, income_median INT, pop_density REAL, avg_age REAL,
  pct_renter REAL, pct_owner REAL, data_complete INT
"""


def fixture_connection() -> sqlite3.Connection:
    connection = sqlite3.connect(":memory:")
    connection.row_factory = sqlite3.Row
    connection.executescript(f"""
        CREATE TABLE precincts ({PRECINCT_COLUMNS});
        CREATE TABLE precinct_elections (
          unit_id TEXT, office TEXT, year INT, dem INT, rep INT, other INT,
          dem_share REAL
        );
        CREATE TABLE baselines (
          scope TEXT PRIMARY KEY, precinct_count INT, political_precinct_count INT,
          pop_total INT, pct_white REAL, pct_black REAL, pct_hispanic REAL,
          pct_asian REAL, pct_native REAL, pct_pacific REAL, pct_other REAL,
          pct_ba_or_higher REAL, income_median INT, pct_renter REAL, avg_age REAL,
          pres24_dem_share REAL
        );
        CREATE VIRTUAL TABLE precinct_rtree USING rtree(
          id, min_lon, max_lon, min_lat, max_lat
        );
        CREATE TABLE county_lean_regions (
          rowid INTEGER PRIMARY KEY, state TEXT, borough TEXT, lean_label TEXT,
          dem_share REAL, min_lon REAL, min_lat REAL, max_lon REAL, max_lat REAL,
          geometry_wkb BLOB
        );
        CREATE INDEX idx_precincts_unit ON precincts(unit_id);
        CREATE INDEX idx_precincts_state ON precincts(state, borough);
        CREATE INDEX idx_pe_unit ON precinct_elections(unit_id);
        CREATE INDEX idx_clr_scope ON county_lean_regions(state, borough);
    """)
    return connection


def insert_precinct(
    connection: sqlite3.Connection,
    rowid: int,
    unit_id: str,
    state: str,
    *,
    lean_year: int | None = 2020,
) -> None:
    columns = [row[1] for row in connection.execute("PRAGMA table_info(precincts)")]
    values = {column: None for column in columns}
    values.update({
        "rowid": rowid, "unit_id": unit_id, "fips": unit_id.split("-:-")[0],
        "state": state, "borough": "Alpha", "precinct_name": "One",
        "min_lon": 0.0, "min_lat": 0.0, "max_lon": 1.0, "max_lat": 1.0,
        "lean_year": lean_year, "lean_dem_share": 0.6 if lean_year else None,
        "lean_label": "Lean Dem" if lean_year else None,
        "lean_votes": 100 if lean_year else None, "pop_total": 100,
        "income_median": 50_000, "data_complete": 1 if lean_year else 0,
    })
    connection.execute(
        f"INSERT INTO precincts ({','.join(columns)}) VALUES ({','.join('?' for _ in columns)})",
        [values[column] for column in columns],
    )
    connection.execute("INSERT INTO precinct_rtree VALUES (?,?,?,?,?)", (rowid, 0, 1, 0, 1))


class PathAndHashTests(unittest.TestCase):
    def test_exact_path_guard_rejects_escape_and_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            expected = root / "artifact.sqlite"
            expected.write_bytes(b"db")
            self.assertEqual(verifier.safe_exact_path(expected, expected), Path(os.path.abspath(expected)))
            with self.assertRaisesRegex(verifier.VerificationError, "exactly"):
                verifier.safe_exact_path(root / "other.sqlite", expected)
            link = root / "link.sqlite"
            os.symlink(expected, link)
            with self.assertRaisesRegex(verifier.VerificationError, "exactly|symlink"):
                verifier.safe_exact_path(link, expected)

    def test_symlinked_ancestor_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            real = root / "real"
            real.mkdir()
            link = root / "link"
            os.symlink(real, link)
            expected = link / "nested" / "artifact.sqlite"
            with self.assertRaisesRegex(verifier.VerificationError, "component cannot be a symlink"):
                verifier.safe_exact_path(expected, expected, output=True)

    def test_hash_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "artifact"
            path.write_bytes(b"actual")
            expected = hashlib.sha256(b"expected").hexdigest()
            with self.assertRaisesRegex(verifier.VerificationError, "SHA256 mismatch"):
                verifier.verify_hash(path, expected)


class PreservationAndMappingTests(unittest.TestCase):
    def make_base_and_combined(self):
        base = fixture_connection()
        combined = fixture_connection()
        insert_precinct(base, 1, "base-:-one", "CA")
        insert_precinct(combined, 1, "base-:-one", "CA")
        return base, combined

    def test_base_preservation_mutation_is_rejected(self):
        base, combined = self.make_base_and_combined()
        self.addCleanup(base.close)
        self.addCleanup(combined.close)
        combined.execute("UPDATE precincts SET precinct_name='Mutated' WHERE rowid=1")
        with mock.patch.object(verifier, "EXPECTED_BASE_STATE_COUNTS", {"CA": 1}):
            with self.assertRaisesRegex(verifier.VerificationError, "base precincts differs"):
                verifier.verify_base_preservation(base, combined)

    def make_candidate_and_combined(self):
        candidate = fixture_connection()
        combined = fixture_connection()
        insert_precinct(candidate, 1, "41001-:-one", "OR")
        insert_precinct(combined, 50, "41001-:-one", "OR")
        candidate.execute("INSERT INTO baselines(scope,precinct_count,political_precinct_count) VALUES ('OR',1,1)")
        combined.execute("INSERT INTO baselines(scope,precinct_count,political_precinct_count) VALUES ('OR',1,1)")
        candidate.execute("INSERT INTO precinct_elections VALUES ('41001-:-one','president',2020,60,40,NULL,0.6)")
        combined.execute("INSERT INTO precinct_elections VALUES ('41001-:-one','president',2020,60,40,NULL,0.6)")
        candidate.execute("INSERT INTO county_lean_regions(rowid,state,borough,lean_label) VALUES (1,'OR','Alpha','Lean Dem')")
        combined.execute("INSERT INTO county_lean_regions(rowid,state,borough,lean_label) VALUES (90,'OR','Alpha','Lean Dem')")
        return candidate, combined

    def test_candidate_mapping_accepts_only_rowid_remapping(self):
        candidate, combined = self.make_candidate_and_combined()
        self.addCleanup(candidate.close)
        self.addCleanup(combined.close)
        report = verifier.verify_candidate_mapping(candidate, combined, "OR")
        self.assertTrue(report["rowids_remapped"])
        combined.execute("UPDATE precincts SET income_median=50001 WHERE state='OR'")
        with self.assertRaisesRegex(verifier.VerificationError, "mapped precincts differs"):
            verifier.verify_candidate_mapping(candidate, combined, "OR")

    def test_rtree_mapping_mutation_is_rejected(self):
        candidate, combined = self.make_candidate_and_combined()
        self.addCleanup(candidate.close)
        self.addCleanup(combined.close)
        combined.execute("DELETE FROM precinct_rtree")
        combined.execute("INSERT INTO precinct_rtree VALUES (50,0,1.1,0,1)")
        with self.assertRaisesRegex(verifier.VerificationError, "mapped R-tree values differ"):
            verifier.verify_candidate_mapping(candidate, combined, "OR")


class PoliticalAndBaselineTests(unittest.TestCase):
    def test_political_null_mutation_is_rejected(self):
        connection = fixture_connection()
        self.addCleanup(connection.close)
        insert_precinct(connection, 1, "41005-:-X000", "OR", lean_year=None)
        connection.execute("UPDATE precincts SET lean_label='Even',lean_dem_share=0.5 WHERE rowid=1")
        with mock.patch.object(verifier, "EXPECTED_COUNTS", {
            "precincts": 1, "precinct_rtree": 1, "precinct_elections": 0,
            "baselines": 0, "county_lean_regions": 0,
        }), mock.patch.object(verifier, "EXPECTED_ALL_STATES", ("OR",)), \
             mock.patch.object(verifier, "EXPECTED_STATE_COUNTS", {"OR": 1}), \
             mock.patch.object(verifier, "EXPECTED_YEARS", {"OR": {None: 1}, "CO": {}}), \
             mock.patch.object(verifier, "EXPECTED_NULL_UNITS", {"OR": {"41005-:-X000"}, "CO": set()}):
            with self.assertRaisesRegex(verifier.VerificationError, "political fields|fake Even"):
                verifier.verify_whole_counts(connection)

    def test_baseline_scope_mutation_is_rejected(self):
        candidate, combined = PreservationAndMappingTests().make_candidate_and_combined()
        self.addCleanup(candidate.close)
        self.addCleanup(combined.close)
        combined.execute("UPDATE baselines SET scope='county|OR|Wrong' WHERE scope='OR'")
        with self.assertRaisesRegex(verifier.VerificationError, "mapped baselines"):
            verifier.verify_candidate_mapping(candidate, combined, "OR")


class CanonicalReportTests(unittest.TestCase):
    def test_report_is_deterministic_across_input_order(self):
        first = verifier.build_report("abc", {"z": {"b": 2, "a": 1}, "a": [3, 2, 1]})
        second = verifier.build_report("abc", {"a": [3, 2, 1], "z": {"a": 1, "b": 2}})
        self.assertEqual(verifier.canonical_json(first), verifier.canonical_json(second))
        decoded = json.loads(verifier.canonical_json(first))
        self.assertEqual(decoded["release_gate"]["status"], "BLOCKED")
        self.assertFalse(decoded["release_gate"]["shipping_authorized"])


class ProtectedBoundaryTests(unittest.TestCase):
    def test_protected_boundary_rejects_a_mutated_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            protected = root / "protected.txt"
            protected.write_text("accepted", encoding="utf-8")
            snapshot = root / "snapshot.json"
            snapshot.write_text(json.dumps({
                "schema_version": 1,
                "files": {"protected.txt": hashlib.sha256(b"accepted").hexdigest()},
            }), encoding="utf-8")
            with mock.patch.object(verifier, "ROOT", root), \
                 mock.patch.dict(verifier.EXPECTED_HASHES, {
                     snapshot: hashlib.sha256(snapshot.read_bytes()).hexdigest()
                 }, clear=True), \
                 mock.patch.object(verifier, "PROTECTED_SNAPSHOT", snapshot):
                self.assertEqual(verifier.verify_protected_boundary(snapshot)["mismatch_count"], 0)
                protected.write_text("mutated", encoding="utf-8")
                with self.assertRaisesRegex(verifier.VerificationError, "protected boundary changed"):
                    verifier.verify_protected_boundary(snapshot)


if __name__ == "__main__":
    unittest.main()
