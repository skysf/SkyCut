// Rounded, UV-mapped glass faces and open rims shared by cards and the timeline deck.
import * as THREE from 'three';
import {toCreasedNormals} from 'three/addons/utils/BufferGeometryUtils.js';

export function roundedShape(width,height,radius) {
  const x=-width/2,y=-height/2,r=Math.min(radius,width/2,height/2);
  const shape=new THREE.Shape();
  shape.moveTo(x+r,y);
  shape.lineTo(x+width-r,y);shape.quadraticCurveTo(x+width,y,x+width,y+r);
  shape.lineTo(x+width,y+height-r);shape.quadraticCurveTo(x+width,y+height,x+width-r,y+height);
  shape.lineTo(x+r,y+height);shape.quadraticCurveTo(x,y+height,x,y+height-r);
  shape.lineTo(x,y+r);shape.quadraticCurveTo(x,y,x+r,y);
  return shape;
}

export function roundedFace(width,height,radius=.12) {
  const geometry=new THREE.ShapeGeometry(roundedShape(width,height,radius),16);
  const position=geometry.attributes.position;
  const uv=new Float32Array(position.count*2);
  for(let i=0;i<position.count;i++) {
    uv[i*2]=(position.getX(i)+width/2)/width;
    uv[i*2+1]=(position.getY(i)+height/2)/height;
  }
  geometry.setAttribute('uv',new THREE.BufferAttribute(uv,2));
  return geometry;
}

// `border` is how far the frame reaches beyond the opening. Most of that band is rounded shoulder
// rather than flat face, so some part of it always catches a light as the scene turns.
export function openRim(width,height,radius=.14,border=.035) {
  const bevel=Math.min(.013,border*.38),flat=border-bevel;
  const shape=roundedShape(width+flat*2,height+flat*2,radius+flat);
  const hole=roundedShape(width+bevel*2,height+bevel*2,radius+bevel);
  shape.holes.push(new THREE.Path(hole.getPoints(64).reverse()));
  const extruded=new THREE.ExtrudeGeometry(shape,{depth:.04,bevelEnabled:true,bevelSegments:5,steps:1,bevelSize:bevel,bevelThickness:.016,curveSegments:16});
  // Extrusions are faceted; smoothing across the bevel lets the edge carry one clean highlight.
  const smooth=toCreasedNormals(extruded,Math.PI/5);extruded.dispose();return smooth;
}
