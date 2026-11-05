// Prepare silent website demo excerpts from the user-selected SouthPole directory.
// Originals are read only. This script makes no network or generation requests.
import {spawnSync} from 'node:child_process';
import {mkdtemp,copyFile,rm,stat,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {buildFilmstrips} from './build-showcase-filmstrips.mjs';
const source=process.argv[2];
if (!source) throw new Error('Usage: node scripts/build-showcase-media.mjs /path/to/AI_Video_SouthPole');
const media=fileURLToPath(new URL('../public/media/',import.meta.url));
const scratch=await mkdtemp(join(tmpdir(),'SrtFlow-showcase-'));
const files=['Shot_船往前开.mp4','Shot_抱企鹅5秒.mp4','Shot_鲸鱼.mp4','Shot对着镜头南极洲气温.mp4','Shot对着镜头南极洲气温_1920x1080_topaz-precision.mp4','Shot_Speak1.mp4'];
function run(command,args) {
  const result=spawnSync(command,args,{encoding:'utf8'});
  if(result.error)throw result.error;
  if(result.status!==0)throw new Error(result.stderr);
  return result.stdout;
}
function convert(input,name,width,height,seconds) {
  run('ffmpeg',['-hide_banner','-loglevel','error','-i',input,'-t',String(seconds),'-an','-vf',`scale=${width}:${height}:force_original_aspect_ratio=increase,crop=${width}:${height},setsar=1,fps=24,format=yuv420p`,'-c:v','libx264','-preset','medium','-crf','27','-movflags','+faststart','-y',join(scratch,name)]);
}
function poster(input,name) {
  run('ffmpeg',['-hide_banner','-loglevel','error','-ss','1','-i',input,'-frames:v','1','-vf','scale=960:540:force_original_aspect_ratio=increase,crop=960:540','-q:v','3','-y',join(scratch,name)]);
}
try {
  const inputs=files.map(name=>resolve(source,name));
  for(const input of inputs)await stat(input);
  const output=[];
  for(let i=0;i<3;i++) {
    convert(inputs[i],`clip-${i}.mp4`,960,540,5);
    poster(inputs[i],`demo-shot-${i}.jpg`);output.push(`demo-shot-${i}.jpg`);
  }
  await writeFile(join(scratch,'clips.txt'),[0,1,2].map(i=>`file 'clip-${i}.mp4'`).join('\n'));
  run('ffmpeg',['-hide_banner','-loglevel','error','-f','concat','-safe','0','-i',join(scratch,'clips.txt'),'-c','copy','-movflags','+faststart','-y',join(scratch,'demo-create.mp4')]);
  convert(inputs[3],'demo-talk-720.mp4',1280,720,9);
  convert(inputs[4],'demo-talk-1080.mp4',1920,1080,9);
  poster(inputs[3],'demo-talk.jpg');
  convert(inputs[5],'demo-speak.mp4',1280,720,10);
  poster(inputs[5],'demo-speak.jpg');
  output.push('demo-create.mp4','demo-talk-720.mp4','demo-talk-1080.mp4','demo-talk.jpg','demo-speak.mp4','demo-speak.jpg');
  for(const name of output) {
    if(name.endsWith('.mp4')) {
      const data=JSON.parse(run('ffprobe',['-v','error','-show_entries','stream=codec_type,width,height:format=duration','-of','json',join(scratch,name)]));
      const duration=name==='demo-create.mp4'?15:name==='demo-speak.mp4'?10:9;
      if(data.streams.length!==1||data.streams[0].codec_type!=='video'||Math.abs(Number(data.format.duration)-duration)>.06)throw new Error(`Invalid silent demo ${name}`);
      console.log(name,JSON.stringify(data));
    }
    await copyFile(join(scratch,name),join(media,name));
  }
  console.log('Prepared nine local demo assets from the original Antarctic footage');
  await buildFilmstrips(media);
} finally {await rm(scratch,{recursive:true,force:true});}
