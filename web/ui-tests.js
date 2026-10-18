// Owner: U3. Real DOM interactions in an isolated same-origin iframe; cloud is mocked.
import { projectionForMap } from "./geometry3d.js";
const iframe = document.getElementById("viewer"), results = [];
const waitFor = async (predicate) => {
  for (let i = 0; i < 150; i++) { if (predicate()) return; await new Promise((resolve) => setTimeout(resolve, 30)); }
  throw new Error("Timed out waiting for UI");
};
const assert = (value, message = "Assertion failed") => { if (!value) throw new Error(message); };
async function check(name, operation) {
  try { await operation(); results.push({ name, pass: true }); }
  catch (error) { results.push({ name, pass: false, error: error.message }); }
}
try {
  await waitFor(() => iframe.contentDocument?.getElementById("map-file") && iframe.contentWindow.document.getElementById("status")?.textContent);
  const doc = iframe.contentDocument, win = iframe.contentWindow, $ = (id) => doc.getElementById(id);
  const sample = await (await fetch("./fixtures/rice-hall-sample.json")).json(); // a TEST FIXTURE only: the viewer ships no sample building
  const change = (element) => element.dispatchEvent(new win.Event("change", { bubbles: true }));
  await check("Viewer starts empty: no placeholder building is loaded", () => {
    assert($("map-title").textContent === "No building open");
    assert($("map-source").textContent === "NOTHING LOADED");
    assert(!$("buildings").textContent.includes("sample"));
  });
  const openFile = async (map) => {
    const transfer = new win.DataTransfer();
    transfer.items.add(new win.File([JSON.stringify(map)], "test-map.json", { type: "application/json" }));
    $("map-file").files = transfer.files; change($("map-file"));
    await waitFor(() => $("map-file").value === "");
  };
  await openFile(sample);
  await waitFor(() => doc.querySelector("#route-result strong"));
  await check("A local map renders the default Room 204 route", () => {
    assert($("route-result").textContent.includes("10.5 m"));
    assert($("destinations").querySelectorAll("button").length === 4);
    assert($("map-source").textContent === "LOCAL MAP");
    assert($("map-canvas").width > 0);
  });
  await check("Destination click updates route and selector", () => {
    [...$("destinations").querySelectorAll("button")].find((b) => b.textContent.includes("Room 206")).click();
    assert($("route-result").textContent.includes("13.5 m"));
    assert($("goal-node").value === sample.nodes[6].id.toLowerCase());
  });
  await check("Clicking a plan marker selects its destination", () => {
    const canvas = $("map-canvas"), rect = canvas.getBoundingClientRect();
    const point = projectionForMap(sample,canvas.clientWidth,canvas.clientHeight).project(sample.nodes[5].position);
    canvas.dispatchEvent(new win.MouseEvent("click", { clientX: rect.left + point.x,
      clientY: rect.top + point.y, bubbles: true }));
    assert($("goal-node").value === sample.nodes[5].id.toLowerCase());
  });
  await check("Stairs show a warning even when discouraged", () => {
    [...$("destinations").querySelectorAll("button")].find((b) => b.textContent.includes("Stairs up")).click();
    assert($("route-result").textContent.includes("This route uses stairs."));
  });
  await check("3D keyboard orbit changes the rendered view and Fit restores it", () => {
    const before = $("map-canvas").toDataURL();
    $("map-canvas").dispatchEvent(new win.KeyboardEvent("keydown",{key:"ArrowRight",bubbles:true,cancelable:true}));
    assert($("map-canvas").toDataURL() !== before);
    $("fit-map").click();
    assert($("map-canvas").toDataURL() === before);
  });
  await check("Selecting the destination as start gives zero distance", () => {
    $("start-node").value = $("goal-node").value; change($("start-node"));
    assert($("route-result").textContent.includes("0.0 m"));
  });
  await check("Search produces an empty state and restores results", () => {
    $("building-search").value = "no-matching-building";
    $("building-search").dispatchEvent(new win.Event("input"));
    assert(!$("library-empty").hidden && !$("buildings").children.length);
    $("building-search").value = ""; $("building-search").dispatchEvent(new win.Event("input"));
    assert($("buildings").children.length === 1);
  });
  await check("Local map import renders untrusted names as plain text", async () => {
    const map = structuredClone(sample); map.name = "<img src=x onerror=alert(1)>";
    await openFile(map);
    assert($("map-title").textContent === map.name && !$("map-title").querySelector("img"));
    assert($("map-source").textContent === "LOCAL MAP");
  });
  await check("Invalid map import preserves current map", async () => {
    const title = $("map-title").textContent;
    const bad = structuredClone(sample); bad.nodes[0].segmentId = "../bad";
    await openFile(bad);
    assert($("status").classList.contains("error") && $("map-title").textContent === title);
  });
  await check("Schema 3 bundle loads verified OBJ geometry",async()=>{
    const raw = new TextEncoder().encode("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n");
    const digest=[...new Uint8Array(await crypto.subtle.digest("SHA-256",raw))].map(b=>b.toString(16).padStart(2,"0")).join("");
    const asset={id:"aaaaaaaa-0000-4000-8000-000000000001",segmentId:"seg1",format:"obj",coordinateFrame:"map",byteCount:raw.length,sha256:digest,boundsMin:[0,0,0],boundsMax:[1,1,0]};
    const map={...sample,meshAssets:[asset]};
    await openFile({map,worldMaps:{},meshFiles:{[asset.id]:btoa(String.fromCharCode(...raw))}});
    await waitFor(()=>$("geometry-status").textContent.includes("1/1 verified"));
  });
  await check("A missing mesh file fails visibly without losing route controls",async()=>{
    const map=structuredClone(sample);
    map.meshAssets=[{id:"aaaaaaaa-0000-4000-8000-000000000002",segmentId:"seg1",format:"obj",coordinateFrame:"map",byteCount:1,sha256:"0".repeat(64),boundsMin:[0,0,0],boundsMax:[1,1,1]}];
    await openFile(map);
    await waitFor(()=>$("geometry-status").textContent.includes("unavailable"));
    assert(!$("start-node").disabled && $("status").classList.contains("error"));
  });
  await check("Disconnected route and stairs preference update correctly", async () => {
    const vectors = await (await fetch("../Samples/route-vectors.json")).json();
    const map = vectors.fixtures.find((f) => f.map).map;
    await openFile(map);
    assert($("route-result").textContent.includes("No connecting route"));
    $("goal-node").value = map.nodes[1].id.toLowerCase(); change($("goal-node"));
    assert($("route-result").textContent.includes("4.5 m"));
    $("prefer-step-free").checked = false; change($("prefer-step-free"));
    assert($("route-result").textContent.includes("2.0 m") && $("route-result").textContent.includes("stairs"));
    $("prefer-step-free").checked = true; change($("prefer-step-free"));
  });
  await check("Empty map has a clear state and disabled route selectors", async () => {
    await openFile({ ...sample, nodes: [], edges: [] });
    assert(!$("map-empty").hidden && $("start-node").disabled && $("goal-node").disabled);
  });
  await check("Shared library connects, validates and selects canonical maps", async () => {
    const requests = [];
    win.fetch = async (url, options) => {
      requests.push([url, options]);
      const body = String(url).includes("/auth/")
        ? { access_token: "test-token", refresh_token: "test-refresh", expires_in: 3600 }
        : [{ map_id: sample.id, map_json: { ...sample, name: "Shared test building" } }];
      return new win.Response(JSON.stringify(body), { status: 200 });
    };
    $("connect-open").click(); $("anon-key").value = "TEST-ANON";
    $("connect-form").dispatchEvent(new win.Event("submit", { bubbles: true, cancelable: true }));
    await waitFor(() => $("connection-state").textContent === "Library connected");
    assert($("map-title").textContent === "Shared test building");
    assert($("anon-key").value === "" && !$("connect-dialog").open);
    assert(requests[1][0].includes("canonical_buildings"));
    $("refresh").click(); await waitFor(() => !$("refresh").disabled);
    assert(requests.filter(([url]) => url.includes("/auth/")).length === 1);
  });
  await check("Empty shared library keeps the map you opened and explains it is empty", async () => {
    win.fetch = async (url) => new win.Response(JSON.stringify(String(url).includes("/auth/")
      ? { access_token: "test-token", refresh_token: "test-refresh", expires_in: 3600 } : []), { status: 200 });
    $("connect-open").click(); $("anon-key").value = "TEST-ANON";
    $("connect-form").dispatchEvent(new win.Event("submit", { bubbles: true, cancelable: true }));
    await waitFor(() => !$("connect-dialog").open);
    assert($("status").textContent.includes("0 shared buildings"));
    assert($("buildings").children.length >= 1);
  });
  await check("390px layout has no horizontal overflow", async () => {
    iframe.style.width = "390px";
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert(doc.documentElement.scrollWidth <= win.innerWidth, `Content width ${doc.documentElement.scrollWidth}, viewport ${win.innerWidth}`);
  });
} catch (error) { results.push({ name: "Viewer initialization", pass: false, error: error.message }); }
for (const test of results) {
  const item = document.createElement("li"); item.className = test.pass ? "pass" : "fail";
  item.textContent = `${test.pass ? "PASS" : "FAIL"} ${test.name}${test.error ? `: ${test.error}` : ""}`;
  document.getElementById("results").append(item);
}
const failures = results.filter((r) => !r.pass).length;
document.getElementById("summary").textContent = `${results.length - failures}/${results.length} passed`;
document.title = failures ? "FAIL: Waypoint interface checks" : "PASS: Waypoint interface checks";
