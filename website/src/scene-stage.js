// Renderer, camera, studio light and the shadow-only floor. Shared by the live hero and the baked still.
import * as THREE from 'three';
import {studioEnvironment} from './scene-environment.js';

// Setup is cut into short tasks so the page stays responsive while the scene is prepared.
export const breathe=()=>new Promise(resolve=>setTimeout(resolve));

export function createStage(canvas,{still=false}={}){
  // A software renderer cannot hold the frame budget: let the context fail so the still stays up.
  // Asking for the context here keeps that expected failure out of the console.
  const attributes={alpha:true,antialias:true,depth:true,stencil:false,premultipliedAlpha:true,
    powerPreference:'low-power',failIfMajorPerformanceCaveat:!still,preserveDrawingBuffer:still};
  const context=canvas.getContext('webgl2',attributes);
  if(!context)throw new Error('WebGL 2 is not available');
  const renderer=new THREE.WebGLRenderer({canvas,context,...attributes});
  renderer.outputColorSpace=THREE.SRGBColorSpace;
  // Neutral keeps the ivory and forest green at their page values; filmic curves grey them.
  renderer.toneMapping=THREE.NeutralToneMapping;renderer.toneMappingExposure=1;
  renderer.shadowMap.enabled=true;renderer.shadowMap.type=THREE.PCFShadowMap;
  const scene=new THREE.Scene(),camera=new THREE.PerspectiveCamera(32,1,.1,100);
  // The key sits high behind the cards, so each one lays a soft shadow on the deck toward the viewer.
  const key=new THREE.DirectionalLight('#ffffff',1.45);
  key.position.set(-3.5,12,-3.2);key.castShadow=true;key.shadow.mapSize.set(1024,1024);
  Object.assign(key.shadow.camera,{left:-7.5,right:7.5,top:7.5,bottom:-7.5,near:1,far:30});
  key.shadow.bias=-.0008;key.shadow.normalBias=.03;key.shadow.radius=7;key.shadow.intensity=.62;
  scene.add(key);
  const floor=new THREE.Mesh(new THREE.PlaneGeometry(40,40),new THREE.ShadowMaterial({color:'#1e2216',opacity:.13}));
  floor.rotation.x=-Math.PI/2;floor.position.y=-1.62;floor.receiveShadow=true;scene.add(floor);
  let environment=null;
  // Not run here: the caller gives the environment a task of its own, apart from the other setup.
  function relight(){
    environment?.dispose();environment=studioEnvironment(renderer);scene.environment=environment.texture;
  }
  let depth=15.6;
  // Shifting the camera a little (pointer parallax) keeps it aimed at the same spot above the deck.
  function look(shiftX=0,shiftY=0){camera.position.set(.8+shiftX,5.8+shiftY,depth);camera.lookAt(0,.2,0);}
  // `width` x `height` is the layout box the camera is composed for; `bleed` pixels are drawn beyond it
  // on every side with the same camera, so nothing is cut at the box edge.
  function frame(width,height,bleed,compact,pixelRatio){
    renderer.setPixelRatio(pixelRatio);renderer.setSize(width+bleed*2,height+bleed*2,false);
    camera.aspect=width/height;camera.fov=compact?40:32;depth=compact?16.2:15.6;
    look();camera.setViewOffset(width,height,-bleed,-bleed,width+bleed*2,height+bleed*2);
  }
  return {
    renderer,scene,camera,frame,look,relight,
    anisotropy:Math.min(8,renderer.capabilities.getMaxAnisotropy()),
    dispose(){environment?.dispose();floor.geometry.dispose();floor.material.dispose();renderer.dispose();}
  };
}
