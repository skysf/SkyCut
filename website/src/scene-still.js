// One motionless frame of the hero scene. The fallback image is baked from the opening pose.
import {createStage} from './scene-stage.js';
import {buildSculpture,updateSculpture,disposeSculpture} from './scene-parts.js';
import {playbackAt,turnAt,OPENING_ANGLE,COMPACT_SCALE,SCENE_BLEED} from './scene-playback.js';

// `width` x `height` is the whole image, bleed included.
export async function renderStill(canvas,{width,height,compact=false,seconds=0,turn=0}){
  const stage=createStage(canvas,{still:true});stage.relight();
  const model=await buildSculpture(compact,null,{anisotropy:stage.anisotropy});
  stage.scene.add(model);updateSculpture(model,playbackAt(seconds),0,false);
  model.rotation.y=turnAt(0)+OPENING_ANGLE+turn;model.scale.setScalar(compact?COMPACT_SCALE:1);
  const bleed=height*SCENE_BLEED/(1+SCENE_BLEED*2);
  stage.frame(width-bleed*2,height-bleed*2,bleed,compact,1);stage.renderer.render(stage.scene,stage.camera);
  return ()=>{disposeSculpture(model);stage.dispose();};
}
