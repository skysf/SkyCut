// Manual check of text legibility in real browser engines: headless, on the built site, no window is opened.
// Playwright is not a dependency of this package and CI does not run this. On a Mac, after `npm run build`:
//   npx -y -p playwright@1.65.0 node scripts/check-legibility-browsers.mjs [--engines chromium,webkit,firefox]
// tests/legibility.test.mjs holds the same rules against the stylesheets; this looks at what a browser really lays out.
import {headlessSite,option,tally} from './pinned-playwright.mjs';

const engineNames=(option('engines')||'chromium').split(',');
const {launch,base,close}=await headlessSite('check-legibility-browsers.mjs');
const {check,finish}=tally();
const PHONE={width:390,height:844},DESKTOP={width:1440,height:900};

// Runs in the page. Every text node that is really shown inside `scope`: those set below 12 px, and
// those under 4.5:1 against the nearest solid background (3:1 from 24 px). Text drawn over footage
// carries its own shadow and is left out, as is anything faded to near nothing while it waits its turn.
const survey=scope=>{
  const parse=value=>{const match=value.match(/rgba?\(([^)]+)\)/);if(!match)return null;const [r,g,b,a=1]=match[1].split(/[,\s/]+/).filter(Boolean).map(Number);return {r,g,b,a};};
  const blend=(top,under)=>({r:top.r*top.a+under.r*(1-top.a),g:top.g*top.a+under.g*(1-top.a),b:top.b*top.a+under.b*(1-top.a),a:1});
  const luminance=color=>[color.r,color.g,color.b].map(value=>{const v=value/255;return v<=.03928?v/12.92:((v+.055)/1.055)**2.4;}).reduce((total,value,i)=>total+value*[.2126,.7152,.0722][i],0);
  const ratio=(a,b)=>{const [light,dark]=[luminance(a),luminance(b)].sort((x,y)=>y-x);return (light+.05)/(dark+.05);};
  const surface=element=>{
    const layers=[];
    for(let node=element;node;node=node.parentElement){const color=parse(getComputedStyle(node).backgroundColor);if(color&&color.a>0){layers.push(color);if(color.a===1)break;}}
    return layers.reverse().reduce((under,layer)=>blend(layer,under),{r:243,g:240,b:232,a:1});
  };
  const label=element=>`${element.tagName.toLowerCase()}${typeof element.className==='string'&&element.className?`.${element.className.trim().split(/\s+/).join('.')}`:''}`;
  const small=new Set(),faint=new Set(),root=document.querySelector(scope);
  const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);
  for(let node=walker.nextNode();node;node=walker.nextNode()){
    if(!node.textContent.trim())continue;
    const element=node.parentElement,style=getComputedStyle(element),box=element.getBoundingClientRect();
    let shown=box.width>0&&box.height>0,opacity=1;
    for(let up=element;up&&shown;up=up.parentElement){const s=getComputedStyle(up);if(s.display==='none'||s.visibility==='hidden'||up.hidden)shown=false;opacity*=Number(s.opacity);}
    if(!shown||opacity<.2)continue;
    const size=parseFloat(style.fontSize),name=`${label(element.parentElement)} > ${label(element)}`;
    if(size<12)small.add(`${size}px ${name}`);
    if(element.closest('.show-preview-subtitle,.show-transition'))continue;
    const ink=parse(style.color),under=surface(element),value=ratio(blend({...ink,a:ink.a*opacity},under),under);
    if(value<(size>=24?3:4.5))faint.add(`${value.toFixed(2)}:1 ${name}`);
  }
  const visible=heading=>{for(let up=heading;up;up=up.parentElement){const s=getComputedStyle(up);if(s.display==='none'||s.visibility==='hidden')return false;}return true;};
  return {small:[...small],faint:[...faint],headings:[...document.querySelectorAll('h1,h2,h3,h4,h5,h6')].filter(visible).map(heading=>Number(heading.tagName[1]))};
};
const skipped=levels=>levels.flatMap((level,i)=>i&&level>levels[i-1]+1?[`h${levels[i-1]} then h${level}`]:[]);
async function open(browser,path,viewport,options={}){
  const context=await browser.newContext({viewport,deviceScaleFactor:2,locale:'en-US',...options});
  const page=await context.newPage();
  await page.goto(`${base}${path}`,{waitUntil:'load'});await page.waitForTimeout(1500);
  return {context,page};
}

for(const engine of engineNames){
  const browser=await launch[engine]();
  // 1. Phone: no page shows text below 12 px, and no page skips a heading level.
  const guide=await (async()=>{const {context,page}=await open(browser,'/en/guides/',PHONE);const href=await page.locator('main a[href*="/guides/"]').first().getAttribute('href');await context.close();return href;})();
  for(const path of ['/en/','/zh/','/de/','/es/','/en/docs/','/en/privacy/','/en/guides/',guide]){
    const {context,page}=await open(browser,path,PHONE,{reducedMotion:'reduce'});
    const found=await page.evaluate(survey,'body');
    check(`${engine} phone ${path}: no text below 12 px`,found.small.length===0,found.small.slice(0,6).join(' | '));
    check(`${engine} phone ${path}: headings do not skip a level`,skipped(found.headings).length===0,skipped(found.headings).join(', '));
    await context.close();
  }
  // 2. The demo area: contrast and sizes hold in every phase, and the chat window keeps one height.
  for(const [name,viewport,language] of [['desktop',DESKTOP,'en'],['phone',PHONE,'en'],['phone',PHONE,'zh'],['phone',PHONE,'de']]){
    const {context,page}=await open(browser,`/${language}/`,viewport);
    const resting=await page.evaluate(survey,'.showcases');
    check(`${engine} ${name} ${language} demo at rest: contrast of at least 4.5:1`,resting.faint.length===0,resting.faint.slice(0,6).join(' | '));
    const headings=(await page.evaluate(survey,'body')).headings;
    check(`${engine} ${name} ${language}: headings do not skip a level`,skipped(headings).length===0,skipped(headings).join(', '));
    const faint=new Set(),small=new Set(),outside=new Set(),heights=[];
    const sections=page.locator('.showcase');
    for(let s=0;s<await sections.count();s++){
      // The page scrolls smoothly, which WebKit and Playwright's own scroll-then-click do not survive together:
      // jump there and trigger the buttons directly.
      const section=sections.nth(s);await section.evaluate(element=>element.scrollIntoView({block:'start',behavior:'instant'}));
      const chat=()=>section.locator('.show-chat').evaluate(element=>Math.round(element.getBoundingClientRect().height));
      const own=[await chat()],buttons=section.locator('[data-phase-button]');
      // Coming into view starts the demo, which types the prompt for 1.8 s: the window must not change while it does.
      if(name==='phone')for(let sample=0;sample<12;sample++){await page.waitForTimeout(200);own.push(await chat());}
      for(let i=0;i<await buttons.count();i++){
        await buttons.nth(i).evaluate(button=>button.click());await page.waitForTimeout(400);
        const found=await page.evaluate(survey,`.showcase:nth-of-type(${s+1})`);
        found.faint.forEach(item=>faint.add(item));found.small.forEach(item=>small.add(item));own.push(await chat());
        // An overlay on the preview (script, character, progress) must stay inside it.
        if(await section.evaluate(element=>{const preview=element.querySelector('.show-preview').getBoundingClientRect();
          return [...element.querySelectorAll('.show-storyboard,.show-character,.show-job')].filter(overlay=>getComputedStyle(overlay).display!=='none')
            .some(overlay=>{const box=overlay.getBoundingClientRect();return overlay.scrollHeight>overlay.clientHeight+1||box.bottom>preview.bottom+1||box.top<preview.top-1;});}))outside.add(`demo ${s+1} step ${i+1}`);
      }
      heights.push(own);
    }
    check(`${engine} ${name} ${language} demo in every step: contrast of at least 4.5:1`,faint.size===0,[...faint].slice(0,6).join(' | '));
    if(name==='phone'){
      check(`${engine} phone ${language} demo in every step: no text below 12 px`,small.size===0,[...small].slice(0,6).join(' | '));
      check(`${engine} phone ${language} demo: overlays stay inside the preview`,outside.size===0,[...outside].join(', '));
      check(`${engine} phone ${language} demo: the chat window keeps one height while the prompt is typed and from the first step to the end`,heights.every(own=>new Set(own).size===1),heights.map(own=>[...new Set(own)].join('/')).join(' | '));
    }
    await context.close();
  }
  // 3. The hero sits in the same place whether or not the web font has arrived.
  for(const [name,viewport] of [['desktop',DESKTOP],['ipad',{width:834,height:1112}],['phone',PHONE]]){
    const box=async blocked=>{
      const context=await browser.newContext({viewport,deviceScaleFactor:2,reducedMotion:'reduce',locale:'en-US'});
      if(blocked)await context.route(/\.woff2(\?|$)/,route=>route.abort());
      const page=await context.newPage();
      await page.goto(`${base}/en/`,{waitUntil:'load'});await page.waitForTimeout(1500);
      // `document.fonts.check` answers true in WebKit even when the file never arrived; the faces' own status does not.
      const result=await page.evaluate(()=>({box:JSON.stringify(document.querySelector('.hero-visual').getBoundingClientRect()),outfit:[...document.fonts].some(face=>face.status==='loaded')}));
      await context.close();return result;
    };
    const loaded=await box(false),fallback=await box(true);
    check(`${engine} ${name}: the hero does not move when the web font arrives`,loaded.outfit&&!fallback.outfit&&loaded.box===fallback.box,
      loaded.box===fallback.box?'':`${fallback.box} without the font, ${loaded.box} with it`);
  }
  await browser.close();
}
await close();
finish();
