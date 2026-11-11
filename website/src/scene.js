// Live hero scene: turntable motion and the shared video/visibility/pause lifecycle.
// The baked still is always underneath; this only takes over while WebGL can hold the frame budget.
import * as THREE from 'three';
import {createStage,breathe} from './scene-stage.js';
import {buildSculpture,updateSculpture,disposeSculpture} from './scene-parts.js';
import {createSceneMedia} from './scene-media.js';
import {createGovernor,FRAME_FLOOR} from './scene-governor.js';
import {playbackAt,turnAt,SCENE_CLIPS,OPENING_ANGLE,COMPACT_SCALE,COMPACT_QUERY} from './scene-playback.js';
import {icon} from './icons.js';

export async function mountScene(host) {
  const canvas=host.querySelector('canvas'),toggle=host.querySelector('.motion-toggle');
  const reduced=matchMedia('(prefers-reduced-motion: reduce)');
  const compact=matchMedia(COMPACT_QUERY);
  const key='SrtFlow.website.motionPaused';
  let paused=false;
  try{paused=localStorage.getItem(key)==='true';}catch{}
  // Throws without WebGL 2 or on a software renderer; the caller leaves the still in place.
  const stage=createStage(canvas);
  const {scene,camera,renderer}=stage,governor=createGovernor();
  const media=createSceneMedia();media.texture.anisotropy=stage.anisotropy;
  let model;
  try{
    await breathe();stage.relight();await breathe();
    model=await buildSculpture(compact.matches,media.texture,stage);
    scene.add(model);updateSculpture(model,playbackAt(0),0,false);
    // Compile the shaders off the main thread where the browser can, before the first frame is drawn.
    await breathe();await renderer.compileAsync(scene,camera);
  }catch(error){
    if(model)disposeSculpture(model);
    media.dispose();stage.dispose();throw error;
  }
  let frame=0,visible=true,lost=false,disposed=false,dragging=false,lastX=0,userAngle=OPENING_ANGLE;
  let elapsed=0,lastTime=0,modelRequest=0;
  const pointer=new THREE.Vector2(),smoothed=new THREE.Vector2();

  function render(){if(!disposed&&!lost)renderer.render(scene,camera);}
  function orient(){
    model.rotation.y=turnAt(elapsed)+userAngle+smoothed.x*.03;
    model.rotation.x=smoothed.y*.01;
    model.position.y=Math.sin(elapsed*.5)*.035;
    // A small camera shift gives real parallax between the cards and the deck.
    stage.look(smoothed.x*.3,-smoothed.y*.18);
  }
  function resize(){
    const width=host.clientWidth,height=host.clientHeight;
    if(!width||!height)return;
    // The canvas is laid out larger than the host by the bleed on every side (see home.css).
    stage.frame(width,height,(canvas.clientHeight-height)/2,compact.matches,Math.min(devicePixelRatio,governor.pixelRatio));
    model.scale.setScalar(compact.matches?COMPACT_SCALE:1);orient();render();
  }
  const playing=()=>!disposed&&!lost&&visible&&!document.hidden&&!paused&&!reduced.matches;
  function tick(time){
    frame=0;
    // Reading `matches` every frame can swallow the query's change event (Chromium), so the loop
    // settles the state itself when it finds it should no longer run.
    if(!playing()){sync();return;}
    frame=requestAnimationFrame(tick);
    const delta=lastTime?time-lastTime:1000/60;
    if(lastTime&&delta<FRAME_FLOOR)return;
    const dt=Math.min(delta/1000,.05);
    lastTime=time;elapsed+=dt;smoothed.lerp(pointer,1-Math.exp(-dt*2.2));
    const playback=playbackAt(media.time);
    updateSculpture(model,playback,dt,media.ready);
    host.dataset.sceneClip=SCENE_CLIPS[playback.active].id;
    orient();render();
    const verdict=governor.sample(delta);
    if(verdict==='lower')resize();
    else if(verdict==='stop')retire('slow');
  }
  function stopFrame(){if(frame)cancelAnimationFrame(frame);frame=0;lastTime=0;governor.settle();}
  function sync(){
    if(disposed)return;
    stopFrame();
    const active=playing();
    media.setPlaying(active);
    // Reduced motion and a lost context show the still: same picture, nothing moving.
    const live=!reduced.matches&&!lost;
    host.classList.toggle('scene-ready',live);host.dataset.scene=live?'live':'still';
    toggle.setAttribute('aria-label',paused?toggle.dataset.playLabel:toggle.dataset.pauseLabel);
    toggle.setAttribute('aria-pressed',String(paused));toggle.innerHTML=icon(paused?'play':'pause');
    render();if(active)frame=requestAnimationFrame(tick);
  }
  const controller=new AbortController(),listen={signal:controller.signal};
  function dispose(){
    if(disposed)return;
    stopFrame();media.setPlaying(false);
    disposed=true;modelRequest++;controller.abort();resizeObserver.disconnect();visibilityObserver.disconnect();
    disposeSculpture(model);media.dispose();stage.dispose();
  }
  // The device cannot keep up: release the GPU and leave the still for the rest of the visit.
  function retire(reason){
    host.classList.remove('scene-ready');host.dataset.scene='still';host.dataset.sceneFallback=reason;dispose();
  }
  const resizeObserver=new ResizeObserver(resize);resizeObserver.observe(host);
  const visibilityObserver=new IntersectionObserver(entries=>{visible=entries[0].isIntersecting;sync();});
  visibilityObserver.observe(host);
  document.addEventListener('visibilitychange',sync,listen);
  reduced.addEventListener('change',sync,listen);
  toggle.addEventListener('click',()=>{
    paused=!paused;try{localStorage.setItem(key,String(paused));}catch{}sync();
  },listen);
  host.addEventListener('pointermove',event=>{
    if(event.pointerType==='touch')return;
    const rect=host.getBoundingClientRect();
    pointer.set((event.clientX-rect.left)/rect.width*2-1,(event.clientY-rect.top)/rect.height*2-1);
    if(dragging){userAngle+=(event.clientX-lastX)*.006;lastX=event.clientX;orient();render();}
  },listen);
  host.addEventListener('pointerleave',()=>{pointer.set(0,0);},listen);
  host.addEventListener('pointerdown',event=>{
    if(event.pointerType==='mouse'&&!toggle.contains(event.target)){dragging=true;lastX=event.clientX;host.setPointerCapture(event.pointerId);}
  },listen);
  host.addEventListener('pointerup',()=>{dragging=false;},listen);
  host.addEventListener('pointercancel',()=>{dragging=false;},listen);
  compact.addEventListener('change',async()=>{
    const request=++modelRequest;
    let next;
    try{next=await buildSculpture(compact.matches,media.texture,stage);}catch{return;}
    if(disposed||request!==modelRequest){disposeSculpture(next);return;}
    scene.remove(model);disposeSculpture(model);model=next;scene.add(model);
    updateSculpture(model,playbackAt(media.time),0,media.ready);resize();sync();
  },listen);
  canvas.addEventListener('webglcontextlost',event=>{event.preventDefault();lost=true;sync();},listen);
  // The environment lives in a render target, which does not survive a lost context.
  canvas.addEventListener('webglcontextrestored',()=>{lost=false;stage.relight();resize();sync();},listen);
  window.addEventListener('pageshow',event=>{if(event.persisted)sync();},listen);
  window.addEventListener('pagehide',event=>{
    stopFrame();media.setPlaying(false);if(!event.persisted)dispose();
  },listen);
  resize();sync();
}
