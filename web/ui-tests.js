import {buildEstimatedBuilding} from "./building-model.js";
// Owner: U3. Real DOM interactions in an isolated same-origin iframe; cloud is mocked.
import { projectionForMap } from "./geometry3d.js";
const iframe = document.getElementById("viewer"), results = [];
const waitFor = async (predicate) => {
  for (let i = 0; i < 150; i++) { if (predicate()) return; await new Promise((resolve) => setTimeout(resolve, 30)); }
  throw new Error("Timed out waiting for UI: " + String(predicate).replace(/\s+/g, " ").slice(0, 140));
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
  await check("Unlabeled breadcrumbs hidden without changing routing",()=>{
    assert($('show-all-points').checked===false);
    assert(Number($('map-canvas').dataset.visiblePoints)===sample.nodes.filter(n=>n.label?.trim()).length);
    assert($('start-node').options.length===sample.nodes.length);
    $('show-all-points').checked=true;$('show-all-points').dispatchEvent(new win.Event('input'));
    assert(Number($('map-canvas').dataset.visiblePoints)===sample.nodes.length);
    $('show-all-points').checked=false;$('show-all-points').dispatchEvent(new win.Event('input'));
  });
  await check("Walkthrough enters perspective and Fit restores overview",()=>{
    $('walk-toggle').click();assert($('map-canvas').dataset.view==='walk');
    assert($('walk-toggle').getAttribute('aria-pressed')==='true');
    assert($('walk-status').textContent.includes('Walking around the floor'));assert($('route-result').textContent.includes('Floor tour'));
    $('fit-map').click();assert($('map-canvas').dataset.view==='overview');
    assert($('walk-toggle').getAttribute('aria-pressed')==='false');
  });
  await check("Double-click and double-tap a labeled place start walking",()=>{
    const c=$('map-canvas'),rect=c.getBoundingClientRect(),target=sample.nodes.find(n=>n.label==='Room 204');
    const building=buildEstimatedBuilding(sample);const point=projectionForMap({...sample,meshAssets:[building]},c.clientWidth,c.clientHeight).project(target.position);
    const coords={clientX:rect.left+point.x,clientY:rect.top+point.y,bubbles:true};
    c.dispatchEvent(new win.MouseEvent('dblclick',coords));assert(c.dataset.view==='walk');
    $('fit-map').click();
    for(let i=0;i<2;i++)c.dispatchEvent(new win.PointerEvent('pointerup',{...coords,pointerType:'touch',pointerId:1}));
    assert(c.dataset.view==='walk');$('fit-map').click();
  });
  await check("Destination click updates route and selector", () => {
    [...$("destinations").querySelectorAll("button")].find((b) => b.textContent.includes("Room 206")).click();
    assert($("route-result").textContent.includes("13.5 m"));
    assert($("goal-node").value === sample.nodes[6].id.toLowerCase());
  });
  await check("Clicking a plan marker selects its destination", () => {
    const canvas = $("map-canvas"), rect = canvas.getBoundingClientRect();
    const point = projectionForMap({...sample,meshAssets:[buildEstimatedBuilding(sample)]},canvas.clientWidth,canvas.clientHeight).project(sample.nodes[5].position);
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
  await check("Start route walks to completion and reports the selected room",async()=>{
    const start={...sample.nodes[0],position:[0,0,0]},goal={...sample.nodes[5],label:'Arrival test',position:[1,0,0]};delete goal.extent;
    await openFile({...sample,name:'Short arrival fixture',nodes:[start,goal],edges:[{from:start.id,to:goal.id,distance:1}],meshAssets:[]});
    $('start-route').click();await waitFor(()=>$('walk-status').textContent==='Arrived at Arrival test.');
    assert($('goal-node').value===goal.id.toLowerCase());assert($('map-canvas').dataset.view==='walk');$('fit-map').click();
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
  await check("Selecting a room reveals route and Start route uses that destination",async()=>{
    await openFile(sample);
    const destination=[...$('destinations').querySelectorAll('button')].find(b=>b.textContent.includes('Room 206'));
    destination.click();assert($('show-overlay').checked);assert(!$('start-route').disabled);
    $('start-route').click();assert($('map-canvas').dataset.view==='walk');
    assert($('goal-node').value===sample.nodes[6].id.toLowerCase());
    [...$('destinations').querySelectorAll('button')].find(b=>b.textContent.includes('Room 204')).click();
    assert($('goal-node').value===sample.nodes[5].id.toLowerCase());assert($('show-overlay').checked);
    $('fit-map').click();
  });
  await check("Expand map gives the canvas more room and restores",()=>{
    const before=$('map-canvas').clientWidth;$('expand-map').click();
    assert($('expand-map').getAttribute('aria-pressed')==='true');
    assert($('map-canvas').clientWidth>=before,'canvas before='+before+' after='+$('map-canvas').clientWidth);$('expand-map').click();
    assert($('expand-map').getAttribute('aria-pressed')==='false');
  });
  await check("Opening a scanned building shows download progress, never starts a walk, and re-opening reuses the verified mesh", async () => {
    const objBytes = new TextEncoder().encode("# unique to the cloud-download check, so the tab cache cannot already hold it\nv 0 0 0\nv 1 0 0\nv 0 1 0\nv 1 1 0\nf 1 2 3\nf 2 4 3\n");
    const sha256 = [...new Uint8Array(await crypto.subtle.digest("SHA-256", objBytes))].map((b) => b.toString(16).padStart(2, "0")).join("");
    const meshId = "bbbbbbbb-0000-4000-8000-0000000000aa", owner = "cccccccc-0000-4000-8000-0000000000bb";
    const asset = { id: meshId, segmentId: "seg1", format: "obj", coordinateFrame: "map", byteCount: objBytes.length, sha256, boundsMin: [0, 0, 0], boundsMax: [1, 1, 0], storageOwner: owner };
    const scanned = { ...sample, id: "dddddddd-0000-4000-8000-000000000001", name: "Scanned test floor", meshAssets: [asset] };
    const plain = { ...sample, id: "dddddddd-0000-4000-8000-000000000002", name: "Graph-only test floor" };
    let downloads = 0, release;
    const gate = new Promise((resolve) => { release = resolve; });
    win.fetch = async (url) => {
      const text = String(url);
      if (text.includes("/auth/")) return new win.Response(JSON.stringify({ access_token: "t", refresh_token: "r", expires_in: 3600 }), { status: 200 });
      if (text.includes("canonical_buildings")) return new win.Response(JSON.stringify([{ map_id: scanned.id, map_json: scanned }, { map_id: plain.id, map_json: plain }]), { status: 200 });
      if (text.includes("/storage/")) {
        downloads++;
        const body = new win.ReadableStream({ async start(controller) { controller.enqueue(objBytes.slice(0, 10)); await gate; controller.enqueue(objBytes.slice(10)); controller.close(); } });
        return new win.Response(body, { status: 200 });
      }
      return new win.Response("[]", { status: 404 });
    };
    $("connect-open").click(); $("anon-key").value = "TEST-ANON";
    $("connect-form").dispatchEvent(new win.Event("submit", { bubbles: true, cancelable: true }));
    const open = (name) => [...$("buildings").querySelectorAll("button")].find((b) => b.textContent.includes(name))?.click();
    await waitFor(() => [...$("buildings").querySelectorAll("button")].some((b) => b.textContent.includes("Scanned test floor")));
    const cards = [...$("buildings").querySelectorAll("button")].map((b) => b.textContent);
    const scannedAt = cards.findIndex((c) => c.includes("Scanned test floor")), plainAt = cards.findIndex((c) => c.includes("Graph-only test floor"));
    assert(scannedAt >= 0 && plainAt > scannedAt, "scanned building must be listed before graph-only ones: " + cards.join(" | "));
    assert(cards[scannedAt].endsWith("· 3D scan") && cards[plainAt].endsWith("· no 3D scan"), "badges: " + cards[scannedAt] + " / " + cards[plainAt]);
    open("Scanned");
    await waitFor(() => $("map-title").textContent === "Scanned test floor");
    await waitFor(() => /Downloading/.test($("geometry-status").textContent)); // progress is visible while bytes are still arriving
    assert($("walk-toggle").textContent === "Walk through" && $("map-canvas").dataset.view === "overview", "must not start in walk mode");
    release();
    await waitFor(() => $("geometry-status").textContent.includes("1/1 verified"));
    assert($("walk-toggle").textContent === "Walk through" && $("map-canvas").dataset.view === "overview", "walk after load: " + $("walk-toggle").textContent);
    assert(!/Walking/.test($("walk-status").textContent), "walk status: " + $("walk-status").textContent);
    assert(downloads === 1, "downloads=" + downloads);
    open("Graph-only"); await waitFor(() => $("map-title").textContent === "Graph-only test floor");
    assert($("map-canvas").dataset.view === "overview" && $("walk-toggle").textContent === "Walk through", "graph-only walk state");
    open("Scanned"); await waitFor(() => $("geometry-status").textContent.includes("1/1 verified"));
    assert(downloads === 1, "the verified mesh must come from the tab cache, not another download");
    assert($("map-canvas").dataset.view === "overview" && $("walk-toggle").textContent === "Walk through", "reopen walk state");
    // A matching hash must not bypass verification of a different manifest's bounds.
    await openFile({map:{...scanned,id:"dddddddd-0000-4000-8000-000000000003",meshAssets:[{...asset,boundsMax:[0.5,1,0]}]},meshFiles:{[meshId]:btoa(String.fromCharCode(...objBytes))}});
    await waitFor(()=>$("geometry-status").textContent.includes("unavailable"));
    assert($("status").textContent.includes("bounds"),"cached mesh bypassed the changed bounds: "+$("status").textContent);

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
