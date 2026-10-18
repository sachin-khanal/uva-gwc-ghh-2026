// Owner: U3. API contract checks with injected fetch, without a live project.
import { CloudLibrary } from "./cloud.js";

export async function runCloudChecks() {
  const results = [];
  const assert = (value, message = "Assertion failed") => { if (!value) throw new Error(message); };
  const session = { access_token: "test-token", refresh_token: "test-refresh", expires_in: 3600 };
  const response = (data, status = 200) => ({ ok: status >= 200 && status < 300, status, json: async () => data });
  async function check(name, operation) {
    try { await operation(); results.push({ name, pass: true }); }
    catch (error) { results.push({ name, pass: false, error: error.message }); }
  }
  await check("Canonical library request, JWT and session reuse", async () => {
    const calls = [];
    const library = new CloudLibrary("https://example.supabase.co/rest/v1/", "ANON", async (url, options) => {
      calls.push([url, options]); return response(url.includes("/auth/") ? session : []);
    });
    await library.list(); await library.list();
    assert(calls.length === 3);
    assert(calls[0][0].endsWith("/auth/v1/signup") && calls[0][1].method === "POST");
    assert(calls[1][0].includes("/rest/v1/canonical_buildings?select="));
    assert(calls[1][1].headers.Authorization === "Bearer test-token");
    assert(calls[1][1].headers.apikey === "ANON");
  });
  await check("401 refreshes existing identity once", async () => {
    const calls = []; let reads = 0;
    const library = new CloudLibrary("https://example.supabase.co", "ANON", async (url) => {
      calls.push(url);
      if (url.includes("/auth/")) return response(session);
      return response([], ++reads === 1 ? 401 : 200);
    });
    await library.list();
    assert(calls.filter((url) => url.endsWith("signup")).length === 1);
    assert(calls.some((url) => url.includes("grant_type=refresh_token")));
  });
  await check("Persistent 401 terminates without infinite retries", async () => {
    let reads = 0, rejected = false;
    const library = new CloudLibrary("https://example.supabase.co", "ANON", async (url) => {
      if (url.includes("/auth/")) return response(session);
      reads++; return response([], 401);
    });
    try { await library.list(); } catch { rejected = true; }
    assert(rejected && reads === 2);
  });
  await check("Rate-limit error is readable", async () => {
    const library = new CloudLibrary("https://example.supabase.co", "ANON", async () => response({}, 429));
    let message = ""; try { await library.list(); } catch (error) { message = error.message; }
    assert(message.includes("Wait"));
  });
  await check("Malformed response rejected", async () => {
    const library = new CloudLibrary("https://example.supabase.co", "ANON", async (url) => response(url.includes("/auth/") ? session : {}));
    let rejected = false; try { await library.list(); } catch { rejected = true; }
    assert(rejected);
  });
  await check("Mesh download uses contributor folder and authenticated binary response", async () => {
    const calls = [], bytes = new Uint8Array([1,2,3]).buffer;
    const library = new CloudLibrary("https://example.supabase.co","ANON",async(url,options)=>{
      calls.push([url,options]);
      return url.includes("/auth/") ? response(session) : {ok:true,status:200,arrayBuffer:async()=>bytes};
    });
    const map={id:"AAAAAAAA-0000-4000-8000-000000000001"};
    const asset={id:"BBBBBBBB-0000-4000-8000-000000000002",storageOwner:"CCCCCCCC-0000-4000-8000-000000000003"};
    assert(await library.mesh(map,asset) === bytes);
    assert(calls[1][0].endsWith("/cccccccc-0000-4000-8000-000000000003/aaaaaaaa-0000-4000-8000-000000000001/bbbbbbbb-0000-4000-8000-000000000002.obj"));
    assert(calls[1][1].headers.Authorization === "Bearer test-token");
  });
  const streamResponse = (chunks, { status = 200, failAfter = null } = {}) => ({ ok: status < 300, status,
    body: { getReader: () => { let i = 0; return { read: async () => {
      if (failAfter !== null && i >= failAfter) throw new Error("aborted");
      return i < chunks.length ? { done: false, value: chunks[i++] } : { done: true }; } }; } } });
  const meshLibrary = (reply) => new CloudLibrary("https://example.supabase.co", "ANON", async (url) => url.includes("/auth/") ? response(session) : reply(url));
  const meshMap = { id: "AAAAAAAA-0000-4000-8000-000000000001" };
  const meshAsset = (byteCount) => ({ id: "BBBBBBBB-0000-4000-8000-000000000002", storageOwner: "CCCCCCCC-0000-4000-8000-000000000003", byteCount });
  await check("Mesh download streams with progress and returns exactly the bytes sent", async () => {
    const chunks = [new Uint8Array([1, 2, 3]), new Uint8Array([4, 5]), new Uint8Array([6])], seen = [];
    const buffer = await meshLibrary(() => streamResponse(chunks)).mesh(meshMap, meshAsset(6), { onProgress: (a, b) => seen.push([a, b]) });
    assert(buffer.byteLength === 6 && [...new Uint8Array(buffer)].join() === "1,2,3,4,5,6");
    assert(JSON.stringify(seen) === "[[3,6],[5,6],[6,6]]");
  });
  await check("Mesh download without a manifest size grows its buffer and still returns exact bytes", async () => {
    const big = new Uint8Array(3 << 20).map((_, i) => i % 251);
    const buffer = await meshLibrary(() => streamResponse([big.subarray(0, 1 << 21), big.subarray(1 << 21)])).mesh(meshMap, meshAsset(undefined));
    assert(buffer.byteLength === big.byteLength && new Uint8Array(buffer)[3000000] === big[3000000]);
  });
  await check("Mesh download larger than its manifest is refused", async () => {
    let message = ""; try { await meshLibrary(() => streamResponse([new Uint8Array(10)])).mesh(meshMap, meshAsset(4)); } catch (error) { message = error.message; }
    assert(message.includes("manifest"), message);
  });
  await check("Truncated and non-streaming mismatched downloads are refused",async()=>{
    for(const reply of [streamResponse([new Uint8Array(2)]),{ok:true,status:200,arrayBuffer:async()=>new ArrayBuffer(2)}]){
      let rejected=false;try{await meshLibrary(()=>reply).mesh(meshMap,meshAsset(4));}catch(error){rejected=error.message.includes("manifest");}assert(rejected);
    }
  });
  await check("Mesh download that stalls reports a clear error", async () => {
    let message = ""; try { await meshLibrary(() => streamResponse([new Uint8Array(2)], { failAfter: 1 })).mesh(meshMap, meshAsset(8)); } catch (error) { message = error.message; }
    assert(message.includes("stalled"), message);
  });
  await check("Mesh download maps 404 to a missing-file message", async () => {
    let message = ""; try { await meshLibrary(() => ({ ok: false, status: 404 })).mesh(meshMap, meshAsset(1)); } catch (error) { message = error.message; }
    assert(message.includes("missing"), message);
  });
  await check("Slow downloads are not cut off by a total timeout (only by a stall)", async () => {
    const library = meshLibrary(() => streamResponse([new Uint8Array(1), new Uint8Array(1)]));
    const slowReader = async (url) => ({ ok: true, status: 200, body: { getReader: () => { let i = 0; return { read: async () => { await new Promise((r) => setTimeout(r, 30)); return i++ < 3 ? { done: false, value: new Uint8Array(1) } : { done: true }; } }; } } });
    library.fetcher = async (url, options) => url.includes("/auth/") ? response(session) : slowReader(url, options);
    const buffer = await library.download("/x", "token", 3, null, 100); // 90 ms in total > 100 ms stall limit would not trip: each chunk arrives within it
    assert(buffer.byteLength === 3);
  });
  await check("Service-role and secret keys rejected", () => {
    for (const secret of ["sb_secret_do-not-use", `x.${btoa(JSON.stringify({ role: "service_role" }))}.x`]) {
      let rejected = false; try { new CloudLibrary("https://example.supabase.co", secret); } catch { rejected = true; }
      assert(rejected);
    }
  });
  await check("HTTP and arbitrary API paths rejected", () => {
    for (const url of ["http://example.com", "https://example.com/other", "https://user:pass@example.com"]) {
      let rejected = false; try { new CloudLibrary(url, "ANON"); } catch { rejected = true; }
      assert(rejected);
    }
  });
  return results;
}
