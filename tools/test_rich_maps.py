"""Independent schema 3 structural/integrity regression checks."""
import base64
import copy
import hashlib
import json
from pathlib import Path
import unittest
from validate_map import validate

ROOT = Path(__file__).resolve().parents[1]


class RichMapTests(unittest.TestCase):
    def setUp(self):
        self.map = json.loads((ROOT / "Samples/rice-hall-sample.json").read_text())
        self.raw = b"v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"
        self.asset = dict(id="aaaaaaaa-0000-4000-8000-000000000001", segmentId="seg1",
                          format="obj", coordinateFrame="map", byteCount=len(self.raw),
                          sha256=hashlib.sha256(self.raw).hexdigest(), boundsMin=[0,0,0], boundsMax=[1,1,0])

    def test_all_format_fixtures(self):
        for version in (1, 2, 3, 4):
            with self.subTest(version=version):
                validate(json.loads((ROOT / f"docs/map-format/map-v{version}.json").read_text()))

    def test_bad_formats(self):
        for version in (0, 5, True, "3", 3.5):
            with self.subTest(version=version), self.assertRaises(ValueError):
                validate({**self.map, "schemaVersion": version})

    def test_bad_extents(self):
        for field, value in [("center", [0,0]), ("halfExtents", [-1,2]),
                             ("halfExtents", [1,float("inf")]), ("yaw", float("nan")),
                             ("areaSquareMeters", 9999), ("areaSquareMeters", -1),
                             ("heightMeters", 0), ("heightMeters", True)]:
            data = copy.deepcopy(self.map)
            data["nodes"][5]["extent"][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                validate(data)

    def test_valid_mesh_bundle(self):
        self.map["meshAssets"] = [self.asset]
        validate(dict(map=self.map, worldMaps={}, meshFiles={self.asset["id"]: base64.b64encode(self.raw).decode()}))

    def test_bad_assets(self):
        for field, value in [("id", "../bad"), ("segmentId", "missing"), ("format", "glb"),
                             ("coordinateFrame", "anchor"), ("byteCount", 40_000_001),
                             ("sha256", "no"), ("boundsMin", [2,2,2]), ("storageOwner", "../bad")]:
            asset = {**self.asset, field: value}
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate({**self.map, "meshAssets": [asset]})
        for assets in ({}, [self.asset, self.asset]):
            with self.assertRaises(ValueError):
                validate({**self.map, "meshAssets": assets})

    def test_corrupt_or_unknown_payload_rejected(self):
        self.map["meshAssets"] = [self.asset]
        for payloads in [{self.asset["id"]: "AA=="}, {self.asset["id"]: "!!"},
                         {"aaaaaaaa-0000-4000-8000-000000000099": "AA=="}]:
            with self.assertRaises(ValueError):
                validate(dict(map=self.map, worldMaps={}, meshFiles=payloads))
