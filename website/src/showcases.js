// Three.js CSS3D product windows with a single visibility-aware animation clock.
// Readable HTML remains the fallback. This module never calls AI or SkyCut APIs.
import {PerspectiveCamera, Scene} from 'three';
import {CSS3DObject, CSS3DRenderer} from 'three/addons/renderers/CSS3DRenderer.js';
import {SHOWCASE_TIMING, showcaseFrame} from './showcase-state.js';
import {createShowcaseView} from './showcase-view.js';
import {icon} from './icons.js';
import {createShowcaseMedia} from './showcase-media.js';
import {attachShowcaseControls} from './showcase-controls.js';

function createStage(section, copy, reduced) {
  const kind = section.dataset.showcase;
  const sceneCopy = copy.scenes.find(s => s.kind === kind);
  const host = section.querySelector('.show-stage');
  const view = createShowcaseView(section, copy, sceneCopy);
  const media = createShowcaseMedia(section,kind);
  const scene = new Scene();
  let camera;
  let renderer = new CSS3DRenderer();
  renderer.domElement.classList.add('show-renderer');
  const chat = new CSS3DObject(host.querySelector('.show-chat'));
  const editor = new CSS3DObject(host.querySelector('.show-editor'));
  [chat,editor].forEach(object=>{object.element.style.userSelect='text';});
  const transfer = new CSS3DObject(host.querySelector('.show-transfer'));
  scene.add(chat, editor, transfer);
  host.append(renderer.domElement);
  host.classList.add('is-3d');
  let layout;
  let previousWidth=-1;
  let wasFlat=false;
  function resize() {
    const width = host.clientWidth;
    if (!width || width===previousWidth) return;
    previousWidth=width;
    const phone = innerWidth <= 600;
    const tablet = !phone && innerWidth <= 900;
    if(phone || tablet) {
      wasFlat=true;
      layout={width:phone?390:740};
      host.classList.remove('is-3d');host.classList.add('is-flat');
      host.style.height='';renderer.domElement.style.display='none';
      [chat,editor].forEach(object=>{
        host.append(object.element);
        Object.assign(object.element.style,{position:'relative',width:'100%',height:'auto',transform:'none'});
      });
      draw();return;
    }
    if(wasFlat) {
      renderer.domElement.remove();renderer=new CSS3DRenderer();
      renderer.domElement.classList.add('show-renderer');host.prepend(renderer.domElement);
      wasFlat=false;
    }
    layout={width:1320,height:660,chat:[310,590,-496,8],editor:[960,590,171,8]};
    host.classList.remove('is-flat');host.classList.add('is-3d');
    renderer.domElement.style.display='block';
    const height = width * layout.height / layout.width;
    host.style.height = `${height}px`;
    renderer.setSize(width, height);
    camera = new PerspectiveCamera(35,width/height,1,4000);
    camera.position.z = layout.height/2/Math.tan(camera.fov*Math.PI/360);
    camera.updateProjectionMatrix();
    [[chat,layout.chat],[editor,layout.editor]].forEach(([object,box]) => {
      object.element.style.width = `${box[0]}px`;
      object.element.style.height = `${box[1]}px`;
      object.element.style.position = 'absolute';
      object.position.set(box[2],box[3],0);
    });
    draw();
  }
  const pause = section.querySelector('[data-show-pause]');
  const transport = section.querySelector('[data-video-toggle]');
  const videoPlay = section.querySelector('[data-video-play]');
  const state = {visible:false, paused:reduced.matches, elapsed:reduced.matches ? SHOWCASE_TIMING[kind].at(-2) : 0};
  function paintPause() {
    pause.innerHTML = icon(state.paused ? 'play' : 'pause');
    pause.setAttribute('aria-label',state.paused ? copy.ui.resume : copy.ui.pause);
    transport.innerHTML=icon(state.paused?'play':'pause');
    transport.setAttribute('aria-label',state.paused?copy.ui.resume:copy.ui.pause);
  }
  function draw() {
    if (!layout) return;
    const workflow = showcaseFrame(kind,state.elapsed);
    const playback = media.update(workflow,!state.paused,state.visible);
    const frame = {...workflow,mediaTime:playback.time,playhead:playback.time/playback.duration};
    view.paint(frame);
    videoPlay.hidden=!playback.blocked;
    // Both windows share a horizontal baseline and never roll or tilt independently.
    const depth = reduced.matches ? 0 : Math.sin(frame.time * .45) * 7;
    chat.position.z = depth;
    editor.position.z = -depth * .25;
    transfer.element.style.display = frame.transfer >= 0 && layout.width > 900 ? 'flex' : 'none';
    if (frame.transfer >= 0) {
      const p = frame.transfer;
      transfer.position.set(-300 + p * 490,45 + Math.sin(p * Math.PI) * 40,60 + Math.sin(p * Math.PI) * 100);
      transfer.element.style.opacity = String(Math.sin(p * Math.PI));
    }
    if(layout.width>900)renderer.render(scene,camera);
  }
  attachShowcaseControls(section,{state,kind,media,view,draw,paintPause,wake,reduced});
  const resizeObserver = new ResizeObserver(resize);
  resizeObserver.observe(host);
  paintPause();resize();
  return {section,state,draw,pauseMedia:()=>media.pause(),setPaused(value) {state.paused=value;paintPause();draw();},step(delta) {state.elapsed+=delta;draw();}};
}
let stages = [];
let raf = 0;
let last = 0;
function wake() {
  if (!raf && !document.hidden && stages.some(s=>s.state.visible && !s.state.paused)) {
    last=performance.now();raf=requestAnimationFrame(tick);
  }
}
function tick(now) {
  raf=0;
  const delta=Math.min((now-last)/1000,.1);last=now;
  stages.filter(s=>s.state.visible && !s.state.paused).forEach(s=>s.step(delta));
  if (!document.hidden && stages.some(s=>s.state.visible && !s.state.paused)) raf=requestAnimationFrame(tick);
}
export function mountShowcases() {
  const root=document.querySelector('[data-showcase-copy]');
  if (!root) return;
  const copy=JSON.parse(root.dataset.showcaseCopy);
  const reduced=matchMedia('(prefers-reduced-motion: reduce)');
  stages=[...root.querySelectorAll('[data-showcase]')].map(section=>createStage(section,copy,reduced));
  const observer=new IntersectionObserver(entries=>{
    entries.forEach(entry=>{const stage=stages.find(s=>s.section===entry.target);stage.state.visible=entry.isIntersecting;stage.draw();});
    wake();
  },{threshold:.08});
  stages.forEach(stage=>observer.observe(stage.section));
  document.addEventListener('visibilitychange',()=>{if(document.hidden){cancelAnimationFrame(raf);raf=0;stages.forEach(s=>s.pauseMedia());}else {stages.forEach(s=>s.draw());wake();}});
  reduced.addEventListener('change',()=>{stages.forEach(s=>s.setPaused(true));});
}
