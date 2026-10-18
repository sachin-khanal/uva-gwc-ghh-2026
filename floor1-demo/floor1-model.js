// Owner: U3. Concept geometry visually traced from the supplied first-floor image.
// Scale (0.1 m/image pixel), 3.2 m height, doors and furniture are estimates.
export const palette={auditorium:'#eab3be',lab:'#b6dce7',office:'#b1d293',meeting:'#e8df9e',lobby:'#df8e6f',cafe:'#e8bf8b',commons:'#d6dfd3',service:'#d1d2cb'};
export const rooms=[
 {name:'Entry lobby',type:'lobby',open:true,poly:[[57,325],[105,325],[110,402],[65,412]],door:1},
 {name:'West lab A',type:'lab',poly:[[50,240],[126,240],[126,320],[50,320]],door:2},
 {name:'West lab B',type:'lab',poly:[[126,240],[202,240],[202,320],[126,320]],door:2},
 {name:'Lab C',type:'lab',poly:[[205,240],[230,240],[230,280],[205,280]],door:1},
 {name:'Lab D',type:'lab',poly:[[205,282],[232,282],[232,322],[205,322]],door:1},
 {name:'Meeting 1',type:'meeting',poly:[[250,241],[298,241],[298,302],[250,302]],door:2},
 {name:'Auditorium',type:'auditorium',poly:[[307,195],[345,184],[451,185],[490,197],[475,321],[310,318]],door:4},
 {name:'North foyer',type:'commons',poly:[[285,91],[410,91],[499,66],[478,137],[450,180],[285,180]],door:4},
 {name:"Einstein’s café",type:'cafe',open:true,poly:[[242,349],[293,349],[293,389],[242,389]],door:0},
 {name:'Marked meeting space',type:'meeting',poly:[[300,331],[329,331],[329,388],[300,388]],door:1},
 {name:'Davis Commons',type:'commons',poly:[[337,353],[421,353],[421,454],[337,454]],door:0},
 {name:'Office 1',type:'office',poly:[[93,440],[115,440],[115,480],[93,480]],door:0},
 {name:'Office 2',type:'office',poly:[[118,441],[143,441],[143,481],[118,481]],door:0},
 {name:'Office 3',type:'office',poly:[[146,443],[174,443],[174,484],[146,484]],door:0},
 {name:'Meeting 2',type:'meeting',poly:[[177,444],[230,444],[230,486],[177,486]],door:0},
 {name:'Office 4',type:'office',poly:[[233,447],[255,447],[255,488],[233,488]],door:0},
 {name:'Office 5',type:'office',poly:[[258,449],[282,449],[282,490],[258,490]],door:0},
 {name:'Meeting 3',type:'meeting',poly:[[285,451],[338,451],[338,492],[285,492]],door:0},
 {name:'Meeting 4',type:'meeting',poly:[[341,464],[394,464],[394,497],[341,497]],door:0},
 {name:'Meeting 5',type:'meeting',poly:[[398,465],[453,465],[453,500],[398,500]],door:0},
 {name:'East lab E',type:'lab',poly:[[245,395],[320,395],[320,430],[245,430]],door:3},
 {name:'West stairs',type:'service',poly:[[31,424],[65,435],[54,470],[20,459]],door:0},
 {name:'East stairs',type:'service',poly:[[435,350],[482,357],[477,386],[435,381]],door:3}
];
export const point=([x,z],y=0)=>[(x-270)*.1,y,(z-300)*.1];
export const center=r=>point(r.poly.reduce((a,p)=>[a[0]+p[0]/r.poly.length,a[1]+p[1]/r.poly.length],[0,0]));
export function inside(x,z,poly){let hit=false;for(let i=0,j=poly.length-1;i<poly.length;j=i++){const a=point(poly[i]),b=point(poly[j]);if((a[2]>z)!=(b[2]>z)&&x<(b[0]-a[0])*(z-a[2])/(b[2]-a[2])+a[0])hit=!hit;}return hit;}
export const outline=[[50,234],[275,234],[275,85],[500,60],[490,200],[482,340],[493,355],[463,505],[83,485],[15,465],[40,405]];
function normalizeDoor(v){const l=Math.hypot(...v)||1;return v.map(x=>x/l);}
export function createModel(wallHeight=.85){
 const vertices=[],walls=[],ceilings=[];const color=h=>h.match(/\w\w/g).map(v=>parseInt(v,16)/255);
 function tri(a,b,c,h,dest=vertices){const rgb=color(h);for(const p of [a,b,c])dest.push(...p,...rgb);}
 function quad(a,b,c,d,h,dest){tri(a,b,c,h,dest);tri(a,c,d,h,dest);}
 function box(x,y,z,w,h,d,c){const a=[x-w/2,y,z-d/2],b=[x+w/2,y,z-d/2],cc=[x+w/2,y,z+d/2],dd=[x-w/2,y,z+d/2],up=p=>[p[0],y+h,p[2]];quad(up(a),up(b),up(cc),up(dd),c);for(const [p,q]of [[a,b],[b,cc],[cc,dd],[dd,a]])quad(p,q,up(q),up(p),c);}
 function wall(a,b,h=wallHeight){const p=point(a),q=point(b);walls.push({p,q});quad(p,q,[q[0],h,q[2]],[p[0],h,p[2]],'#dfdfd4');const dx=q[0]-p[0],dz=q[2]-p[2],l=Math.hypot(dx,dz),ox=dz/l*.06,oz=-dx/l*.06;quad([p[0]+ox,0,p[2]+oz],[q[0]+ox,0,q[2]+oz],[q[0]+ox,h,q[2]+oz],[p[0]+ox,h,p[2]+oz],'#f7f4e9');}
 // Concave building slab decomposed into strips; no fabricated surveyed envelope.
 box(-.5,-.24,6.5,42,.2,14,'#e7e4d6');box(12,-.24,-6,19,.2,31,'#e7e4d6');box(-12,-.24,-2,21,.2,9,'#e7e4d6');
 for(const r of rooms){const p=r.poly.map(v=>point(v,.015));for(let i=1;i<p.length-1;i++)tri(p[0],p[i],p[i+1],palette[r.type]);const roof=p.map(v=>[v[0],3.2,v[2]]);for(let i=1;!r.open&&i<roof.length-1;i++)tri(roof[0],roof[i],roof[i+1],'#e8e4d9',ceilings);
  r.poly.forEach((a,i)=>{if(r.open)return;const b=r.poly[(i+1)%r.poly.length];if(i!==r.door){wall(a,b);return;}const len=Math.hypot(b[0]-a[0],b[1]-a[1]),gap=Math.min(.42,8/len),mix=t=>a.map((v,k)=>v+(b[k]-v)*t),s=mix(.5-gap),e=mix(.5+gap);wall(a,s);wall(e,b);r.entry=point(mix(.5),0);const pp=point(s,.025),qq=point(e,.025);
   // Open door leaves and a contrasting jamb make room entrances visible at eye level.
   const dx=qq[0]-pp[0],dz=qq[2]-pp[2],length=Math.hypot(dx,dz),u=[dx/length,0,dz/length];
   const c=center(r),inward=normalizeDoor([c[0]-r.entry[0],0,c[2]-r.entry[2]]);
   const up=(p,y)=>[p[0],y,p[2]];
   for(const p of [pp,qq])box(p[0],0,p[2],.12,2.35,.12,'#39746a');
   quad(up(pp,2.25),up(qq,2.25),up(qq,2.4),up(pp,2.4),'#39746a');
   // A leaf swung toward the room leaves the center of the opening clear.
   const leafEnd=[pp[0]+inward[0]*Math.min(.75,length*.48),0,pp[2]+inward[2]*Math.min(.75,length*.48)];
   quad(up(pp,.04),up(leafEnd,.04),up(leafEnd,2.18),up(pp,2.18),'#bb9464');
   box(leafEnd[0],1.02,leafEnd[2],.07,.08,.07,'#e6c878');
   const signA=[r.entry[0]-u[0]*.6,2.5,r.entry[2]-u[2]*.6],signB=[r.entry[0]+u[0]*.6,2.5,r.entry[2]+u[2]*.6];
   quad(signA,signB,[signB[0],2.85,signB[2]],[signA[0],2.85,signA[2]],'#275e54');
   r.sign=[r.entry[0],2.68,r.entry[2]];
   quad([pp[0]-.12,.025,pp[2]-.12],[qq[0]+.12,.025,qq[2]-.12],[qq[0]+.12,.025,qq[2]+.12],[pp[0]-.12,.025,pp[2]+.12],'#368f84');});
  const c=center(r);if(r.type==='office'){box(c[0],0,c[2],1.1,.75,.6,'#f3e9ce');box(c[0],0,c[2]+.7,.45,.45,.45,'#648274');}
  if(r.type==='meeting'||r.type==='lab'){box(c[0],0,c[2],Math.min(2,(r.poly[1][0]-r.poly[0][0])*.045),.76,1.05,'#f8f5e7');for(const dz of [-.9,.9])for(const dx of [-.6,.6])box(c[0]+dx,0,c[2]+dz,.42,.46,.42,'#879a8d');}
 }
 // Auditorium stage and rows inspired by the visible seating banks; counts are illustrative.
 box(12.3,0,-10.4,10.4,.48,1.7,'#8e7066');for(let row=0;row<7;row++)for(let col=0;col<13;col++){if(col===3||col===9)continue;const x=5+col*1.02,z=-8.8+row*1.47;box(x,0,z,.58,.43,.57,'#b67482');box(x,.43,z+.25,.58,.45,.12,'#c68d99');}
 for(const [x,z]of [[8,7],[12,7],[8,11],[12,11]]){box(x,0,z,1,.74,1,'#e8c58e');for(const dx of [-.85,.85])box(x+dx,0,z,.4,.44,.4,'#8f9d86');}
 for(let i=0;i<9;i++){box(-22.5+i*.09,0,13.2+i*.26,2.4,.12+i*.14,.25,'#b1b8af');box(19,0,5.3+i*.25,2.6,.12+i*.14,.25,'#b1b8af');}
 return{vertices:new Float32Array(vertices),ceilings:new Float32Array(ceilings),walls};
}
export function canMove(x,z,walls){if(!inside(x,z,outline))return false;return !walls.some(({p,q})=>{const dx=q[0]-p[0],dz=q[2]-p[2],t=Math.max(0,Math.min(1,((x-p[0])*dx+(z-p[2])*dz)/(dx*dx+dz*dz)));return Math.hypot(x-p[0]-t*dx,z-p[2]-t*dz)<.22;});}
