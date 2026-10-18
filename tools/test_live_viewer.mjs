// File: tools/test_live_viewer.mjs
// Owner: U3 / D (web integration).
// Purpose: opt-in real Supabase -> browser checks; no map publication or deletion.
// Uses an already-installed Playwright module; credentials stay in process/browser memory.
import {parseArgs} from 'node:util';
import {pathToFileURL} from 'node:url';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
const {values:options}=parseArgs({options:{config:{type:'string'},playwright:{type:'string'},browser:{type:'string'},base:{type:'string',default:'http://127.0.0.1:8041/web/'},artifacts:{type:'string',default:join(tmpdir(),'waypoint-live-evidence')}}});
const {chromium}=await import(options.playwright ? pathToFileURL(options.playwright).href : 'playwright-core');
import {readFile,mkdir} from 'node:fs/promises';
import {CloudLibrary} from '../web/cloud.js';
import {validateMap,route,routeSummary} from '../web/router.js';
import {verifyMeshFast} from '../web/meshloader.js';
const cfg=options.config?await readFile(options.config,'utf8'):'';
const value=k=>process.env[k]||cfg.match(new RegExp('^'+k+'\\s*=\\s*(.+)$','m'))?.[1].trim();
const configuredURL=value('SUPABASE_URL'),key=value('SUPABASE_ANON_KEY');
if(!configuredURL||!key)throw Error('Set SUPABASE_URL and SUPABASE_ANON_KEY or pass --config Local.xcconfig.');
const url=configuredURL.replace('https:/$()/','https://');
const lib=new CloudLibrary(url,key),rows=await lib.list();
if(!rows.length)throw Error('No live maps: this run cannot verify real buildings.');
const browser=await chromium.launch({...(options.browser?{executablePath:options.browser}:{}),headless:true,args:['--enable-unsafe-swiftshader']});
const errors=[],results=[];await mkdir(options.artifacts,{recursive:true});
const check=async(name,fn)=>{try{await fn();results.push({name,pass:true});console.log('PASS',name);}catch(e){results.push({name,pass:false,error:e.message});console.log('FAIL',name,e.message.slice(0,500));}};
const assert=(x,m)=>{if(!x)throw Error(m)};
try{
await check('all live map manifests and ordered node routes validate',async()=>{
 let pairs=0;
 for(const row of rows){const map=validateMap(row.map_json);assert(row.map_id.toLowerCase()===map.id.toLowerCase(),'building ID mismatch');
  for(const a of map.nodes)for(const b of map.nodes){const path=route(map,a.id,b.id);assert(path,'disconnected real map');assert(path[0].id===a.id&&path.at(-1).id===b.id,'wrong endpoints');assert(new Set(path.map(n=>n.id)).size===path.length,'route loop');assert(Number.isFinite(routeSummary(map,path).meters),'invalid route distance');pairs++;}}
 console.log('LIVE maps',rows.length,'ordered route pairs',pairs);
});
await check('every real published OBJ verifies; public download is denied',async()=>{
 let count=0;
 for(const row of rows){const map=validateMap(row.map_json);for(const asset of map.meshAssets??[]){
  const start=performance.now(),bytes=await lib.mesh(map,asset),mesh=await verifyMeshFast(asset,bytes);assert(mesh.triangleCount>0,'empty mesh');
  const path=`/storage/v1/object/public/meshes/${asset.storageOwner.toLowerCase()}/${map.id.toLowerCase()}/${asset.id.toLowerCase()}.obj`;
  const denied=await fetch(url+path,{headers:{apikey:key},signal:AbortSignal.timeout(20000)});assert(!denied.ok,'private scan exposed publicly');await denied.body?.cancel();
  count++;console.log('LIVE verified',bytes.byteLength,'bytes',mesh.triangleCount,'triangles',Math.round(performance.now()-start),'ms');}}
 assert(count>0,'no real OBJ available: scan verification missing');
});
const second=new CloudLibrary(url,key);
await check('two independent anonymous identities',async()=>{const a=await lib.ensureSession(),b=await second.ensureSession();assert(a.access_token!==b.access_token,'same identity');});
await check('second identity reads every published mesh',async()=>{for(const row of rows)for(const asset of row.map_json.meshAssets??[]){const bytes=await second.mesh(row.map_json,asset);await verifyMeshFast(asset,bytes);}});
await check('unauthenticated library read returns no rows',async()=>{const r=await fetch(url+'/rest/v1/canonical_buildings?select=map_id',{headers:{apikey:key}});assert(!r.ok||(await r.json()).length===0,'library exposed without sign-in');});
await check('invalid canonical input refused by live RPC',async()=>{const session=await lib.ensureSession();const r=await fetch(url+'/rest/v1/rpc/extend_building',{method:'POST',headers:{apikey:key,Authorization:'Bearer '+session.access_token,'Content-Type':'application/json'},body:JSON.stringify({incoming:{}})});assert(r.status===400,'malformed RPC status '+r.status);});
await check('live anonymous session refresh keeps identity',async()=>{const a=await lib.ensureSession();const user=a.user?.id;lib.session.until=0;const b=await lib.ensureSession();assert(b.access_token&&b.refresh_token,'no refreshed session');assert(!user||b.user?.id===user,'identity changed');});
const context=await browser.newContext({viewport:{width:1440,height:1000}}),page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));
await page.goto(options.base);
await page.clock.install();
await check('real browser connects to real Supabase library',async()=>{await page.locator('#connect-open').click();await page.locator('#project-url').fill(url);await page.locator('#anon-key').fill(key);await page.locator('#connect-submit').click();await page.waitForFunction(()=>document.getElementById('connection-state').textContent==='Library connected',null,{timeout:45000});assert(await page.locator('#buildings button').count()===rows.length,'not all real maps listed');});
for(let i=0;i<rows.length;i++){
const map=validateMap(rows[i].map_json);
await check('real map '+i+' opens and renders its geometry',async()=>{const ordered=[...rows].sort((a,b)=>Number((b.map_json.meshAssets??[]).length>0)-Number((a.map_json.meshAssets??[]).length>0));const card=page.locator('#buildings button').nth(ordered.findIndex(r=>r.map_id===rows[i].map_id));await card.click();await page.waitForFunction(name=>document.getElementById('map-title').textContent===name,map.name);if(map.meshAssets?.length){await page.waitForFunction(count=>document.getElementById('geometry-status').textContent.includes(`${count}/${count} verified`),map.meshAssets.length,{timeout:90000});assert(await page.locator('#surface-canvas').evaluate(c=>c.width>0&&c.height>0),'no surface canvas');}else assert((await page.locator('#geometry-status').textContent()).includes('Estimated'),'estimated geometry missing');assert(await page.locator('#surface-canvas').evaluate(c=>{const gl=c.getContext('webgl');if(!gl||!c.width||!c.height)return false;const pixels=new Uint8Array(c.width*c.height*4);gl.readPixels(0,0,c.width,c.height,gl.RGBA,gl.UNSIGNED_BYTE,pixels);for(let i=3;i<pixels.length;i+=4)if(pixels[i])return true;return false;}),'geometry uploaded but no visible surface pixels');await page.screenshot({path:join(options.artifacts,`map-${i}.png`),fullPage:true});});
await check('real map '+i+' route controls agree with stored graph',async()=>{const starts=await page.locator('#start-node option').evaluateAll(es=>es.map(e=>e.value)),goals=await page.locator('#goal-node option').evaluateAll(es=>es.map(e=>e.value));let best=null;for(const a of starts)for(const b of goals){const p=route(map,a,b);if(p){const summary=routeSummary(map,p);if(!best||summary.meters>best.meters)best={a,b,meters:summary.meters};}}assert(best,'no route');await page.locator('#start-node').selectOption(best.a);await page.locator('#goal-node').selectOption(best.b);const text=await page.locator('#route-result').textContent();assert(text.includes(best.meters.toFixed(1)),`distance mismatch expected ${best.meters.toFixed(1)} got ${text}`);await page.locator('#start-route').click();await page.clock.fastForward(300000);await page.waitForFunction(()=>document.getElementById('walk-status').textContent.startsWith('Arrived at '),null,{timeout:15000});await page.locator('#fit-map').click();await page.locator('#expand-map').click();assert(await page.locator('#expand-map').getAttribute('aria-pressed')==='true','expand');await page.locator('#expand-map').click();await page.locator('#walk-toggle').click();assert(await page.locator('#map-canvas').getAttribute('data-view')==='walk','walk mode');await page.locator('#fit-map').click();assert(await page.locator('#map-canvas').getAttribute('data-view')==='overview','fit');});
}
await check('live refresh retains an open real map',async()=>{const name=await page.locator('#map-title').textContent();await page.locator('#refresh').click();await page.waitForFunction(()=>!document.getElementById('refresh').disabled);assert(await page.locator('#map-title').textContent()===name,'selection changed');});
await check('offline refresh is visible and preserves real map/route controls',async()=>{await context.setOffline(true);await page.locator('#refresh').click();await page.waitForFunction(()=>document.getElementById('status').classList.contains('error'));assert(await page.locator('#start-node option').count()>0,'lost route selectors');await context.setOffline(false);await page.locator('#refresh').click();await page.waitForFunction(()=>!document.getElementById('refresh').disabled);});
await check('390px real map has no horizontal overflow',async()=>{await page.setViewportSize({width:390,height:844});await page.waitForTimeout(300);assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'horizontal overflow');await page.screenshot({path:join(options.artifacts,'mobile.png'),fullPage:true});});
await check('credentials stay out of persistent browser storage',async()=>{const x=await page.evaluate(()=>({local:localStorage.length,session:sessionStorage.length,cookies:document.cookie,key:document.getElementById('anon-key').value}));assert(x.local===0&&x.session===0&&!x.cookies&&!x.key,'credentials/storage not cleared');});
await check('loopback preview exposes assets and refuses credential/traversal paths',async()=>{
 const base=new URL(options.base);
 assert(['127.0.0.1','localhost','[::1]'].includes(base.hostname),'run boundary tests only against a local preview');
 for(const path of ['/web/','/web/app.js','/web/meshloader.js','/.env.local','/.mcp.json','/.git/config','/Config/Local.xcconfig','/supabase/migrations/0001_init.sql','/web/%2e%2e/Config/Local.xcconfig','/web/fixtures/']){
  const response=await fetch(base.origin+path);const expected=['/web/','/web/app.js','/web/meshloader.js'].includes(path)?200:404;
  assert(response.status===expected,'preview boundary '+path+' returned '+response.status);await response.body?.cancel();
 }
});
await check('real graph retains route controls when WebGL is unavailable',async()=>{
 const fallback=await chromium.launch({...(options.browser?{executablePath:options.browser}:{}),headless:true,args:['--disable-webgl']});
 try{const p=await fallback.newPage();const faults=[];p.on('pageerror',e=>faults.push(e.message));await p.goto(options.base);
 const map={...rows[0].map_json,meshAssets:[]};await p.locator('#map-file').setInputFiles({name:'real-graph.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify(map))});
 await p.waitForFunction(()=>document.getElementById('map-title').textContent!=='No building open');
 assert(await p.locator('#start-node option').count()>0,'route controls lost');assert(!faults.length,'unhandled fallback exception');
 assert((await p.locator('#geometry-status').textContent()).includes('WebGL'),'graphics failure not explained');
 }finally{await fallback.close();}
});
await check('no unhandled browser exceptions',async()=>assert(errors.length===0,errors.join('; ')));
console.log('RESULT',JSON.stringify(results));if(results.some(x=>!x.pass))process.exitCode=1;
}finally{await browser.close();}
