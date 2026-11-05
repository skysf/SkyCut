// Website-only playback of the supplied Antarctic shots. No remote video services.
export const SHOWCASE_MEDIA = {
  create: {duration:15,video:'/media/demo-create.mp4',poster:'/media/demo-shot-0.jpg'},
  upscale: {duration:9,video:'/media/demo-talk-720.mp4',enhanced:'/media/demo-talk-1080.mp4',poster:'/media/demo-talk.jpg'},
  translate: {duration:10,video:'/media/demo-speak.mp4',poster:'/media/demo-speak.jpg'},
};
export const LANGUAGE_CODES = ['en','fr','ja','de','es','zh','zh-Hant'];
export const CAPTION_STARTS = [.7,3.18,4.8,7.36];
export const CAPTION_ENDS = [3.18,4.8,7.08,9.42];
export function captionIndexAt(time) {
  return CAPTION_STARTS.findIndex((start,i)=>time>=start && time<CAPTION_ENDS[i]);
}
export function createShowcaseMedia(host,kind) {
  const video=host.querySelector('.show-demo-video');
  const media=SHOWCASE_MEDIA[kind];
  let pendingSeek=null,wantedPlaying=false,currentSource='',playRequest=null,blocked=false,lastTime=0;
  video.muted=true;video.defaultMuted=true;
  video.loop=true;video.playsInline=true;
  video.setAttribute('muted','');video.setAttribute('playsinline','');
  function apply() {
    // Seek only for an explicit control or a source replacement, never every RAF.
    if(video.readyState>=1 && pendingSeek!==null) {
      video.currentTime=pendingSeek;pendingSeek=null;
    }
    if(!wantedPlaying) {if(!video.paused)video.pause();return;}
    if(video.readyState<2 || !video.paused || playRequest || blocked)return;
    playRequest=Promise.resolve(video.play()).then(()=>{
      if(!wantedPlaying)video.pause();
    }).catch(error=>{
      if(wantedPlaying && error.name!=='AbortError')blocked=true;
    }).finally(()=>{playRequest=null;});
  }
  video.addEventListener('loadedmetadata',apply);
  video.addEventListener('canplay',apply);
  return {
    update(frame,playing,visible) {
      if(video.readyState>=2)lastTime=video.currentTime;
      wantedPlaying=playing&&visible&&!document.hidden;
      if(visible) {
        const source=kind==='upscale'&&frame.enhancement===1?media.enhanced:media.video;
        if(source!==currentSource) {
          pendingSeek=pendingSeek??(currentSource?video.currentTime:0);
          currentSource=source;blocked=false;
          video.preload='auto';video.src=source;video.load();
        }
        apply();
      } else video.pause();
      return {time:lastTime,duration:media.duration,blocked};
    },
    seek(time) {pendingSeek=Math.max(0,Math.min(media.duration-.04,time));lastTime=pendingSeek;apply();},
    retry() {blocked=false;apply();},
    pause() {wantedPlaying=false;video.pause();},
  };
}
