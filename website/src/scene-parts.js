// Layered footage cards and their slot transitions. Playback and renderer lifecycle live elsewhere.
import * as THREE from 'three';
import {roundedFace,openRim} from './scene-shapes.js';
import {buildDeck} from './scene-deck.js';
import {SCENE_CLIPS,cardOrder} from './scene-playback.js';

const slots=[
  {x:-2.5,y:1.3,z:.70,scale:1},
  {x:-.10,y:1.15,z:-.10,scale:.82},
  {x:2.08,y:1.00,z:-.85,scale:.68},
  {x:3.90,y:.87,z:-1.50,scale:.56}
];

function photoTexture(image){
  const texture=new THREE.Texture(image);texture.needsUpdate=true;
  texture.colorSpace=THREE.SRGBColorSpace;return texture;
}

function footageCard(image){
  const group=new THREE.Group();
  const still=photoTexture(image);
  const rimMaterial=new THREE.MeshStandardMaterial({color:'#285b44',roughness:.28,metalness:.6,transparent:true,opacity:.82});
  const rim=new THREE.Mesh(openRim(5,3.125,.18,.025),rimMaterial);
  rim.position.z=-.024;group.add(rim);
  const face=roundedFace(5,3.125,.18);
  const frontMaterial=new THREE.MeshBasicMaterial({map:still,side:THREE.FrontSide,transparent:true,opacity:.97,depthWrite:true,toneMapped:false});
  const backMaterial=new THREE.MeshBasicMaterial({map:still,side:THREE.BackSide,transparent:true,opacity:.48,depthWrite:false,toneMapped:false});
  // Both faces carry the footage. The back is translucent rather than an opaque blank plate.
  group.add(new THREE.Mesh(face,frontMaterial),new THREE.Mesh(face,backMaterial));
  return {group,still,frontMaterial,backMaterial,rimMaterial,visibility:1,rank:0};
}

export async function buildSculpture(compact=false,videoTexture=null){
  const images=await Promise.all(SCENE_CLIPS.map(clip=>new Promise((resolve,reject)=>{
    const image=new Image();image.onload=()=>resolve(image);image.onerror=reject;
    image.src=`/media/scene-${clip.id}.jpg`;
  })));
  const model=new THREE.Group(),deck=buildDeck(images);
  model.add(deck.group);
  const cards=images.map(footageCard),target=new THREE.Vector3();
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
      card.frontMaterial.opacity=.97*card.visibility;
      card.backMaterial.opacity=.48*card.visibility;
      card.rimMaterial.opacity=.82*card.visibility;
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
      if(material.map&&!material.map.isVideoTexture)textures.add(material.map);
    }
  });
  textures.forEach(texture=>texture.dispose());materials.forEach(material=>material.dispose());
  geometries.forEach(geometry=>geometry.dispose());
}
