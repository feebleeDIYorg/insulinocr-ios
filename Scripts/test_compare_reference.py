import pathlib
import itertools
import random
import tempfile
import unittest

from compare_reference import basal_metrics, pair_by_time, pair_events, point_metrics, read_reference, timestamp


class ReferenceComparisonTests(unittest.TestCase):
    def test_event_matching_agrees_with_exhaustive_small_assignments(self):
        generator = random.Random(17)
        for _ in range(30):
            observed = [(generator.randrange(6), None, generator.choice(["bolus", "carbohydrates", "unknown"])) for _ in range(3)]
            expected = [(generator.randrange(6), 1, generator.choice(["bolus", "carbohydrates"])) for _ in range(3)]
            scores = []
            for assignment in itertools.product(range(-1, 3), repeat=3):
                selected = [j for j in assignment if j >= 0]
                if len(set(selected)) != len(selected):
                    continue
                if any(j >= 0 and (abs(observed[i][0] - expected[j][0]) > 2
                       or observed[i][2] not in ("unknown", expected[j][2])) for i, j in enumerate(assignment)):
                    continue
                scores.append((len(selected), -sum(abs(observed[i][0] - expected[j][0]) for i, j in enumerate(assignment) if j >= 0)))
            actual = pair_events(observed, expected, tolerance=2)
            self.assertEqual((len(actual), -sum(delta for _, _, delta in actual)), max(scores))

    def test_simultaneous_event_kinds_match_independently_of_input_order(self):
        observed = [(0, 1, "bolus"), (0, 5, "carbohydrates")]
        expected = list(reversed(observed))
        pairs = pair_events(observed, expected)
        self.assertEqual({(i, j) for i, j, _ in pairs}, {(0, 1), (1, 0)})

    def test_unknown_event_cannot_consume_only_match_for_classified_event(self):
        observed = [(0, None, "unknown"), (100, 1, "bolus")]
        expected = [(0, 1, "bolus"), (100, 5, "carbohydrates")]
        self.assertEqual({(i, j) for i, j, _ in pair_events(observed, expected)}, {(0, 1), (1, 0)})
        self.assertEqual(len(pair_events(observed + observed, expected)), 2)

    def test_matching_maximizes_unique_matches_before_minimizing_time_error(self):
        pairs = pair_by_time([(0, 1), (100, 2)], [(90, 1), (200, 2)])
        self.assertEqual([(i, j) for i, j, _ in pairs], [(0, 0), (1, 1)])

    def test_duplicates_and_unknown_values_do_not_inflate_numeric_recall(self):
        result = point_metrics([(0, 4), (1, 4), (300, None)], [(0, 4), (300, 5)])
        self.assertEqual(result["matchedCount"], 2)
        self.assertEqual(result["numericMatchedCount"], 1)
        self.assertEqual(result["precision"], 1 / 3)
        self.assertEqual(result["recall"], 0.5)

    def test_basal_error_is_time_weighted_and_uncovered_time_is_reported(self):
        result = basal_metrics([(0, 10, 2), (10, 30, 5)], [(0, 1), (10, 3)], 0, 40)
        self.assertAlmostEqual(result["timeWeightedMAEUnitsPerHour"], 5 / 3)
        self.assertEqual(result["comparisonCoverage"], 0.75)

    def test_reference_sections_units_and_summer_timezone(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "reference.txt"
            path.write_text("Meal ***\n(dd/mm/yyyy hh:mm) (g)\n17/09/2026 15:21\t18\nGlucose_concentration ***\n(dd/mm/yyyy hh:mm) (mmol/L)\n17/09/2026 15:21\t8.5\nSensor_stopped ***\n17/09/2026 15:21\t99\n")
            result = read_reference(path, "Europe/Zurich")
        self.assertEqual(result["carbohydrates"], [(timestamp("2026-09-17T13:21:00Z"), 18)])
        self.assertEqual(result["glucose"], [(timestamp("2026-09-17T13:21:00Z"), 8.5)])

    def test_unexpected_reference_units_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "reference.txt"
            path.write_text("Glucose_concentration ***\n(dd/mm/yyyy hh:mm) (mg/dL)\n17/09/2026 15:21\t150\n")
            with self.assertRaises(ValueError):
                read_reference(path, "Europe/Zurich")


if __name__ == "__main__":
    unittest.main()
