// Shared reel timing and card order. Pure values only, without DOM or WebGL state.
export const SCENE_CLIPS = [
  {id:'ship', caption:'Across the ocean', sourceStart:21.2},
  {id:'penguin', caption:'Life endures', sourceStart:117},
  {id:'whale', caption:'Beneath the ice', sourceStart:111},
  {id:'penguin-colony', caption:'Across the ice', source:'penguins', sourceStart:0, sourceSeconds:10, duration:10, posterOffset:3.5}
];
export const CLIP_SECONDS = 5;
export const SOURCE_SECONDS = 2;
export const REEL_SECONDS = SCENE_CLIPS.reduce((total,clip)=>total+(clip.duration??CLIP_SECONDS),0);
export const SCENE_SEGMENTS = SCENE_CLIPS.map((clip,index)=>{
  const start=SCENE_CLIPS.slice(0,index).reduce((total,item)=>total+(item.duration??CLIP_SECONDS),0);
  const duration=clip.duration??CLIP_SECONDS;
  return {start,duration,end:start+duration};
});
export const TURN_SECONDS = 48;

export function playbackAt(seconds) {
  const time = Number.isFinite(seconds) ? Math.max(0,seconds) % REEL_SECONDS : 0;
  const active = SCENE_SEGMENTS.findIndex(segment=>time<segment.end);
  return {time,active,progress:time / REEL_SECONDS,localTime:time-SCENE_SEGMENTS[active].start};
}

export function cardOrder(active) {
  return SCENE_CLIPS.map((_,slot)=>(active+slot)%SCENE_CLIPS.length);
}

export function turnAt(seconds) {
  return Math.max(0,seconds) / TURN_SECONDS * Math.PI * 2;
}

export function timecode(seconds) {
  const frames = Math.floor(Math.max(0,seconds) * 20);
  return [0,Math.floor(frames/1200),Math.floor(frames/20)%60,frames%20]
    .map(value=>String(value).padStart(2,'0')).join(':');
}
