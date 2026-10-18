"""U3 regression checks for malformed maps and command-line failures."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from validate_map import validate

SAMPLE = Path(__file__).resolve().parents[1] / "Samples/rice-hall-sample.json"


class MapValidationTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads(SAMPLE.read_text(encoding="utf-8"))

    def test_sample_and_bundle(self):
        validate(self.data)
        validate({"map": self.data, "worldMaps": {"seg1": "aGVsbG8="}})

    def test_hostile_nodes(self):
        mutations = [
            ("segmentId", "../escape"), ("segmentId", ""),
            ("segmentId", "a" * 65), ("segmentId", "é"),
            ("position", [0, float("inf"), 0]),
            ("position", [0, float("nan"), 0]),
            ("position", [0, True, 0]), ("position", [0, 0]),
            ("position", [0, 1e100, 0]), ("kind", "unknown"),
            ("id", "not-a-uuid"), ("createdBy", None),
        ]
        for key, value in mutations:
            with self.subTest(key=key, value=value):
                data = copy.deepcopy(self.data)
                data["nodes"][0][key] = value
                with self.assertRaises(ValueError):
                    validate(data)

    def test_duplicate_ids_case_insensitive(self):
        self.data["nodes"].append(copy.deepcopy(self.data["nodes"][0]))
        self.data["nodes"][-1]["id"] = self.data["nodes"][-1]["id"].lower()
        with self.assertRaisesRegex(ValueError, "duplicate"):
            validate(self.data)

    def test_bad_edges(self):
        for patch in [{"to": self.data["id"]},
                      {"to": self.data["edges"][0]["from"]},
                      {"distance": 100}, {"distance": float("nan")},
                      {"hazard": "unknown"}]:
            with self.subTest(patch=patch):
                data = copy.deepcopy(self.data)
                data["edges"][0].update(patch)
                with self.assertRaises(ValueError):
                    validate(data)

    def test_distance_tolerance(self):
        self.data["edges"][0]["distance"] = 3.75
        validate(self.data)
        self.data["edges"][0]["distance"] = 3.751
        with self.assertRaises(ValueError):
            validate(self.data)

    def test_size_limits(self):
        for key, count in [("nodes", 5001), ("edges", 20001)]:
            data = copy.deepcopy(self.data)
            data[key] = [data[key][0]] * count
            with self.assertRaisesRegex(ValueError, "too large"):
                validate(data)

    def test_bundle_errors(self):
        for world_maps in [None, {"../bad": ""}, {"seg1": "!invalid!"}]:
            with self.subTest(world_maps=world_maps):
                with self.assertRaises(ValueError):
                    validate({"map": self.data, "worldMaps": world_maps})

    def test_missing_fields_and_wrong_types(self):
        for key in ["id", "name", "version", "nodes", "edges"]:
            data = copy.deepcopy(self.data)
            del data[key]
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate(data)
        for data in [[], None, {**self.data, "version": True}]:
            with self.assertRaises(ValueError):
                validate(data)

    def test_cli(self):
        script = str(Path(__file__).with_name("validate_map.py"))
        with tempfile.TemporaryDirectory() as folder:
            broken = Path(folder) / "broken.json"
            broken.write_text("{invalid", encoding="utf-8")
            for paths, expected in [([], 0), ([str(SAMPLE)], 0), ([str(broken)], 1),
                                    ([str(Path(folder) / "missing*.json")], 1),
                                    ([str(SAMPLE), str(broken)], 1)]:
                result = subprocess.run([sys.executable, script, *paths],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
