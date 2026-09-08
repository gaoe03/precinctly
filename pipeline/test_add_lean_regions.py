#!/usr/bin/env python3
"""Regression tests for the legacy county lean-region post-processor."""

from __future__ import annotations

import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from shapely import wkb
from shapely.geometry import LineString, MultiPolygon, Polygon, box

try:
    from pipeline import add_lean_regions as builder
except ModuleNotFoundError:
    import add_lean_regions as builder  # type: ignore[no-redef]


SCHEMA = """
CREATE TABLE precincts (
    state TEXT, borough TEXT, lean_label TEXT, lean_dem_share REAL,
    lean_votes INTEGER, geometry_wkb BLOB
);
CREATE TABLE county_lean_regions (
    rowid INTEGER PRIMARY KEY, state TEXT, borough TEXT, lean_label TEXT,
    dem_share REAL, min_lon REAL, min_lat REAL, max_lon REAL, max_lat REAL,
    geometry_wkb BLOB
);
CREATE INDEX idx_clr_scope ON county_lean_regions(state, borough);
"""


class FailingInsertConnection:
    def __init__(self, connection):
        self.connection = connection

    def __getattr__(self, name):
        return getattr(self.connection, name)

    def executemany(self, sql, values):
        if "INSERT INTO county_lean_regions" in sql:
            raise sqlite3.OperationalError("injected late insertion failure")
        return self.connection.executemany(sql, values)


class LeanRegionBuilderTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.path = Path(self.temporary_directory.name) / "fixture.sqlite"
        connection = sqlite3.connect(self.path)
        connection.executescript(SCHEMA)
        connection.execute(
            "INSERT INTO county_lean_regions "
            "(rowid,state,borough,lean_label,dem_share) VALUES (77,'OLD','Sentinel','Keep',0.77)"
        )
        connection.commit()
        connection.close()

    def insert_precinct(self, county, geometry, *, label="Lean Dem", share=0.6, votes=100):
        connection = sqlite3.connect(self.path)
        blob = None if geometry is None else (
            geometry if isinstance(geometry, bytes) else wkb.dumps(geometry)
        )
        connection.execute(
            "INSERT INTO precincts VALUES (?,?,?,?,?,?)",
            ("CA", county, label, share, votes, blob),
        )
        connection.commit()
        connection.close()

    def sentinel_rows(self):
        connection = sqlite3.connect(self.path)
        try:
            return connection.execute(
                "SELECT rowid,state,borough,lean_label,dem_share "
                "FROM county_lean_regions ORDER BY rowid"
            ).fetchall()
        finally:
            connection.close()

    def logical_output(self):
        connection = sqlite3.connect(self.path)
        try:
            rows = connection.execute(
                "SELECT state,borough,lean_label,dem_share,geometry_wkb "
                "FROM county_lean_regions ORDER BY state,borough,lean_label"
            ).fetchall()
            return [
                (state, county, label, share, wkb.loads(bytes(blob)).normalize().wkb_hex)
                for state, county, label, share, blob in rows
            ]
        finally:
            connection.close()

    def test_valid_donut_and_disjoint_geometry_remain_intact_and_rerun_is_deterministic(self):
        donut = Polygon(
            [(0, 0), (4, 0), (4, 4), (0, 4), (0, 0)],
            [[(1, 1), (2, 1), (2, 2), (1, 2), (1, 1)]],
        )
        self.insert_precinct("Alpha", donut)
        self.insert_precinct("Alpha", box(10, 10, 11, 11))

        self.assertEqual(builder.rebuild_lean_regions(self.path), 1)
        first = self.logical_output()
        geometry = wkb.loads(bytes.fromhex(first[0][4]))
        self.assertIsInstance(geometry, MultiPolygon)
        self.assertEqual(len(geometry.geoms), 2)
        self.assertEqual(sum(len(part.interiors) for part in geometry.geoms), 1)

        self.assertEqual(builder.rebuild_lean_regions(self.path), 1)
        self.assertEqual(self.logical_output(), first)

    def test_corrupt_missing_invalid_and_nonpolygon_geometry_preserve_existing_table(self):
        invalid = Polygon([(0, 0), (2, 2), (0, 2), (2, 0), (0, 0)])
        cases = (
            (b"not-wkb", "corrupt WKB"),
            (None, "no geometry"),
            (invalid, "invalid geometry"),
            (LineString([(0, 0), (1, 1)]), "nonpolygon geometry"),
        )
        for geometry, message in cases:
            with self.subTest(message=message):
                connection = sqlite3.connect(self.path)
                connection.execute("DELETE FROM precincts")
                connection.commit()
                connection.close()
                self.insert_precinct("Alpha", geometry)
                with self.assertRaisesRegex(ValueError, message):
                    builder.rebuild_lean_regions(self.path)
                self.assertEqual(
                    self.sentinel_rows(), [(77, "OLD", "Sentinel", "Keep", 0.77)]
                )

    def test_one_bad_group_aborts_without_a_silent_partial_map(self):
        self.insert_precinct("Alpha", box(0, 0, 1, 1))
        self.insert_precinct("Beta", b"not-wkb")
        with self.assertRaisesRegex(ValueError, "corrupt WKB"):
            builder.rebuild_lean_regions(self.path)
        self.assertEqual(self.sentinel_rows(), [(77, "OLD", "Sentinel", "Keep", 0.77)])

    def test_one_collapsed_source_geometry_aborts_without_a_partial_group(self):
        self.insert_precinct("Alpha", box(0, 0, 1, 1))
        self.insert_precinct("Alpha", box(2, 2, 2.00000001, 2.00000001))
        with self.assertRaisesRegex(ValueError, "collapsed during precision snapping"):
            builder.rebuild_lean_regions(self.path)
        self.assertEqual(self.sentinel_rows(), [(77, "OLD", "Sentinel", "Keep", 0.77)])

    def test_empty_source_preserves_existing_table(self):
        with self.assertRaisesRegex(ValueError, "no rows"):
            builder.rebuild_lean_regions(self.path)
        self.assertEqual(self.sentinel_rows(), [(77, "OLD", "Sentinel", "Keep", 0.77)])

    def test_no_argument_exits_before_calling_builder(self):
        with mock.patch.object(builder, "rebuild_lean_regions") as rebuild:
            with self.assertRaisesRegex(SystemExit, "Usage"):
                builder.main([])
        rebuild.assert_not_called()

    def test_missing_database_path_is_not_created(self):
        missing = Path(self.temporary_directory.name) / "missing.sqlite"
        with self.assertRaisesRegex(FileNotFoundError, "does not exist"):
            builder.rebuild_lean_regions(missing)
        self.assertFalse(missing.exists())

    def test_source_is_write_locked_before_geometry_build(self):
        self.insert_precinct("Alpha", box(0, 0, 1, 1))
        original_clean_union = builder.clean_union

        def assert_locked(geometries):
            competing = sqlite3.connect(self.path, timeout=0)
            try:
                with self.assertRaisesRegex(sqlite3.OperationalError, "locked"):
                    competing.execute(
                        "INSERT INTO precincts VALUES (?,?,?,?,?,?)",
                        ("CA", "Beta", "Lean Dem", 0.5, 10, wkb.dumps(box(2, 2, 3, 3))),
                    )
            finally:
                competing.close()
            return original_clean_union(geometries)

        with mock.patch.object(builder, "clean_union", side_effect=assert_locked):
            self.assertEqual(builder.rebuild_lean_regions(self.path), 1)

    def test_late_insertion_failure_rolls_back_replacement(self):
        self.insert_precinct("Alpha", box(0, 0, 1, 1))
        real_connection = sqlite3.connect(self.path)
        failing_connection = FailingInsertConnection(real_connection)
        with mock.patch.object(builder.sqlite3, "connect", return_value=failing_connection):
            with self.assertRaisesRegex(sqlite3.OperationalError, "late insertion failure"):
                builder.rebuild_lean_regions(self.path)
        self.assertEqual(self.sentinel_rows(), [(77, "OLD", "Sentinel", "Keep", 0.77)])


if __name__ == "__main__":
    unittest.main()
