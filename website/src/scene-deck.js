// Ivory timeline surface, transport, thumbnails, captions and the moving playhead.
import * as THREE from 'three';
import {RoundedBoxGeometry} from 'three/addons/geometries/RoundedBoxGeometry.js';
import {roundedFace,openRim} from './scene-shapes.js';
import {SCENE_CLIPS,SCENE_SEGMENTS,REEL_SECONDS,timecode} from './scene-playback.js';

const WIDTH=2048,HEIGHT=960,WORLD_WIDTH=10.5,WORLD_HEIGHT=4.9;
const TRACK_LEFT=225,TRACK_WIDTH=1760;
const green='#214e3a',paper='#f2eee1';
const point=(x,y)=>[(x/WIDTH-.5)*WORLD_WIDTH,(y/HEIGHT-.5)*WORLD_HEIGHT];
function rect(ctx,x,y,w,h,r=10){ctx.beginPath();ctx.roundRect(x,y,w,h,r);ctx.fill();}
function cover(ctx,image,x,y,width,height){
  const scale=Math.max(width/image.width,height/image.height);
  const sw=width/scale,sh=height/scale;
  ctx.drawImage(image,(image.width-sw)/2,(image.height-sh)/2,sw,sh,x,y,width,height);
}
function triangle(ctx,x,y,direction=1){
  ctx.beginPath();ctx.moveTo(x+direction*12,y);ctx.lineTo(x-direction*9,y-12);ctx.lineTo(x-direction*9,y+12);ctx.closePath();ctx.fill();
}
function tools(ctx){
  ctx.strokeStyle='#435146';ctx.lineWidth=4;ctx.lineCap='round';
  ctx.beginPath();ctx.arc(103,340,11,0,Math.PI*2);ctx.moveTo(137,340);ctx.arc(126,340,11,0,Math.PI*2);ctx.stroke();
  ctx.beginPath();ctx.moveTo(109,329);ctx.lineTo(138,286);ctx.moveTo(120,330);ctx.lineTo(91,286);ctx.stroke();
  ctx.strokeRect(91,417,46,27);ctx.strokeRect(82,426,46,27);
  ctx.beginPath();ctx.moveTo(90,613);ctx.lineTo(138,613);ctx.moveTo(114,613);ctx.lineTo(114,653);ctx.stroke();
  for(let i=0;i<7;i++){
    const h=[12,27,44,24,54,34,14][i];
    ctx.beginPath();ctx.moveTo(85+i*9,807-h/2);ctx.lineTo(85+i*9,807+h/2);ctx.stroke();
  }
}
function staticSurface(images){
  const canvas=document.createElement('canvas');canvas.width=WIDTH;canvas.height=HEIGHT;
  const ctx=canvas.getContext('2d');
  ctx.fillStyle=paper;ctx.fillRect(0,0,WIDTH,HEIGHT);
  ctx.strokeStyle='#d5d4c6';ctx.lineWidth=2;
  ctx.beginPath();ctx.moveTo(65,168);ctx.lineTo(1980,168);ctx.stroke();
  ctx.fillStyle='#e7e4d7';rect(ctx,220,50,355,79,35);
  ctx.fillStyle=green;
  triangle(ctx,290,90,-1);triangle(ctx,315,90,-1);
  ctx.fillRect(382,76,7,29);ctx.fillRect(399,76,7,29);
  triangle(ctx,486,90);triangle(ctx,512,90);
  ctx.font='500 23px sans-serif';ctx.fillText('SkyCut',1770,101);
  ctx.fillStyle='#7b8272';ctx.font='22px monospace';
  const markers=[...SCENE_SEGMENTS.map(segment=>segment.start),REEL_SECONDS];
  markers.forEach((seconds,i)=>{
    const x=TRACK_LEFT+seconds/REEL_SECONDS*TRACK_WIDTH;
    ctx.textAlign=i===markers.length-1?'right':'left';ctx.fillText(timecode(seconds),x,224);
    ctx.beginPath();ctx.moveTo(x,247);ctx.lineTo(x,900);ctx.stroke();
  });
  for(let second=1;second<REEL_SECONDS;second++){
    const tx=TRACK_LEFT+second/REEL_SECONDS*TRACK_WIDTH;
    ctx.beginPath();ctx.moveTo(tx,238);ctx.lineTo(tx,249);ctx.stroke();
  }
  ctx.textAlign='left';tools(ctx);
  images.forEach((image,i)=>{
    const segment=SCENE_SEGMENTS[i];
    const x=TRACK_LEFT+segment.start/REEL_SECONDS*TRACK_WIDTH+4;
    const w=segment.duration/REEL_SECONDS*TRACK_WIDTH-9;
    ctx.save();ctx.beginPath();ctx.roundRect(x,285,w,270,10);ctx.clip();
    cover(ctx,image,x,285,w,270);ctx.restore();
    ctx.fillStyle=green;rect(ctx,x+8,601,w-16,68,8);
    ctx.fillStyle='#fff9ea';ctx.font='23px sans-serif';ctx.textAlign='center';
    ctx.fillText(SCENE_CLIPS[i].caption,x+w/2,645);
  });
  ctx.fillStyle='#e1e5d3';rect(ctx,TRACK_LEFT,722,TRACK_WIDTH,166,11);
  ctx.fillStyle='#749468';
  for(let i=0;i<585;i++){
    const amplitude=10+Math.abs(Math.sin(i*.49)*Math.cos(i*.13)*Math.sin(i*.033))*118;
    ctx.fillRect(TRACK_LEFT+4+i*3,805-amplitude/2,2,amplitude);
  }
  const texture=new THREE.CanvasTexture(canvas);texture.colorSpace=THREE.SRGBColorSpace;
  texture.anisotropy=4;return texture;
}

export function buildDeck(images){
  const group=new THREE.Group();
  const body=new THREE.Mesh(new RoundedBoxGeometry(10.8,.29,5.2,5,.14),
    new THREE.MeshStandardMaterial({color:'#e6ddc8',roughness:.37,metalness:.16}));
  body.position.y=-1.4;body.castShadow=true;body.receiveShadow=true;group.add(body);
  const surface=new THREE.Mesh(roundedFace(WORLD_WIDTH,WORLD_HEIGHT,.16),
    new THREE.MeshStandardMaterial({map:staticSurface(images),roughness:.85}));
  surface.rotation.x=-Math.PI/2;surface.position.y=-1.247;group.add(surface);

  const counter=document.createElement('canvas');counter.width=512;counter.height=84;
  const ctx=counter.getContext('2d');
  const counterTexture=new THREE.CanvasTexture(counter);counterTexture.colorSpace=THREE.SRGBColorSpace;
  const readout=new THREE.Mesh(new THREE.PlaneGeometry(2.62,.43),
    new THREE.MeshBasicMaterial({map:counterTexture,transparent:true,depthWrite:false}));
  const [counterX,counterZ]=point(895,88);
  readout.position.set(counterX,-1.235,counterZ);readout.rotation.x=-Math.PI/2;group.add(readout);

  const playhead=new THREE.Mesh(new THREE.BoxGeometry(.028,.033,3.48),
    new THREE.MeshBasicMaterial({color:green}));
  playhead.position.set(0,-1.212,.49);group.add(playhead);
  const handle=new THREE.Mesh(new RoundedBoxGeometry(.15,.06,.16,2,.025),
    new THREE.MeshStandardMaterial({color:paper,roughness:.4,metalness:.1}));
  handle.position.set(0,-1.19,-1.27);group.add(handle);
  const outline=new THREE.Mesh(openRim(2.18,1.40,.06,.018),
    new THREE.MeshBasicMaterial({color:green}));
  outline.rotation.x=-Math.PI/2;outline.position.y=-1.222;group.add(outline);

  let stamp='';
  function update(playback){
    const [x]=point(TRACK_LEFT+TRACK_WIDTH*playback.progress,0);
    playhead.position.x=x;handle.position.x=x;
    const segment=SCENE_SEGMENTS[playback.active];
    const center=TRACK_LEFT+(segment.start+segment.duration/2)/REEL_SECONDS*TRACK_WIDTH;
    const [clipX,clipZ]=point(center,420);
    outline.position.x=clipX;outline.position.z=clipZ;
    outline.scale.x=(segment.duration/REEL_SECONDS*TRACK_WIDTH-9)/WIDTH*WORLD_WIDTH/2.18;
    const next=timecode(playback.time);
    if(stamp===next)return;
    stamp=next;ctx.clearRect(0,0,512,84);
    ctx.fillStyle=green;ctx.font='500 47px monospace';ctx.textAlign='center';ctx.textBaseline='middle';
    ctx.fillText(next,256,43);counterTexture.needsUpdate=true;
  }
  return {group,update};
}
