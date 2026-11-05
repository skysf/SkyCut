// Shared demo controls. Selecting a step previews it while keeping video playback active.
import {phaseTime,showcaseFrame} from './showcase-state.js';
export function attachShowcaseControls(section,{state,kind,media,view,draw,paintPause,wake,reduced}) {
  const resume=()=>{state.paused=false;media.retry();paintPause();draw();wake();};
  ['[data-show-pause]','[data-video-toggle]'].forEach(selector=>section.querySelector(selector)?.addEventListener('click',()=>{
    state.paused=!state.paused;media.retry();paintPause();draw();wake();
  }));
  section.querySelector('[data-video-play]')?.addEventListener('click',resume);
  section.querySelector('[data-show-replay]').addEventListener('click',()=>{
    state.elapsed=0;state.paused=reduced.matches;media.seek(0);media.retry();
    view.reset();paintPause();draw();wake();
  });
  section.querySelectorAll('[data-phase-button]').forEach(button=>button.addEventListener('click',()=>{
    state.elapsed=phaseTime(kind,Number(button.dataset.phaseButton));
    media.seek(showcaseFrame(kind,state.elapsed).mediaTime);
    resume();
  }));
  section.querySelectorAll('[data-show-language]').forEach(button=>button.addEventListener('click',()=>{
    view.selectLanguage(Number(button.dataset.showLanguage));draw();
  }));
}
