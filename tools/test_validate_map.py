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

    def test_schema_versions(self):
        formats = Path(__file__).resolve().parents[1] / "docs/map-format"
        for name in ("map-v1.json", "map-v2.json", "map-v3.json"):
            validate(json.loads((formats / name).read_text(encoding="utf-8")))
        for bad in (0, -1, 4, 2.0, "2", True, None):
            data = copy.deepcopy(self.data)
            data["schemaVersion"] = bad
            with self.assertRaises(ValueError, msg=repr(bad)):
                validate(data)

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
            for paths, expected in [([str(SAMPLE)], 0), ([str(broken)], 1),
                                    ([str(Path(folder) / "missing*.json")], 1),
                                    ([str(SAMPLE), str(broken)], 1)]:
                result = subprocess.run([sys.executable, script, *paths],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)


class FormatThreeExtrasTests(unittest.TestCase):
    def setUp(self):
        self.v3 = json.loads((Path(__file__).resolve().parents[1] / "docs/map-format/map-v3.json").read_text(encoding="utf-8"))

    def room(self, data):
        return next(n for n in data["nodes"] if n.get("extent"))

    def test_fixture_with_extent_and_mesh_assets_passes(self):
        validate(self.v3)
        self.assertTrue(self.v3.get("meshAssets"))

    def test_hostile_extents_are_rejected(self):
        mutations = [
            lambda e, n: e.update(halfExtents=[500, 500]), lambda e, n: e.update(halfExtents=[0, 2]),
            lambda e, n: e.update(areaSquareMeters=0), lambda e, n: e.update(areaSquareMeters=9999),
            lambda e, n: e.update(center=[400, 0, 0]), lambda e, n: e.update(center=[float("nan"), 0, 0]),
            lambda e, n: e.update(heightMeters=-1), lambda e, n: e.update(yaw=float("inf")),
            lambda e, n: n.update(kind="door"),
        ]
        for i, mutate in enumerate(mutations):
            data = copy.deepcopy(self.v3)
            node = self.room(data)
            mutate(node["extent"], node)
            with self.assertRaises(ValueError, msg=f"mutation {i}"):
                validate(data)

    def test_malformed_mesh_assets_are_rejected(self):
        mutations = [
            lambda a: a.update(segmentId="nope"), lambda a: a.update(format="usdz"), lambda a: a.update(coordinateFrame="world"),
            lambda a: a.update(byteCount=0), lambda a: a.update(byteCount=40_000_001), lambda a: a.update(sha256="abc"),
            lambda a: a.update(sha256="AB" * 32), lambda a: a.update(boundsMin=[9, 0, 0]), lambda a: a.update(storageOwner="x"),
        ]
        for i, mutate in enumerate(mutations):
            data = copy.deepcopy(self.v3)
            mutate(data["meshAssets"][0])
            with self.assertRaises(ValueError, msg=f"mutation {i}"):
                validate(data)
        data = copy.deepcopy(self.v3)
        data["meshAssets"] = data["meshAssets"] * 2  # duplicate id
        with self.assertRaises(ValueError):
            validate(data)

    def test_web_viewer_fixture_validates_if_it_is_a_map(self):
        fixture = Path(__file__).resolve().parents[1] / "web/fixtures/rice-hall-sample.json"
        if fixture.exists():
            validate(json.loads(fixture.read_text(encoding="utf-8")))


class DefaultFolderTests(unittest.TestCase):
    def test_default_run_passes_with_non_map_json_present_and_explicit_path_still_validates_it(self):
        samples = Path(__file__).resolve().parents[1] / "Samples"
        vectors = samples / "route-vectors.json"
        if not vectors.exists():
            self.skipTest("no route-vectors.json in this checkout")
        tool = str(Path(__file__).resolve().parent / "validate_map.py")
        default = subprocess.run([sys.executable, tool], capture_output=True, text=True)
        self.assertEqual(default.returncode, 0, default.stdout)
        self.assertIn("SKIP", default.stdout)
        explicit = subprocess.run([sys.executable, tool, str(vectors)], capture_output=True, text=True)
        self.assertEqual(explicit.returncode, 1, "naming a non-map file must still fail")


if __name__ == "__main__":
    unittest.main()
