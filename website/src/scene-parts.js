// Layered footage cards and their slot transitions. Playback and renderer lifecycle live elsewhere.
import * as THREE from 'three';
import {roundedFace,openRim} from './scene-shapes.js';
import {buildDeck,DECK_FONT} from './scene-deck.js';
import {breathe} from './scene-stage.js';
import {SCENE_CLIPS,cardOrder} from './scene-playback.js';

const slots=[
  {x:-2.5,y:1.3,z:.70,scale:1},
  {x:-.10,y:1.15,z:-.10,scale:.82},
  {x:2.08,y:1.00,z:-.85,scale:.68},
  {x:3.90,y:.87,z:-1.50,scale:.56}
];
const FRONT=.97,BACK=.48,PANE=.016;

function photoTexture(image,anisotropy){
  const texture=new THREE.Texture(image);texture.needsUpdate=true;
  texture.colorSpace=THREE.SRGBColorSpace;texture.anisotropy=anisotropy;return texture;
}

// A cheap stand-in for transmission: a black, mirror-smooth layer that only adds its reflection.
// Alpha is left alone so the page still shows through the translucent back of a card.
function glassMaterial(side){
  return new THREE.MeshPhysicalMaterial({color:'#000',roughness:.07,metalness:0,ior:1.5,envMapIntensity:1,side,
    transparent:true,depthWrite:false,blending:THREE.CustomBlending,blendEquation:THREE.AddEquation,
    blendSrc:THREE.SrcAlphaFactor,blendDst:THREE.OneFactor,blendSrcAlpha:THREE.ZeroFactor,blendDstAlpha:THREE.OneFactor});
}

function footageCard(image,shapes,anisotropy){
  const group=new THREE.Group();
  const still=photoTexture(image,anisotropy);
  const rimMaterial=new THREE.MeshPhysicalMaterial({color:'#266347',roughness:.3,metalness:.45,clearcoat:1,clearcoatRoughness:.06,transparent:true});
  const rim=new THREE.Mesh(shapes.rim,rimMaterial);
  rim.position.z=-.02;rim.castShadow=true;group.add(rim);
  const frontMaterial=new THREE.MeshBasicMaterial({map:still,side:THREE.FrontSide,transparent:true,opacity:FRONT,depthWrite:true,toneMapped:false});
  const backMaterial=new THREE.MeshBasicMaterial({map:still,side:THREE.BackSide,transparent:true,opacity:BACK,depthWrite:false,toneMapped:false});
  // Both faces carry the footage. The back is translucent rather than an opaque blank plate.
  const front=new THREE.Mesh(shapes.face,frontMaterial),back=new THREE.Mesh(shapes.face,backMaterial);
  front.position.z=PANE;back.position.z=-PANE;front.castShadow=true;frontMaterial.shadowSide=THREE.DoubleSide;
  const sheens=[glassMaterial(THREE.FrontSide),glassMaterial(THREE.BackSide)];
  const frontSheen=new THREE.Mesh(shapes.face,sheens[0]),backSheen=new THREE.Mesh(shapes.face,sheens[1]);
  frontSheen.position.z=PANE+.003;backSheen.position.z=-PANE-.003;
  group.add(front,back,frontSheen,backSheen);
  return {group,still,frontMaterial,backMaterial,rimMaterial,sheens,visibility:1,rank:0};
}

export async function buildSculpture(compact=false,videoTexture=null,{anisotropy=1}={}){
  const [images]=await Promise.all([
    Promise.all(SCENE_CLIPS.map(clip=>new Promise((resolve,reject)=>{
      const image=new Image();image.onload=()=>resolve(image);image.onerror=reject;
      image.src=`/media/scene-${clip.id}.jpg`;
    }))),
    // The deck lettering is drawn once; wait for the page font so it never falls back.
    document.fonts?.load(`500 24px ${DECK_FONT}`).catch(()=>{})
  ]);
  const model=new THREE.Group(),deck=await buildDeck(images,{anisotropy});
  model.add(deck.group);
  const shapes={rim:openRim(5,3.125,.18,.036),face:roundedFace(5,3.125,.18)};
  await breathe();
  const cards=images.map(image=>footageCard(image,shapes,anisotropy)),target=new THREE.Vector3();
  model.userData.stills=cards.map(card=>card.still);
  cards.forEach((card,index)=>{
    const pose=slots[index];card.rank=index;
    card.group.position.set(pose.x,pose.y,pose.z);
    card.group.scale.setScalar(pose.scale);
    // Keep card edges aligned with the deck; only the shared turntable rotates.
    card.group.rotation.set(0,0,0);
    model.add(card.group);
  });
  let active=-1;
  model.userData.update=(playback,dt,videoReady)=>{
    const order=cardOrder(playback.active);
    const blend=1-Math.exp(-dt*5.5);
    if(active!==playback.active||model.userData.videoReady!==videoReady){
      active=playback.active;model.userData.videoReady=videoReady;
      cards.forEach((card,index)=>{
        const texture=index===active&&videoReady?videoTexture:card.still;
        card.frontMaterial.map=texture;card.backMaterial.map=texture;
        card.frontMaterial.needsUpdate=true;card.backMaterial.needsUpdate=true;
      });
    }
    cards.forEach((card,index)=>{
      const rank=order.indexOf(index),pose=slots[rank];
      const lift=card.rank===0&&rank===3?Math.sin(Math.min(playback.localTime/.85,1)*Math.PI)*.65:0;
      const amount=dt?blend:1;
      card.group.position.lerp(target.set(pose.x,pose.y+lift,pose.z-lift),amount);
      card.group.scale.lerp(target.setScalar(pose.scale),amount);
      const targetVisibility=compact&&rank>1?0:1;
      card.visibility=THREE.MathUtils.lerp(card.visibility,targetVisibility,amount);
      card.frontMaterial.opacity=FRONT*card.visibility;
      card.backMaterial.opacity=BACK*card.visibility;
      card.rimMaterial.opacity=card.visibility;
      card.sheens.forEach(sheen=>{sheen.opacity=card.visibility;});
      card.group.visible=card.visibility>.005;
      if(playback.localTime>.85)card.rank=rank;
    });
    deck.update(playback);
  };
  return model;
}

export function updateSculpture(model,playback,dt,videoReady){
  model.userData.update(playback,dt,videoReady);
}

export function disposeSculpture(object){
  const textures=new Set(object.userData.stills||[]),materials=new Set(),geometries=new Set();
  object.traverse(child=>{
    if(child.geometry)geometries.add(child.geometry);
    if(child.material)for(const material of Array.isArray(child.material)?child.material:[child.material]){
      materials.add(material);
      for(const key of ['map','bumpMap','roughnessMap']){
        if(material[key]&&!material[key].isVideoTexture)textures.add(material[key]);
      }
    }
  });
  textures.forEach(texture=>texture.dispose());materials.forEach(material=>material.dispose());
  geometries.forEach(geometry=>geometry.dispose());
}
