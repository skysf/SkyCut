// Lacquered ivory timeline deck: printed surface, relief, contact shadow, readout and playhead.
import * as THREE from 'three';
import {breathe} from './scene-stage.js';
import {RoundedBoxGeometry} from 'three/addons/geometries/RoundedBoxGeometry.js';
import {roundedFace,openRim} from './scene-shapes.js';
import {SCENE_CLIPS,SCENE_SEGMENTS,REEL_SECONDS,timecode} from './scene-playback.js';

const WIDTH=2048,HEIGHT=960,WORLD_WIDTH=10.5,WORLD_HEIGHT=4.9;
const TRACK_LEFT=225,TRACK_WIDTH=1760;
const green='#214e3a',paper='#f2eee1';
// The page font ships with the site, so the deck reads the same on every system and in the baked still.
export const DECK_FONT='"Outfit Variable",sans-serif';
const point=(x,y)=>[(x/WIDTH-.5)*WORLD_WIDTH,(y/HEIGHT-.5)*WORLD_HEIGHT];
const clipSpan=index=>{
  const segment=SCENE_SEGMENTS[index];
  return {x:TRACK_LEFT+segment.start/REEL_SECONDS*TRACK_WIDTH+4,w:segment.duration/REEL_SECONDS*TRACK_WIDTH-9};
};
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
function printedSurface(images,anisotropy){
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
  ctx.font=`600 25px ${DECK_FONT}`;ctx.fillText('SkyCut',1770,101);
  ctx.fillStyle='#7b8272';ctx.font=`400 21px ${DECK_FONT}`;
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
    const {x,w}=clipSpan(i);
    ctx.save();ctx.beginPath();ctx.roundRect(x,285,w,270,10);ctx.clip();
    cover(ctx,image,x,285,w,270);ctx.restore();
    ctx.fillStyle=green;rect(ctx,x+8,601,w-16,68,8);
    ctx.fillStyle='#fff9ea';ctx.font=`500 24px ${DECK_FONT}`;ctx.textAlign='center';
    ctx.fillText(SCENE_CLIPS[i].caption,x+w/2,644);
  });
  ctx.fillStyle='#e1e5d3';rect(ctx,TRACK_LEFT,722,TRACK_WIDTH,166,11);
  ctx.fillStyle='#749468';
  for(let i=0;i<585;i++){
    const amplitude=10+Math.abs(Math.sin(i*.49)*Math.cos(i*.13)*Math.sin(i*.033))*118;
    ctx.fillRect(TRACK_LEFT+4+i*3,805-amplitude/2,2,amplitude);
  }
  const texture=new THREE.CanvasTexture(canvas);texture.colorSpace=THREE.SRGBColorSpace;
  texture.anisotropy=anisotropy;return texture;
}
// Red is height and green is roughness: clips and captions sit proud and glossy like inlaid tiles,
// the transport and the audio lane are pressed into the matte paper. Feathered edges read as bevels.
function reliefSurface(anisotropy){
  const canvas=document.createElement('canvas');canvas.width=WIDTH/2;canvas.height=HEIGHT/2;
  const ctx=canvas.getContext('2d');ctx.scale(.5,.5);
  const press=(height,roughness,x,y,w,h,r)=>{
    ctx.fillStyle=ctx.shadowColor=`rgb(${height},${Math.round(roughness*255)},0)`;rect(ctx,x,y,w,h,r);
  };
  ctx.fillStyle='rgb(128,186,0)';ctx.fillRect(0,0,WIDTH,HEIGHT);
  ctx.shadowBlur=3;
  press(92,.52,220,50,355,79,35);
  SCENE_SEGMENTS.forEach((_,i)=>{
    const {x,w}=clipSpan(i);
    press(184,.3,x,285,w,270,10);press(166,.42,x+8,601,w-16,68,8);
  });
  press(98,.6,TRACK_LEFT,722,TRACK_WIDTH,166,11);
  const texture=new THREE.CanvasTexture(canvas);texture.anisotropy=anisotropy;return texture;
}
// Soft ambient shadow where the deck meets the floor. It turns with the deck; the directional
// shadow from the key light is drawn separately by the stage floor.
function contactShadow(){
  const W=512,H=336,canvas=document.createElement('canvas');canvas.width=W;canvas.height=H;
  const ctx=canvas.getContext('2d');ctx.fillStyle='#000';ctx.shadowOffsetX=W;
  for(const [blur,alpha,grow] of [[32,.27,3],[12,.34,-5]]){
    ctx.shadowColor=`rgba(30,34,22,${alpha})`;ctx.shadowBlur=blur;
    rect(ctx,(W-346)/2-grow-W,(H-166)/2-grow,346+grow*2,166+grow*2,10);
  }
  const mesh=new THREE.Mesh(new THREE.PlaneGeometry(16,10.5),
    new THREE.MeshBasicMaterial({map:new THREE.CanvasTexture(canvas),transparent:true,depthWrite:false,toneMapped:false}));
  mesh.rotation.x=-Math.PI/2;mesh.position.y=-1.612;return mesh;
}

export async function buildDeck(images,{anisotropy=1}={}){
  const group=new THREE.Group();
  const lacquer=new THREE.MeshPhysicalMaterial({color:'#eee6d3',roughness:.44,metalness:0,clearcoat:.75,clearcoatRoughness:.14});
  const body=new THREE.Mesh(new RoundedBoxGeometry(10.8,.29,5.2,8,.14),lacquer);
  body.position.y=-1.4;body.castShadow=true;body.receiveShadow=true;group.add(body);
  const print=printedSurface(images,anisotropy);
  await breathe();
  const relief=reliefSurface(anisotropy),ground=contactShadow();
  await breathe();
  const surface=new THREE.Mesh(roundedFace(WORLD_WIDTH,WORLD_HEIGHT,.16),new THREE.MeshPhysicalMaterial({
    map:print,bumpMap:relief,bumpScale:1.6,roughnessMap:relief,roughness:1,metalness:0,
    clearcoat:.4,clearcoatRoughness:.22}));
  surface.rotation.x=-Math.PI/2;surface.position.y=-1.247;surface.receiveShadow=true;group.add(surface);
  group.add(ground);

  const counter=document.createElement('canvas');counter.width=512;counter.height=84;
  const ctx=counter.getContext('2d');
  const counterTexture=new THREE.CanvasTexture(counter);counterTexture.colorSpace=THREE.SRGBColorSpace;
  counterTexture.anisotropy=anisotropy;
  const readout=new THREE.Mesh(new THREE.PlaneGeometry(2.62,.43),
    new THREE.MeshBasicMaterial({map:counterTexture,transparent:true,depthWrite:false}));
  const [counterX,counterZ]=point(895,88);
  readout.position.set(counterX,-1.235,counterZ);readout.rotation.x=-Math.PI/2;group.add(readout);

  const playhead=new THREE.Mesh(new THREE.BoxGeometry(.028,.033,3.48),
    new THREE.MeshStandardMaterial({color:green,roughness:.45}));
  playhead.position.set(0,-1.212,.49);group.add(playhead);
  const handle=new THREE.Mesh(new RoundedBoxGeometry(.15,.06,.16,3,.025),
    new THREE.MeshPhysicalMaterial({color:paper,roughness:.3,clearcoat:1,clearcoatRoughness:.1}));
  handle.position.set(0,-1.19,-1.27);handle.castShadow=true;group.add(handle);
  const outline=new THREE.Mesh(openRim(2.18,1.40,.06,.018),
    new THREE.MeshStandardMaterial({color:green,roughness:.5}));
  outline.rotation.x=-Math.PI/2;outline.position.y=-1.222;group.add(outline);

  let stamp='';
  // Fixed cells keep the running digits from shuffling sideways in a proportional face.
  function drawReadout(text){
    ctx.clearRect(0,0,512,84);
    ctx.fillStyle=green;ctx.font=`500 48px ${DECK_FONT}`;ctx.textAlign='center';ctx.textBaseline='middle';
    const widths=[...text].map(character=>character===':'?17:29);
    let x=256-widths.reduce((total,width)=>total+width,0)/2;
    [...text].forEach((character,i)=>{ctx.fillText(character,x+widths[i]/2,character===':'?40:44);x+=widths[i];});
    counterTexture.needsUpdate=true;
  }
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
    stamp=next;drawReadout(next);
  }
  return {group,update};
}
