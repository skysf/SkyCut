// Fingerprint of everything the baked hero still is rendered from, and of the files that bake wrote.
// The bake records it; a test recomputes it, so a scene change without a new bake cannot be merged.
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {HERO_STILLS,stillFormats} from './hero-still.mjs';
import {SCENE_CLIPS} from '../src/scene-playback.js';

const root=new URL('../',import.meta.url);
export const STAMP_FILE=new URL('hero-still-stamp.json',import.meta.url);
// What the picture depends on: the scene modules, the four posters and the bake itself.
// The live-only modules (scene.js, scene-media.js, scene-governor.js) do not change a motionless frame.
export const STILL_SOURCES=[
  'src/scene-still.js','src/scene-stage.js','src/scene-environment.js','src/scene-deck.js','src/scene-parts.js',
  'src/scene-shapes.js','src/scene-playback.js','scripts/hero-still.mjs','scripts/build-hero-still.mjs',
  ...SCENE_CLIPS.map(clip=>`public/media/scene-${clip.id}.jpg`)
];
// The renderer and the font drawn on the deck are pinned packages: a new version is a new picture.
const PACKAGES=['three','@fontsource-variable/outfit'];
export const stillFiles=()=>HERO_STILLS.flatMap(still=>still.heights.flatMap(height=>
  stillFormats(still,height).map(format=>`hero-still-${still.name}-${height}.${format}`)));

export async function stillStamp(){
  const manifest=JSON.parse(await readFile(new URL('package.json',root),'utf8'));
  const sources=createHash('sha256');
  for(const name of PACKAGES)sources.update(`${name}@${manifest.dependencies[name]}\n`);
  for(const path of STILL_SOURCES)sources.update(`${path}\n`).update(await readFile(new URL(path,root)));
  const files={};
  for(const file of stillFiles()){
    files[file]=createHash('sha256').update(await readFile(new URL(`public/media/${file}`,root))).digest('hex');
  }
  return {sources:sources.digest('hex'),files};
}
