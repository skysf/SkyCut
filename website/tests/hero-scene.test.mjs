// The hero keeps one picture in every browser: a baked still by default, the live scene only when it can run.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,stat} from 'node:fs/promises';
import {createGovernor,wantsLiveScene,PIXEL_RATIOS,FRAME_BUDGET,FRAME_PATIENCE,FRAME_WARMUP} from '../src/scene-governor.js';
import {SCENE_BLEED,COMPACT_QUERY} from '../src/scene-playback.js';
import {HERO_STILLS,SCENE_HEIGHTS,heroStill,stillFormats} from '../scripts/hero-still.mjs';
import {stillStamp,stillFiles,STAMP_FILE,STILL_SOURCES} from '../scripts/hero-still-stamp.mjs';
import {render,languages} from '../scripts/template.mjs';
const root=new URL('../',import.meta.url);
const read=path=>readFile(new URL(path,root),'utf8');
const run=(governor,ms,frames)=>{const verdicts=[];for(let i=0;i<frames;i++)verdicts.push(governor.sample(ms));return verdicts;};
const decisive=verdicts=>verdicts.filter(verdict=>verdict!=='ok');

test('reduced motion and missing WebGL 2 never start the animated scene',async()=>{
  assert.equal(wantsLiveScene({webgl2:true,reducedMotion:false}),true);
  assert.equal(wantsLiveScene({webgl2:true,reducedMotion:true}),false);
  assert.equal(wantsLiveScene({webgl2:false,reducedMotion:false}),false);
  const main=await read('src/main.js');
  // The scene module, and with it Three.js and the animation loop, is only imported behind that answer.
  const gate=main.indexOf('wantsLiveScene({'),load=main.indexOf("import('./scene.js')");
  assert.ok(gate>0&&load>gate);
  assert.match(main.slice(gate,load),/\)\)return;/);
  assert.match(main,/'WebGL2RenderingContext' in window/);
  assert.equal(main.split("import('./scene.js')").length,2);
});

test('a display that holds 30 fps keeps the live scene at full sharpness',()=>{
  for(const ms of [1000/120,1000/60,1000/30,FRAME_BUDGET]){
    const governor=createGovernor();
    assert.deepEqual(decisive(run(governor,ms,2000)),[]);
    assert.equal(governor.pixelRatio,PIXEL_RATIOS[0]);
  }
});

// Enough frames of `ms` to outlast the warm-up and the patience once.
const outlast=ms=>Math.ceil((FRAME_WARMUP+FRAME_PATIENCE)/ms)+12;

test('a device over the frame budget first renders fewer pixels, then gives the picture back to the still',()=>{
  const governor=createGovernor();
  const verdicts=decisive(run(governor,60,outlast(60)*PIXEL_RATIOS.length));
  assert.deepEqual(verdicts,[...PIXEL_RATIOS.slice(1).map(()=>'lower'),'stop']);
  assert.equal(governor.pixelRatio,PIXEL_RATIOS.at(-1));
  assert.deepEqual(PIXEL_RATIOS,[...PIXEL_RATIOS].sort((a,b)=>b-a));
  // Under ten frames a second goes straight to the fewest pixels, and is not waited out as a stall.
  const crawling=createGovernor();
  assert.deepEqual(decisive(run(crawling,500,outlast(250))),['lower']);
  assert.equal(crawling.pixelRatio,PIXEL_RATIOS.at(-1));
  assert.equal(decisive(run(crawling,500,outlast(250)))[0],'stop');
  // The whole way down takes seconds, not minutes, of real time.
  assert.ok((FRAME_WARMUP+FRAME_PATIENCE)*PIXEL_RATIOS.length<=12000);
});

test('one long stall or a pause does not count against the scene',()=>{
  const governor=createGovernor();
  // A two-second hitch every hundred frames on an otherwise smooth display.
  for(let i=0;i<40;i++)assert.deepEqual(decisive([...run(governor,1000/60,99),governor.sample(2000)]),[]);
  assert.deepEqual(decisive(run(governor,NaN,50)),[]);
  // Slow frames just short of the patience, then a pause: the count starts again.
  const short=Math.floor((FRAME_WARMUP+FRAME_PATIENCE)/60)-6;
  run(governor,60,short);governor.settle();
  assert.deepEqual(decisive(run(governor,60,short)),[]);
});

for(const language of languages){
  test(`${language}: the static page already carries the baked still, sized so nothing shifts`,async()=>{
    const {default:copy}=await import(`../content/${language}.js`);
    const home=render(copy),hero=home.slice(home.indexOf('class="hero-visual"'),home.indexOf('class="hero-badges"'));
    const picture=hero.match(/<picture class="scene-still">[\s\S]*?<\/picture>/)?.[0];
    assert.ok(picture,'the still must be in the HTML, not injected by a script');
    assert.ok(hero.indexOf('<picture')<hero.indexOf('<canvas id="timeline-scene" aria-hidden="true">'));
    assert.doesNotMatch(hero,/fallback-scene|timeline-illustration/);
    const image=picture.match(/<img [^>]*>/)[0];
    assert.match(image,/ width="\d+" height="\d+"/);assert.match(image,/fetchpriority="high"/);
    assert.doesNotMatch(image,/loading="lazy"/);
    assert.ok(image.includes(`alt="${copy.imageAlt}"`));
    // Phone sources come first and carry the same query the scene uses for its two-card composition.
    const sources=[...picture.matchAll(/<source ([^>]*)>/g)].map(match=>match[1]);
    assert.deepEqual(sources.map(source=>source.includes(`media="${COMPACT_QUERY}"`)),[true,true,false,false,true]);
    assert.deepEqual(sources.slice(0,4).map(source=>source.match(/type="image\/(\w+)"/)[1]),['avif','webp','avif','webp']);
    for(const file of new Set([...picture.matchAll(/\/media\/(hero-still-[\w-]+\.\w+)/g)].map(match=>match[1]))){
      assert.ok((await stat(new URL(`public/media/${file}`,root))).size>8000,file);
    }
  });
}

test('every still file named in the markup has the declared pixel size',async()=>{
  const size=async(file)=>{
    const bytes=await readFile(new URL(`public/media/${file}`,root));
    if(file.endsWith('.jpg')){
      for(let i=2;i<bytes.length;){
        const marker=bytes[i+1],length=bytes.readUInt16BE(i+2);
        if(marker>=0xc0&&marker<=0xc2)return [bytes.readUInt16BE(i+7),bytes.readUInt16BE(i+5)];
        i+=2+length;
      }
    }
    if(file.endsWith('.webp')){
      const at=bytes.indexOf('VP8X');assert.ok(at>0,'stills keep their alpha channel');
      return [bytes.readUIntLE(at+12,3)+1,bytes.readUIntLE(at+15,3)+1];
    }
    const at=bytes.indexOf('ispe');assert.ok(at>0);
    return [bytes.readUInt32BE(at+8),bytes.readUInt32BE(at+12)];
  };
  for(const still of HERO_STILLS)for(const height of still.heights){
    for(const format of stillFormats(still,height)){
      assert.deepEqual(await size(`hero-still-${still.name}-${height}.${format}`),[Math.round(height*still.aspect),height]);
    }
  }
});

test('the baked still was rendered from the scene as it is now',async()=>{
  const recorded=JSON.parse(await readFile(STAMP_FILE,'utf8')),current=await stillStamp();
  assert.equal(current.sources,recorded.sources,
    'The hero scene, its posters or the bake changed after the still was baked. Run `npm run build:hero-still` in website/ and commit the new images and stamp.');
  assert.deepEqual(current.files,recorded.files,'The still images in public/media are not the ones the last bake wrote. Run `npm run build:hero-still`.');
  // Every file the page can ask for is covered, and every module that draws the scene is fingerprinted.
  const named=[...new Set([...heroStill('').matchAll(/\/media\/(hero-still-[\w-]+\.\w+)/g)].map(match=>match[1]))].sort();
  assert.deepEqual(named,stillFiles().sort());
  const imports=async(path,seen=new Set())=>{
    if(seen.has(path))return seen;seen.add(path);
    for(const match of (await read(path)).matchAll(/from '\.\/(scene-[\w-]+\.js)'/g))await imports(`src/${match[1]}`,seen);
    return seen;
  };
  for(const module of await imports('src/scene-still.js'))assert.ok(STILL_SOURCES.includes(module),`${module} draws the still but is not fingerprinted`);
});

test('the still and the canvas share one bleeding box, so swapping them cannot move the layout',async()=>{
  const css=(await read('src/styles/home.css'))+(await read('src/styles/responsive.css'));
  // Fixed scene heights per layout; the bleed in CSS is the share the camera and the bake use.
  const heights=[...css.matchAll(/--scene-height:(\d+)px/g)].map(match=>Number(match[1])).sort((a,b)=>a-b);
  assert.deepEqual(heights,Object.values(SCENE_HEIGHTS).sort((a,b)=>a-b));
  assert.ok(css.includes(`--scene-bleed:calc(var(--scene-height)*${String(SCENE_BLEED).replace(/^0/,'')})`));
  heights.forEach(height=>assert.ok(Number.isInteger(height*SCENE_BLEED),'whole pixels keep the canvas sharp'));
  assert.match(css,/\.hero-visual \{[^}]*height:var\(--scene-height\);position:relative/);
  assert.match(css,/\.scene-still,#timeline-scene \{position:absolute;[^}]*pointer-events:none;\}/);
  assert.match(css,/\.scene-still img \{[^}]*object-fit:cover;\}/);
  assert.match(css,/#timeline-scene \{display:block;opacity:0;\}/);
  // The still is on screen unless the scene says it is ready; nothing hides both.
  assert.match(css,/\.scene-ready #timeline-scene \{opacity:1;\}/);
  assert.match(css,/\.scene-ready \.scene-still \{opacity:0;\}/);
  assert.doesNotMatch(css,/#timeline-scene \{display:none/);
  assert.match(css,/\.motion-toggle \{display:none;/);assert.match(css,/\.scene-ready \.motion-toggle \{display:grid;\}/);
  // The image must be wider than the bleeding box at every layout, or fitting by height would crop it.
  const widest={phone:600-40+20,tablet:900-72,narrow:(1150-72)*1.15/2.05+58,desktop:1320*1.3/2.2+70,large:1320*1.3/2.2+70};
  const [wide,compact]=HERO_STILLS;
  for(const [layout,width] of Object.entries(widest)){
    const height=SCENE_HEIGHTS[layout],bleed=height*SCENE_BLEED;
    const still=layout==='phone'?compact:wide;
    assert.ok(still.aspect>(width+bleed*2)/(height+bleed*2),layout);
  }
  const sizes=heroStill('').match(/sizes="([^"]+)"/g);
  assert.ok(sizes.at(-1).includes(`${Math.round(SCENE_HEIGHTS.desktop*(1+SCENE_BLEED*2)*wide.aspect)}px"`));
});

test('the live scene steps aside for reduced motion, a lost context and a slow device',async()=>{
  const scene=await read('src/scene.js');
  assert.match(scene,/const live=!reduced\.matches&&!lost;/);
  assert.match(scene,/host\.classList\.toggle\('scene-ready',live\)/);
  assert.match(scene,/const playing=\(\)=>[^;]*!paused&&!reduced\.matches;/);
  // The loop itself falls back through sync(): a swallowed change event must not leave the canvas up.
  assert.match(scene,/if\(!playing\(\)\)\{sync\(\);return;\}\s*frame=requestAnimationFrame\(tick\)/);
  assert.match(scene,/webglcontextlost',event=>\{event\.preventDefault\(\);lost=true;sync\(\);\}/);
  assert.match(scene,/webglcontextrestored',\(\)=>\{lost=false;stage\.relight\(\)/);
  assert.match(scene,/verdict==='stop'\)retire\('slow'\)/);
  const stage=await read('src/scene-stage.js');
  assert.match(stage,/failIfMajorPerformanceCaveat:!still/);
  assert.match(stage,/if\(!context\)throw/);
});
