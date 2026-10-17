# U3 development tools

Requires Python 3.10+; no packages to install. From the repository root on Windows:

```powershell
python tools/validate_map.py
python tools/validate_map.py "Samples/*.json"
python tools/validate_map.py path/to/export.waypointmap
python -B -m unittest discover -s tools -p "test_*.py" -v
```

The default checks every `Samples/*.json` file. Explicit paths and quoted glob
patterns are supported. Each file prints PASS or FAIL with a reason; exit status
is 0 only when every file passes, otherwise 1 (including unmatched patterns).
On a Mac use `python3` instead of `python` if necessary.

The validator independently checks the current Swift map decoding fields,
`SegmentID` alphabet, and `MapBundle.validate()` limits, references, unique UUIDs,
finite coordinates, and edge distance tolerance (max of 0.5 m or 25%). Bundles
also require valid base64 world maps with safe keys and at most 50 MB per entry.
Unknown extra fields are allowed, as with Swift Codable. Float calculations
approximate Swift SIMD arithmetic; values at rounding boundaries may differ.
Marker numeric fields must be finite (a deliberate stricter check than the
current bundle validator). No new constraints on positive versions, positive
edge distances, connectivity, or unique edges are invented here.

This is a developer check, not proof that a map matches a real building or that
a route is safe. It does not implement the store's existing-map merge checks.
CI wiring (INF-2) is a separate task; this change does not add a workflow.
