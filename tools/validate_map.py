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
CURRENT_SCHEMA = 3
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
    schema = data.get("schemaVersion", 1)
    if schema is None:
        schema = 1
    require(type(schema) is int and 1 <= schema <= CURRENT_SCHEMA, "unsupported schemaVersion; update Waypoint")
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
        extent = node.get("extent")
        if extent is not None:
            object_value(extent, path + ".extent")
            require(node["kind"] == "room", "extent belongs to a room")
            position(extent.get("center"), "extent.center")
            half = extent.get("halfExtents")
            require(isinstance(half, list) and len(half) == 2, "extent.halfExtents: expected two numbers")
            half = [float32(v, "extent.halfExtents") for v in half]
            require(all(v > 0 for v in half), "extent dimensions must be positive")
            float32(extent.get("yaw"), "extent.yaw")
            area = float32(extent.get("areaSquareMeters"), "extent.areaSquareMeters")
            require(0 < area <= 4 * half[0] * half[1] + 0.01, "invalid enclosed area")
            if extent.get("heightMeters") is not None:
                require(float32(extent["heightMeters"], "extent.heightMeters") > 0, "height must be positive")
    assets = data.get("meshAssets")
    if assets is None:
        assets = []
    require(isinstance(assets, list) and len(assets) <= 100, "invalid meshAssets")
    asset_ids = {}
    segments = {n["segmentId"] for n in nodes}
    total_bytes = 0
    for asset in assets:
        object_value(asset, "mesh asset")
        asset_id = uuid_value(asset.get("id"), "asset.id")
        require(asset_id not in asset_ids, "duplicate mesh asset")
        asset_ids[asset_id] = asset
        require(asset.get("segmentId") in segments, "asset segment is missing")
        require(asset.get("format") == "obj" and asset.get("coordinateFrame") == "map", "unsupported mesh format/frame")
        count = asset.get("byteCount")
        require(type(count) is int and 1 <= count <= 40_000_000, "mesh byteCount outside 1..40000000")
        total_bytes += count
        digest = asset.get("sha256")
        require(isinstance(digest, str) and re.fullmatch(r"[a-f0-9]{64}", digest), "invalid mesh checksum")
        lo = position(asset.get("boundsMin"), "boundsMin")
        hi = position(asset.get("boundsMax"), "boundsMax")
        require(all(a <= b for a, b in zip(lo, hi)), "inverted mesh bounds")
        if asset.get("storageOwner") is not None:
            uuid_value(asset["storageOwner"], "storageOwner")
    require(total_bytes <= 80_000_000, "mesh assets exceed 80 MB total")
    if "map" in document and document.get("meshFiles") is not None:
        for asset_key, payload in object_value(document["meshFiles"], "meshFiles").items():
            asset = asset_ids.get(uuid_value(asset_key, "meshFiles key"))
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
        if not args.paths:
            # Shared routing fixtures are test vectors, not a BuildingMap document.
            matches = [name for name in matches if Path(name).name != "route-vectors.json"]
        if not matches:
            print(f"FAIL {pattern}: no files matched")
            failed = True
        for filename in matches:
            try:
                with open(filename, encoding="utf-8-sig") as source:
                    validate(json.load(source))
                print(f"PASS {filename}")
            except (OSError, ValueError, RecursionError) as error:
                print(f"FAIL {filename}: {error}")
                failed = True
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
