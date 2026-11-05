// Regression: a moving synthetic playhead must never substitute for decoded video playback.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {SHOWCASE_MEDIA,createShowcaseMedia} from '../src/showcase-media.js';
import {showcaseFrame} from '../src/showcase-state.js';
import {attachShowcaseControls} from '../src/showcase-controls.js';
import {render} from '../scripts/template.mjs';
import chinese from '../content/zh.js';

function fakeVideo() {
  const listeners={};let time=0;
  return {
    readyState:0,paused:true,src:'',seeks:0,plays:0,loads:0,style:{},
    get currentTime(){return time;},set currentTime(value){time=value;this.seeks++;},
    advance(value){time=value;},
    setAttribute(){},addEventListener(name,fn){listeners[name]=fn;},
    load(){this.loads++;this.readyState=0;this.paused=true;},
    ready(){this.readyState=2;listeners.loadedmetadata();listeners.canplay();},
    play(){this.plays++;this.paused=false;return Promise.resolve();},
    pause(){this.paused=true;},
  };
}
test('all three previews autoplay and follow decoded time without repeated seeking or a frozen final frame',async()=>{
  const previous=globalThis.document;globalThis.document={hidden:false};
  try {
    for(const kind of Object.keys(SHOWCASE_MEDIA)) {
      const video=fakeVideo();const media=createShowcaseMedia({querySelector:()=>video},kind);
      media.update(showcaseFrame(kind,0),true,false);assert.equal(video.src,'');assert.equal(video.loads,0);
      media.update(showcaseFrame(kind,0),true,true);
      assert.equal(video.preload,'auto','a preload none poster must be actively loaded before waiting for metadata');
      assert.equal(video.loads,1);
      video.ready();await new Promise(setImmediate);
      assert.equal(video.paused,false,`${kind} must play at its first visible phase`);
      assert.equal(video.loop,true);
      const seeks=video.seeks;
      video.advance(1.25);
      for(let i=0;i<60;i++) {
        const playback=media.update(showcaseFrame(kind,1+i/60),true,true);
        assert.equal(playback.time,1.25,'the playhead uses the decoder clock even if frames stall');
      }
      assert.equal(video.seeks,seeks,'RAF must not seek over a playing video');
      const end=kind==='create'?35:20;
      media.update(showcaseFrame(kind,end),true,true);
      if(video.readyState<2) {video.ready();await new Promise(setImmediate);media.update(showcaseFrame(kind,end),true,true);}
      assert.equal(video.paused,false,'completion keeps the preview looping');
      media.update(showcaseFrame(kind,end),true,false);assert.equal(video.paused,true);
    }
  } finally {globalThis.document=previous;}
});
test('a blocked autoplay has a retry path without repeatedly starting play promises',async()=>{
  const previous=globalThis.document;globalThis.document={hidden:false};
  try {
    const video=fakeVideo();let attempts=0;
    video.play=()=>{attempts++;return Promise.reject(Object.assign(new Error('Gesture required'),{name:'NotAllowedError'}));};
    const media=createShowcaseMedia({querySelector:()=>video},'translate');
    media.update(showcaseFrame('translate',0),true,true);video.ready();await new Promise(setImmediate);
    for(let i=0;i<20;i++)assert.equal(media.update(showcaseFrame('translate',1),true,true).blocked,true);
    assert.equal(attempts,1);
    video.play=()=>{video.paused=false;return Promise.resolve();};
    media.retry();await new Promise(setImmediate);
    assert.equal(media.update(showcaseFrame('translate',1),true,true).blocked,false);
    assert.equal(video.paused,false);
  } finally {globalThis.document=previous;}
});
test('720p replacement keeps the actual playback position and explicit seeks remain available',async()=>{
  const previous=globalThis.document;globalThis.document={hidden:false};
  try {
    const video=fakeVideo();const media=createShowcaseMedia({querySelector:()=>video},'upscale');
    media.update(showcaseFrame('upscale',0),true,true);video.ready();await Promise.resolve();
    video.advance(4.2);
    media.update(showcaseFrame('upscale',10),true,true);
    assert.equal(video.src,SHOWCASE_MEDIA.upscale.enhanced);
    video.ready();await Promise.resolve();
    assert.equal(video.currentTime,4.2);
    media.seek(2);assert.equal(video.currentTime,2);
    media.pause();assert.equal(video.paused,true);
  } finally {globalThis.document=previous;}
});
test('choosing a workflow step resumes playback instead of silently pausing it',async()=>{
  const button=()=>({dataset:{},addEventListener(event,fn){this[event]=fn;}});
  const pause=button(),transport=button(),replay=button(),fallback=button(),phase=button();
  phase.dataset.phaseButton='4';
  const elements={'[data-show-pause]':pause,'[data-video-toggle]':transport,'[data-show-replay]':replay,'[data-video-play]':fallback};
  const state={elapsed:0,paused:true};let wakes=0,draws=0,seek=null;
  const section={querySelector:s=>elements[s],querySelectorAll:s=>s==='[data-phase-button]'?[phase]:[]};
  attachShowcaseControls(section,{state,kind:'create',media:{seek:t=>{seek=t;},retry(){}},view:{reset(){}},draw:()=>draws++,paintPause(){},wake:()=>wakes++,reduced:{matches:false}});
  phase.click();assert.equal(state.paused,false);assert.ok(seek>0);assert.equal(wakes,1);assert.equal(draws,1);
  transport.click();assert.equal(state.paused,true);
  const production=await readFile(new URL('../src/showcases.js',import.meta.url),'utf8');
  assert.match(production,/attachShowcaseControls\(section,/);
  assert.match(production,/mediaTime:playback\.time/);
});
test('each timeline clip renders a sequence of real source frames with preserved image aspect',async()=>{
  const html=render(chinese);
  assert.equal((html.match(/class="show-filmstrip"/g)||[]).length,5);
  assert.equal((html.match(/class="show-film-cell"/g)||[]).length,36);
  assert.match(html,/viewBox="1760 0 160 90"/);
  assert.match(html,/preserveAspectRatio="xMidYMid slice"/);
  for(const kind of Object.keys(SHOWCASE_MEDIA)) {
    const bytes=await readFile(new URL(`../public/media/demo-${kind}-strip.jpg`,import.meta.url));
    assert.ok(bytes.length>1000);
  }
});
