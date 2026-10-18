// Owner: U3 (web). Fast path for real LiDAR OBJ scans: typed arrays instead of one JS array per vertex and triangle.
// A 26 MB floor (347k vertices, 677k triangles) used to take ~265 MB of JS heap and a few seconds of main-thread work;
// here positions/indices are two flat typed arrays and the GPU buffer is filled in a single pass.
// Validation matches geometry3d.js `parseOBJ` + `verifyMesh` (triangles only, finite numbers, distinct in-range indices,
// size/SHA-256/bounds from the manifest); `tests` in geometry-tests.js check both parsers agree.

export const MAX_VERTICES = 500000, MAX_TRIANGLES = 1000000;

/** Parse OBJ text into {positions: Float32Array(3n), indices: Uint32Array(3m), vertexCount, triangleCount}.
 *  `bounds` ({boundsMin, boundsMax}, optional) is checked per vertex with the same tolerance as `verifyMesh`. */
export function parseOBJFast(text, bounds = null) {
  let positions = new Float32Array(3 * 1024), indices = new Uint32Array(3 * 1024);
  let vertexCount = 0, triangleCount = 0;
  const length = text.length;
  const tolerance = (value) => Math.max(0.00001, Math.abs(value) * 0.000001);
  const starts = [0, 0, 0, 0], stops = [0, 0, 0, 0], face = [0, 0, 0];
  let position = 0;
  while (position < length) {
    let end = text.indexOf("\n", position);
    if (end === -1) end = length;
    // Only lines starting with "v " or "f " matter; vn/vt/comments/groups are skipped without allocating.
    while (position < end && text.charCodeAt(position) <= 32) position++;
    const c0 = text.charCodeAt(position), c1 = text.charCodeAt(position + 1);
    if ((c0 === 118 || c0 === 102) && (c1 === 32 || c1 === 9)) {
      // Tokenise in place (no split/trim/regex per line: that was the main cost on a 1M-line file).
      let count = 0, i = position + 1;
      while (i < end && count < 4) {
        while (i < end && (text.charCodeAt(i) <= 32)) i++;
        if (i >= end) break;
        const start = i;
        while (i < end && text.charCodeAt(i) > 32) i++;
        starts[count] = start; stops[count] = i; count++;
      }
      if (c0 === 118) {
        if (count !== 3) throw new Error("OBJ vertices need XYZ coordinates.");
        if (vertexCount >= MAX_VERTICES) throw new Error("Invalid or oversized OBJ.");
        if (vertexCount * 3 + 3 > positions.length) { const grown = new Float32Array(positions.length * 2); grown.set(positions); positions = grown; }
        for (let k = 0; k < 3; k++) {
          const value = Number(text.substring(starts[k], stops[k]));
          if (!Number.isFinite(value) || !Number.isFinite(Math.fround(value))) throw new Error("Invalid or oversized OBJ.");
          if (bounds && (value < bounds.boundsMin[k] - tolerance(value) || value > bounds.boundsMax[k] + tolerance(value))) {
            throw new Error("Mesh geometry falls outside its declared bounds.");
          }
          positions[vertexCount * 3 + k] = value;
        }
        vertexCount++;
      } else {
        if (count !== 3 || triangleCount >= MAX_TRIANGLES) throw new Error("Only triangular OBJ meshes are supported.");
        if (triangleCount * 3 + 3 > indices.length) { const grown = new Uint32Array(indices.length * 2); grown.set(indices); indices = grown; }
        for (let k = 0; k < 3; k++) {
          let stop = starts[k]; // "12", "12/3" or "12//4": the vertex index is what precedes the first "/" (a bounded scan; indexOf would run to the end of the file)
          while (stop < stops[k] && text.charCodeAt(stop) !== 47) stop++;
          const index = Number(text.substring(starts[k], stop)) - 1;
          if (!Number.isInteger(index) || index < 0 || index >= MAX_VERTICES) throw new Error("Invalid OBJ triangle.");
          face[k] = index;
        }
        if (face[0] === face[1] || face[0] === face[2] || face[1] === face[2]) throw new Error("Invalid OBJ triangle.");
        indices[triangleCount * 3] = face[0]; indices[triangleCount * 3 + 1] = face[1]; indices[triangleCount * 3 + 2] = face[2];
        triangleCount++;
      }
    }
    position = end + 1;
  }
  if (!vertexCount || !triangleCount) throw new Error("OBJ has missing geometry or invalid indices.");
  for (let i = 0; i < triangleCount * 3; i++) if (indices[i] >= vertexCount) throw new Error("OBJ has missing geometry or invalid indices.");
  return { positions: positions.slice(0, vertexCount * 3), indices: indices.slice(0, triangleCount * 3), vertexCount, triangleCount };
}

const hex = (buffer) => [...new Uint8Array(buffer)].map((b) => b.toString(16).padStart(2, "0")).join("");

/** Size, SHA-256, strict UTF-8, then parse + bounds. Same errors as `verifyMesh`, typed-array result. */
export async function verifyMeshFast(asset, bytes) {
  if (bytes.byteLength !== asset.byteCount) throw new Error("Mesh size does not match its manifest.");
  if (hex(await crypto.subtle.digest("SHA-256", bytes)) !== asset.sha256) throw new Error("Mesh checksum does not match its manifest.");
  const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  return parseOBJFast(text, asset);
}

/** Interleaved GPU data: per vertex position(3) normal(3) colour(3), flat-shaded, one pass, no temporary arrays. */
export function surfaceBuffer(mesh, color = [0.79, 0.82, 0.78]) {
  const { positions, indices, triangleCount } = mesh, data = new Float32Array(triangleCount * 27);
  let out = 0;
  for (let t = 0; t < triangleCount; t++) {
    const a = indices[t * 3] * 3, b = indices[t * 3 + 1] * 3, c = indices[t * 3 + 2] * 3;
    const ux = positions[b] - positions[a], uy = positions[b + 1] - positions[a + 1], uz = positions[b + 2] - positions[a + 2];
    const vx = positions[c] - positions[a], vy = positions[c + 1] - positions[a + 1], vz = positions[c + 2] - positions[a + 2];
    let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
    const norm = Math.hypot(nx, ny, nz) || 1; nx /= norm; ny /= norm; nz /= norm;
    for (const p of [a, b, c]) {
      data[out++] = positions[p]; data[out++] = positions[p + 1]; data[out++] = positions[p + 2];
      data[out++] = nx; data[out++] = ny; data[out++] = nz;
      data[out++] = color[0]; data[out++] = color[1]; data[out++] = color[2];
    }
  }
  return data;
}

/** Tab-lifetime cache of VERIFIED meshes keyed by their SHA-256 (content-addressed, so never stale).
 *  Memory only on purpose: scans are not written to disk on the viewing machine. */
export class MeshCache {
  constructor(limit = 3) { this.limit = limit; this.items = new Map(); }
  get(sha256) {
    if (!this.items.has(sha256)) return null;
    const mesh = this.items.get(sha256); this.items.delete(sha256); this.items.set(sha256, mesh); return mesh;
  }
  put(sha256, mesh) {
    this.items.delete(sha256); this.items.set(sha256, mesh);
    while (this.items.size > this.limit) this.items.delete(this.items.keys().next().value);
  }
}

export const formatMegabytes = (bytes) => `${(bytes / 1048576).toFixed(1)} MB`;
