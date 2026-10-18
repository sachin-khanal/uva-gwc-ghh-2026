"""U3: independently check BuildingMap/MapBundle JSON without dependencies.

Mirrors MapTypes.swift decoding and MapBundle.validate() structural rules.
Positions and distances are rounded to Swift Float precision before comparison.
Does not check real-world accuracy or the safety of a route.
"""

import argparse
import base64
import glob
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import sys
from uuid import UUID

MAX_NODES = 5_000
MAX_EDGES = 20_000
MAX_WORLD_MAP_BYTES = 50_000_000
SEGMENT = re.compile(r"[A-Za-z0-9_-]{1,64}\Z")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def object_value(value, path):
    require(isinstance(value, dict), f"{path}: expected an object")
    return value


def string(value, path):
    require(isinstance(value, str), f"{path}: expected a string")
    return value


def uuid_value(value, path):
    value = string(value, path)
    require(re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", value),
            f"{path}: expected a UUID")
    return UUID(value)


def float32(value, path):
    require(type(value) in (int, float), f"{path}: expected a number")
    try:
        result = struct.unpack("f", struct.pack("f", value))[0]
    except (OverflowError, struct.error):
        raise ValueError(f"{path}: outside Float range") from None
    require(math.isfinite(result), f"{path}: expected a finite Float")
    return result


def position(value, path):
    require(isinstance(value, list) and len(value) == 3,
            f"{path}: expected three coordinates")
    return tuple(float32(v, path) for v in value)


def segment(value, path):
    require(isinstance(value, str) and SEGMENT.fullmatch(value),
            f"{path}: unsafe segment id (use 1-64 ASCII letters, digits, _ or -)")


# Map format versions this tool understands (mirror of Swift `MapSchema`; specs in docs/MAP_FORMAT.md).
CURRENT_SCHEMA = 4
OLDEST_SCHEMA = 1


# Format-3 optional fields. Mirrors Swift `MapExtrasValidation.swift` and web/router.js (keep all three in step).
MAX_ROOM_HALF = 30.0
MAX_ROOM_HEIGHT = 20.0
MAX_ASSETS = 100
MAX_ASSET_BYTES = 40_000_000
MAX_ASSET_TOTAL = 80_000_000
SHA256 = re.compile(r"^[a-f0-9]{64}$")


def check_extents(nodes):
    for i, node in enumerate(nodes):
        extent = node.get("extent")
        if extent is None:
            continue
        path = f"nodes[{i}].extent"
        object_value(extent, path)
        require(node.get("kind") == "room", path + ": only a room can have a floor area")
        center = position(extent.get("center"), path + ".center")
        half = extent.get("halfExtents")
        require(isinstance(half, list) and len(half) == 2, path + ".halfExtents: expected [x, z]")
        hx, hz = float32(half[0], path + ".halfExtents[0]"), float32(half[1], path + ".halfExtents[1]")
        require(0.05 < hx <= MAX_ROOM_HALF and 0.05 < hz <= MAX_ROOM_HALF, path + ".halfExtents: size out of range")
        float32(extent.get("yaw"), path + ".yaw")
        area = float32(extent.get("areaSquareMeters"), path + ".areaSquareMeters")
        require(0 < area <= 4 * hx * hz + 0.01, path + ".areaSquareMeters: does not match the size")
        if extent.get("heightMeters") is not None:
            height = float32(extent["heightMeters"], path + ".heightMeters")
            require(0 < height <= MAX_ROOM_HEIGHT, path + ".heightMeters: out of range")
        where = position(node.get("position"), "node.position")
        far = math.hypot(center[0] - where[0], center[2] - where[2])
        require(far <= math.hypot(hx, hz) + 1, path + ": floor area is far from its room")


def check_mesh_assets(assets, nodes):
    if assets is None:
        return
    require(isinstance(assets, list) and len(assets) <= MAX_ASSETS, "meshAssets: expected a list of at most 100")
    segments = {n.get("segmentId") for n in nodes}
    seen, total = set(), 0
    for i, asset in enumerate(assets):
        path = f"meshAssets[{i}]"
        object_value(asset, path)
        asset_id = uuid_value(asset.get("id"), path + ".id")
        require(asset_id not in seen, path + ": duplicate id")
        seen.add(asset_id)
        segment(asset.get("segmentId"), path + ".segmentId")
        require(asset["segmentId"] in segments, path + ".segmentId: no such scan in this map")
        require(asset.get("format") == "obj" and asset.get("coordinateFrame") == "map", path + ": unsupported format or frame")
        size = asset.get("byteCount")
        require(type(size) is int and 1 <= size <= MAX_ASSET_BYTES, path + ".byteCount: out of range")
        require(isinstance(asset.get("sha256"), str) and SHA256.match(asset["sha256"]), path + ".sha256: expected 64 lowercase hex characters")
        lo, hi = position(asset.get("boundsMin"), path + ".boundsMin"), position(asset.get("boundsMax"), path + ".boundsMax")
        require(all(a <= b for a, b in zip(lo, hi)), path + ": bounds are inverted")
        if asset.get("storageOwner") is not None:
            uuid_value(asset["storageOwner"], path + ".storageOwner")
        total += size
    require(total <= MAX_ASSET_TOTAL, "meshAssets: more than 80 MB in total")


def validate(document):
    """Raise ValueError for invalid data; accept a bare map or exported bundle."""
    object_value(document, "document")
    if "map" in document:
        data = object_value(document["map"], "map")
        world_maps = object_value(document.get("worldMaps"), "worldMaps")
        for key, encoded in world_maps.items():
            segment(key, "worldMaps key")
            string(encoded, f"worldMaps.{key}")
            require(len(encoded) <= 4 * ((MAX_WORLD_MAP_BYTES + 2) // 3),
                    "world map exceeds 50 MB")
            try:
                decoded = base64.b64decode(encoded, validate=True)
            except ValueError:
                raise ValueError(f"worldMaps.{key}: invalid base64") from None
            require(len(decoded) <= MAX_WORLD_MAP_BYTES, "world map exceeds 50 MB")
    else:
        data = document
    if "schemaVersion" in data:  # absent == format 1
        schema = data["schemaVersion"]
        require(type(schema) is int and schema >= OLDEST_SCHEMA, "schemaVersion: expected an integer >= 1")
        require(schema <= CURRENT_SCHEMA,
                f"schemaVersion: format {schema} is newer than this tool understands ({CURRENT_SCHEMA})")
    uuid_value(data.get("id"), "id")
    string(data.get("name"), "name")
    version = data.get("version")
    require(type(version) is int and -(2**63) <= version < 2**63,
            "version: expected a Swift Int")
    nodes, edges = data.get("nodes"), data.get("edges")
    require(isinstance(nodes, list), "nodes: expected an array")
    require(isinstance(edges, list), "edges: expected an array")
    require(len(nodes) <= MAX_NODES and len(edges) <= MAX_EDGES, "map is too large")
    positions = {}
    for i, node in enumerate(nodes):
        path = f"nodes[{i}]"
        object_value(node, path)
        node_id = uuid_value(node.get("id"), path + ".id")
        require(node_id not in positions, path + ": duplicate node id")
        require(node.get("kind") in ("corridor", "door", "stairs", "elevator", "room", "junction"),
                path + ": unknown node kind")
        if node.get("label") is not None:
            string(node["label"], path + ".label")
        string(node.get("createdBy"), path + ".createdBy")
        segment(node.get("segmentId"), path + ".segmentId")
        positions[node_id] = position(node.get("position"), path + ".position")
    check_extents(nodes)
    check_mesh_assets(data.get("meshAssets"), nodes)
    if "map" in document and document.get("meshFiles") is not None:
        manifest = {uuid_value(a["id"], "mesh id"): a for a in data.get("meshAssets", []) or []}
        for asset_key, payload in object_value(document["meshFiles"], "meshFiles").items():
            asset = manifest.get(uuid_value(asset_key, "meshFiles key"))
            require(asset is not None and isinstance(payload, str), "unknown mesh payload")
            require(len(payload) <= 4 * ((40_000_000 + 2) // 3), "mesh payload too large")
            try:
                raw = base64.b64decode(payload, validate=True)
            except ValueError:
                raise ValueError("invalid mesh base64") from None
            require(len(raw) == asset["byteCount"] and hashlib.sha256(raw).hexdigest() == asset["sha256"], "mesh integrity mismatch")
    for i, edge in enumerate(edges):
        path = f"edges[{i}]"
        object_value(edge, path)
        start = uuid_value(edge.get("from"), path + ".from")
        end = uuid_value(edge.get("to"), path + ".to")
        require(start in positions and end in positions and start != end,
                path + ": missing node or self-loop")
        require(edge.get("hazard") in (None, "stairs", "narrow", "doorThreshold"),
                path + ": unknown hazard")
        distance = float32(edge.get("distance"), path + ".distance")
        # Float arithmetic, including intermediate subtraction and squared length.
        delta = [float32(a - b, path) for a, b in zip(positions[start], positions[end])]
        squares = [float32(v * v, path) for v in delta]
        straight = float32(math.sqrt(float32(float32(squares[0] + squares[1], path)
                                             + squares[2], path)), path)
        tolerance = max(0.5, float32(straight * 0.25, path))
        require(abs(float32(distance - straight, path)) <= tolerance,
                path + ": distance does not match node positions")
    marker = data.get("marker")
    if marker is not None:
        object_value(marker, "marker")
        string(marker.get("name"), "marker.name")
        position(marker.get("position"), "marker.position")
        float32(marker.get("widthMeters"), "marker.widthMeters")
        float32(marker.get("yaw"), "marker.yaw")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", help="map/bundle files or quoted glob patterns")
    args = parser.parse_args(argv)
    patterns = args.paths or [str(Path(__file__).resolve().parents[1] / "Samples" / "*.json")]
    failed = False
    for pattern in patterns:
        matches = sorted(glob.glob(pattern))
        if not matches:
            print(f"FAIL {pattern}: no files matched")
            failed = True
        for filename in matches:
            try:
                with open(filename, encoding="utf-8-sig") as source:
                    document = json.load(source)
                # With no arguments the whole Samples/ folder is checked, and it also holds non-map data (e.g. route-vectors.json
                # test vectors added by the web viewer). Skip those there; a file named on the command line is always validated.
                if not args.paths and isinstance(document, dict) and "nodes" not in document and "map" not in document:
                    print(f"SKIP {filename}: not a map (no nodes)")
                    continue
                validate(document)
                print(f"PASS {filename}")
            except (OSError, ValueError, RecursionError) as error:
                print(f"FAIL {filename}: {error}")
                failed = True
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
