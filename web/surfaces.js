// Owner: U3. Actual map-frame LiDAR triangles, depth-tested and lit; no inferred walls.
export function surfaceVertices(mesh) {
  const data = new Float32Array(mesh.triangles.length * 18);
  let offset = 0;
  for (const triangle of mesh.triangles) {
    const [a,b,c] = triangle.map(i => mesh.vertices[i]);
    const u = b.map((v,i)=>v-a[i]), v = c.map((v,i)=>v-a[i]);
    const n = [u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0]];
    const length = Math.hypot(...n) || 1;
    for (const p of [a,b,c]) { data.set([...p,...n.map(x=>x/length)],offset); offset+=6; }
  }
  return data;
}

export class SurfaceRenderer {
  constructor(canvas) { this.canvas=canvas; this.buffers=[]; this.gl=canvas.getContext('webgl',{alpha:true,antialias:true,preserveDrawingBuffer:true}); }
  initialize() {
    const gl=this.gl;
    if (!gl || gl.isContextLost()) throw new Error('3D surfaces require WebGL. Enable browser graphics acceleration and reload.');
    if (this.program) return;
    const shader=(type,source)=>{
      const s=gl.createShader(type);gl.shaderSource(s,source);gl.compileShader(s);
      if (!gl.getShaderParameter(s,gl.COMPILE_STATUS)) throw new Error('Could not initialize scan surface rendering.');
      return s;
    };
    const vertex=shader(gl.VERTEX_SHADER,`
      attribute vec3 position; attribute vec3 normal;
      uniform vec3 center; uniform vec4 camera; uniform vec2 scale;
      uniform float radius; varying vec3 surfaceNormal; varying float height;
      void main(){
        vec3 p=position-center;
        float rx=camera.x*p.x+camera.y*p.z;
        float rz=-camera.y*p.x+camera.x*p.z;
        float y=camera.z*p.y-camera.w*rz;
        float distance=radius*3.0-(camera.w*p.y+camera.z*rz);
        float near=radius*0.1; float far=radius*6.0;
        gl_Position=vec4(rx*scale.x,y*scale.y,(far+near)/(far-near)*distance-2.0*far*near/(far-near),distance);
        surfaceNormal=normal; height=position.y;
      }`);
    const fragment=shader(gl.FRAGMENT_SHADER,`
      precision highp float; varying vec3 surfaceNormal; varying float height;
      uniform float cutHeight;
      void main(){
        if(height>cutHeight) discard;
        float light=0.42+0.58*abs(dot(normalize(surfaceNormal),normalize(vec3(0.35,0.8,0.5))));
        gl_FragColor=vec4(vec3(0.79,0.82,0.78)*light,1.0);
      }`);
    this.program=gl.createProgram();gl.attachShader(this.program,vertex);gl.attachShader(this.program,fragment);gl.linkProgram(this.program);
    if (!gl.getProgramParameter(this.program,gl.LINK_STATUS)) throw new Error('Could not link scan surface rendering.');
    gl.deleteShader(vertex);gl.deleteShader(fragment);
  }
  clearMeshes() {
    for(const item of this.buffers) this.gl.deleteBuffer(item.buffer);
    this.buffers=[];this.clear();
  }
  add(mesh) {
    this.initialize();const gl=this.gl, data=surfaceVertices(mesh), buffer=gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER,buffer);gl.bufferData(gl.ARRAY_BUFFER,data,gl.STATIC_DRAW);
    this.buffers.push({buffer,count:data.length/6});
  }
  clear() { if(this.gl) this.gl.clear(this.gl.COLOR_BUFFER_BIT|this.gl.DEPTH_BUFFER_BIT); }
  draw(scene,width,height,zoom,yaw,pitch,cutHeight) {
    if(!this.buffers.length) return;
    this.initialize();const gl=this.gl,dpr=window.devicePixelRatio||1;
    this.canvas.width=Math.round(width*dpr);this.canvas.height=Math.round(height*dpr);
    gl.viewport(0,0,this.canvas.width,this.canvas.height);gl.clearColor(0,0,0,0);this.clear();
    gl.enable(gl.DEPTH_TEST);gl.disable(gl.CULL_FACE);gl.useProgram(this.program);
    const uniform=name=>gl.getUniformLocation(this.program,name);
    const focal=Math.max(40,Math.min(width-100,height-100))*2*zoom;
    gl.uniform3fv(uniform('center'),scene.center);gl.uniform4f(uniform('camera'),Math.cos(yaw),Math.sin(yaw),Math.cos(pitch),Math.sin(pitch));
    gl.uniform2f(uniform('scale'),2*focal/width,2*focal/height);gl.uniform1f(uniform('radius'),scene.radius);gl.uniform1f(uniform('cutHeight'),cutHeight);
    for(const {buffer,count} of this.buffers){
      gl.bindBuffer(gl.ARRAY_BUFFER,buffer);
      for(const [name,offset] of [['position',0],['normal',12]]){
        const loc=gl.getAttribLocation(this.program,name);gl.enableVertexAttribArray(loc);gl.vertexAttribPointer(loc,3,gl.FLOAT,false,24,offset);
      }
      gl.drawArrays(gl.TRIANGLES,0,count);
    }
  }
}
