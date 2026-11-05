// One silent local video decoder, shared by whichever footage card is currently in front.
import * as THREE from 'three';

export function createSceneMedia() {
  const video=document.createElement('video');
  video.muted=true;video.defaultMuted=true;video.loop=true;video.playsInline=true;
  video.setAttribute('muted','');video.setAttribute('playsinline','');
  video.preload='auto';video.src='/media/timeline-loop.mp4';
  const texture=new THREE.VideoTexture(video);
  texture.colorSpace=THREE.SRGBColorSpace;
  texture.minFilter=THREE.LinearFilter;texture.magFilter=THREE.LinearFilter;
  texture.generateMipmaps=false;
  let wanted=false,disposed=false;
  const resume=()=>{
    if(wanted&&!disposed)void video.play().then(()=>{
      if(!wanted||disposed)video.pause();
    }).catch(()=>{});
  };
  video.addEventListener('canplay',resume);
  return {
    video,texture,
    get ready(){return video.readyState>=2&&!video.seeking;},
    get time(){return video.currentTime;},
    setPlaying(playing){
      if(wanted===playing)return;
      wanted=playing;
      if(playing)resume();else video.pause();
    },
    dispose(){
      disposed=true;wanted=false;video.pause();
      video.removeEventListener('canplay',resume);
      video.removeAttribute('src');video.load();texture.dispose();
    }
  };
}
