// The baked hero image: one wide and one phone composition, their sizes and the static markup.
// A perspective camera with a fixed vertical field of view shows the same picture at any width,
// only cropped at the sides. So one image wider than every layout, fitted by height, lines up
// with the live canvas at every breakpoint. Heights include the bleed on both sides.
import {COMPACT_QUERY,SCENE_BLEED} from '../src/scene-playback.js';

export const PAPER='#f3f0e8';
export const HERO_STILLS=[
  {name:'wide',compact:false,aspect:8/5,heights:[720,1080,1440]},
  {name:'compact',compact:true,aspect:7/4,heights:[768,1152]}
];
// The scene heights of home.css and responsive.css, by layout. The image is fitted to the height
// plus bleed, so its rendered width follows from that, not from the width of the box.
export const SCENE_HEIGHTS={phone:320,tablet:510,narrow:490,desktop:560,large:650};
// Every size ships as AVIF and WebP with alpha; only the smallest also as the flattened JPEG fallback.
export const stillFormats=(still,height)=>height===still.heights[0]?['avif','webp','jpg']:['avif','webp'];
const shown=(still,height)=>Math.round(height*(1+SCENE_BLEED*2)*still.aspect);
const sizes=still=>still.compact?`${shown(still,SCENE_HEIGHTS.phone)}px`:
  `(max-width: 900px) ${shown(still,SCENE_HEIGHTS.tablet)}px, (max-width: 1150px) ${shown(still,SCENE_HEIGHTS.narrow)}px, `+
  `(min-width: 1600px) ${shown(still,SCENE_HEIGHTS.large)}px, ${shown(still,SCENE_HEIGHTS.desktop)}px`;
const width=(still,height)=>Math.round(height*still.aspect);
const srcset=(still,format)=>still.heights.map(height=>`/media/hero-still-${still.name}-${height}.${format} ${width(still,height)}w`).join(', ');

export function heroStill(alt){
  const [wide,compact]=HERO_STILLS;
  const sources=[compact,wide].flatMap(still=>['avif','webp'].map(format=>
    `<source ${still.compact?`media="${COMPACT_QUERY}" `:''}type="image/${format}" srcset="${srcset(still,format)}" sizes="${sizes(still)}">`));
  // The JPEG has no alpha, so it is flattened onto the page colour; only very old browsers get it.
  return `<picture class="scene-still">${sources.join('')}<source media="${COMPACT_QUERY}" srcset="/media/hero-still-compact-${compact.heights[0]}.jpg">`+
    `<img src="/media/hero-still-wide-${wide.heights[0]}.jpg" alt="${alt}" width="${width(wide,wide.heights[0])}" height="${wide.heights[0]}" decoding="async" fetchpriority="high"></picture>`;
}
