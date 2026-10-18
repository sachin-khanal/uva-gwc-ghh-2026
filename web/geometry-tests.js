import {buildEstimatedBuilding,wallOccludes} from "./building-model.js";
import {walkingProjection,sampleJourney,visiblePlaces,createFloorTour,namedPlaces,sampleFloorTour} from "./walkthrough.js";
// Owner: U3. Schema 3 and real 3D geometry regressions, independent of live cloud.
import { projection,roomCorners,parseOBJ,verifyMesh } from "./geometry3d.js";
import { validateMap } from "./router.js";
import { SurfaceRenderer, surfaceVertices } from "./surfaces.js";
import { parseOBJFast, verifyMeshFast, surfaceBuffer, MeshCache } from "./meshloader.js";
export async function runGeometryChecks(sample) {
  const results = [];
  const assert = (v) => { if (!v) throw new Error("Assertion failed"); };
  const check = async (name,fn) => {
    try { await fn(); results.push({name,pass:true}); }
    catch(error){results.push({name,pass:false,error:error.message});}
  };
  await check("Schema 4 stair metadata survives validation",()=>{
    const map=structuredClone(sample);map.schemaVersion=4;
    const node=map.nodes.find(n=>n.kind==='stairs');
    assert(node);node.stairs={direction:'both',railings:'both',stepCount:12};
    validateMap(map);
    node.stairs.stepCount=-1;
    let rejected=false;try{validateMap(map);}catch{rejected=true;}assert(rejected);
  });
  await check("3D projection uses height and yaw",()=>{
    const p=projection([[0,0,0],[0,3,0]],500,400);
    assert(p.project([0,0,0]).y!==p.project([0,3,0]).y);
    const a=projection([[0,0,0],[4,0,3]],500,400,1,0).project([4,0,3]);
    const b=projection([[0,0,0],[4,0,3]],500,400,1,1).project([4,0,3]);
    assert(a.x!==b.x);
  });
  await check("Room footprint uses measured rectangle",()=>{
    const corners=roomCorners({center:[0,0,0],halfExtents:[2,3],yaw:0});
    assert(corners.length===4 && corners[0][0]===-2 && corners[2][2]===3);
  });
  await check("OBJ supports actual triangular geometry",()=>{
    const mesh=parseOBJ("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n");
    assert(mesh.vertices.length===3 && mesh.triangles[0][2]===2);
  });
  await check("OBJ rejects out-of-range indices",()=>{
    let failed=false;try{parseOBJ("v 0 0 0\nf 1 2 3");}catch{failed=true;}assert(failed);
  });
  await check("Mesh bytes and SHA-256 match the manifest",async()=>{
    const bytes=new TextEncoder().encode("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n").buffer;
    const sha256=[...new Uint8Array(await crypto.subtle.digest("SHA-256",bytes))].map(b=>b.toString(16).padStart(2,"0")).join("");
    const asset={byteCount:bytes.byteLength,sha256,boundsMin:[0,0,0],boundsMax:[1,1,0]};
    assert((await verifyMesh(asset,bytes)).vertices.length===3);
    let failed=false;try{await verifyMesh({...asset,sha256:"0".repeat(64)},bytes);}catch{failed=true;}assert(failed);
  });
  // ---- fast scan pipeline (meshloader.js) ----
  const syntheticObj=(triangles,{crlf=false,extras=true}={})=>{
    const lines=extras?["# generated","o scan","vn 0 0 1"]:[];const vertices=triangles+2;
    for(let i=0;i<vertices;i++)lines.push(`v ${(i%97)*0.013-0.5} ${((i*7)%89)*0.011} ${(i%53)*-0.02}`);
    for(let t=0;t<triangles;t++)lines.push(extras&&t%2?`f ${t+1}//1 ${t+2}//1 ${t+3}//1`:`f ${t+1} ${t+2} ${t+3}`);
    return lines.join(crlf?"\r\n":"\n")+"\n";
  };
  await check("Fast OBJ parser agrees with the reference parser (comments, vn, a//b faces, CRLF)",()=>{
    for(const options of [{},{crlf:true},{extras:false}]){
      const text=syntheticObj(500,options),slow=parseOBJ(text),fast=parseOBJFast(text);
      assert(fast.vertexCount===slow.vertices.length&&fast.triangleCount===slow.triangles.length);
      for(let i=0;i<slow.vertices.length;i++)for(let k=0;k<3;k++)assert(Math.abs(fast.positions[i*3+k]-slow.vertices[i][k])<1e-6);
      for(let t=0;t<slow.triangles.length;t++)for(let k=0;k<3;k++)assert(fast.indices[t*3+k]===slow.triangles[t][k]);
    }
  });
  await check("Fast OBJ parser rejects what the reference parser rejects",()=>{
    for(const bad of ["v 0 0 0\nf 1 2 3\n","v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 1 2\n","v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3 1\n","v 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n",
      "v 0 0 x\nv 1 0 0\nv 0 1 0\nf 1 2 3\n","v 0 0 0\nv 1 0 0\nv 0 1 0\nf 0 1 2\n","v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1.5 2 3\n","v 0 0 0\nv 1 0 0\nv 0 1 0\n","# nothing\n","v 0 0 0\nv 1 0 0\nv 0 1 0\nf -1 2 3\n"]){
      let fast=false,slow=false;try{parseOBJFast(bad);}catch{fast=true;}try{parseOBJ(bad);}catch{slow=true;}
      assert(fast&&slow);
    }
  });
  await check("Fast OBJ parser handles whitespace and rejects typed-array overflow",()=>{
    const text="  v 0 0 0\n\tv 1 0 0\n v 0 1 0\n  f 1 2 3\n";
    assert(parseOBJFast(text).triangleCount===1);
    for(const bad of [text.replace("f 1 2 3","f 4294967297 2 3"),text.replace("v 1 0 0","v 1e100 0 0")]){
      let rejected=false;try{parseOBJFast(bad);}catch{rejected=true;}assert(rejected);
    }
  });
  await check("Fast OBJ parser enforces the manifest bounds",()=>{
    const text="v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n";
    assert(parseOBJFast(text,{boundsMin:[0,0,0],boundsMax:[1,1,0]}).vertexCount===3);
    let failed=false;try{parseOBJFast(text,{boundsMin:[0,0,0],boundsMax:[0.5,1,0]});}catch{failed=true;}assert(failed);
  });
  await check("verifyMeshFast checks size, SHA-256, then parses",async()=>{
    const bytes=new TextEncoder().encode("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n").buffer;
    const sha256=[...new Uint8Array(await crypto.subtle.digest("SHA-256",bytes))].map(b=>b.toString(16).padStart(2,"0")).join("");
    const asset={byteCount:bytes.byteLength,sha256,boundsMin:[0,0,0],boundsMax:[1,1,0]};
    const mesh=await verifyMeshFast(asset,bytes);assert(mesh.vertexCount===3&&mesh.triangleCount===1&&mesh.positions instanceof Float32Array);
    for(const bad of [{...asset,sha256:"0".repeat(64)},{...asset,byteCount:5},{...asset,boundsMax:[0.1,0.1,0]}]){
      let failed=false;try{await verifyMeshFast(bad,bytes);}catch{failed=true;}assert(failed);
    }
  });
  await check("surfaceBuffer matches the reference layout: position, unit normal, colour",()=>{
    let seed=7;const rnd=()=>(seed=(seed*1103515245+12345)%2147483648)/2147483648; // well-conditioned triangles: exactly collinear ones round differently in Float32
    const lines=[];for(let i=0;i<120;i++)lines.push(`v ${rnd()} ${rnd()} ${rnd()}`);for(let t=0;t<40;t++)lines.push(`f ${t*3+1} ${t*3+2} ${t*3+3}`);
    const text=lines.join("\n")+"\n",slow=parseOBJ(text),fast=parseOBJFast(text);
    const reference=surfaceVertices(slow),data=surfaceBuffer(fast);
    assert(data.length===fast.triangleCount*27);
    for(let v=0;v<fast.triangleCount*3;v++){
      for(let k=0;k<6;k++)assert(Math.abs(data[v*9+k]-reference[v*6+k])<1e-4);
      assert(Math.abs(data[v*9+6]-0.79)<1e-6&&Math.abs(data[v*9+8]-0.78)<1e-6);
    }
  });
  await check("Mesh cache is content-addressed and evicts the least recently used",()=>{
    const cache=new MeshCache(2);cache.put("a",{n:1});cache.put("b",{n:2});assert(cache.get("a").n===1);cache.put("c",{n:3});
    assert(cache.get("b")===null&&cache.get("a").n===1&&cache.get("c").n===3&&cache.get("zzz")===null);
  });
  await check("Large scan budget: 150k triangles parse and buffer fast, with typed arrays only",()=>{
    const text=syntheticObj(150000,{extras:false}); // plain 'f a b c' lines: an unbounded indexOf('/') made this quadratic once
    let t0=performance.now();const mesh=parseOBJFast(text);const parse=performance.now()-t0;
    t0=performance.now();const data=surfaceBuffer(mesh);const buffer=performance.now()-t0;
    assert(mesh.triangleCount===150000&&data.length===150000*27);
    assert(parse<800&&buffer<400,`parse ${Math.round(parse)} ms, buffer ${Math.round(buffer)} ms`);
  });
  await check("SurfaceRenderer accepts a typed scan mesh (browser only)",()=>{
    if(typeof document==="undefined")return; // browser-only check is reported as skipped below
    const renderer=new SurfaceRenderer(document.createElement("canvas"));renderer.add(parseOBJFast("v -1 -1 0\nv 1 -1 0\nv 0 1 0\nf 1 2 3\n"));
    assert(renderer.buffers.length===1&&renderer.buffers[0].count===3);
  });
  for(const schemaVersion of [0,5,"3",true]) await check(`Reject unsupported format ${schemaVersion}`,()=>{
    let failed=false;try{validateMap({...sample,schemaVersion});}catch{failed=true;}assert(failed);
  });
  await check("Schema 3 rejects malformed room and mesh fields",()=>{
    for(const change of [(m)=>m.nodes[5].extent.halfExtents=[-1,2],(m)=>m.meshAssets=[{id:"../bad"}]]) {
      const m=structuredClone(sample);change(m);let failed=false;try{validateMap(m);}catch{failed=true;}assert(failed);
    }
  });
  await check("Surface renderer keeps every triangle and unit face normals",()=>{
    const mesh={vertices:[[-1,-1,0],[1,-1,0],[0,1,0]],triangles:Array.from({length:12001},()=>[0,1,2])};
    const data=surfaceVertices(mesh);assert(data.length===12001*18 && Math.abs(data[5]-1)<0.00001);
  });
  await check("WebGL renders captured surfaces and clips upper geometry",()=>{
    if(typeof document==="undefined")return;
    const canvas=document.createElement("canvas"), renderer=new SurfaceRenderer(canvas);
    renderer.add({vertices:[[-1,-1,0],[1,-1,0],[0,1,0]],triangles:[[0,1,2]]});
    const scene=projection([[-1,-1,0],[1,1,0]],200,200,1,0,0);
    renderer.draw(scene,200,200,1,0,0,2);
    const gl=renderer.gl, pixel=new Uint8Array(4);
    gl.readPixels(canvas.width/2,canvas.height/2,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel);
    assert(pixel[3]===255);
    const eyeScene={...scene,...walkingProjection([0,0,2],0,0,200,200)};
    renderer.draw(eyeScene,200,200,1,0,0,2);
    gl.readPixels(canvas.width/2,canvas.height/2,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel);assert(pixel[3]===255);

    renderer.draw(scene,200,200,1,0,0,-2);
    gl.readPixels(canvas.width/2,canvas.height/2,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel);
    assert(pixel[3]===0);renderer.clearMeshes();assert(renderer.buffers.length===0);
  });
  await check("Walking projection hides points behind camera",()=>{
    const p=walkingProjection([0,1.6,0],0,0,800,600);
    assert(p.project([0,1.6,-3]).visible===true);assert(p.project([0,1.6,3]).visible===false);
    assert(Math.abs(p.project([0,1.6,-3]).x-400)<.001);
  });
  await check("Journey follows the stored bend, not a diagonal shortcut",()=>{
    const nodes=[{position:[0,0,0]},{position:[0,0,-2]},{position:[2,0,-2]}];
    const mid=sampleJourney(nodes,1.5,2);assert(mid.position[0]===1&&mid.position[2]===-2);
    assert(sampleJourney(nodes,10).done);assert(sampleJourney([],0)===null);
  });
  await check("Whitespace labels do not expose an unlabeled triangle",()=>{
    const nodes=[{label:'Room'},{label:' '},{label:null}];assert(visiblePlaces({nodes}).length===1);assert(visiblePlaces({nodes},true).length===3);
  });
  await check("Estimated building preserves every named place without mutating the map",()=>{
    const before=JSON.stringify(sample),model=buildEstimatedBuilding(sample);
    assert(model.features.length===sample.nodes.filter(n=>n.label?.trim()).length);
    assert(model.sourcePoints===sample.nodes.length&&model.mesh.triangles.length>100);
    assert(JSON.stringify(sample)===before);
    assert(model.mesh.colors.length===model.mesh.triangles.length);
    for(const triangle of model.mesh.triangles)assert(triangle.every(i=>i>=0&&i<model.mesh.vertices.length));
    assert(model.features.every(f=>f.center.every(Number.isFinite)));
  });
  await check("Empty building needs no estimated walls",()=>assert(buildEstimatedBuilding({nodes:[],edges:[]})===null));
  await check("Indoor preview has full-height walls and a ceiling",()=>{
    const model=buildEstimatedBuilding(sample);assert(model.assumptions.wallHeight===2.8);
    assert(model.ceiling.ceiling&&model.ceiling.triangles.length>0);
    assert(model.wallSegments.length>0);
  });
  await check("Walls hide distant labels without blocking clear door gaps",()=>{
    assert(wallOccludes([0,1.6,0],[0,1.6,-4],[{a:[-1,-2],b:[1,-2]}]));
    assert(!wallOccludes([0,1.6,0],[0,1.6,-4],[{a:[1,-2],b:[2,-2]}]));
    assert(walkingProjection([0,0,0],0,0,800,600).focal===360);
  });
  await check("Floor tour starts beside Room 412 and returns via mapped connections",()=>{
    const map={nodes:[{id:'a',kind:'room',label:'Room 412',position:[0,0,1]},{id:'b',kind:'corridor',position:[0,0,0]},{id:'c',kind:'corridor',position:[3,0,0]},{id:'d',kind:'room',label:'Room 414',position:[3,0,1]}],edges:[{from:'a',to:'b',distance:1},{from:'b',to:'c',distance:3},{from:'c',to:'d',distance:1}]};
    const tour=createFloorTour(map);assert(tour.start.id==='b'&&tour.near==='Room 412');
    assert(tour.nodes.some(n=>n.id==='c'));assert(tour.nodes.at(-1).id==='b');
    for(let i=1;i<tour.nodes.length;i++)assert(map.edges.some(e=>[e.from,e.to].includes(tour.nodes[i-1].id)&&[e.from,e.to].includes(tour.nodes[i].id)));
    assert(createFloorTour({nodes:[],edges:[]})===null);
  });
  await check("Named-only view keeps Room 412 and drops duplicate 412 and corridors",()=>{
    const map={nodes:[{id:'a',label:'Room 412',kind:'room'},{id:'b',label:'412',kind:'room'},{id:'c',kind:'corridor'},{id:'d',label:'Room 414',kind:'room'}]};
    const names=namedPlaces(map).map(n=>n.label);assert(names.length===2&&names.includes('Room 412')&&names.includes('Room 414')&&!names.includes('412'));
  });
  await check("Door frames are compact and attached to room/corridor boundaries",()=>{
    const model=buildEstimatedBuilding(sample),doors=model.features.filter(f=>f.doorAttached);
    assert(doors.length>0);for(const f of doors){assert(f.doorWidth===.82&&f.doorHeight===2.05);assert(f.door.every(Number.isFinite));}
    assert(model.features.length===namedPlaces(sample).length);
  });
  await check("Tour pauses at checkpoints and resumes without skipping movement",()=>{
    const tour={nodes:[{position:[0,0,0]},{position:[0,0,-6]}],stops:[{distance:3,label:'elevator',seconds:3}]};
    assert(sampleFloorTour(tour,3,1.5).paused==='elevator');
    assert(sampleFloorTour(tour,3,1.5).position[2]===-3);
    assert(!sampleFloorTour(tour,5.5,1.5).paused&&sampleFloorTour(tour,5.5,1.5).position[2]<-3);
    assert(sampleFloorTour(tour,8,1.5).done);
  });
  if(typeof document==="undefined") for(const test of results) {
    if(test.name==="SurfaceRenderer accepts a typed scan mesh (browser only)" || test.name==="WebGL renders captured surfaces and clips upper geometry") test.skipped=true;
  }
  return results;
}
