// Bake the hero fallback image from the real Three.js scene with a local headless Chromium.
// No downloads, uploads or deployments. Needs a Chromium-based browser and Python with Pillow.
import {spawn,spawnSync} from 'node:child_process';
import {mkdtemp,writeFile,copyFile,rm,readdir,access,mkdir} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir,homedir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {createServer} from 'vite';
import {HERO_STILLS,PAPER,stillFormats} from './hero-still.mjs';
import {stillStamp,STAMP_FILE} from './hero-still-stamp.mjs';

const root=fileURLToPath(new URL('../',import.meta.url));
const media=join(root,'public/media');
// `--review <dir>` writes plain PNGs of other poses for looking at the scene; nothing is published.
const reviewDir=process.argv[2]==='--review'?process.argv[3]:null;
if(process.argv[2]&&!reviewDir)throw new Error('Usage: npm run build:hero-still [-- --review /path/to/folder]');

const shots=reviewDir?[
  ...[0,.9,1.8,2.7,3.6,4.5,5.4].map((turn,i)=>({name:`turn-${i}`,width:1700,height:1120,turn})),
  ...[5,10,15].map(seconds=>({name:`clip-${seconds}`,width:1700,height:1120,seconds})),
  {name:'compact',width:740,height:640,compact:true}
]:HERO_STILLS.flatMap(still=>still.heights.map(height=>(
  {name:`${still.name}-${height}`,width:Math.round(height*still.aspect),height,compact:still.compact})));

async function browserPath(){
  const cache=join(homedir(),'Library/Caches/ms-playwright');
  const shells=(await readdir(cache).catch(()=>[])).filter(name=>name.startsWith('chromium_headless_shell-')).sort().reverse()
    .flatMap(name=>['arm64','x64'].map(arch=>join(cache,name,`chrome-headless-shell-mac-${arch}`,'chrome-headless-shell')));
  const candidates=[process.env.CHROME_PATH,...shells,
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome','/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge'].filter(Boolean);
  for(const candidate of candidates){try{await access(candidate);return candidate;}catch{}}
  throw new Error('No Chromium-based browser found. Set CHROME_PATH to one.');
}

const page=`<!doctype html><meta charset="utf-8"><link rel="stylesheet" href="/src/styles/base.css"><canvas></canvas>
<script type="module">
import {renderStill} from '/src/scene-still.js';
const post=(path,body)=>fetch('/__hero-still/'+path,{method:'POST',body});
try{
  const shots=await (await fetch('/__hero-still/shots')).json();
  for(const shot of shots){
    const canvas=document.createElement('canvas');
    const dispose=await renderStill(canvas,shot);
    const blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/png'));
    dispose();
    if(!blob)throw new Error('No image for '+shot.name);
    await post('shot?name='+shot.name,blob);
  }
  await post('done','');
}catch(error){await post('error',String(error&&error.stack||error));}
</script>`;

const scratch=await mkdtemp(join(tmpdir(),'SrtFlow-website-hero-'));
let finish,fail;
const finished=new Promise((resolve,reject)=>{finish=resolve;fail=reject;});
const body=request=>new Promise((resolve,reject)=>{
  const chunks=[];request.on('data',chunk=>chunks.push(chunk));
  request.on('end',()=>resolve(Buffer.concat(chunks)));request.on('error',reject);
});
const server=await createServer({root,logLevel:'error',server:{port:0,strictPort:false,host:'127.0.0.1'},plugins:[{
  name:'skycut-hero-still',
  configureServer(vite){vite.middlewares.use('/__hero-still',async(request,response)=>{
    const url=new URL(request.url,'http://local');
    if(url.pathname==='/')return response.setHeader('Content-Type','text/html').end(page);
    if(url.pathname==='/shots')return response.setHeader('Content-Type','application/json').end(JSON.stringify(shots));
    const data=await body(request);
    if(url.pathname==='/shot'){
      const shot=shots.find(item=>item.name===url.searchParams.get('name'));
      if(!shot)return response.writeHead(400).end();
      await writeFile(join(scratch,`${shot.name}.png`),data);
    }else if(url.pathname==='/done')finish();
    else if(url.pathname==='/error')fail(new Error(`The scene did not render: ${data}`));
    response.end('ok');
  });}
}]});
await server.listen();
const address=server.httpServer.address();
// The bake does not need speed: software WebGL gives the same picture on every machine.
// HERO_STILL_GPU=1 uses the Mac's own GPU instead, which is quicker for review frames.
const webgl=process.env.HERO_STILL_GPU?['--use-angle=metal','--enable-gpu','--ignore-gpu-blocklist']:['--enable-unsafe-swiftshader','--use-angle=swiftshader'];
const browser=spawn(await browserPath(),['--headless','--remote-debugging-port=0','--no-first-run','--mute-audio','--hide-scrollbars',
  ...webgl,`--user-data-dir=${join(scratch,'profile')}`,
  `http://127.0.0.1:${address.port}/__hero-still/`],{stdio:'ignore'});
const timeout=setTimeout(()=>fail(new Error('Timed out waiting for the headless browser')),240000);
browser.on('error',fail);
browser.on('exit',code=>fail(new Error(`The headless browser exited early (${code})`)));

const encode=`
import sys
from PIL import Image
source,stem,paper,formats=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4].split(',')
image=Image.open(source).convert('RGBA')
if 'avif' in formats: image.save(stem+'.avif','AVIF',quality=62,speed=3)
if 'webp' in formats: image.save(stem+'.webp','WEBP',quality=84,method=6)
if 'jpg' in formats:
    flat=Image.new('RGB',image.size,paper); flat.paste(image,mask=image.getchannel('A'))
    flat.save(stem+'.jpg','JPEG',quality=82,optimize=True,progressive=True)
`;
try{
  // Stop the browser and the dev server before anything is written into public/.
  try{await finished;}finally{
    clearTimeout(timeout);browser.removeAllListeners('exit');browser.kill();await server.close();
  }
  if(reviewDir){
    await mkdir(reviewDir,{recursive:true});
    for(const shot of shots)await copyFile(join(scratch,`${shot.name}.png`),join(reviewDir,`${shot.name}.png`));
    console.log(`Wrote ${shots.length} review frames to ${reviewDir}`);
  }else{
    for(const still of HERO_STILLS)for(const height of still.heights){
      const name=`${still.name}-${height}`,formats=stillFormats(still,height);
      const result=spawnSync('python3',['-c',encode,join(scratch,`${name}.png`),join(scratch,`hero-still-${name}`),PAPER,formats.join(',')],{encoding:'utf8'});
      if(result.error)throw result.error;
      if(result.status!==0)throw new Error(result.stderr||`Pillow exited ${result.status}`);
      for(const format of formats)await copyFile(join(scratch,`hero-still-${name}.${format}`),join(media,`hero-still-${name}.${format}`));
    }
    // Record what this bake was rendered from and what it wrote; tests/hero-scene.test.mjs compares.
    await writeFile(STAMP_FILE,JSON.stringify(await stillStamp(),null,2)+'\n');
    console.log(`Baked ${shots.length} hero stills into public/media and stamped them`);
  }
}finally{await rm(scratch,{recursive:true,force:true});}
