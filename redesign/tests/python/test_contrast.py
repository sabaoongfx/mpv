"""Tests for redesign/tools/contrast.py (WCAG maths and the bundle palette)."""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
spec = importlib.util.spec_from_file_location("contrast", os.path.join(REPO, "redesign", "tools", "contrast.py"))
contrast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contrast)


class Maths(unittest.TestCase):
    def test_white_on_black_is_21_to_1(self):
        self.assertAlmostEqual(contrast.ratio("FFFFFF", "000000"), 21.0, places=6)

    def test_same_colour_is_1_to_1(self):
        self.assertAlmostEqual(contrast.ratio("8F8F8F", "8F8F8F"), 1.0, places=6)

    def test_order_does_not_matter(self):
        self.assertAlmostEqual(contrast.ratio("1B1B1B", "FFFFFF"), contrast.ratio("FFFFFF", "1B1B1B"))

    def test_mid_grey_on_black_is_between_4_6_and_4_8(self):
        self.assertTrue(4.6 <= contrast.ratio("777777", "000000") <= 4.8)


class Palette(unittest.TestCase):
    def test_bundle_palette_passes_every_check(self):
        self.assertEqual(contrast.main(), 0)

    def test_osc_colours_are_read_from_the_bundle(self):
        osc = contrast.osc_colours()
        self.assertEqual(osc["background_color"], "1B1B1B")
        self.assertEqual(osc["buttons_color"], "FFFFFF")

    def test_script_colours_are_read(self):
        menu = contrast.script_colours("juxtopposed-menu.lua")
        self.assertEqual(menu["COL_HOVER"], "242424")


if __name__ == "__main__":
    unittest.main()
