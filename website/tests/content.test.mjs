// Translation contracts, published product constraints and static route generation.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,access} from 'node:fs/promises';
import english from '../content/en.js';
import {render,languages} from '../scripts/template.mjs';
import {browserLanguage} from '../src/language.js';
const root=new URL('../',import.meta.url);
function shape(value) {if(Array.isArray(value))return value.map(shape);if(value&&typeof value==='object')return Object.fromEntries(Object.keys(value).sort().map(k=>[k,shape(value[k])]));return typeof value;}
for(const language of languages) {
  test(`${language}: complete schema, concise hero, accessible static routes and independent opt-ins`,async()=>{
    const {default:copy}=await import(`../content/${language}.js`);
    assert.deepEqual(shape(copy),shape(english));assert.equal(copy.lang,language);assert.equal(copy.hero.length,2);
    copy.hero.forEach(line=>assert.ok(line.length<=25));
    const home=render(copy);assert.match(home,/name="newsletter"/);assert.match(home,/name="intel"/);assert.match(home,/name="windows"/);assert.doesNotMatch(home,/type="checkbox"[^>]*checked/);
    assert.match(home,/https:\/\/skylu.ai\/download\/skycut/);assert.match(home,/canvas id="timeline-scene"/);assert.match(home,/role="status"/);assert.match(home,/aria-label=/);
    assert.equal((home.match(/<h1\b/g)||[]).length,1);assert.equal((home.match(/rel="canonical"/g)||[]).length,1);
    assert.equal((home.match(/id="pricing"/g)||[]).length,1);
    for(const nav of ['desktop-nav','mobile-nav','footer-links']) {
      assert.ok(home.match(new RegExp(`class="${nav}"[\\s\\S]*?</(?:nav|div)>`))[0].includes(`href="/${language}/#pricing"`));
    }
    for(const path of ['', 'docs','privacy']) {
      const page=render(copy,path);assert.ok(page.includes(`https://skycut.app/${language}/`));assert.doesNotMatch(page,/undefined|\[object Object\]/);
      for(const lang of languages) assert.ok(page.includes(`hreflang="${lang==='zh'?'zh-CN':lang}"`));
    }
  });
}
test('device language selects a supported translation and all Chinese locales use Chinese',()=>{
  assert.equal(browserLanguage(['zh-CN']),'zh');assert.equal(browserLanguage(['zh-Hans-US']),'zh');assert.equal(browserLanguage(['zh-SG']),'zh');assert.equal(browserLanguage(['zh-TW','de']),'zh');assert.equal(browserLanguage(['es-MX','en']),'es');assert.equal(browserLanguage(['de-DE']),'de');assert.equal(browserLanguage(['fr-FR']),'en');
});
test('progressive enhancement keeps required assets local, and future platforms are not downloadable',async()=>{
  const home=render(english);const links=[...home.matchAll(/(?:href|src)="(\/(?:media|src)\/[^"#]+)"/g)].map(m=>m[1]);
  for(const link of links)await access(new URL(link.startsWith('/media/')?'public'+link:'.'+link,root));
  const html=home.slice(home.indexOf('class="platform-grid"'),home.indexOf('class="faq'));
  assert.equal((html.match(/https:\/\/skylu.ai\/download\/skycut/g)||[]).length,1);
  assert.match(html,/data-subscribe="intel"/);assert.match(html,/data-subscribe="windows"/);
  const scene=await readFile(new URL('src/scene.js',root),'utf8');assert.match(scene,/IntersectionObserver/);assert.match(scene,/visibilitychange/);assert.match(scene,/prefers-reduced-motion/);assert.match(scene,/renderer\.dispose/);
  const headers=JSON.parse(await readFile(new URL('vercel.json',root),'utf8'));assert.ok(headers.headers.some(h=>h.headers.some(i=>i.key==='Content-Security-Policy')));
});
