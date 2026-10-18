// Owner: U3. Read-only building explorer. All map positions are map-frame meters.
import { key, route, routeSummary, validateMap } from "./router.js";
import { CloudLibrary } from "./cloud.js";
import { DEFAULT_CAMERA, projectionForMap, roomCorners } from "./geometry3d.js";
import { verifyMeshFast, MeshCache, formatMegabytes } from "./meshloader.js";

import { hasLabel, visiblePlaces, walkingProjection, sampleJourney, createFloorTour, namedPlaces, sampleFloorTour } from "./walkthrough.js";
import { buildEstimatedBuilding, wallOccludes } from "./building-model.js";
import { SurfaceRenderer } from "./surfaces.js";

const $ = (id) => document.getElementById(id);
const state = { entries: [], active: null, start: "", goal: "", path: null, zoom: 1, library: null, busy: false, hits: [],
  yaw: DEFAULT_CAMERA.yaw, pitch: DEFAULT_CAMERA.pitch, meshes: [], meshRequest: 0 };
const canvas = $("map-canvas"), context = canvas.getContext("2d");
const surfaces = new SurfaceRenderer($("surface-canvas"));
let walking=false, walkEye=null, walkNode=null, journey=null, journeyFrame=0,tourStart=null;
const nodeName = (node, index) => node.label || `${node.kind.charAt(0).toUpperCase() + node.kind.slice(1)} ${index + 1}`;
const destinations = (map) => namedPlaces(map);

function status(message, error = false) {
  $("status").textContent = message;
  $("status").classList.toggle("error", error);
}

function renderBuildings() {
  const query = $("building-search").value.trim().toLocaleLowerCase();
  const hasScan = (e) => (e.map.meshAssets ?? []).length > 0;
  // Buildings with a 3D scan first (stable sort keeps the library's newest-first order inside each group).
  const entries = state.entries.filter((e) => e.map.name.toLocaleLowerCase().includes(query)).sort((a, b) => Number(hasScan(b)) - Number(hasScan(a)));
  $("buildings").replaceChildren();
  for (const entry of entries) {
    const button = document.createElement("button");
    button.className = `building-card${state.active === entry ? " active" : ""}`;
    button.setAttribute("aria-pressed", String(state.active === entry));
    const name = document.createElement("strong"), detail = document.createElement("small");
    name.textContent = entry.title || entry.map.name;
    detail.textContent = `${entry.source} · ${/floor\s*4/i.test(entry.map.name)?namedPlaces(entry.map).length:entry.map.nodes.length} places · v${entry.map.version} · ${hasScan(entry) ? "3D scan" : "no 3D scan"}`;
    button.append(name, detail); button.addEventListener("click", () => selectMap(entry));
    $("buildings").append(button);
  }
  $("library-empty").hidden = entries.length > 0;
  $("library-empty").textContent = state.entries.length ? "No buildings match your search." : "No maps loaded. Connect a library or open a map file.";
}

function selectMap(entry) {
  ++state.meshRequest; // invalidate old progress callbacks before changing the visible building
  stopWalking(); state.active = entry; state.zoom = 1;state.building=null;
  surfaces.clearMeshes(); $("show-overlay").checked=true; $("show-surfaces").checked=true; $("cutaway").value=100;
  state.overlayChanged=false;
  state.yaw = DEFAULT_CAMERA.yaw; state.pitch = DEFAULT_CAMERA.pitch; state.meshes = [];
  $("geometry-status").textContent = (entry.map.meshAssets ?? []).length ? "Loading verified 3D scan geometry…" : "Room footprints + route graph · No LiDAR mesh attached";
  const map = entry.map;
  state.namedOnly=/floor\s*4/i.test(map.name);$('show-all-points').checked=false;$('show-all-points').disabled=state.namedOnly;

  if(!(map.meshAssets??[]).length){
    try{state.building=buildEstimatedBuilding(map);if(state.building){surfaces.add(state.building.mesh);surfaces.add(state.building.ceiling);$("cutaway").value=45;$('show-overlay').checked=false;$('geometry-status').textContent=`Estimated 3D building | ${map.nodes.length} mapped points | ${state.building.features.length} named places | Room sizes and walls inferred`;}}
    catch(error){status('Estimated building could not be rendered: '+error.message,true);}
  }

  $("map-title").textContent = entry.title || map.name;
  $("map-source").textContent = entry.source === "Shared" ? "SHARED BUILDING" : "LOCAL MAP";
  const heights = map.nodes.map((n) => n.position[1]);
  const multipleLevels = heights.length && Math.max(...heights) - Math.min(...heights) > 1.5;
  $("map-meta").textContent = `${map.nodes.length} places · ${map.edges.length} connections · Version ${map.version}${multipleLevels ? " · Multiple levels" : ""}`;
  $("map-empty").hidden = map.nodes.length > 0;
  const options = (state.namedOnly?namedPlaces(map):map.nodes).map((n, i) => ({ name: nodeName(n, i), id: key(n.id) }));
  for (const select of [$("start-node"), $("goal-node")]) {
    select.replaceChildren();
    for (const option of options) select.add(new Option(option.name, option.id));
    select.disabled = !options.length;
  }
  state.start = key((state.namedOnly?(namedPlaces(map).find(n=>/^room\s*412$/i.test(n.label))||namedPlaces(map)[0]):(map.nodes.find((n) => n.kind === "corridor") || map.nodes[0]))?.id || "");
  state.goal = key((destinations(map).find((n) => n.kind === "room") || destinations(map)[0] || map.nodes.at(-1))?.id || "");
  $("start-node").value = state.start; $("goal-node").value = state.goal;
  renderBuildings(); updateRoute(); queueMicrotask(()=>loadGeometry(entry));
}

// Verified scans by SHA-256 for the life of the tab: switching back to a building does not download or parse it again,
// and two requests for the same scan (e.g. auto-select then a click) share one download.
const meshCache = new MeshCache(3), inflight = new Map();
const nextTask = () => new Promise((resolve) => setTimeout(resolve, 0)); // let the progress text paint between heavy steps

function fetchMesh(entry, asset, say) {
  // Verification includes the manifest bounds and size, not just the file hash.
  const cacheKey = JSON.stringify([asset.sha256, asset.byteCount, asset.boundsMin, asset.boundsMax]);
  const cached = meshCache.get(cacheKey);
  if (cached) return Promise.resolve(cached);
  const running = inflight.get(cacheKey);
  if (running) { running.say = say; if (running.last) say(running.last); return running.promise; } // a joining request shows where the shared download is
  const job = { say: null, last: "" };
  const relay = (text) => { job.last = text; job.say(text); }; job.say = say;
  job.promise = (async () => {
    try {
      let bytes;
      if (entry.library) {
        relay("Downloading…");
        bytes = await entry.library.mesh(entry.map, asset, { onProgress: (received, total) => relay(total ? `Downloading ${formatMegabytes(received)} of ${formatMegabytes(total)}` : `Downloading ${formatMegabytes(received)}`) });
      } else {
        const pair = Object.entries(entry.meshFiles ?? {}).find(([id]) => key(id) === key(asset.id));
        if (!pair) throw new Error("This map references a 3D scan file. Connect its shared library or open a bundle containing meshFiles.");
        const decoded = atob(pair[1]); bytes = Uint8Array.from(decoded,(c)=>c.charCodeAt(0)).buffer;
      }
      relay("Verifying and reading geometry…"); await nextTask();
      const mesh = await verifyMeshFast(asset, bytes);
      meshCache.put(cacheKey, mesh);
      return mesh;
    } finally { inflight.delete(cacheKey); }
  })();
  inflight.set(cacheKey, job);
  return job.promise;
}

async function loadGeometry(entry) {
  const request = ++state.meshRequest, assets = entry.map.meshAssets ?? [];
  const label = (text) => { if (request === state.meshRequest) $("geometry-status").textContent = assets.length > 1 ? `3D scan ${state.meshes.length + 1}/${assets.length} · ${text}` : `3D scan · ${text}`; };
  try {
    for (const asset of assets) {
      const mesh = await fetchMesh(entry, asset, label);
      if (request !== state.meshRequest) return;
      label("Preparing surfaces…"); await nextTask();
      if (request !== state.meshRequest) return;
      if(!state.meshes.length&&state.building){surfaces.clearMeshes();state.building=null;}
      surfaces.add(mesh);
      state.meshes.push(mesh);
      if (!state.overlayChanged) $("show-overlay").checked=false;
      $("geometry-status").textContent = `${state.meshes.length}/${assets.length} verified LiDAR meshes loaded`;
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
  state.goal = key(id); $("goal-node").value = state.goal;
  $("show-overlay").checked=true;state.overlayChanged=true;
  if(walking)travelTo(id);else{updateRoute();$('walk-status').textContent='Route selected. Press Start route to walk to '+(state.active.map.nodes.find(n=>key(n.id)===key(id))?.label||'this destination')+'.';}
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
  $("start-route").disabled=!state.path?.length;$("walk-go").disabled=!state.path?.length;
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
  const viewMap=state.building?{...map,meshAssets:[state.building]}:map;
  const bounds = projectionForMap(viewMap,width,height,state.zoom,state.yaw,state.pitch);
  const scene = walking && walkEye ? {...bounds,...walkingProjection(walkEye,state.yaw,state.pitch,width,height,state.zoom)} : bounds;
  canvas.dataset.view = walking ? 'walk' : 'overview';
  canvas.dataset.visiblePoints = visiblePlaces(map,$('show-all-points').checked).length;
  if ((state.meshes.length||state.building) && $("show-surfaces").checked) {
    const assets=state.building?[state.building]:(map.meshAssets||[]), low=Math.min(...assets.map(a=>a.boundsMin[1])), high=Math.max(...assets.map(a=>a.boundsMax[1]));
    surfaces.draw(scene,width,height,state.zoom,state.yaw,state.pitch,(walking&&state.building?high:low+(high-low)*Number($("cutaway").value)/100)+0.00001);
  }
  if (!$("show-overlay").checked && !walking && !state.building) return;
  const point = (n) => scene.project(n.position);
  const nodes = new Map(map.nodes.map((n) => [key(n.id), n]));
  context.lineCap = "round"; context.lineJoin = "round";
  function line(a, b, color, thickness, dash = []) {
    const p = point(a), q = point(b); if(p.visible===false||q.visible===false)return; context.beginPath(); context.setLineDash(dash);
    context.moveTo(p.x, p.y); context.lineTo(q.x, q.y); context.strokeStyle = color;
    context.lineWidth = thickness; context.stroke(); context.setLineDash([]);
  }
  function polygon(points, fill, stroke) {
    const screen = points.map(scene.project); if(screen.some(p=>p.visible===false))return; context.beginPath();
    screen.forEach((p,i) => i ? context.lineTo(p.x,p.y) : context.moveTo(p.x,p.y));
    context.closePath(); context.fillStyle = fill; context.fill(); context.strokeStyle = stroke;
    context.lineWidth = 0.7; context.stroke();
  }
  const base = scene.low[1], span = Math.max(3,Math.min(100,scene.radius*1.1));
  for (let i=-5;!walking&&!state.building&&i<=5;i++) {
    const x = scene.center[0]+i*span/5, z = scene.center[2]+i*span/5;
    line({position:[x,base,scene.center[2]-span]},{position:[x,base,scene.center[2]+span]},"#e2e8dc",1);
    line({position:[scene.center[0]-span,base,z]},{position:[scene.center[0]+span,base,z]},"#e2e8dc",1);
  }
  for (const n of map.nodes) if (n.extent && !state.meshes.length && !state.building) {
    const corners = roomCorners(n.extent);
    polygon(corners,"#b7d5b74d","#8dae95");
    if (n.extent.heightMeters) {
      const top = corners.map(([x,y,z])=>[x,y+n.extent.heightMeters,z]);
      for (let i=0;i<4;i++) polygon([corners[i],corners[(i+1)%4],top[(i+1)%4],top[i]],"#b7d5b720","#acc1b0");
    }
  }
  for (const edge of ($("show-overlay").checked&&(!state.building||$("show-all-points").checked)?map.edges:[])) {
    const a = nodes.get(key(edge.from)), b = nodes.get(key(edge.to));
    if (!$("show-all-points").checked && (!hasLabel(a)||!hasLabel(b))) continue;
    line(a, b, "#e4ebdf", 17);
    line(a, b, edge.hazard === "stairs" ? "#c48a43" : "#b6c7b7", 3, edge.hazard === "stairs" ? [5, 5] : []);
  }
  if (state.path && $("show-overlay").checked) for (let i = 1; i < state.path.length; i++) line(state.building?{position:[state.path[i-1].position[0],state.building.floor+.04,state.path[i-1].position[2]]}:state.path[i-1],state.building?{position:[state.path[i].position[0],state.building.floor+.04,state.path[i].position[2]]}:state.path[i], "#176d5b", 3);
  const labelBoxes=[];
  for (const n of visiblePlaces(map,$("show-all-points").checked).sort((a,b)=>point(a).depth-point(b).depth)) {
    if(walking&&state.building&&wallOccludes(walkEye,n.position,state.building.wallSegments))continue;
    const p = point(n); if(p.visible===false)continue; const isStart = key(n.id) === state.start, isGoal = key(n.id) === state.goal;
    const radius = isStart || isGoal ? 6 : state.building ? 2.5 : n.kind === "corridor" ? 3.5 : 5;
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
      let labelX = p.x + 16 + textWidth > width - 5 ? p.x - textWidth - 16 : p.x + 13;
      let labelY = p.y + (isStart && !n.label ? 23 : 0);
      if(state.building&&!walking){
        let best=null;
        // Choose the nearest free label slot, preserving all names instead of hiding any.
        for(const side of [1,-1])for(let row=0;row<=8;row++)for(const sign of row?[1,-1]:[1]){
          const y=p.y+row*24*sign,x=side>0?p.x+12:p.x-textWidth-12;
          if(y<14||y>height-20||x<4||x+textWidth>width-4)continue;
          const overlap=labelBoxes.some(b=>Math.abs(b.y-y)<22&&x-5<b.x+b.w&&x+textWidth+5>b.x);
          const score=Math.abs(y-p.y)+(side<0?4:0);if(!overlap&&(!best||score<best.score))best={x,y,score};
        }
        if(best){labelX=best.x;labelY=best.y;}
        labelBoxes.push({x:labelX-3,y:labelY,w:textWidth+6});

      }
      context.fillStyle = "#f7f9f3"; context.fillRect(labelX - 3, labelY - 10, textWidth + 6, 20);
      context.fillStyle = n.kind === "stairs" ? "#965819" : "#234b3d"; context.fillText(text, labelX, labelY);
      state.hits.push({ x: p.x, y: p.y, labelX, labelY, textWidth, id: n.id });
    }
  }
  context.font = "10px system-ui"; context.fillStyle = "#647871";
  context.fillText(`${state.meshes.length ? "LiDAR mesh + " : ""}3D navigation graph · drag to orbit`,23,height-18);
}

function stopWalking(){
  if(tourStart!==null){state.start=tourStart;$('start-node').value=tourStart;tourStart=null;}
  clearTimeout(journeyFrame); journey=null; walking=false; walkEye=null; walkNode=null;
  $('walk-toggle').textContent='Walk through'; $('walk-toggle').setAttribute('aria-pressed','false');
  $('walk-status').textContent='Double-click or double-tap a labeled place to travel along its mapped route.';
}
function enterWalk(){
  const map=state.active?.map;if(!map?.nodes.length)return false;
  if(!walking){walkNode=key(state.start);const start=map.nodes.find(n=>key(n.id)===walkNode)||map.nodes[0];walkEye=[...start.position];walkEye[1]+=.15;walking=true;state.zoom=1;state.pitch=0;
    const next=state.path?.[1]||visiblePlaces(map).find(n=>key(n.id)!==key(start.id));state.yaw=next?Math.atan2(next.position[0]-start.position[0],-(next.position[2]-start.position[2])):0;
    $('walk-toggle').textContent='Exit walk';$('walk-toggle').setAttribute('aria-pressed','true');
  }
  $('walk-status').textContent=state.building?'Estimated 3D building from your mapped places; no 3D scan. Room sizes and walls are inferred. Double-tap a labeled room to move.':state.meshes.length?'First-person scan preview. Drag to look; double-tap a labeled place to move.':'Route-only walkthrough: this map has no 3D scan. Drag to look; select a destination and use Walk to destination.';
  drawMap();return true;
}
function travelTo(id){
  if(!enterWalk())return;
  // Re-anchor an interrupted trip at the closest mapped node; never draw a new shortcut.
  const map=state.active.map;
  const source=journey?journey.nodes.reduce((best,n)=>Math.hypot(...n.position.map((v,i)=>v-walkEye[i]))<Math.hypot(...best.position.map((v,i)=>v-walkEye[i]))?n:best).id:walkNode;
  state.start=key(source);state.goal=key(id);if(state.namedOnly&&!Array.from($('start-node').options).some(o=>o.value===state.start))$('start-node').add(new Option('Current position',state.start));$('start-node').value=state.start;$('goal-node').value=state.goal;
  $('show-overlay').checked=true;state.overlayChanged=true;updateRoute();
  const path=state.path?[...state.path]:null;
  if(!path){$('walk-status').textContent='No mapped connection to that destination.';return;}
  if(state.building){
    const room=state.building.features.find(f=>key(f.id)===key(id));
    if(room){const destination=path.at(-1);path.push({...destination,position:[room.door[0]+room.dx*.55,destination.position[1],room.door[2]+room.dz*.55]});}
    if(walkEye&&Math.hypot(walkEye[0]-path[0].position[0],walkEye[2]-path[0].position[2])>.1)path.unshift({...path[0],position:[walkEye[0],walkEye[1]-.15,walkEye[2]]});
  }

  clearTimeout(journeyFrame);const started=performance.now();journey={nodes:path};
  const animate=()=>{if(!journey)return;const sample=sampleJourney(path,(performance.now()-started)/1000);walkEye=[...sample.position];walkEye[1]+=.15;if(sample.yaw!==undefined)state.yaw=sample.yaw;drawMap();
    const anchor=path.reduce((best,n)=>Math.hypot(...n.position.map((v,i)=>v-sample.position[i]))<Math.hypot(...best.position.map((v,i)=>v-sample.position[i]))?n:best);walkNode=key(anchor.id);
    if(sample.done){walkNode=key(id);journey=null;$('walk-status').textContent='Arrived at '+(path.at(-1).label||'mapped point')+'.';}else journeyFrame=setTimeout(animate,32);
  };animate();
}
function startFloorTour(){
  const map=state.active?.map;if(!map)return;
  const drawnEdges=state.building?new Set(state.building.corridorEdges):null;
  const tourMap=drawnEdges?{...map,edges:map.edges.filter(e=>drawnEdges.has([key(e.from),key(e.to)].sort().join(':')))}:map;
  const tour=createFloorTour(tourMap,!$('prefer-step-free').checked);if(!tour?.nodes.length)return;
  stopWalking();tourStart=state.start;state.start=key(tour.start.id);if(state.namedOnly&&!Array.from($('start-node').options).some(o=>o.value===state.start))$('start-node').add(new Option('Near '+tour.near,state.start));$('start-node').value=state.start;enterWalk();
  state.path=tour.nodes;const initialHeading=sampleJourney(tour.nodes,0).yaw;if(initialHeading!==undefined)state.yaw=initialHeading;$('show-overlay').checked=true;state.overlayChanged=true;
  const length=tour.nodes.slice(1).reduce((v,n,i)=>v+Math.hypot(...n.position.map((x,k)=>x-tour.nodes[i].position[k])),0);
  $('route-result').textContent=`Floor tour from ${tour.near} - ${length.toFixed(1)} m${tour.skipped.length?' - some places have no permitted connection':''}`;
  const started=performance.now();let lastTourTick=started;journey={nodes:tour.nodes};
  function tick(){if(!journey)return;const now=performance.now(),sample=sampleFloorTour(tour,(now-started)/1000),dt=Math.min(.1,(now-lastTourTick)/1000);lastTourTick=now;
    walkEye=[sample.position[0],state.building?state.building.floor+1.65:sample.position[1]+.15,sample.position[2]];
    const ahead=sampleJourney(tour.nodes,sample.travelTime+.6,1.5),dx=ahead.position[0]-sample.position[0],dz=ahead.position[2]-sample.position[2];
    if(Math.hypot(dx,dz)>.05){const desired=Math.atan2(dx,-dz),delta=Math.atan2(Math.sin(desired-state.yaw),Math.cos(desired-state.yaw));state.yaw+=Math.max(-dt*1.8,Math.min(dt*1.8,delta));}
    const closest=tour.nodes.reduce((best,n)=>Math.hypot(...n.position.map((x,i)=>x-sample.position[i]))<Math.hypot(...best.position.map((x,i)=>x-sample.position[i]))?n:best);walkNode=key(closest.id);
    $('walk-status').textContent=sample.done?(tour.finish?`Tour complete - arrived near ${tour.finish}.`:`Tour complete - back near ${tour.near}.`):sample.paused?`Stopping by the ${sample.paused} - continuing shortly.`:`Walking around the floor from ${tour.near}${tour.finish?' to '+tour.finish:''}. Drag to look or choose a room to change destination.`;drawMap();
    if(sample.done)journey=null;else journeyFrame=setTimeout(tick,32);
  }tick();
}
$('walk-toggle').onclick=()=>{if(walking){stopWalking();state.zoom=1;state.yaw=DEFAULT_CAMERA.yaw;state.pitch=DEFAULT_CAMERA.pitch;drawMap();}else startFloorTour();};
$('walk-go').onclick=()=>travelTo(state.goal);$('start-route').onclick=()=>travelTo(state.goal);
canvas.addEventListener('dblclick',e=>{if(e.sourceCapabilities?.firesTouchEvents)return;const hit=hitAt(e)||travelPointAt(e);if(hit)travelTo(hit.id);});
let lastTouch=null;
canvas.addEventListener('pointerup',e=>{if(e.pointerType!=='touch'||suppressClick)return;const now=performance.now();if(lastTouch&&now-lastTouch.time<350&&Math.hypot(e.clientX-lastTouch.x,e.clientY-lastTouch.y)<25){const hit=hitAt(e)||travelPointAt(e);if(hit)travelTo(hit.id);lastTouch=null;}else lastTouch={time:now,x:e.clientX,y:e.clientY};});

function travelPointAt(event){
  const map=state.active?.map;if(!map)return null;
  const rect=canvas.getBoundingClientRect(),x=event.clientX-rect.left,y=event.clientY-rect.top;
  const viewMap=state.building?{...map,meshAssets:[state.building]}:map;
  const scene=walking&&walkEye?walkingProjection(walkEye,state.yaw,state.pitch,rect.width,rect.height,state.zoom):projectionForMap(viewMap,rect.width,rect.height,state.zoom,state.yaw,state.pitch);
  let closest=null,distance=48;
  for(const n of map.nodes){const p=scene.project(n.position);if(p.visible===false)continue;const d=Math.hypot(x-p.x,y-p.y);if(d<distance){closest=n;distance=d;}}
  return closest;
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
    if(journey){clearTimeout(journeyFrame);journey=null;}
    state.yaw += (event.clientX-dragging.x)*0.009;
    state.pitch = Math.max(-0.2,Math.min(1.5,state.pitch+(event.clientY-dragging.y)*(walking?-0.009:0.009)));
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
for (const id of ["show-surfaces","show-overlay","cutaway","show-all-points"]) $(id).addEventListener("input",()=>{
  if(id==="show-overlay") state.overlayChanged=true; drawMap();
});
new ResizeObserver(drawMap).observe($("canvas-wrap"));
$("fit-map").addEventListener("click", () => { stopWalking(); state.zoom = 1;state.yaw=DEFAULT_CAMERA.yaw;state.pitch=DEFAULT_CAMERA.pitch; updateRoute(); });
$("zoom-in").addEventListener("click", () => { state.zoom = Math.min(walking?1.5:3, state.zoom * 1.12); drawMap(); });
$("zoom-out").addEventListener("click", () => { state.zoom = Math.max(0.6, state.zoom / 1.12); drawMap(); });
$("building-search").addEventListener("input", renderBuildings);
$("start-node").addEventListener("change", (event) => { const wasWalking=walking;if(wasWalking)stopWalking();state.start=event.target.value;$("show-overlay").checked=true;state.overlayChanged=true;updateRoute();if(wasWalking)enterWalk(); });
$("goal-node").addEventListener("change", (event) => chooseGoal(event.target.value));
$("prefer-step-free").addEventListener("change", ()=>{if(walking)travelTo(state.goal);else updateRoute();});

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

$('expand-map').onclick=()=>{const expanded=document.querySelector('.workspace').classList.toggle('map-expanded');$('expand-map').textContent=expanded?'Restore layout':'Expand map';$('expand-map').setAttribute('aria-pressed',String(expanded));drawMap();};
