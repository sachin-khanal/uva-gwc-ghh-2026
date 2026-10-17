// Owner: U3. Software 3D projection and bounded OBJ parsing; no dependency or inferred walls.
export const DEFAULT_CAMERA = { yaw: -0.55, pitch: 0.65 };

export function projection(points, width, height, zoom = 1, yaw = DEFAULT_CAMERA.yaw, pitch = DEFAULT_CAMERA.pitch) {
  const low = [Infinity,Infinity,Infinity], high = [-Infinity,-Infinity,-Infinity];
  for (const p of points) for (let i=0;i<3;i++) { low[i] = Math.min(low[i],p[i]); high[i] = Math.max(high[i],p[i]); }
  const center = low.map((v, i) => (v + high[i]) / 2);
  const radius = Math.max(2, Math.hypot(...high.map((v, i) => v - low[i])) / 2);
  const focal = Math.max(40, Math.min(width - 100, height - 100)) * 2 * zoom;
  const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch);
  const project = (p) => {
    const [x,y,z] = p.map((v, i) => v - center[i]);
    const rx = cy*x + sy*z, rz = -sy*x + cy*z;
    const vertical = cp*y - sp*rz, depth = sp*y + cp*rz;
    const scale = focal / Math.max(radius * 0.15, radius * 3 - depth);
    return { x: width/2 + rx*scale, y: height/2 - vertical*scale, depth };
  };
  return { project, low, high, center, radius };
}

export function projectionForMap(map, width, height, zoom = 1, yaw = DEFAULT_CAMERA.yaw, pitch = DEFAULT_CAMERA.pitch) {
  const points = map.nodes.map((n) => n.position);
  for (const n of map.nodes) if (n.extent) {
    const floor = roomCorners(n.extent); points.push(...floor);
    if (n.extent.heightMeters) points.push(...floor.map(([x,y,z]) => [x,y+n.extent.heightMeters,z]));
  }
  for (const a of map.meshAssets ?? []) points.push(a.boundsMin,a.boundsMax);
  return projection(points.length ? points : [[0,0,0]],width,height,zoom,yaw,pitch);
}

export function roomCorners(extent) {
  const [a,b] = extent.halfExtents, c = Math.cos(extent.yaw), s = Math.sin(extent.yaw);
  return [[-a,-b],[a,-b],[a,b],[-a,b]].map(([x,z]) =>
    [extent.center[0]+c*x+s*z, extent.center[1], extent.center[2]-s*x+c*z]);
}

export function parseOBJ(text) {
  const vertices = [], triangles = [];
  for (const raw of text.split(/\r?\n/)) {
    const fields = raw.trim().split(/\s+/), type = fields.shift();
    if (type === "v") {
      if (fields.length !== 3) throw new Error("OBJ vertices need XYZ coordinates.");
      const v = fields.map(Number);
      if (!v.every(Number.isFinite) || vertices.length >= 500000) throw new Error("Invalid or oversized OBJ.");
      vertices.push(v);
    } else if (type === "f") {
      if (fields.length !== 3 || triangles.length >= 1000000) throw new Error("Only triangular OBJ meshes are supported.");
      const face = fields.map((token) => Number(token.split("/")[0]) - 1);
      if (!face.every((i) => Number.isInteger(i) && i >= 0) || new Set(face).size !== 3) throw new Error("Invalid OBJ triangle.");
      triangles.push(face);
    }
  }
  if (!vertices.length || !triangles.length || triangles.some((t) => t.some((i) => i >= vertices.length))) throw new Error("OBJ has missing geometry or invalid indices.");
  return { vertices, triangles };
}

export async function verifyMesh(asset, bytes) {
  if (bytes.byteLength !== asset.byteCount) throw new Error("Mesh size does not match its manifest.");
  const digest = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((b) => b.toString(16).padStart(2,"0")).join("");
  if (digest !== asset.sha256) throw new Error("Mesh checksum does not match its manifest.");
  const mesh = parseOBJ(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  // OBJEncoder writes Float values; tolerate the roundtrip at a scale-relative precision.
  for (const v of mesh.vertices) for (let i=0;i<3;i++) {
    const tolerance = Math.max(0.00001, Math.abs(v[i]) * 0.000001);
    if (v[i] < asset.boundsMin[i] - tolerance || v[i] > asset.boundsMax[i] + tolerance) throw new Error("Mesh geometry falls outside its declared bounds.");
  }
  return mesh;
}
