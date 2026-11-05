// Extract the local hero clips from the film and supplied replacement. No downloads or deployments.
import {spawnSync} from 'node:child_process';
import {mkdtemp,writeFile,copyFile,rm,stat} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {SCENE_CLIPS,CLIP_SECONDS,SOURCE_SECONDS,REEL_SECONDS} from '../src/scene-playback.js';

if(!process.argv[2]||!process.argv[3])throw new Error('Usage: npm run build:scene-media -- /path/to/antarctica-720p.mp4 /path/to/penguins.mp4');
const source=resolve(process.argv[2]);await stat(source);
const penguins=resolve(process.argv[3]);await stat(penguins);
const media=fileURLToPath(new URL('../public/media/',import.meta.url));
const scratch=await mkdtemp(join(tmpdir(),'SrtFlow-website-reel-'));
function run(command,args){
  const result=spawnSync(command,args,{encoding:'utf8'});
  if(result.error)throw result.error;
  if(result.status!==0)throw new Error(result.stderr||`${command} exited ${result.status}`);
  return result.stdout;
}
try{
  for(const clip of SCENE_CLIPS){
    const input=clip.source==='penguins'?penguins:source;
    const duration=clip.duration??CLIP_SECONDS,sourceSeconds=clip.sourceSeconds??SOURCE_SECONDS;
    // Film excerpts are slowed; the supplied ten-second penguin shot keeps its full frame and speed.
    const fit=clip.source==='penguins'?'scale=640:360':'crop=1120:630:80:0,scale=640:360';
    const filter=`trim=duration=${sourceSeconds},setpts=${duration/sourceSeconds}*(PTS-STARTPTS),fps=20,tpad=stop_mode=clone:stop_duration=0.2,trim=duration=${duration},${fit},format=yuv420p`;
    run('ffmpeg',['-hide_banner','-loglevel','error','-ss',String(clip.sourceStart),'-i',input,'-vf',filter,'-an','-c:v','libx264','-preset','medium','-crf','25','-movflags','+faststart','-y',join(scratch,`${clip.id}.mp4`)]);
    run('ffmpeg',['-hide_banner','-loglevel','error','-ss',String(clip.sourceStart+(clip.posterOffset??.25)),'-i',input,'-frames:v','1','-vf',fit,'-q:v','3','-y',join(scratch,`scene-${clip.id}.jpg`)]);
  }
  const list=join(scratch,'clips.txt');
  await writeFile(list,SCENE_CLIPS.map(clip=>`file '${clip.id}.mp4'`).join('\n'));
  const output=join(scratch,'timeline-loop.mp4');
  run('ffmpeg',['-hide_banner','-loglevel','error','-f','concat','-safe','0','-i',list,'-c','copy','-movflags','+faststart','-y',output]);
  const probe=JSON.parse(run('ffprobe',['-v','error','-show_entries','stream=codec_type,width,height:format=duration','-of','json',output]));
  if(probe.streams.length!==1||probe.streams[0].codec_type!=='video'||Math.abs(Number(probe.format.duration)-REEL_SECONDS)>.06)throw new Error('Reel must be silent and match the timeline duration');
  for(const clip of SCENE_CLIPS)await copyFile(join(scratch,`scene-${clip.id}.jpg`),join(media,`scene-${clip.id}.jpg`));
  await copyFile(output,join(media,'timeline-loop.mp4'));
  console.log(`Created ${REEL_SECONDS}s silent hero reel and four posters`);
}finally{await rm(scratch,{recursive:true,force:true});}
