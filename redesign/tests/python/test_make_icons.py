"""Tests for redesign/tools/make_icons.py (path parsing, stroke quads, generated files)."""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))


def load(name, rel):
    spec = importlib.util.spec_from_file_location(name, os.path.join(REPO, rel))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


icons = load("make_icons", "redesign/tools/make_icons.py")


def close(a, b, tol=1e-6):
    return abs(a - b) <= tol


class ParsePath(unittest.TestCase):
    def test_absolute_lines_and_close(self):
        sub = icons.parse_path("M0 0 L10 0 V10 H0 Z")
        self.assertEqual(len(sub), 1)
        pts, closed = sub[0]
        self.assertTrue(closed)
        self.assertEqual(pts, [(0, 0), (10, 0), (10, 10), (0, 10)])

    def test_relative_commands(self):
        pts, closed = icons.parse_path("m1 1 l2 0 v2 h-2 z")[0]
        self.assertTrue(closed)
        self.assertEqual(pts, [(1, 1), (3, 1), (3, 3), (1, 3)])

    def test_implicit_lineto_after_move(self):
        pts, _ = icons.parse_path("M0 0 5 0 5 5")[0]
        self.assertEqual(pts, [(0, 0), (5, 0), (5, 5)])

    def test_cubic_is_flattened_to_eight_segments(self):
        pts, _ = icons.parse_path("M0 0 C0 10 10 10 10 0")[0]
        self.assertEqual(len(pts), 9)
        self.assertTrue(close(pts[0][0], 0) and close(pts[-1][0], 10) and close(pts[-1][1], 0))

    def test_smooth_cubic_reflects_the_previous_control_point(self):
        pts, _ = icons.parse_path("M0 0 C0 10 10 10 10 0 S20 -10 20 0")[0]
        self.assertTrue(close(pts[-1][0], 20) and close(pts[-1][1], 0))

    def test_two_subpaths(self):
        subs = icons.parse_path("M0 0 L1 0 L1 1 Z M5 5 L6 5 L6 6 Z")
        self.assertEqual(len(subs), 2)
        self.assertEqual(subs[1][0][0], (5, 5))

    def test_unknown_command_is_an_error(self):
        with self.assertRaises(ValueError):
            icons.parse_path("M0 0 A1 1 0 0 1 2 2")


class Transform(unittest.TestCase):
    def test_translate(self):
        self.assertEqual(icons.parse_transform("translate(-1.5 2)"), (-1.5, 2.0))

    def test_missing_transform_is_zero(self):
        self.assertEqual(icons.parse_transform(""), (0.0, 0.0))


class StrokeQuads(unittest.TestCase):
    def test_one_segment_becomes_one_quad_of_the_stroke_width(self):
        quads = icons.stroke_quads([(0, 0), (10, 0)], closed=False, hw=0.5)
        self.assertEqual(len(quads), 1)
        ys = sorted({round(y, 6) for _, y in quads[0]})
        self.assertEqual(ys, [-0.5, 0.5])

    def test_quads_are_counter_clockwise(self):
        for quad in icons.stroke_quads([(0, 0), (10, 0), (10, 10)], closed=False, hw=0.75):
            self.assertGreater(icons.signed_area(quad), 0)

    def test_closed_path_adds_the_closing_segment(self):
        open_n = len(icons.stroke_quads([(0, 0), (1, 0), (1, 1)], closed=False, hw=0.5))
        closed_n = len(icons.stroke_quads([(0, 0), (1, 0), (1, 1)], closed=True, hw=0.5))
        self.assertEqual(closed_n, open_n + 1)

    def test_zero_length_segments_are_skipped(self):
        self.assertEqual(icons.stroke_quads([(2, 2), (2, 2)], closed=False, hw=0.5), [])


class GeneratedFiles(unittest.TestCase):
    """Drift check: the generated data in the repo must match the VLC SVGs it came from.
    Skipped when the VLC tree is not checked out next to this repository."""

    def setUp(self):
        if not os.path.isdir(icons.PIX):
            self.skipTest("VLC redesign tree not found at " + icons.PIX)

    def test_shared_module_is_up_to_date(self):
        with open(icons.SHARED, encoding="utf-8") as f:
            self.assertEqual(f.read(), icons.build_shared(),
                             "run redesign/tools/make_icons.py to regenerate")

    def test_osc_block_is_up_to_date(self):
        with open(icons.OSC, encoding="utf-8") as f:
            src = f.read()
        block = icons.build_block().rstrip("\n")
        self.assertIn(block, src, "run redesign/tools/make_icons.py to regenerate osc.lua")


if __name__ == "__main__":
    unittest.main()
