// Small text stays readable: sizes on phones, contrast in the demo area, heading order, a hero that
// does not move when the web font arrives.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {cssStyles} from '../scripts/css-cascade.mjs';
import {render,languages} from '../scripts/template.mjs';
import {renderGuide,renderGuideHub} from '../scripts/guide-page.mjs';
import {guidesIn} from '../scripts/guide-model.mjs';
const read=path=>readFile(new URL(`../${path}`,import.meta.url),'utf8');
// In the order a page loads them (see css-cascade.test.mjs); a later rule for the same selector wins.
const SHEETS=['base','responsive','home','showcases','pricing','guides'];
const styles=Object.fromEntries(await Promise.all(SHEETS.map(async name=>[name,cssStyles(await read(`src/styles/${name}.css`))])));
const everyRule=SHEETS.flatMap(name=>styles[name]);

// --- 1. Nothing a phone shows is set smaller than 12 px -------------------------------------------
const PHONE=390,SMALLEST=12;
// The demo's editor window is never wider than the phone, so its container query holds as well.
const onPhone=condition=>!condition||(!/prefers-reduced-motion/.test(condition)
  &&[...condition.matchAll(/max-width:\s*(\d+)px/g)].every(match=>PHONE<=Number(match[1]))
  &&[...condition.matchAll(/min-width:\s*(\d+)px/g)].every(match=>PHONE>=Number(match[1])));
const pixels=value=>{
  const size=value.replace('!important','').trim();
  if(/^[\d.]+px$/.test(size))return parseFloat(size);
  const clamp=size.match(/^clamp\(([\d.]+)px,([\d.]+)vw,([\d.]+)px\)$/);
  return clamp?Math.min(Math.max(Number(clamp[1]),Number(clamp[2])*PHONE/100),Number(clamp[3])):null;
};
// What each selector ends up with on a phone: later rules win, `!important` holds against plain ones.
function onPhoneValue(property){
  const values=new Map();
  for(const rule of everyRule){
    const value=rule.declarations[property];
    if(value===undefined||!onPhone(rule.condition))continue;
    if(values.get(rule.selector)?.includes('!important')&&!value.includes('!important'))continue;
    values.set(rule.selector,value);
  }
  return values;
}
// Parts of the demo's editor window that phones do not show at all, and the rule that hides them.
const HIDDEN_ON_PHONES={
  '.show-panel-title':'.show-library','.show-assets>div>span':'.show-library',
  '.show-inspector dl':'.show-inspector','.inspector-check':'.show-inspector','.inspector-fps':'.show-inspector'
};

test('on a phone no visible text is set below 12 px',()=>{
  const sizes=onPhoneValue('font-size'),display=onPhoneValue('display');
  const hidden=selector=>display.get(selector)?.startsWith('none');
  const small=[...sizes].filter(([,value])=>pixels(value)!==null&&pixels(value)<SMALLEST)
    .filter(([selector])=>!hidden(selector)&&!hidden(HIDDEN_ON_PHONES[selector]))
    .map(([selector,value])=>`${selector} ${value}`);
  assert.deepEqual(small,[],`These are smaller than ${SMALLEST}px at ${PHONE}px wide. Give them at least ${SMALLEST}px in the phone rules, or hide them there.`);
  // The exemptions above only hold while their ancestor really is hidden on phones.
  for(const ancestor of new Set(Object.values(HIDDEN_ON_PHONES)))assert.ok(hidden(ancestor),`${ancestor} is no longer hidden on phones`);
  assert.equal(pixels('clamp(42px,11vw,64px)'),42.9);assert.equal(pixels('.88em'),null);
  assert.equal(onPhone('@media(max-width:1150px) and (min-width:901px)'),false);assert.equal(onPhone('@container (max-width:700px)'),true);
});

// --- 2. Small text in the demo area reaches 4.5:1 against the surface it sits on -------------------
const channels=hex=>{
  const digits=hex.slice(1),full=digits.length<=4?[...digits].map(digit=>digit+digit).join(''):digits;
  return [0,2,4,6].map(at=>full.length>at?parseInt(full.slice(at,at+2),16):255);
};
const over=([r,g,b,a],[r2,g2,b2])=>[r,g,b].map((value,i)=>value*a/255+[r2,g2,b2][i]*(1-a/255));
const luminance=color=>color.slice(0,3).map(value=>{const v=value/255;return v<=.03928?v/12.92:((v+.055)/1.055)**2.4;})
  .reduce((total,value,i)=>total+value*[.2126,.7152,.0722][i],0);
const contrast=(a,b)=>{const [light,dark]=[luminance(a),luminance(b)].sort((x,y)=>y-x);return (light+.05)/(dark+.05);};
const root=Object.assign({},...everyRule.filter(rule=>rule.selector===':root'&&!rule.condition).map(rule=>rule.declarations));
const PAGE=root['--paper'],WHITE='#ffffff';
// The value a selector always has (outside any media query), with custom properties resolved.
function plain(selector,property){
  const rule=everyRule.filter(candidate=>candidate.selector===selector&&!candidate.condition&&candidate.declarations[property]!==undefined).at(-1);
  assert.ok(rule,`${selector} declares no ${property}`);
  const value=rule.declarations[property].replace(/var\((--[\w-]+)\)/g,(_,name)=>root[name]);
  return property==='opacity'?Number(value):value.match(/#[0-9a-f]{3,8}\b/i)?.[0]??assert.fail(`${selector} { ${property}: ${value} } is not a plain colour`);
}
// [text, surface] or [text, surface, {color: selector the text colour is inherited from, dim: selector whose opacity dims it}].
// A surface is a selector with a background, or a colour. Translucent chips over footage are judged on white, the worst case.
const QUIET_TEXT=[
  ['.show-heading h2',PAGE],['.show-heading p',PAGE],['.show-demo-label',PAGE],['.show-phases button',PAGE],['.show-languages button',PAGE,{color:':root'}],
  ['.show-chat-header div>span','.show-window'],['.show-thinking','.show-window'],['.show-chat-steps p','.show-window'],
  ['.show-chat-steps strong','.show-window',{color:'.show-window',dim:'.show-chat-steps li'}],['.show-compose','.show-window'],
  ['.show-user-message','.show-user-message'],['.show-transport','.show-viewer'],['.show-tools','.show-timeline'],['.show-ruler','.show-timeline'],
  ['.show-inspector dt','.show-inspector'],['.inspector-check','.show-inspector'],['.inspector-fps','.show-inspector'],
  ['.show-storyboard>div>span','.show-storyboard'],['.show-character span','.show-character'],
  ['.show-video-clip>span','.show-video-clip>span'],['.show-subtitle-lane>span','.show-subtitle-lane>span',{color:'.show-window'}],
  ['.show-subtitle-lane.translated>span','.show-subtitle-lane.translated>span'],['.show-audio-lane>span:first-child','.show-audio-lane>span:first-child'],
  ['.show-quality','.show-quality'],['.show-languages button[aria-pressed=true]','.show-languages button[aria-pressed=true]'],
  // The muted text colour of the whole site, on the tinted surfaces it is used on.
  ['.compatibility','.platform-card.available'],['.section-heading p','.film-section'],['.comparison-access.is-unavailable','.platform-card.available']
];
// Colours in the demo that are not text on a known surface: icons, and captions drawn over footage with a shadow.
const NOT_QUIET_TEXT=['.show-window','.agent-symbol','.show-compose .ui-glyph','.show-transition>span','.show-transport-toggle','.show-video-play',
  '.show-audio-lane','.show-preview-subtitle','.show-transfer','.show-phases button[aria-pressed=true]',
  '.show-phases button[aria-pressed=true]>span','.show-phases button.is-complete>span','.show-playback button','.show-chat-steps .is-complete>span'];

test('small text in the demo area has a contrast of at least 4.5:1',()=>{
  const failures=[];
  for(const [text,surface,{color=text,dim}={}] of QUIET_TEXT){
    try{
      const background=over(channels(surface.startsWith('#')?surface:plain(surface,'background')),channels(WHITE));
      const ink=channels(plain(color,'color')),opacity=dim?plain(dim,'opacity'):1;
      const shown=over([...ink.slice(0,3),ink[3]*opacity],background),ratio=contrast(shown,background);
      if(ratio<4.5)failures.push(`${text} on ${surface}: ${ratio.toFixed(2)}:1`);
    }catch(error){failures.push(`${text} on ${surface}: ${error.message}`);}
  }
  assert.deepEqual(failures,[]);
  // Every text colour the demo stylesheet sets is either checked above or named as not being text on a surface.
  const covered=new Set([...QUIET_TEXT.flatMap(([text,,options])=>[text,options?.color]),...NOT_QUIET_TEXT]);
  const unchecked=styles.showcases.filter(rule=>!rule.condition&&rule.declarations.color&&!covered.has(rule.selector)).map(rule=>rule.selector);
  assert.deepEqual(unchecked,[],'New text colours in showcases.css must be added to QUIET_TEXT with the surface they sit on');
  assert.ok(Math.abs(contrast(channels('#ffffff'),channels('#000000'))-21)<.01);
});

test('the demo does not dim its status text through script',async()=>{
  // Opacity set from script escapes the stylesheet check above; the finished label must stay readable.
  assert.doesNotMatch(await read('src/showcase-view.js'),/thinking\.style\.opacity/);
});

test('the typed prompt keeps its whole sentence in the bubble, so the chat window has one height while it types',async()=>{
  // Typing by replacing the bubble's text made a two-line prompt start on one line: on phones, where the
  // bubble has no minimum height, the chat window shrank by a line when the demo started and grew back.
  const view=await read('src/showcase-view.js');
  assert.doesNotMatch(view,/prompt\.textContent\s*=/);
  assert.match(view,/untyped\.textContent\s*=\s*sceneCopy\.prompt\.slice\(promptText\.length\)/);
  const hidden=styles.showcases.filter(rule=>rule.selector==='.show-untyped'&&!rule.condition).at(-1)?.declarations.visibility;
  assert.equal(hidden,'hidden');
});

// --- 3. Headings never skip a level ------------------------------------------------------------------
test('no page skips a heading level, and each has one h1',async()=>{
  for(const language of languages){
    const {default:copy}=await import(`../content/${language}.js`);
    const pages={home:render(copy),docs:render(copy,'docs'),privacy:render(copy,'privacy'),guides:renderGuideHub(copy)};
    for(const guide of guidesIn(language))pages[`guide ${guide.slug}`]=renderGuide(copy,guide);
    for(const [name,html] of Object.entries(pages)){
      const levels=[...html.matchAll(/<h([1-6])\b/g)].map(match=>Number(match[1]));
      assert.equal(levels.filter(level=>level===1).length,1,`${language} ${name}`);
      levels.forEach((level,i)=>assert.ok(i===0?level===1:level<=levels[i-1]+1,`${language} ${name}: h${levels[i-1]} is followed by h${level}`));
    }
  }
});

// --- 4. The hero's rows do not depend on which font has loaded ----------------------------------------
test('the hero badge row has a fixed line height, so the hero does not shift when the web font arrives',()=>{
  // With `line-height: normal` the row height comes from the font's own metrics: the fallback font and
  // Outfit differ by 5 px there, and the hero, centred above it, moved by 1.25 px after load.
  const row=styles.home.filter(rule=>rule.selector==='.hero-badges'&&!rule.condition).at(-1).declarations['line-height'];
  assert.match(row??'normal',/^\d*\.?\d+(px)?$/);
  for(const rule of everyRule.filter(candidate=>candidate.selector.startsWith('.hero-badges')))assert.notEqual(rule.declarations['line-height'],'normal');
});
