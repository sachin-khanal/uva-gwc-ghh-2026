// Owner: U3. Estimated architectural preview from saved positions; never a surveyed mesh.
// Corridor width, room size, floor offset and wall height are display assumptions only.
import {key,route} from './router.js';
import {hasLabel,namedPlaces,createFloorTour} from './walkthrough.js';
export function buildEstimatedBuilding(map,{namedOnly=false}={}) {
  if(!map.nodes.length)return null;
  const step=.18,width=1.8,wallHeight=2.8;
  const sorted=map.nodes.map(n=>n.position[1]).sort((a,b)=>a-b),floor=sorted[Math.floor(sorted.length/2)]-1.5;
  const byID=new Map(map.nodes.map(n=>[key(n.id),n])),adj=new Map(map.nodes.map(n=>[key(n.id),[]]));
  for(const e of map.edges){adj.get(key(e.from))?.push(byID.get(key(e.to)));adj.get(key(e.to))?.push(byID.get(key(e.from)));}
  const labels=namedPlaces(map),kept=new Map();
  if(map.nodes.length>1500||labels.length>300)throw Error('This map is too large for the estimated building preview.');
  const root=labels[0]||map.nodes[0];
  // Union shortest paths to destinations: dangling unlabeled loops do not become fake hallways.
  for(const goal of labels){const path=route(map,root.id,goal.id,true);if(!path)continue;for(let i=1;i<path.length;i++){const a=path[i-1],b=path[i];const id=[key(a.id),key(b.id)].sort().join(':');kept.set(id,[a,b]);}}
  // The fixed floor tour may use a loop connector absent from root-to-room shortest paths.
  const floorTour=createFloorTour(map,false);
  if(floorTour?.finish)for(let i=1;i<floorTour.nodes.length;i++){const a=floorTour.nodes[i-1],b=floorTour.nodes[i];kept.set([key(a.id),key(b.id)].sort().join(':'),[a,b]);}
  const cells=new Map(),features=[],vertices=[],triangles=[],colors=[],outer=[],partitions=new Map(),wallSegments=[],ceilingVertices=[],ceilingTriangles=[];
  const cellKey=(i,j)=>i+','+j;
  function paint(x,z,owner){if(cells.size>100000)throw Error('Estimated floor area exceeds the preview limit.');const i=Math.floor(x/step),j=Math.floor(z/step),id=cellKey(i,j);if(owner===0||!cells.has(id))cells.set(id,{i,j,owner});}
  function disk(x,z,r,owner){for(let i=Math.floor((x-r)/step);i<=Math.ceil((x+r)/step);i++)for(let j=Math.floor((z-r)/step);j<=Math.ceil((z+r)/step);j++)if(Math.hypot((i+.5)*step-x,(j+.5)*step-z)<=r)paint((i+.5)*step,(j+.5)*step,owner);}
  for(const [a,b] of (namedOnly?[]:kept.values())){
    const length=Math.hypot(b.position[0]-a.position[0],b.position[2]-a.position[2]),count=Math.max(1,Math.ceil(length/(step*.5)));
    for(let k=0;k<=count;k++)disk(a.position[0]+(b.position[0]-a.position[0])*k/count,a.position[2]+(b.position[2]-a.position[2])*k/count,width/2,0);
  }
  for(const [index,n] of labels.entries()){
    const neighbors=(adj.get(key(n.id))||[]).filter(Boolean),corridor=neighbors.find(v=>!hasLabel(v))||neighbors[0];
    let dx=corridor?n.position[0]-corridor.position[0]:1,dz=corridor?n.position[2]-corridor.position[2]:0,len=Math.hypot(dx,dz);if(len<.05){dx=1;dz=0;len=1;}dx/=len;dz/=len;
    const depth=n.kind==='stairs'?2.4:3.6,roomWidth=n.kind==='elevator'?2:3,center=[n.position[0]+dx*depth*.5,floor,n.position[2]+dz*depth*.5];
    const feature={id:n.id,label:n.label,kind:n.kind,center,door:[n.position[0],floor,n.position[2]],owner:index+1,dx,dz};features.push(feature);
    // Captured extents take precedence; missing sizes use the clearly marked display assumptions.
    if(n.extent){const e=n.extent,c=Math.cos(e.yaw),s=Math.sin(e.yaw);for(let x=-e.halfExtents[0];x<e.halfExtents[0];x+=step*.7)for(let z=-e.halfExtents[1];z<e.halfExtents[1];z+=step*.7)paint(e.center[0]+c*x+s*z,e.center[2]-s*x+c*z,index+1);feature.center=[...e.center];}
    else for(let across=-roomWidth/2;across<=roomWidth/2;across+=step*.7)for(let along=.1;along<=depth;along+=step*.7)paint(n.position[0]+dx*along-dz*across,n.position[2]+dz*along+dx*across,index+1);
    disk(n.position[0],n.position[2],.5,0);
  }
  // Place entrances on the actual room/corridor boundary, not at the scan tag position.
  const entryCandidates=new Map(features.map(f=>[f.owner,[]]));
  for(const cell of cells.values())if(cell.owner){
    for(const [di,dj]of [[1,0],[-1,0],[0,1],[0,-1]]){
      const other=cells.get(cellKey(cell.i+di,cell.j+dj));if(other?.owner!==0)continue;
      entryCandidates.get(cell.owner)?.push([(cell.i+.5+di*.5)*step,floor,(cell.j+.5+dj*.5)*step]);
    }
  }
  for(const f of features){
    const original=[...f.door],candidates=entryCandidates.get(f.owner)||[];
    const closest=candidates.reduce((best,p)=>!best||Math.hypot(p[0]-original[0],p[2]-original[2])<Math.hypot(best[0]-original[0],best[2]-original[2])?p:best,null);
    f.doorAttached=!!closest;f.doorWidth=.82;f.doorHeight=2.05;
    if(closest)f.door=[...closest];
  }
  function quad(a,b,c,d,color){const start=vertices.length;vertices.push(a,b,c,d);triangles.push([start,start+1,start+2],[start,start+2,start+3]);colors.push(color,color);}
  const floorColor=owner=>!owner?[.82,.85,.81]:[.76,.83,.74];
  for(const cell of cells.values()){
    const {i,j,owner}=cell,x=i*step,z=j*step;
    const roofStart=ceilingVertices.length;
    ceilingVertices.push([x,floor+wallHeight,z],[x+step,floor+wallHeight,z],[x+step,floor+wallHeight,z+step],[x,floor+wallHeight,z+step]);
    ceilingTriangles.push([roofStart,roofStart+1,roofStart+2],[roofStart,roofStart+2,roofStart+3]);
    quad([x,floor,z],[x+step,floor,z],[x+step,floor,z+step],[x,floor,z+step],floorColor(owner));
    for(const [di,dj]of [[1,0],[0,1],[-1,0],[0,-1]]){
      const other=cells.get(cellKey(i+di,j+dj));if(other?.owner===owner)continue;
      if(other&&(di<0||dj<0))continue;
      const mx=x+step/2+di*step/2,mz=z+step/2+dj*step/2;
      const doorOwner=owner||other?.owner,feature=doorOwner?features[doorOwner-1]:null;
      if(other&&feature?.doorAttached&&(owner===0||other.owner===0)&&Math.hypot(mx-feature.door[0],mz-feature.door[2])<feature.doorWidth/2+step*.4)continue;
      const ax=mx-dj*step/2,az=mz+di*step/2,bx=mx+dj*step/2,bz=mz-di*step/2;
      if(!other){outer.push([[ax,az],[bx,bz]]);continue;}
      const group=[owner,other.owner].sort((a,b)=>a-b).join(':');
      if(!partitions.has(group))partitions.set(group,[]);partitions.get(group).push([[ax,az],[bx,bz]]);
    }
  }
  // Simplify outer grid contours into straight architectural walls rather than voxel steps.
  const code=p=>p.map(v=>Math.round(v*10000)).join(','),links=new Map(outer.map(([a,b])=>[code(a),{a,b}]));
  function simplify(points,tolerance){if(points.length<3)return points;const a=points[0],b=points.at(-1),dx=b[0]-a[0],dz=b[1]-a[1],len=dx*dx+dz*dz;let far=0,index=0;
    for(let i=1;i<points.length-1;i++){const p=points[i],t=len?Math.max(0,Math.min(1,((p[0]-a[0])*dx+(p[1]-a[1])*dz)/len)):0,d=Math.hypot(p[0]-a[0]-dx*t,p[1]-a[1]-dz*t);if(d>far){far=d;index=i;}}
    if(far<=tolerance)return[a,b];return [...simplify(points.slice(0,index+1),tolerance).slice(0,-1),...simplify(points.slice(index),tolerance)];
  }
  function cleanWall(a,b){
    wallSegments.push({a,b});
    const [ax,az]=a,[bx,bz]=b,dx=bx-ax,dz=bz-az,length=Math.hypot(dx,dz);if(length<.02)return;
    const ox=-dz/length*.045,oz=dx/length*.045;
    // Cover tiny raster/contour discrepancies at the wall foot, avoiding white cracks on zoom.
    const fx=-dz/length*.18,fz=dx/length*.18;
    quad([ax+fx,floor+.001,az+fz],[bx+fx,floor+.001,bz+fz],[bx-fx,floor+.001,bz-fz],[ax-fx,floor+.001,az-fz],[.79,.84,.77]);
    const leftA=[ax+ox,floor,az+oz],leftB=[bx+ox,floor,bz+oz],rightA=[ax-ox,floor,az-oz],rightB=[bx-ox,floor,bz-oz],up=p=>[p[0],floor+wallHeight,p[2]];
    quad(leftA,leftB,up(leftB),up(leftA),[.9,.9,.85]);quad(rightB,rightA,up(rightA),up(rightB),[.88,.89,.83]);
    quad(up(leftA),up(leftB),up(rightB),up(rightA),[.66,.72,.66]);
  }
  // Simplify each internal partition separately so door gaps stay open.
  for(const segments of partitions.values()){
    const touching=new Map(),remaining=new Set(segments);
    for(const edge of segments)for(const p of edge){const id=code(p);if(!touching.has(id))touching.set(id,[]);touching.get(id).push(edge);}
    while(remaining.size){let edge=[...remaining].find(e=>e.some(p=>touching.get(code(p)).filter(e=>remaining.has(e)).length===1))||remaining.values().next().value;
      let start=edge.find(p=>touching.get(code(p)).filter(e=>remaining.has(e)).length===1)||edge[0],path=[start];
      while(edge){remaining.delete(edge);const end=code(edge[0])===code(start)?edge[1]:edge[0];path.push(end);start=end;edge=touching.get(code(end))?.find(e=>remaining.has(e));}
      const points=simplify(path,.16);for(let i=1;i<points.length;i++)cleanWall(points[i-1],points[i]);
    }
  }
  while(links.size){let edge=links.values().next().value;const path=[edge.a];while(edge){links.delete(code(edge.a));path.push(edge.b);edge=links.get(code(edge.b));}
    const mid=Math.floor(path.length/2),contour=[...simplify(path.slice(0,mid+1),.16).slice(0,-1),...simplify(path.slice(mid),.16)];
    for(let i=1;i<contour.length;i++)cleanWall(contour[i-1],contour[i]);
  }
  // Compact jambs sit flush in the opening; lintels connect them to the wall above.
  for(const f of features){if(!f.doorAttached)continue;const [x,,z]=f.door,half=f.doorWidth/2,tx=-f.dz*half,tz=f.dx*half,h=f.doorHeight;
    quad([x-tx,floor+.015,z-tz],[x+tx,floor+.015,z+tz],[x+tx+f.dx*.1,floor+.015,z+tz+f.dz*.1],[x-tx+f.dx*.1,floor+.015,z-tz+f.dz*.1],[.32,.48,.4]);
    for(const sign of [-1,1]){const a=[x+tx*sign,floor,z+tz*sign],b=[a[0]+f.dx*.045,floor,a[2]+f.dz*.045];quad(a,b,[b[0],floor+h,b[2]],[a[0],floor+h,a[2]],[.34,.45,.37]);}
    quad([x-tx,floor+h-.055,z-tz],[x+tx,floor+h-.055,z+tz],[x+tx,floor+h,z+tz],[x-tx,floor+h,z-tz],[.34,.45,.37]);
    quad([x-tx,floor+h,z-tz],[x+tx,floor+h,z+tz],[x+tx,floor+wallHeight,z+tz],[x-tx,floor+wallHeight,z-tz],[.9,.9,.85]);
  }
  if(!vertices.length)return null;
  const low=[Infinity,Infinity,Infinity],high=[-Infinity,-Infinity,-Infinity];for(const v of vertices)for(let i=0;i<3;i++){low[i]=Math.min(low[i],v[i]);high[i]=Math.max(high[i],v[i]);}
  return {mesh:{vertices,triangles,colors},ceiling:{vertices:ceilingVertices,triangles:ceilingTriangles,ceiling:true},wallSegments,features,floor,boundsMin:low,boundsMax:high,sourcePoints:map.nodes.length,corridorEdges:[...kept.keys()],assumptions:{corridorWidth:width,roomDepth:3.6,wallHeight}};
}

// Only hide labels actually behind an inferred wall; names remain in the room list.
export function wallOccludes(eye,target,segments){
  const dx=target[0]-eye[0],dz=target[2]-eye[2];
  return segments.some(({a,b})=>{const sx=b[0]-a[0],sz=b[1]-a[1],den=dx*sz-dz*sx;if(Math.abs(den)<1e-7)return false;
    const ax=a[0]-eye[0],az=a[1]-eye[2],t=(ax*sz-az*sx)/den,u=(ax*dz-az*dx)/den;return t>.03&&t<.96&&u>=0&&u<=1;
  });
}
