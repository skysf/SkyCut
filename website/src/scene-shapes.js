// Rounded, UV-mapped glass faces and open rims shared by cards and the timeline deck.
import * as THREE from 'three';

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

export function openRim(width,height,radius=.14,border=.035) {
  const shape=roundedShape(width+border*2,height+border*2,radius+border);
  const hole=roundedShape(width,height,radius);
  shape.holes.push(new THREE.Path(hole.getPoints(64).reverse()));
  return new THREE.ExtrudeGeometry(shape,{depth:.045,bevelEnabled:true,bevelSegments:2,steps:1,bevelSize:.012,bevelThickness:.012,curveSegments:12});
}
