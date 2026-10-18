import {key,route} from "./router.js";
// Owner: U3. Perspective preview follows stored graph connections; never invents walls.
export const hasLabel = n => typeof n.label === 'string' && n.label.trim().length > 0;
export function namedPlaces(map){
  const hasRoom412=map.nodes.some(n=>/^room\s*412$/i.test(n.label?.trim()||''));
  return map.nodes.filter(n=>hasLabel(n)&&n.kind!=='corridor'&&!(hasRoom412&&n.label.trim()==='412'));
}
export const visiblePlaces = (map, all = false) => all?map.nodes:namedPlaces(map);
export function walkingProjection(eye, yaw, pitch, width, height, zoom = 1) {
  const focal = Math.min(width, height) * .6 * zoom;
  const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch);
  return { eye, focal, walking: true, project(p) {
    const [x,y,z] = p.map((v,i) => v-eye[i]);
    const horizontal = cy*x+sy*z, forward = sy*x-cy*z;
    const vertical = cp*y-sp*forward, depth = sp*y+cp*forward;
    if (depth < .12) return {x:-10000,y:-10000,depth,visible:false};
    return {x:width/2+horizontal*focal/depth,y:height/2-vertical*focal/depth,depth,visible:true};
  }};
}
export function sampleJourney(nodes, elapsed, speed = 1.8) {
  if (!nodes.length) return null;
  let remaining = Math.max(0,elapsed)*speed;
  for (let i=1;i<nodes.length;i++) {
    const a=nodes[i-1].position,b=nodes[i].position,length=Math.hypot(...b.map((v,k)=>v-a[k]));
    if (length>0 && remaining<length) return {position:a.map((v,k)=>v+(b[k]-v)*remaining/length),yaw:Math.atan2(b[0]-a[0],-(b[2]-a[2])),done:false};
    remaining-=length;
  }
  return {position:[...nodes.at(-1).position],done:true};
}

// Tour stays on mapped hallways beside named places, starting near Room 412 when present.
export function createFloorTour(map,allowStairs=false){
  const byID=new Map(map.nodes.map(n=>[key(n.id),n]));
  const named=namedPlaces(map),preferred=named.find(n=>/^room\s*412$/i.test(n.label.trim()))||named.find(n=>/^412$/i.test(n.label.trim()))||named[0]||map.nodes[0];
  if(!preferred)return null;
  function anchor(n){const neighbors=map.edges.filter(e=>key(e.from)===key(n.id)||key(e.to)===key(n.id)).map(e=>byID.get(key(key(e.from)===key(n.id)?e.to:e.from))).filter(Boolean);return neighbors.find(v=>v.kind==='corridor'||v.kind==='junction')||n;}
  const room401=named.find(n=>/^room\s*401$/i.test(n.label.trim())),finish=named.find(n=>/^room\s*420\s*[-?]\s*428$/i.test(n.label.trim()));
  if(room401&&finish){
    const distance=(a,b)=>Math.hypot(a.position[0]-b.position[0],a.position[2]-b.position[2]);
    const stairs=named.filter(n=>n.kind==='stairs').sort((a,b)=>distance(a,room401)-distance(b,room401))[0];
    const start=anchor(stairs||room401),nodes=[start],stops=[],skipped=[];let current=start,total=0;
    const itinerary=['Room 401','Room 402','Room 403','Room 404','Room 405','Room 406','Room 407','Room 408','Room 409','Room 410','Room 411','Room 412','Room 414','Room 442','Room 434','Room 432','Room 440','Room 430','Room 429','elevator','bathroom','Room 427','Room 425',finish.label];
    for(const name of itinerary){
      const choices=named.filter(n=>n.label.trim().toLowerCase()===name.toLowerCase());let best=null,place=null,cost=Infinity;
      for(const choice of choices){const path=route(map,current.id,anchor(choice).id,allowStairs);if(!path)continue;const length=path.slice(1).reduce((v,n,i)=>v+Math.hypot(...n.position.map((x,k)=>x-path[i].position[k])),0);if(length<cost){best=path;place=choice;cost=length;}}
      if(!best){skipped.push(...choices);continue;}
      nodes.push(...best.slice(1));total+=cost;current=best.at(-1);
      if(/elevator|bathroom/i.test(place.label))stops.push({distance:total,label:place.label,seconds:3});
    }
    return {nodes,start,near:'stairs near Room 401',finish:finish.label,skipped,returnsToStart:false,stops};
  }
  const start=anchor(preferred),remaining=new Map(named.map(n=>[key(anchor(n).id),anchor(n)])),nodes=[start],skipped=[];remaining.delete(key(start.id));let current=start;
  while(remaining.size){let next=null,best=null,cost=Infinity;
    for(const n of remaining.values()){const path=route(map,current.id,n.id,allowStairs);if(!path)continue;const length=path.slice(1).reduce((v,p,i)=>v+Math.hypot(...p.position.map((x,k)=>x-path[i].position[k])),0);if(length<cost){cost=length;next=n;best=path;}}
    if(!next){skipped.push(...remaining.values());break;}
    nodes.push(...best.slice(1));for(const n of best)remaining.delete(key(n.id));current=next;
  }
  const back=route(map,current.id,start.id,allowStairs);if(back)nodes.push(...back.slice(1));
  return {nodes,start,near:preferred.label||'starting point',skipped,returnsToStart:!!back};
}

// Timed pauses do not move the camera, then travel resumes from the same position.
export function sampleFloorTour(tour,elapsed,speed=1.5){
  let time=Math.max(0,elapsed),paused=null;
  for(const stop of tour.stops||[]){const at=stop.distance/speed;if(time<at)break;if(time<at+stop.seconds){paused=stop.label;time=at;break;}time-=stop.seconds;}
  return {...sampleJourney(tour.nodes,time,speed),paused,travelTime:time};
}
