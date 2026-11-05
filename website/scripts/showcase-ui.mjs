// Warm SkyCut layout reconstructed from the screenshot with real Antarctic footage.
// This is website illustration, not a running editor or an AI connection.
import {escape as e} from './html.mjs';
import {icon} from '../src/icons.js';
import {filmstrip} from './showcase-filmstrip.mjs';
import {SHOWCASE_MEDIA,CAPTION_STARTS,CAPTION_ENDS} from '../src/showcase-media.js';
export function footage(cls = '') {
  const name=cls.includes('character-portrait')?'demo-talk':cls.includes('talk')?'demo-talk':cls.includes('speak')?'demo-speak':`demo-shot-${cls.includes('shot-1')?1:cls.includes('shot-2')?2:0}`;
  return `<div class="reference-footage ${cls}"><img src="/media/${name}.jpg" width="960" height="540" alt="" loading="lazy"></div>`;
}
const glyph=name=>`<span class="ui-glyph" aria-hidden="true">${icon(name)}</span>`;
const wave=()=>`<span class="show-wave" aria-hidden="true">${Array.from({length:80},(_,i)=>`<i style="--amp:${18+Math.abs(Math.sin(i*1.72)*Math.cos(i*.39))*80}%"></i>`).join('')}</span>`;
function inspector(u,kind) {
  const duration=SHOWCASE_MEDIA[kind].duration;
  return `<aside class="show-inspector"><h4>${e(u.inspector)}</h4><dl><div><dt>${e(u.duration)}</dt><dd>0:${String(duration).padStart(2,'0')}</dd></div><div><dt>${e(u.clips)}</dt><dd data-clip-count>${kind==='create'?3:1}</dd></div><div><dt>${e(u.audioClips)}</dt><dd>3</dd></div><div><dt>${e(u.resolution)}</dt><dd data-resolution>1920×1080</dd></div></dl><h4>${e(kind==='translate'?u.subtitles:u.output)}</h4><div class="inspector-check">${icon('check')}<span>${e(kind==='translate'?u.translateReady:u.keepFps)}</span></div><span class="inspector-resolution" data-output-resolution>1080p</span><span class="inspector-fps">24 fps</span></aside>`;
}
function subtitleLanes(c) {
  const duration=SHOWCASE_MEDIA.translate.duration;
  const cues=translated=>c.captions.en.map((line,i)=>`<span ${translated?'data-translated-cue':''} style="left:${CAPTION_STARTS[i]/duration*100}%;width:${(CAPTION_ENDS[i]-CAPTION_STARTS[i])/duration*100}%">${e(line)}</span>`).join('');
  return `<div class="show-subtitle-lane">${cues(false)}</div><div class="show-subtitle-lane translated">${cues(true)}</div>`;
}
function timeline(c,kind) {
  const u=c.ui;
  const duration=SHOWCASE_MEDIA[kind].duration;
  const shots=kind==='create'?c.shots:[u.clipName];
  const tracks=[[u.music,'music'],[u.ambience,'ambience'],[u.voice,'voice']];
  return `<div class="show-timeline"><div class="show-tools"><span>${glyph('ai')}${e(u.add)}</span><span aria-hidden="true">↖　↶　↷</span>${glyph('cut')}<span class="tool-spacer"></span>${glyph('arrow')}${glyph('sound')}</div><div class="show-tracks"><div class="show-track-heads"><span>${glyph('picture')} V1</span>${kind==='translate'?`<span>${glyph('words')} EN</span><span>${glyph('words')} <b data-track-language>EN</b></span>`:''}${tracks.map(([label])=>`<span>${glyph('sound')}<small>${e(label)}</small><i></i></span>`).join('')}</div><div class="show-track-lanes"><div class="show-ruler">${Array.from({length:6},(_,i)=>`<span>00:${String(Math.round(i*duration/5)).padStart(2,'0')}</span>`).join('')}</div><div class="show-video-lane">${shots.map((s,i)=>`<div class="show-video-clip" data-timeline-clip="${i}" style="width:${100/shots.length}%"><span>${e(s)}</span>${filmstrip(kind,i)}</div>`).join('')}</div>${kind==='translate'?subtitleLanes(c):''}${tracks.map(([label,cls])=>`<div class="show-audio-lane ${cls}"><span>${e(label)}</span>${wave()}</div>`).join('')}<div class="show-playhead" aria-hidden="true"></div></div></div></div>`;
}
function viewer(c,kind) {
  const u=c.ui,media=SHOWCASE_MEDIA[kind];
  return `<div class="show-viewer"><div class="show-preview"><video class="show-demo-video" muted playsinline preload="none" poster="${media.poster}" aria-hidden="true"></video><div class="show-storyboard">${c.script.map((s,i)=>`<div data-script="${i}"><span>0${i+1}</span><p>${e(s)}</p></div>`).join('')}</div><div class="show-character">${footage('character-portrait')}<div><span>${e(u.character)}</span><strong>${e(c.characterName)}</strong>${icon('check')}</div></div><div class="show-job"><span class="show-job-icon">${icon('ai')}</span><strong data-job-title>${e(u.ready)}</strong><div class="show-job-meter"><i></i></div><span data-job-percent>100%</span></div><div class="show-scan" aria-hidden="true"></div><div class="show-preview-subtitle" data-preview-subtitle>${e(c.translations[0])}</div><button class="show-video-play" type="button" data-video-play aria-label="${e(u.resume)}" hidden>${icon('play')}</button><span class="show-quality" data-quality>${kind==='translate'?'720p':'1080p'}</span></div><div class="show-transport"><button class="show-transport-toggle" type="button" data-video-toggle aria-label="${e(u.pause)}">${icon('pause')}</button><span data-timecode>0:00</span><span>/ 0:${String(media.duration).padStart(2,'0')}</span><span>16:9</span><span>24 fps</span><span>${e(u.original)}</span></div></div>`;
}
export function editor(c,kind) {
  const u=c.ui;
  return `<div class="show-window show-editor" aria-label="SkyCut ${e(u.project)}"><div class="show-titlebar"><span class="show-window-dots" aria-hidden="true"><i></i><i></i><i></i></span>${glyph('picture')}<strong>${e(u.project)}</strong><span class="titlebar-right">${glyph('arrow')}${glyph('ai')}</span></div><div class="show-workspace"><aside class="show-library"><div class="show-library-tabs">${glyph('picture')}${glyph('words')}${glyph('sound')}</div><h4>${e(u.library)}</h4><div class="show-assets">${c.shots.map((s,i)=>`<div data-asset="${i}">${footage(`shot-${i}`)}<span>${e(s)}</span></div>`).join('')}</div><h4>${e(u.transitions)}</h4><div class="show-transition">${footage()}<span>${icon('chevron')}</span>${footage('shot-2')}</div></aside>${viewer(c,kind)}${inspector(u,kind)}</div>${timeline(c,kind)}</div>`;
}
export function chat(c,scene) {
  const u=c.ui;
  return `<div class="show-window show-chat"><div class="show-chat-header"><span class="agent-symbol">${icon('ai')}</span><div><strong>${e(u.agent)}</strong><span><i></i>${e(u.connected)}</span></div></div><div class="show-conversation"><div class="show-user-message" data-prompt>${e(scene.prompt)}</div><div class="show-agent"><span class="agent-symbol">${icon('ai')}</span><div class="show-thinking"><span>${e(u.thinking)}</span><i></i><i></i><i></i></div></div><ol class="show-chat-steps">${scene.steps.map((s,i)=>`<li data-chat-step="${i}"><span>${icon('check')}</span><div><strong>${e(s)}</strong><p>${e(scene.messages[i])}</p></div></li>`).join('')}</ol><p class="show-chat-done">${e(scene.done)}</p></div><div class="show-compose"><span>${e(u.compose)}</span>${glyph('arrow')}</div></div>`;
}
