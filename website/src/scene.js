// Three.js renderer, full turntable motion and shared video/visibility/pause lifecycle.
import * as THREE from 'three';
import {buildSculpture,updateSculpture,disposeSculpture} from './scene-parts.js';
import {createSceneMedia} from './scene-media.js';
import {playbackAt,turnAt,SCENE_CLIPS} from './scene-playback.js';
import {icon} from './icons.js';

export async function mountScene(host) {
  const canvas=host.querySelector('canvas'),toggle=host.querySelector('.motion-toggle');
  const reduced=matchMedia('(prefers-reduced-motion: reduce)');
  const compact=matchMedia('(max-width: 600px)');
  const key='SrtFlow.website.motionPaused';
  let paused=false;
  try{paused=localStorage.getItem(key)==='true';}catch{}
  const renderer=new THREE.WebGLRenderer({canvas,alpha:true,antialias:true,powerPreference:'low-power'});
  renderer.setPixelRatio(Math.min(devicePixelRatio,1.75));
  renderer.outputColorSpace=THREE.SRGBColorSpace;
  renderer.toneMapping=THREE.ACESFilmicToneMapping;renderer.toneMappingExposure=1.15;
  renderer.shadowMap.enabled=true;renderer.shadowMap.type=THREE.PCFShadowMap;
  const scene=new THREE.Scene();
  const camera=new THREE.PerspectiveCamera(32,1,.1,100);
  camera.position.set(.8,5.8,15.6);camera.lookAt(0,.2,0);
  scene.add(new THREE.HemisphereLight('#fffbed','#b2ac92',2.7));
  const light=new THREE.DirectionalLight('#fff9e8',3.1);
  light.position.set(-6,10,7);light.castShadow=true;light.shadow.mapSize.set(1024,1024);
  Object.assign(light.shadow.camera,{left:-9,right:9,top:9,bottom:-9,near:.1,far:35});
  light.shadow.bias=-.001;light.shadow.normalBias=.04;scene.add(light);
  const fill=new THREE.DirectionalLight('#dce5d1',1.2);fill.position.set(7,3,-3);scene.add(fill);
  const floor=new THREE.Mesh(new THREE.PlaneGeometry(35,35),new THREE.ShadowMaterial({opacity:.14}));
  floor.rotation.x=-Math.PI/2;floor.position.y=-1.62;floor.receiveShadow=true;scene.add(floor);
  const media=createSceneMedia();
  let model;
  try{model=await buildSculpture(compact.matches,media.texture);}catch(error){
    media.dispose();renderer.dispose();floor.geometry.dispose();floor.material.dispose();throw error;
  }
  scene.add(model);updateSculpture(model,playbackAt(0),0,false);
  let frame=0,visible=true,lost=false,disposed=false,dragging=false,lastX=0,userAngle=-.1;
  let elapsed=0,lastTime=0,modelRequest=0;
  const pointer=new THREE.Vector2(),smoothed=new THREE.Vector2();

  function render(){if(!disposed&&!lost)renderer.render(scene,camera);}
  function orient(){
    model.rotation.y=turnAt(elapsed)+userAngle+smoothed.x*.035;
    model.rotation.x=smoothed.y*.012;
    model.position.y=Math.sin(elapsed*.5)*.035;
  }
  function resize(){
    const width=host.clientWidth,height=host.clientHeight;
    if(!width||!height)return;
    renderer.setSize(width,height,false);camera.aspect=width/height;
    camera.fov=compact.matches?40:32;camera.position.z=compact.matches?16.2:15.6;
    camera.lookAt(0,.2,0);camera.updateProjectionMatrix();
    model.scale.setScalar(compact.matches?.96:1);orient();render();
  }
  function tick(time){
    frame=0;
    if(disposed||lost||!visible||document.hidden||paused||reduced.matches)return;
    const dt=lastTime?Math.min((time-lastTime)/1000,.05):1/60;
    lastTime=time;elapsed+=dt;smoothed.lerp(pointer,.035);
    const playback=playbackAt(media.time);
    updateSculpture(model,playback,dt,media.ready);
    host.dataset.sceneClip=SCENE_CLIPS[playback.active].id;
    orient();render();frame=requestAnimationFrame(tick);
  }
  function stopFrame(){if(frame)cancelAnimationFrame(frame);frame=0;lastTime=0;}
  function sync(){
    if(disposed)return;
    stopFrame();
    const playing=!paused&&!reduced.matches&&visible&&!document.hidden&&!lost;
    media.setPlaying(playing);
    host.classList.toggle('scene-ready',!reduced.matches&&!lost);
    toggle.setAttribute('aria-label',paused?toggle.dataset.playLabel:toggle.dataset.pauseLabel);
    toggle.setAttribute('aria-pressed',String(paused));toggle.innerHTML=icon(paused?'play':'pause');
    render();if(playing)frame=requestAnimationFrame(tick);
  }
  const resizeObserver=new ResizeObserver(resize);resizeObserver.observe(host);
  const visibilityObserver=new IntersectionObserver(entries=>{visible=entries[0].isIntersecting;sync();});
  visibilityObserver.observe(host);
  const onVisibility=()=>sync();document.addEventListener('visibilitychange',onVisibility);
  const onReduced=()=>sync();reduced.addEventListener('change',onReduced);
  toggle.addEventListener('click',()=>{
    paused=!paused;try{localStorage.setItem(key,String(paused));}catch{}sync();
  });
  host.addEventListener('pointermove',event=>{
    if(event.pointerType==='touch')return;
    const rect=host.getBoundingClientRect();
    pointer.set((event.clientX-rect.left)/rect.width*2-1,(event.clientY-rect.top)/rect.height*2-1);
    if(dragging){userAngle+=(event.clientX-lastX)*.006;lastX=event.clientX;orient();render();}
  });
  host.addEventListener('pointerleave',()=>{pointer.set(0,0);});
  host.addEventListener('pointerdown',event=>{
    if(event.pointerType==='mouse'&&event.target===canvas){dragging=true;lastX=event.clientX;host.setPointerCapture(event.pointerId);}
  });
  host.addEventListener('pointerup',()=>{dragging=false;});
  host.addEventListener('pointercancel',()=>{dragging=false;});
  const onCompact=async()=>{
    const request=++modelRequest;
    const next=await buildSculpture(compact.matches,media.texture);
    if(disposed||request!==modelRequest){disposeSculpture(next);return;}
    scene.remove(model);disposeSculpture(model);model=next;scene.add(model);
    updateSculpture(model,playbackAt(media.time),0,media.ready);resize();sync();
  };
  compact.addEventListener('change',onCompact);
  canvas.addEventListener('webglcontextlost',event=>{event.preventDefault();lost=true;sync();});
  canvas.addEventListener('webglcontextrestored',()=>{lost=false;sync();});
  window.addEventListener('pageshow',event=>{if(event.persisted)sync();});
  window.addEventListener('pagehide',event=>{
    stopFrame();media.setPlaying(false);if(event.persisted)return;
    disposed=true;modelRequest++;resizeObserver.disconnect();visibilityObserver.disconnect();
    document.removeEventListener('visibilitychange',onVisibility);reduced.removeEventListener('change',onReduced);
    compact.removeEventListener('change',onCompact);disposeSculpture(model);media.dispose();
    floor.geometry.dispose();floor.material.dispose();renderer.dispose();
  });
  resize();sync();
}
