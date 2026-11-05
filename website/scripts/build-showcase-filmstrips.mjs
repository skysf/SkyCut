// Generate real sequential thumbnail sheets from the local website demo videos.
// These sheets are static timeline UI assets, never video decoders or remote requests.
import {spawnSync} from 'node:child_process';
import {copyFile,mkdtemp,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {SHOWCASE_MEDIA} from '../src/showcase-media.js';
export const FILMSTRIP_FRAMES=12;
export async function buildFilmstrips(media) {
  const scratch=await mkdtemp(join(tmpdir(),'SrtFlow-filmstrips-'));
  try {
    for(const [kind,clip] of Object.entries(SHOWCASE_MEDIA)) {
      const name=`demo-${kind}-strip.jpg`;
      const result=spawnSync('ffmpeg',['-hide_banner','-loglevel','error','-i',join(media,clip.video.split('/').at(-1)),'-vf',`fps=${FILMSTRIP_FRAMES}/${clip.duration},scale=160:90,tile=${FILMSTRIP_FRAMES}x1`,'-frames:v','1','-q:v','3','-y',join(scratch,name)],{encoding:'utf8'});
      if(result.error)throw result.error;
      if(result.status!==0)throw new Error(result.stderr);
      await copyFile(join(scratch,name),join(media,name));
      console.log(`Created ${name} with ${FILMSTRIP_FRAMES} sequential frames`);
    }
  } finally {await rm(scratch,{recursive:true,force:true});}
}
if(process.argv[1]===fileURLToPath(import.meta.url))await buildFilmstrips(fileURLToPath(new URL('../public/media/',import.meta.url)));
