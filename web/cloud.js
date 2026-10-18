// Owner: U3. Supabase REST, matching the native client and canonical migration 0002.
// Configuration and tokens are memory-only; no cookies, disk or browser storage.
export class CloudLibrary {
  constructor(url, anonKey, fetcher = globalThis.fetch.bind(globalThis)) {
    const parsed = new URL(url);
    if (parsed.protocol !== "https:" || parsed.username || parsed.password || parsed.search || parsed.hash) throw new Error("Use an HTTPS project URL.");
    if (!["", "/", "/rest/v1", "/rest/v1/"].includes(parsed.pathname)) throw new Error("Use the project URL, without API paths.");
    this.url = parsed.origin; this.anonKey = anonKey.trim(); this.fetcher = fetcher;
    if (!this.anonKey || this.anonKey.startsWith("sb_secret_")) throw new Error("Enter the anon public key, not a secret key.");
    // Legacy keys are JWTs: detect an accidentally pasted service_role key locally.
    if (this.anonKey.split(".").length === 3) {
      try {
        const payload = JSON.parse(atob(this.anonKey.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
        if (payload.role === "service_role") throw new Error("SERVICE_ROLE");
      } catch (error) { if (error.message === "SERVICE_ROLE") throw new Error("Use the anon public key, never service_role."); }
    }
    this.session = null;
  }

  async request(path, options = {}, token = null, binary = false) {
    let response;
    try {
      response = await this.fetcher(this.url + path, {
        ...options, headers: { apikey: this.anonKey, "Content-Type": "application/json",
          ...(token ? { Authorization: `Bearer ${token}` } : {}) },
        signal: AbortSignal.timeout(20000),
      });
    } catch { throw new Error("Cannot reach Supabase. Check your connection and project URL."); }
    if (!response.ok) {
      const error = new Error(response.status === 429 ? "Too many sign-ins. Wait before reconnecting."
        : response.status === 401 || response.status === 403 ? "Access denied. Check the anon key and anonymous sign-ins."
        : response.status === 404 ? (binary ? "The referenced 3D scan file is missing." : "Cloud library not found. Check that migration 0002 is applied.")
        : `Supabase returned ${response.status}. Check that the project is available.`);
      error.status = response.status; throw error;
    }
    return binary ? response.arrayBuffer() : response.json();
  }

  /** Download one scan file. `onProgress(received, total)` is called as bytes arrive. The 20 s limit is per STALL (no bytes),
   *  not for the whole transfer, so a 26 MB scan on slow Wi-Fi is not cut off. The size is capped at the manifest's byteCount. */
  async mesh(map, asset, { onProgress } = {}) {
    if (!asset.storageOwner) throw new Error("This mesh has not been published.");
    const path = `/storage/v1/object/authenticated/meshes/${asset.storageOwner.toLowerCase()}/${map.id.toLowerCase()}/${asset.id.toLowerCase()}.obj`;
    const session = await this.ensureSession();
    try { return await this.download(path, session.access_token, asset.byteCount, onProgress); }
    catch (error) {
      if (error.status !== 401) throw error;
      this.session.until = 0;
      return this.download(path, (await this.ensureSession()).access_token, asset.byteCount, onProgress);
    }
  }

  async download(path, token, expected, onProgress, stallMs = 20000) {
    const controller = new AbortController();
    let timer; const arm = () => { clearTimeout(timer); timer = setTimeout(() => controller.abort(), stallMs); };
    arm();
    try {
      let response;
      try {
        response = await this.fetcher(this.url + path, { headers: { apikey: this.anonKey, Authorization: `Bearer ${token}` }, signal: controller.signal });
      } catch { throw new Error("Cannot reach Supabase. Check your connection and project URL."); }
      if (!response.ok) {
        const error = new Error(response.status === 401 || response.status === 403 ? "Access denied. Check the anon key and anonymous sign-ins."
          : response.status === 404 ? "The referenced 3D scan file is missing." : `Supabase returned ${response.status}. Check that the project is available.`);
        error.status = response.status; throw error;
      }
      const reader = response.body?.getReader?.();
      if (!reader) {
        const whole = await response.arrayBuffer();
        if (Number.isFinite(expected) && whole.byteLength !== expected) throw new Error("Mesh size does not match its manifest.");
        onProgress?.(whole.byteLength, whole.byteLength); return whole;
      }
      const limit = Number.isFinite(expected) && expected > 0 ? expected : Infinity;
      let buffer = new Uint8Array(Number.isFinite(limit) ? limit : 1 << 20), received = 0;
      for (;;) {
        let chunk;
        try { chunk = await reader.read(); } catch { throw new Error("The 3D scan download stalled. Check your connection and try again."); }
        if (chunk.done) break;
        arm();
        if (received + chunk.value.byteLength > limit) { controller.abort(); throw new Error("Mesh size does not match its manifest."); }
        if (received + chunk.value.byteLength > buffer.length) { const grown = new Uint8Array(Math.max(buffer.length * 2, received + chunk.value.byteLength)); grown.set(buffer.subarray(0, received)); buffer = grown; }
        buffer.set(chunk.value, received); received += chunk.value.byteLength;
        onProgress?.(received, Number.isFinite(limit) ? limit : 0);
      }
      if (Number.isFinite(expected) && received !== expected) throw new Error("Mesh size does not match its manifest.");
      return buffer.buffer.byteLength === received ? buffer.buffer : buffer.buffer.slice(0, received);
    } finally { clearTimeout(timer); }
  }

  async ensureSession() {
    if (this.session && this.session.until > Date.now() + 60000) return this.session;
    let auth;
    if (this.session?.refresh_token) {
      try { auth = await this.request("/auth/v1/token?grant_type=refresh_token", {
        method: "POST", body: JSON.stringify({ refresh_token: this.session.refresh_token }),
      }); } catch (error) { if (![400, 401, 403].includes(error.status)) throw error; }
    }
    if (!auth) auth = await this.request("/auth/v1/signup", { method: "POST", body: "{}" });
    if (!auth.access_token || !auth.refresh_token || !Number.isFinite(auth.expires_in)) throw new Error("Unexpected sign-in response.");
    this.session = { ...auth, until: Date.now() + auth.expires_in * 1000 };
    return this.session;
  }

  async list(retry = true) {
    const session = await this.ensureSession();
    try {
      const rows = await this.request("/rest/v1/canonical_buildings?select=map_id,name,version,map_json,updated_at&order=updated_at.desc", {}, session.access_token);
      if (!Array.isArray(rows)) throw new Error("Unexpected library response.");
      return rows;
    } catch (error) {
      if (error.status === 401 && retry) {
        // Refresh the same anonymous identity, rather than spawning a user for each request.
        this.session.until = 0;
        return this.list(false);
      }
      throw error;
    }
  }
}
