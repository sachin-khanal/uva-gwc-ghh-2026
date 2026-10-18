// Owner: U3. Read-only building explorer. All map positions are map-frame meters.
import { key, route, routeSummary, validateMap } from "./router.js";
import { CloudLibrary } from "./cloud.js";
import { DEFAULT_CAMERA, projectionForMap, roomCorners, verifyMesh } from "./geometry3d.js";

import { SurfaceRenderer } from "./surfaces.js";

const $ = (id) => document.getElementById(id);
const state = { entries: [], active: null, start: "", goal: "", path: null, zoom: 1, library: null, busy: false, hits: [],
  yaw: DEFAULT_CAMERA.yaw, pitch: DEFAULT_CAMERA.pitch, meshes: [], meshRequest: 0 };
const canvas = $("map-canvas"), context = canvas.getContext("2d");
const surfaces = new SurfaceRenderer($("surface-canvas"));
const nodeName = (node, index) => node.label || `${node.kind.charAt(0).toUpperCase() + node.kind.slice(1)} ${index + 1}`;
const destinations = (map) => map.nodes.filter((n) => n.label && n.kind !== "corridor");

function status(message, error = false) {
  $("status").textContent = message;
  $("status").classList.toggle("error", error);
}

function renderBuildings() {
  const query = $("building-search").value.trim().toLocaleLowerCase();
  const entries = state.entries.filter((e) => e.map.name.toLocaleLowerCase().includes(query));
  $("buildings").replaceChildren();
  for (const entry of entries) {
    const button = document.createElement("button");
    button.className = `building-card${state.active === entry ? " active" : ""}`;
    button.setAttribute("aria-pressed", String(state.active === entry));
    const name = document.createElement("strong"), detail = document.createElement("small");
    name.textContent = entry.title || entry.map.name;
    detail.textContent = `${entry.source} · ${entry.map.nodes.length} places · v${entry.map.version}`;
    button.append(name, detail); button.addEventListener("click", () => selectMap(entry));
    $("buildings").append(button);
  }
  $("library-empty").hidden = entries.length > 0;
  $("library-empty").textContent = state.entries.length ? "No buildings match your search." : "No maps loaded. Connect a library or open a map file.";
}

function selectMap(entry) {
  state.active = entry; state.zoom = 1;
  surfaces.clearMeshes(); $("show-overlay").checked=true; $("show-surfaces").checked=true; $("cutaway").value=100;
  state.overlayChanged=false;
  state.yaw = DEFAULT_CAMERA.yaw; state.pitch = DEFAULT_CAMERA.pitch; state.meshes = [];
  $("geometry-status").textContent = (entry.map.meshAssets ?? []).length ? "Loading verified 3D scan geometry…" : "Room footprints + route graph · No LiDAR mesh attached";
  const map = entry.map;
  $("map-title").textContent = entry.title || map.name;
  $("map-source").textContent = entry.source === "Shared" ? "SHARED BUILDING" : "LOCAL MAP";
  const heights = map.nodes.map((n) => n.position[1]);
  const multipleLevels = heights.length && Math.max(...heights) - Math.min(...heights) > 1.5;
  $("map-meta").textContent = `${map.nodes.length} places · ${map.edges.length} connections · Version ${map.version}${multipleLevels ? " · Multiple levels" : ""}`;
  $("map-empty").hidden = map.nodes.length > 0;
  const options = map.nodes.map((n, i) => ({ name: nodeName(n, i), id: key(n.id) }));
  for (const select of [$("start-node"), $("goal-node")]) {
    select.replaceChildren();
    for (const option of options) select.add(new Option(option.name, option.id));
    select.disabled = !options.length;
  }
  state.start = key((map.nodes.find((n) => n.kind === "corridor") || map.nodes[0])?.id || "");
  state.goal = key((destinations(map).find((n) => n.kind === "room") || destinations(map)[0] || map.nodes.at(-1))?.id || "");
  $("start-node").value = state.start; $("goal-node").value = state.goal;
  renderBuildings(); updateRoute(); queueMicrotask(()=>loadGeometry(entry));
}

async function loadGeometry(entry) {
  const request = ++state.meshRequest;
  try {
    for (const asset of entry.map.meshAssets ?? []) {
      let bytes;
      if (entry.library) bytes = await entry.library.mesh(entry.map,asset);
      else {
        const pair = Object.entries(entry.meshFiles ?? {}).find(([id]) => key(id) === key(asset.id));
        if (!pair) throw new Error("This map references a 3D scan file. Connect its shared library or open a bundle containing meshFiles.");
        const decoded = atob(pair[1]); bytes = Uint8Array.from(decoded,(c)=>c.charCodeAt(0)).buffer;
      }
      if (request !== state.meshRequest) return;
      const mesh = await verifyMesh(asset,bytes);
      if (request !== state.meshRequest) return;
      surfaces.add(mesh);
      state.meshes.push(mesh);
      if (!state.overlayChanged) $("show-overlay").checked=false;
      $("geometry-status").textContent = `${state.meshes.length}/${entry.map.meshAssets.length} verified LiDAR meshes loaded`;
      drawMap();
    }
  } catch (error) { if (request === state.meshRequest) { $("geometry-status").textContent="3D scan unavailable · Route graph remains visible"; status(error.message,true); } }
}

function renderDestinations() {
  const map = state.active.map, places = destinations(map);
  $("place-count").textContent = places.length;
  $("destinations").replaceChildren();
  if (!places.length) {
    const hint = document.createElement("p"); hint.className = "small muted";
    hint.textContent = "No labeled destinations yet. You can still select any point above.";
    $("destinations").append(hint);
  }
  for (const place of places) {
    const button = document.createElement("button");
    button.className = `destination ${place.kind}${key(place.id) === state.goal ? " active" : ""}`;
    button.setAttribute("aria-pressed", String(key(place.id) === state.goal));
    const label = document.createElement("span"), kind = document.createElement("span");
    label.textContent = place.label; kind.className = "kind"; kind.textContent = place.kind;
    button.append(label, kind);
    button.addEventListener("click", () => chooseGoal(place.id));
    $("destinations").append(button);
  }
}

function chooseGoal(id) {
  state.goal = key(id); $("goal-node").value = state.goal; updateRoute();
}

function updateRoute() {
  if (!state.active) return;
  const map = state.active.map;
  state.path = route(map, state.start, state.goal, !$("prefer-step-free").checked);
  const result = $("route-result"); result.replaceChildren();
  if (!map.nodes.length) result.textContent = "Choose a building with mapped places to plan a route.";
  else if (!state.path) result.textContent = "No connecting route. These places may belong to separate scan areas.";
  else {
    const summary = routeSummary(map, state.path);
    const length = document.createElement("strong"); length.textContent = `${summary.meters.toFixed(1)} m`;
    const detail = document.createElement("span");
    detail.textContent = state.path.length === 1 ? "You're previewing the starting point." : `${state.path.length - 1} connections to ${state.path.at(-1).label || "your destination"}`;
    result.append(length, detail);
    if (summary.stairs) {
      const warning = document.createElement("div"); warning.className = "warning";
      warning.textContent = "This route uses stairs."; result.append(warning);
    }
    if (summary.hazards.some((h) => h !== "stairs")) {
      const caution = document.createElement("div"); caution.className = "warning";
      caution.textContent = "Includes a narrow passage or door threshold."; result.append(caution);
    }
  }
  renderDestinations(); drawMap();
}

function drawMap() {
  if (!context) return;
  const width = canvas.clientWidth, height = canvas.clientHeight, dpr = window.devicePixelRatio || 1;
  canvas.width = Math.round(width * dpr); canvas.height = Math.round(height * dpr);
  context.setTransform(dpr, 0, 0, dpr, 0, 0); context.clearRect(0, 0, width, height);
  state.hits = [];
  const map = state.active?.map;
  surfaces.clear();
  if (!map?.nodes.length || !width || !height) return;
  const scene = projectionForMap(map,width,height,state.zoom,state.yaw,state.pitch);
  if (state.meshes.length && $("show-surfaces").checked) {
    const assets=map.meshAssets, low=Math.min(...assets.map(a=>a.boundsMin[1])), high=Math.max(...assets.map(a=>a.boundsMax[1]));
    surfaces.draw(scene,width,height,state.zoom,state.yaw,state.pitch,low+(high-low)*Number($("cutaway").value)/100+0.00001);
  }
  if (!$("show-overlay").checked) return;
  const point = (n) => scene.project(n.position);
  const nodes = new Map(map.nodes.map((n) => [key(n.id), n]));
  context.lineCap = "round"; context.lineJoin = "round";
  function line(a, b, color, thickness, dash = []) {
    const p = point(a), q = point(b); context.beginPath(); context.setLineDash(dash);
    context.moveTo(p.x, p.y); context.lineTo(q.x, q.y); context.strokeStyle = color;
    context.lineWidth = thickness; context.stroke(); context.setLineDash([]);
  }
  function polygon(points, fill, stroke) {
    const screen = points.map(scene.project); context.beginPath();
    screen.forEach((p,i) => i ? context.lineTo(p.x,p.y) : context.moveTo(p.x,p.y));
    context.closePath(); context.fillStyle = fill; context.fill(); context.strokeStyle = stroke;
    context.lineWidth = 0.7; context.stroke();
  }
  const base = scene.low[1], span = Math.max(3,Math.min(100,scene.radius*1.1));
  for (let i=-5;i<=5;i++) {
    const x = scene.center[0]+i*span/5, z = scene.center[2]+i*span/5;
    line({position:[x,base,scene.center[2]-span]},{position:[x,base,scene.center[2]+span]},"#e2e8dc",1);
    line({position:[scene.center[0]-span,base,z]},{position:[scene.center[0]+span,base,z]},"#e2e8dc",1);
  }
  for (const n of map.nodes) if (n.extent && !state.meshes.length) {
    const corners = roomCorners(n.extent);
    polygon(corners,"#b7d5b74d","#8dae95");
    if (n.extent.heightMeters) {
      const top = corners.map(([x,y,z])=>[x,y+n.extent.heightMeters,z]);
      for (let i=0;i<4;i++) polygon([corners[i],corners[(i+1)%4],top[(i+1)%4],top[i]],"#b7d5b720","#acc1b0");
    }
  }
  for (const edge of map.edges) {
    const a = nodes.get(key(edge.from)), b = nodes.get(key(edge.to));
    line(a, b, "#e4ebdf", 17);
    line(a, b, edge.hazard === "stairs" ? "#c48a43" : "#b6c7b7", 3, edge.hazard === "stairs" ? [5, 5] : []);
  }
  if (state.path) for (let i = 1; i < state.path.length; i++) line(state.path[i - 1], state.path[i], "#176d5b", 5);
  for (const n of [...map.nodes].sort((a,b)=>point(a).depth-point(b).depth)) {
    const p = point(n), isStart = key(n.id) === state.start, isGoal = key(n.id) === state.goal;
    const radius = isStart || isGoal ? 7 : n.kind === "corridor" ? 3.5 : 5;
    context.beginPath(); context.arc(p.x, p.y, radius + 3, 0, Math.PI * 2); context.fillStyle = "#f7f9f3"; context.fill();
    context.beginPath(); context.arc(p.x, p.y, radius, 0, Math.PI * 2);
    context.fillStyle = isStart ? "#193d38" : isGoal ? "#176d5b" : n.kind === "stairs" ? "#a85e1b" : "#8da995"; context.fill();
    if (isStart || isGoal) { context.beginPath(); context.arc(p.x, p.y, 2, 0, Math.PI * 2); context.fillStyle = "#fff"; context.fill(); }
    const label = n.label || (isStart ? "Starting point" : isGoal ? "Destination" : "");
    if (label) {
      // Canvas text is inert: uploaded labels are never interpreted as HTML.
      const text = label.length > 30 ? label.slice(0, 29) + "…" : label;
      context.font = `${isGoal ? "600" : "500"} 11px system-ui`; context.textBaseline = "middle";
      const textWidth = context.measureText(text).width;
      const labelX = p.x + 16 + textWidth > width - 5 ? p.x - textWidth - 16 : p.x + 13;
      const labelY = p.y + (isStart && !n.label ? 23 : 0);
      context.fillStyle = "#f7f9f3"; context.fillRect(labelX - 3, labelY - 10, textWidth + 6, 20);
      context.fillStyle = n.kind === "stairs" ? "#965819" : "#234b3d"; context.fillText(text, labelX, labelY);
      state.hits.push({ x: p.x, y: p.y, labelX, labelY, textWidth, id: n.id });
    }
  }
  context.font = "10px system-ui"; context.fillStyle = "#647871";
  context.fillText(`${state.meshes.length ? "LiDAR mesh + " : ""}3D navigation graph · drag to orbit`,23,height-18);
}

function hitAt(event) {
  const rect = canvas.getBoundingClientRect(), x = event.clientX - rect.left, y = event.clientY - rect.top;
  return state.hits.findLast((h) => Math.hypot(x - h.x, y - h.y) < 18
    || (x >= h.labelX - 3 && x <= h.labelX + h.textWidth + 3 && Math.abs(y - h.labelY) < 12));
}
let dragging = null, suppressClick = false;
canvas.addEventListener("pointerdown",(event)=>{
  dragging = {x:event.clientX,y:event.clientY,startX:event.clientX,startY:event.clientY};
  suppressClick = false; canvas.setPointerCapture(event.pointerId);
});
canvas.addEventListener("pointermove",(event)=>{
  if (!dragging) { canvas.style.cursor = hitAt(event) ? "pointer" : "grab"; return; }
  if (Math.hypot(event.clientX-dragging.startX,event.clientY-dragging.startY)>4) suppressClick = true;
  if (suppressClick) {
    state.yaw += (event.clientX-dragging.x)*0.009;
    state.pitch = Math.max(-0.2,Math.min(1.5,state.pitch+(event.clientY-dragging.y)*0.009));
    drawMap();
  }
  dragging.x=event.clientX;dragging.y=event.clientY;
});
canvas.addEventListener("pointerup",()=>{dragging=null;});
canvas.addEventListener("pointercancel",()=>{dragging=null;suppressClick=true;});
canvas.addEventListener("click", (event) => { if (suppressClick) { suppressClick=false;return; } const hit = hitAt(event); if (hit) chooseGoal(hit.id); });
canvas.addEventListener("keydown",(event)=>{
  if (!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(event.key))return;
  event.preventDefault(); state.yaw += event.key==='ArrowLeft' ? -0.12 : event.key==='ArrowRight' ? 0.12 : 0;
  state.pitch=Math.max(-0.2,Math.min(1.5,state.pitch+(event.key==='ArrowUp' ? 0.12 : event.key==='ArrowDown' ? -0.12 : 0)));drawMap();
});
for (const id of ["show-surfaces","show-overlay","cutaway"]) $(id).addEventListener("input",()=>{
  if(id==="show-overlay") state.overlayChanged=true; drawMap();
});
new ResizeObserver(drawMap).observe($("canvas-wrap"));
$("fit-map").addEventListener("click", () => { state.zoom = 1;state.yaw=DEFAULT_CAMERA.yaw;state.pitch=DEFAULT_CAMERA.pitch; drawMap(); });
$("zoom-in").addEventListener("click", () => { state.zoom = Math.min(4, state.zoom * 1.25); drawMap(); });
$("zoom-out").addEventListener("click", () => { state.zoom = Math.max(0.5, state.zoom / 1.25); drawMap(); });
$("building-search").addEventListener("input", renderBuildings);
$("start-node").addEventListener("change", (event) => { state.start = event.target.value; updateRoute(); });
$("goal-node").addEventListener("change", (event) => { state.goal = event.target.value; updateRoute(); });
$("prefer-step-free").addEventListener("change", updateRoute);

$("map-file").addEventListener("change", async (event) => {
  const file = event.target.files[0]; if (!file) return;
  try {
    if (file.size > 5_000_000) throw new Error("Open the building's map.json instead; this preview accepts files up to 5 MB.");
    const document = JSON.parse(await file.text()), map = validateMap(document);
    const entry = { map, source: "Local",meshFiles:document.meshFiles }; state.entries.push(entry); selectMap(entry);
    status(`Opened ${map.name}. This file stays in your browser.`);
  } catch (error) { status(error.message, true); }
  event.target.value = "";
});

async function loadLibrary(library) {
  const rows = await library.list(), entries = [], rejected = [];
  for (const row of rows) {
    try {
      const map = validateMap(row.map_json);
      if (key(row.map_id) !== key(map.id)) throw new Error("Building ID mismatch.");
      entries.push({ map, source: "Shared",library });
    } catch { rejected.push(row.map_id); }
  }
  const activeID = state.active?.source === "Shared" ? key(state.active.map.id) : null;
  state.entries = [...state.entries.filter((e) => e.source !== "Shared"), ...entries];
  const active = entries.find((e) => key(e.map.id) === activeID) || entries[0] || state.entries[0];
  if (active) selectMap(active); else renderBuildings();
  $("library-caption").textContent = "AVAILABLE BUILDINGS";
  status(`${entries.length} shared building${entries.length === 1 ? "" : "s"} loaded.${entries.length ? "" : " Publish a building from the app to see it here."}${rejected.length ? ` Skipped ${rejected.length} invalid map(s).` : ""}`, rejected.length > 0);
}

$("connect-open").addEventListener("click", () => $("connect-dialog").showModal());
$("connect-close").addEventListener("click", () => $("connect-dialog").close());
$("connect-form").addEventListener("submit", async (event) => {
  event.preventDefault(); if (state.busy) return;
  state.busy = true; $("connect-submit").disabled = true; $("refresh").disabled = true; $("connect-error").textContent = "";
  try {
    const candidate = new CloudLibrary($("project-url").value.trim(), $("anon-key").value);
    await loadLibrary(candidate); state.library = candidate;
    $("anon-key").value = ""; $("connection-state").textContent = "Library connected";
    $("connect-open").textContent = "Connection settings"; $("connect-dialog").close();
  } catch (error) { $("connect-error").textContent = error.message; }
  finally { state.busy = false; $("connect-submit").disabled = false; $("refresh").disabled = !state.library; }
});
$("refresh").addEventListener("click", async () => {
  if (!state.library || state.busy) return;
  state.busy = true; $("refresh").disabled = true; status("Refreshing shared maps…");
  try { await loadLibrary(state.library); } catch (error) { status(error.message, true); }
  finally { state.busy = false; $("refresh").disabled = false; }
});

// No bundled sample building (removed 2026-10-18): the viewer starts empty and only ever shows REAL scans (the shared library or a local map file).
$("map-title").textContent = "No building open";
$("map-source").textContent = "NOTHING LOADED";
status("Connect your library to see shared scans, or open a local map file.");
renderBuildings();
