// Small procedural studio for image-based light. Rendered once into a PMREM; nothing is downloaded.
import * as THREE from 'three';

const DISTANCE=30,RADIANS=Math.PI/180;
// Azimuth runs from the camera side (+z) toward +x, elevation from the horizon, both in degrees.
// What each surface can mirror is fixed by the turntable: the upright glass only ever sees the ring
// just below the horizon, the deck top the band low behind the scene, and bevels everything above.
// Lights are neutral so the ivory and green keep their page values.
const BANDS=[
  {el:56,height:7,color:'#ffffff',power:3.1},  // ring light: soft fill from all round
  {el:47,height:1.1,color:'#ffffff',power:11}, // hairline ring: one crisp line along every bevel, at any turn
  {el:9,height:9,color:'#ffffff',power:1.3}    // low glow behind the horizon: soft sheen on the far deck
];
const PANELS=[
  {az:-140,el:68,w:34,h:22,color:'#ffffff',power:2.6,soft:.55}, // key softbox, same side as the shadow light
  {az:132,el:20,w:6,h:30,color:'#eaf3e4',power:3.2,soft:.45},   // cool strip behind, right: rim light
  {az:-150,el:-18,w:7,h:18,color:'#ffffff',power:3,soft:.4},    // low strips the glass sweeps past
  {az:66,el:-18,w:9,h:18,color:'#f4f8ee',power:2.4,soft:.4},
  {az:-50,el:-19,w:30,h:13,color:'#ffffff',power:2.3,soft:.15}  // faint sheen on the front card at rest
];

function falloff(draw){
  const canvas=document.createElement('canvas');canvas.width=canvas.height=64;
  const ctx=canvas.getContext('2d');ctx.fillStyle=draw(ctx);ctx.fillRect(0,0,64,64);
  const texture=new THREE.CanvasTexture(canvas);texture.colorSpace=THREE.SRGBColorSpace;return texture;
}
function stops(gradient,list){list.forEach(([at,color])=>gradient.addColorStop(at,color));return gradient;}
const glow=soft=>falloff(ctx=>stops(ctx.createRadialGradient(32,32,0,32,32,32),[[0,'#fff'],[soft,'#fff'],[1,'#000']]));
const stripe=()=>falloff(ctx=>stops(ctx.createLinearGradient(0,0,0,64),[[0,'#000'],[.3,'#fff'],[.7,'#fff'],[1,'#000']]));
const emitter=(map,color,power,side)=>new THREE.MeshBasicMaterial({map,color:new THREE.Color(color).multiplyScalar(power),
  blending:THREE.AdditiveBlending,transparent:true,depthWrite:false,side});

function dome(){
  const geometry=new THREE.SphereGeometry(60,24,16),position=geometry.attributes.position;
  const colors=new Float32Array(position.count*3);
  const zenith=new THREE.Color('#ffffff').multiplyScalar(.5),horizon=new THREE.Color('#fdfcf8').multiplyScalar(.4);
  const ground=new THREE.Color('#f6f2e8').multiplyScalar(.3),color=new THREE.Color();
  for(let i=0;i<position.count;i++){
    const height=position.getY(i)/60;
    color.copy(horizon).lerp(height>0?zenith:ground,Math.min(1,Math.abs(height)*1.6)).toArray(colors,i*3);
  }
  geometry.setAttribute('color',new THREE.BufferAttribute(colors,3));
  return new THREE.Mesh(geometry,new THREE.MeshBasicMaterial({vertexColors:true,side:THREE.BackSide}));
}

export function studioEnvironment(renderer){
  const studio=new THREE.Scene(),owned=[];
  const add=(geometry,material)=>{
    const mesh=new THREE.Mesh(geometry,material);studio.add(mesh);
    owned.push(geometry,material);if(material.map)owned.push(material.map);return mesh;
  };
  const room=dome();studio.add(room);owned.push(room.geometry,room.material);
  for(const band of BANDS){
    const mesh=add(new THREE.CylinderGeometry(DISTANCE,DISTANCE,band.height,48,1,true),emitter(stripe(),band.color,band.power,THREE.BackSide));
    mesh.position.y=DISTANCE*Math.tan(band.el*RADIANS);
  }
  for(const panel of PANELS){
    const mesh=add(new THREE.PlaneGeometry(panel.w,panel.h),emitter(glow(panel.soft),panel.color,panel.power,THREE.DoubleSide));
    const az=panel.az*RADIANS,el=panel.el*RADIANS;
    mesh.position.set(Math.sin(az)*Math.cos(el),Math.sin(el),Math.cos(az)*Math.cos(el)).multiplyScalar(DISTANCE);
    mesh.lookAt(0,0,0);
  }
  const generator=new THREE.PMREMGenerator(renderer);
  const target=generator.fromScene(studio,.02,.1,100,{size:128});
  generator.dispose();owned.forEach(item=>item.dispose());
  return target;
}
