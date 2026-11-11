// Manual check of the hero in real browser engines: headless, on the built site, no window is opened.
// Playwright is not a dependency of this package and CI does not run this. On a Mac, after `npm run build`:
//   npx -y playwright@1.65.0 install chromium webkit firefox     (once per machine)
//   npx -y -p playwright@1.65.0 node scripts/check-hero-browsers.mjs [--out <folder>] [--engines chromium,webkit,firefox]
import {createRequire} from 'node:module';
import {execFileSync} from 'node:child_process';
import {realpathSync} from 'node:fs';
import {mkdir,access} from 'node:fs/promises';
import {dirname,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {preview} from 'vite';

const PLAYWRIGHT='1.65.0';
const root=fileURLToPath(new URL('../',import.meta.url));
const option=name=>{const at=process.argv.indexOf(`--${name}`);return at>0?process.argv[at+1]:null;};
const out=option('out'),engineNames=(option('engines')||'chromium,webkit,firefox').split(',');

// `npx -p playwright@x node …` puts the package's command on PATH; follow it back to the package itself.
function loadPlaywright(){
  let home;
  try{home=dirname(realpathSync(execFileSync('which',['playwright'],{encoding:'utf8'}).trim()));}catch{
    throw new Error(`Playwright is not on PATH. Run: npx -y -p playwright@${PLAYWRIGHT} node scripts/check-hero-browsers.mjs`);
  }
  const require=createRequire(join(home,'package.json')),version=require('./package.json').version;
  if(version!==PLAYWRIGHT)throw new Error(`This check is pinned to playwright@${PLAYWRIGHT}, found ${version}`);
  return require('./index.js');
}
if(process.platform!=='darwin')throw new Error('This check needs a Mac: headless Chromium only gets a real GPU through Metal here.');
await access(join(root,'dist/en/index.html')).catch(()=>{throw new Error('Build the site first: npm run build');});
const playwright=loadPlaywright();
const launch={
  chromium:()=>playwright.chromium.launch({headless:true,args:['--use-angle=metal','--enable-gpu','--ignore-gpu-blocklist','--mute-audio']}),
  webkit:()=>playwright.webkit.launch({headless:true}),
  firefox:()=>playwright.firefox.launch({headless:true,firefoxUserPrefs:{'media.volume_scale':'0.0'}})
};
if(out)await mkdir(out,{recursive:true});
const server=await preview({root,logLevel:'silent',preview:{port:0,strictPort:false,host:'127.0.0.1'}});
const base=`http://127.0.0.1:${server.httpServer.address().port}`;

let failed=0,passed=0;
function check(name,ok,detail=''){
  if(ok)passed++;else failed++;
  console.log(`${ok?'PASS':'FAIL'} ${name}${detail?`  ${detail}`:''}`);
}
// Count what the hero itself draws; other parts of the page keep animation frames of their own.
const countDraws=()=>{
  window.__draws=0;
  if(!window.WebGL2RenderingContext)return;
  for(const name of ['drawElements','drawArrays','drawElementsInstanced','drawArraysInstanced']){
    const original=WebGL2RenderingContext.prototype[name];
    WebGL2RenderingContext.prototype[name]=function(...args){window.__draws++;return original.apply(this,args);};
  }
};
const withoutWebGL=()=>{
  const original=HTMLCanvasElement.prototype.getContext;
  HTMLCanvasElement.prototype.getContext=function(type,...rest){return /webgl/i.test(type)?null:original.call(this,type,...rest);};
};
const pausedFromTheStart=()=>{try{localStorage.setItem('SrtFlow.website.motionPaused','true');}catch{}};
const state=page=>page.evaluate(()=>{
  const host=document.querySelector('.hero-visual'),canvas=host.querySelector('canvas'),still=host.querySelector('.scene-still'),image=still.querySelector('img');
  const shown=element=>{const style=getComputedStyle(element);return style.display!=='none'&&style.visibility!=='hidden'&&Number(style.opacity)>.5;};
  return {ready:host.classList.contains('scene-ready'),fallback:host.dataset.sceneFallback||null,canvas:shown(canvas),
    still:shown(still)&&image.complete&&image.naturalWidth>0,toggle:shown(host.querySelector('.motion-toggle')),
    size:`${canvas.width}x${canvas.height}`,box:JSON.stringify(host.getBoundingClientRect()),
    columns:getComputedStyle(document.querySelector('.hero')).gridTemplateColumns.split(' ').length,
    sceneScripts:performance.getEntriesByType('resource').filter(entry=>/\/assets\/scene-/.test(entry.name)).length};
});
const draws=async(page,ms=1000)=>{const before=await page.evaluate(()=>window.__draws);await page.waitForTimeout(ms);return (await page.evaluate(()=>window.__draws))-before;};
const live=page=>page.waitForFunction(()=>document.querySelector('.hero-visual').classList.contains('scene-ready'),null,{timeout:20000});
// WebKit logs its own media-control icons in headless mode; the static preview has no signup API.
const noise=/Button failed to load|Failed to load resource|404/;
async function open(browser,{init=[],...options}={}){
  const context=await browser.newContext({viewport:{width:1440,height:900},deviceScaleFactor:2,locale:'en-US',...options});
  if(options.javaScriptEnabled!==false)for(const script of [countDraws,...init])await context.addInitScript(script);
  const page=await context.newPage(),errors=[];
  page.on('pageerror',error=>errors.push(String(error).slice(0,160)));
  page.on('console',message=>{if(message.type()==='error'&&!noise.test(message.text()))errors.push(message.text().slice(0,160));});
  await page.goto(`${base}/en/`,{waitUntil:'load'});
  return {context,page,errors};
}
const shoot=(target,name)=>out?target.screenshot({path:join(out,`${name}.png`)}):null;

// 1. Every engine x layout x {motion, reduced motion} x {WebGL, no WebGL}: one picture, and one box.
// `columns` is the hero grid of that layout: copy beside the scene on a desktop, stacked otherwise.
// It fails when the tablet and phone rules do not apply at all, whatever the scene itself does.
const layouts=[
  {name:'desktop',viewport:{width:1440,height:900},deviceScaleFactor:2,columns:2},
  {name:'ipad',viewport:{width:834,height:1112},deviceScaleFactor:2,columns:1},
  {name:'phone',viewport:{width:390,height:844},deviceScaleFactor:3,columns:1}
];
for(const engine of engineNames){
  const browser=await launch[engine]();
  for(const layout of layouts){
    const boxes=new Set();
    for(const reduced of [false,true])for(const webgl of [true,false]){
      const name=`${engine} ${layout.name} ${reduced?'reduced motion':'motion'} ${webgl?'WebGL':'no WebGL'}`;
      const {context,page,errors}=await open(browser,{viewport:layout.viewport,deviceScaleFactor:layout.deviceScaleFactor,
        reducedMotion:reduced?'reduce':'no-preference',init:webgl?[]:[withoutWebGL]});
      await page.waitForTimeout(4500);
      const now=await state(page),drawn=await draws(page);
      const expected=!reduced&&webgl?now.ready&&now.canvas&&!now.still&&now.toggle&&drawn>200:
        !now.ready&&now.still&&!now.canvas&&!now.toggle&&drawn===0&&(!reduced||now.sceneScripts===0);
      check(name,expected&&now.columns===layout.columns&&errors.length===0,
        `${now.ready?'live':'still'}, ${drawn} draws/s, ${now.columns}-column hero${errors.length?`, ${errors.join(' | ')}`:''}`);
      boxes.add(now.box);
      await shoot(page,name.replace(/ /g,'-'));
      await context.close();
    }
    // Whichever picture is up, the scene sits in exactly the same place. Compared once the page has
    // settled: web fonts arriving shortly after load nudge the whole hero, with or without the scene.
    check(`${engine} ${layout.name}: the scene box is identical in all four states`,boxes.size===1,[...boxes].join(' vs '));
  }
  await browser.close();
}

// 2. Fallbacks, in Chromium. Everything below the hero is hidden so nothing else competes for frames.
if(engineNames.includes('chromium')){
  const quiet=()=>document.addEventListener('DOMContentLoaded',()=>document.querySelectorAll('main>*:not(.hero)').forEach(element=>{element.style.display='none';}));
  let browser=await launch.chromium();
  {
    const {context,page}=await open(browser,{javaScriptEnabled:false});
    await page.waitForTimeout(800);
    const seen=await page.locator('.scene-still img').evaluate(image=>image.complete&&image.naturalWidth>0&&getComputedStyle(image.parentElement).opacity==='1');
    const toggle=await page.locator('.motion-toggle').evaluate(element=>getComputedStyle(element).display);
    check('no JavaScript: the still is shown and the pause button is not',seen&&toggle==='none');
    await shoot(page.locator('.hero'),'no-javascript');await context.close();
  }
  {
    const {context,page,errors}=await open(browser,{init:[quiet]});
    await live(page);
    let now=await state(page),rate=await draws(page);
    check('WebGL and motion: the live scene replaces the still',now.canvas&&!now.still&&now.toggle&&rate>200,`${rate} draws/s`);
    await page.evaluate(()=>{window.__lose=document.querySelector('#timeline-scene').getContext('webgl2').getExtension('WEBGL_lose_context');window.__lose.loseContext();});
    await page.waitForTimeout(600);now=await state(page);rate=await draws(page);
    check('context lost: the still is back, nothing is drawn, the button is gone',now.still&&!now.canvas&&!now.toggle&&rate===0);
    await shoot(page.locator('.hero'),'context-lost');
    await page.evaluate(()=>window.__lose.restoreContext());
    await page.waitForTimeout(1500);now=await state(page);rate=await draws(page);
    check('context restored: the live scene resumes',now.canvas&&!now.still&&rate>200,`${rate} draws/s`);
    await page.locator('.motion-toggle').click();await page.waitForTimeout(300);
    check('pause button: nothing is drawn, the picture stays',(await draws(page))===0&&(await state(page)).canvas);
    await page.locator('.motion-toggle').click();await page.waitForTimeout(300);
    check('pause button again: the scene resumes',(await draws(page))>200);
    await page.emulateMedia({reducedMotion:'reduce'});await page.waitForTimeout(500);now=await state(page);
    check('reduced motion turned on mid-visit: the still is shown, nothing is drawn',now.still&&!now.canvas&&!now.toggle&&(await draws(page))===0);
    await page.emulateMedia({reducedMotion:'no-preference'});await page.waitForTimeout(500);
    check('reduced motion turned off again: the scene resumes',(await state(page)).canvas&&(await draws(page))>200);
    await page.evaluate(()=>{document.body.style.minHeight='4000px';window.scrollTo(0,2500);});await page.waitForTimeout(600);
    check('scrolled out of view: nothing is drawn',(await draws(page))===0);
    check('no page errors on the live path',errors.length===0,errors.join(' | '));
    await context.close();
  }
  {
    const {context,page}=await open(browser,{reducedMotion:'reduce',init:[quiet]});
    await page.waitForTimeout(1500);const now=await state(page);
    check('reduced motion from the start: the still is shown and Three.js is never downloaded',now.still&&!now.canvas&&now.sceneScripts===0&&(await draws(page))===0);
    await page.emulateMedia({reducedMotion:'no-preference'});await live(page);
    check('motion allowed later: the live scene mounts',(await state(page)).canvas);
    await context.close();
  }
  {
    // The swap must be invisible: the still and the paused first live frame, same box, same picture.
    const still=await open(browser,{reducedMotion:'reduce'});await still.page.waitForTimeout(1200);
    const stillBox=(await state(still.page)).box;await shoot(still.page.locator('.hero'),'swap-still');await still.context.close();
    const paused=await open(browser,{init:[pausedFromTheStart]});await live(paused.page);await paused.page.waitForTimeout(1200);
    const now=await state(paused.page);await shoot(paused.page.locator('.hero'),'swap-live');await paused.context.close();
    check('the layout box is the same with the still and with the canvas',now.canvas&&!now.still&&now.box===stillBox,now.box);
  }
  {
    const {context,page,errors}=await open(browser,{init:[quiet]});
    await live(page);const sizes=[(await state(page)).size];
    // Stretch every animation frame the way a GPU that cannot keep up would.
    await page.evaluate(()=>{const frame=window.requestAnimationFrame;window.requestAnimationFrame=callback=>frame(time=>{const end=performance.now()+55;while(performance.now()<end);callback(time);});});
    let now;
    for(let i=0;i<120;i++){
      await page.waitForTimeout(500);now=await state(page);
      if(now.size!==sizes.at(-1))sizes.push(now.size);
      if(now.fallback)break;
    }
    check('slow frames: fewer pixels first',sizes.length>=2,sizes.join(' > '));
    check('slow frames: then the still takes over for good',now.fallback==='slow'&&now.still&&!now.canvas&&!now.toggle&&(await draws(page))===0);
    check('no page errors on the slow path',errors.length===0,errors.join(' | '));
    await shoot(page.locator('.hero'),'slow-device');await context.close();
  }
  await browser.close();
  {
    // Software WebGL (no GPU): the scene may start, and the frame budget must hand the picture back.
    browser=await playwright.chromium.launch({headless:true,args:['--enable-unsafe-swiftshader','--mute-audio']});
    const {context,page,errors}=await open(browser,{init:[quiet]}),started=Date.now();
    let now;
    for(let i=0;i<120;i++){await page.waitForTimeout(500);now=await state(page);if(now.fallback||(i>12&&!now.ready))break;}
    check('software WebGL: the still is back within the frame budget',now.still&&!now.canvas&&!now.toggle,`after ${Math.round((Date.now()-started)/100)/10}s`);
    check('no page errors on the software path',errors.length===0,errors.join(' | '));
    await shoot(page.locator('.hero'),'software-webgl');await context.close();await browser.close();
  }
}
await new Promise(resolve=>server.httpServer.close(resolve));
console.log(failed?`${failed} of ${failed+passed} checks FAILED`:`All ${passed} checks passed`);
process.exit(failed?1:0);
