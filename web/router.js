// Owner: U3. Pure A* port of WaypointCore/Router.swift; map-frame meters.
// Stairs add 1000 to cost when not allowed; they remain a fallback, not forbidden.
// Math.fround approximates Swift Float arithmetic. Equal-cost ties are unspecified.
const f = Math.fround;
export const key = (id) => String(id).toLowerCase();
export const distance = (a, b) => {
  const d = a.map((v, i) => f(f(v) - f(b[i])));
  return f(Math.sqrt(f(f(f(d[0] * d[0]) + f(d[1] * d[1])) + f(d[2] * d[2]))));
};

export function route(map, start, goal, allowStairs = false) {
  start = key(start); goal = key(goal);
  const nodes = new Map(map.nodes.map((n) => [key(n.id), n]));
  if (!nodes.has(start) || !nodes.has(goal)) return null;
  if (start === goal) return [nodes.get(start)];
  const adj = new Map([...nodes.keys()].map((id) => [id, []]));
  for (const e of map.edges) {
    const a = key(e.from), b = key(e.to);
    if (!nodes.has(a) || !nodes.has(b)) continue;
    adj.get(a).push([b, e]); adj.get(b).push([a, e]);
  }
  const g = new Map([[start, 0]]), scores = new Map([[start, distance(nodes.get(start).position, nodes.get(goal).position)]]);
  const previous = new Map(), open = new Set([start]), closed = new Set();
  while (open.size) {
    let current = null;
    for (const id of open) if (current === null || scores.get(id) < scores.get(current)) current = id;
    if (current === goal) {
      const path = [current];
      while (previous.has(current)) { current = previous.get(current); path.push(current); }
      return path.reverse().map((id) => nodes.get(id));
    }
    open.delete(current); closed.add(current);
    for (const [next, e] of adj.get(current)) {
      if (closed.has(next)) continue;
      const cost = f(f(e.distance) + (e.hazard === "stairs" && !allowStairs ? 1000 : 0));
      const tentative = f(g.get(current) + cost);
      if (tentative < (g.get(next) ?? Infinity)) {
        previous.set(next, current); g.set(next, tentative);
        scores.set(next, f(tentative + distance(nodes.get(next).position, nodes.get(goal).position)));
        open.add(next);
      }
    }
  }
  return null;
}

export function routeSummary(map, path) {
  const edges = [];
  for (let i = 1; i < path.length; i++) {
    const a = key(path[i - 1].id), b = key(path[i].id);
    edges.push(map.edges.find((e) => (key(e.from) === a && key(e.to) === b) || (key(e.from) === b && key(e.to) === a)));
  }
  return { meters: edges.reduce((sum, e) => sum + e.distance, 0),
    stairs: edges.some((e) => e.hazard === "stairs"), hazards: edges.map((e) => e.hazard).filter(Boolean) };
}

export function validateMap(input) {
  const map = input?.map ?? input;
  const fail = (message) => { throw new Error(`Invalid map: ${message}`); };
  const uuid = (v) => typeof v === "string" && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(v);
  if (!map || !uuid(map.id) || typeof map.name !== "string" || !Number.isSafeInteger(map.version)
      || !Array.isArray(map.nodes) || !Array.isArray(map.edges)) fail("missing map fields.");
  const schema = map.schemaVersion ?? 1;
  if (!Number.isInteger(schema) || schema < 1 || schema > 3) fail("unsupported schemaVersion; update the viewer.");
  const finite = (v) => typeof v === "number" && Number.isFinite(f(v));
  const vector = (v, count) => Array.isArray(v) && v.length === count && v.every(finite);
  if (map.nodes.length > 5000 || map.edges.length > 20000) fail("too many nodes or connections.");
  const positions = new Map();
  for (const n of map.nodes) {
    if (!n || !uuid(n.id) || positions.has(key(n.id))) fail("missing or duplicate node ID.");
    if (!["corridor", "door", "stairs", "elevator", "room", "junction"].includes(n.kind)) fail("unknown place type.");
    if (typeof n.segmentId !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(n.segmentId)) fail("unsafe scan segment.");
    if (typeof n.createdBy !== "string" || (n.label != null && typeof n.label !== "string")) fail("invalid place label.");
    if (!Array.isArray(n.position) || n.position.length !== 3 || !n.position.every((v) => typeof v === "number" && Number.isFinite(f(v)))) fail("invalid coordinates.");
    positions.set(key(n.id), n.position);
    if (n.extent != null) {
      const e = n.extent;
      if (n.kind !== "room" || !vector(e.center, 3) || !vector(e.halfExtents, 2)
          || !e.halfExtents.every((v) => v > 0) || !finite(e.yaw) || !finite(e.areaSquareMeters)
          || e.areaSquareMeters <= 0 || e.areaSquareMeters > 4 * e.halfExtents[0] * e.halfExtents[1] + 0.01
          || (e.heightMeters != null && (!finite(e.heightMeters) || e.heightMeters <= 0))) fail("invalid room extent.");
    }
  }
  const assets = map.meshAssets ?? [];
  if (!Array.isArray(assets) || assets.length > 100) fail("invalid mesh manifest.");
  const assetsSeen = new Set(), segments = new Set(map.nodes.map((n) => n.segmentId));
  let totalBytes = 0;
  for (const a of assets) {
    if (!a || !uuid(a.id) || assetsSeen.has(key(a.id)) || !segments.has(a.segmentId)
        || a.format !== "obj" || a.coordinateFrame !== "map"
        || !Number.isInteger(a.byteCount) || a.byteCount < 1 || a.byteCount > 40000000
        || typeof a.sha256 !== "string" || !/^[a-f0-9]{64}$/.test(a.sha256)
        || !vector(a.boundsMin, 3) || !vector(a.boundsMax, 3)
        || a.boundsMin.some((v, i) => v > a.boundsMax[i]) || (a.storageOwner != null && !uuid(a.storageOwner))) fail("invalid mesh asset.");
    assetsSeen.add(key(a.id)); totalBytes += a.byteCount;
  }
  if (totalBytes > 80000000) fail("mesh assets exceed 80 MB total.");
  for (const e of map.edges) {
    if (!e || !uuid(e.from) || !uuid(e.to) || key(e.from) === key(e.to)
        || !positions.has(key(e.from)) || !positions.has(key(e.to))) fail("a connection has no valid endpoints.");
    if (e.hazard != null && !["stairs", "narrow", "doorThreshold"].includes(e.hazard)) fail("unknown hazard.");
    const straight = distance(positions.get(key(e.from)), positions.get(key(e.to)));
    if (typeof e.distance !== "number" || !Number.isFinite(f(e.distance)) || !Number.isFinite(straight)
        || Math.abs(f(f(e.distance) - straight)) > Math.max(0.5, f(straight * 0.25))) fail("connection distance disagrees with coordinates.");
  }
  return map;
}
