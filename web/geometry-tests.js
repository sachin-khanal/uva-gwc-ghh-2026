// Owner: U3. Schema 3 and real 3D geometry regressions, independent of live cloud.
import { projection,roomCorners,parseOBJ,verifyMesh } from "./geometry3d.js";
import { validateMap } from "./router.js";
import { SurfaceRenderer, surfaceVertices } from "./surfaces.js";
export async function runGeometryChecks(sample) {
  const results = [];
  const assert = (v) => { if (!v) throw new Error("Assertion failed"); };
  const check = async (name,fn) => {
    try { await fn(); results.push({name,pass:true}); }
    catch(error){results.push({name,pass:false,error:error.message});}
  };
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
    const canvas=document.createElement("canvas"), renderer=new SurfaceRenderer(canvas);
    renderer.add({vertices:[[-1,-1,0],[1,-1,0],[0,1,0]],triangles:[[0,1,2]]});
    const scene=projection([[-1,-1,0],[1,1,0]],200,200,1,0,0);
    renderer.draw(scene,200,200,1,0,0,2);
    const gl=renderer.gl, pixel=new Uint8Array(4);
    gl.readPixels(canvas.width/2,canvas.height/2,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel);
    assert(pixel[3]===255);
    renderer.draw(scene,200,200,1,0,0,-2);
    gl.readPixels(canvas.width/2,canvas.height/2,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel);
    assert(pixel[3]===0);renderer.clearMeshes();assert(renderer.buffers.length===0);
  });
  return results;
}
