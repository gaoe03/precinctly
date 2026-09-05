#!/usr/bin/env python3
"""Focused safety tests for the Phase 3 full evaluation merge."""

from __future__ import annotations

import argparse
from pathlib import Path
import tempfile
import unittest
from unittest import mock

try:
    from pipeline.phase3_build_full_evaluation import (
        OUTPUT,
        Phase3MergeError,
        allocate_rowids,
        install_verified_database,
        safe_output,
        sha256,
        verify_regular_hash,
    )
except ModuleNotFoundError:
    from phase3_build_full_evaluation import (  # type: ignore[no-redef]
        OUTPUT,
        Phase3MergeError,
        allocate_rowids,
        install_verified_database,
        safe_output,
        sha256,
        verify_regular_hash,
    )


class MergeSafetyTests(unittest.TestCase):
    def test_output_path_is_exactly_guarded(self):
        self.assertEqual(safe_output(str(OUTPUT)), OUTPUT)
        for path in ("/tmp/phase3.sqlite", str(OUTPUT.with_name("shipping.sqlite"))):
            with self.subTest(path=path):
                with self.assertRaises(argparse.ArgumentTypeError):
                    safe_output(path)

    def test_hash_guard_rejects_stale_input(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.sqlite"
            path.write_bytes(b"accepted")
            verify_regular_hash(path, sha256(path))
            with self.assertRaisesRegex(Phase3MergeError, "hash mismatch"):
                verify_regular_hash(path, "0" * 64)

    def test_rowid_mapping_is_stable_and_rejects_duplicates(self):
        self.assertEqual(allocate_rowids([9, 4, 20], 101), {9: 101, 4: 102, 20: 103})
        with self.assertRaisesRegex(Phase3MergeError, "duplicate source rowid"):
            allocate_rowids([1, 1], 3)

    def test_output_directory_symlink_is_rejected(self):
        with mock.patch.object(Path, "is_symlink", return_value=True):
            with self.assertRaisesRegex(argparse.ArgumentTypeError, "cannot contain a symlink"):
                safe_output(str(OUTPUT))

    def test_failure_before_replace_preserves_prior_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            staged, target = root / "staged.sqlite", root / "target.sqlite"
            staged.write_bytes(b"new-complete")
            target.write_bytes(b"prior-complete")

            def failpoint(stage: str) -> None:
                if stage == "before_replace":
                    raise RuntimeError("injected")

            with self.assertRaisesRegex(RuntimeError, "injected"):
                install_verified_database(staged, target, failpoint)
            self.assertEqual(target.read_bytes(), b"prior-complete")

    def test_replace_error_preserves_prior_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            staged, target = root / "staged.sqlite", root / "target.sqlite"
            staged.write_bytes(b"new-complete")
            target.write_bytes(b"prior-complete")
            with mock.patch("pipeline.phase3_build_full_evaluation.os.replace", side_effect=OSError("injected")):
                with self.assertRaisesRegex(OSError, "injected"):
                    install_verified_database(staged, target)
            self.assertEqual(target.read_bytes(), b"prior-complete")

    def test_failure_after_replace_leaves_new_complete_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            staged, target = root / "staged.sqlite", root / "target.sqlite"
            staged.write_bytes(b"new-complete")
            target.write_bytes(b"prior-complete")

            def failpoint(stage: str) -> None:
                if stage == "after_replace":
                    raise RuntimeError("injected")

            with self.assertRaisesRegex(RuntimeError, "injected"):
                install_verified_database(staged, target, failpoint)
            self.assertEqual(target.read_bytes(), b"new-complete")


if __name__ == "__main__":
    unittest.main()
