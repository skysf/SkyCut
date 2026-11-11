// What answer engines read: the robots policy for AI crawlers, llms.txt, the facts
// in structured data, and the recorded day each page last changed.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {render} from '../scripts/template.mjs';
import {renderRobots} from '../scripts/sitemap.mjs';
import {renderLlms,renderLlmsFull} from '../scripts/llms.mjs';
import {AI_CRAWLERS,INDEXABLE_PAGES,APP_FACTS} from '../scripts/site-config.mjs';
import {readRevisions,stalePages,stamped,fingerprint} from '../scripts/page-revisions.mjs';
import {prices} from '../content/pricing.js';
import {cloudModelGroups} from '../content/ai-models.js';
import {featureGroups,characterRows,localModelRows} from '../content/feature-matrix.js';
const languages=['en','zh','de','es'];
const jsonGraph=html=>JSON.parse(html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1])['@graph'];
const node=(graph,type)=>graph.find(item=>item['@type']===type);
const unescape=text=>text.replace(/&amp;/g,'&').replace(/&#39;/g,"'").replace(/&quot;/g,'"').replace(/&lt;/g,'<').replace(/&gt;/g,'>');

test('robots.txt welcomes documented AI crawlers of both kinds and keeps /api/ closed for each',()=>{
  const robots=renderRobots();
  const groups=robots.trim().split(/\n\n+/).filter(block=>/User-agent:/.test(block));
  assert.equal(groups.length,3,'the default group plus one group per kind of AI crawler');
  for(const block of groups) {
    assert.match(block,/^Allow: \/$/m);assert.match(block,/^Disallow: \/api\/$/m,'a named group does not inherit the default rules');
    assert.doesNotMatch(block,/^Disallow: \/$/m);
  }
  for(const agent of ['OAI-SearchBot','ChatGPT-User','Claude-SearchBot','Claude-User','PerplexityBot','GPTBot','ClaudeBot','Google-Extended','Applebot-Extended','CCBot']) {
    assert.ok([...AI_CRAWLERS.answers,...AI_CRAWLERS.training].includes(agent));
    assert.match(robots,new RegExp(`^User-agent: ${agent}$`,'m'));
  }
  assert.equal(new Set([...AI_CRAWLERS.answers,...AI_CRAWLERS.training]).size,AI_CRAWLERS.answers.length+AI_CRAWLERS.training.length,'one group per agent');
  assert.match(robots,/^User-agent: \*$/m);assert.match(robots,/Sitemap: https:\/\/skycut\.app\/sitemap\.xml/);
});

test('llms.txt states the product facts from the same sources as the pages',async()=>{
  const short=renderLlms(),full=renderLlmsFull();
  const usd=prices('en'),cny=prices('zh');
  assert.match(short,/^# SkyCut\n\n> SkyCut is an AI video editor for Mac\./,'llmstxt.org: an H1 then a one paragraph summary');
  for(const text of [short,full]) {
    for(const fact of [`$${usd.monthly} per month`,`$${usd.yearly} per year`,`¥${cny.monthly}`,`¥${cny.yearly}`,APP_FACTS.operatingSystem,'Apple silicon','no Windows version','no Intel Mac version',
      'Claude Code','Claude Desktop','Codex','MCP','watermark','7 days of Pro','1,000 Sky Studio credits','Sky Lu','Sky Studio','https://skylu.ai/download/skycut','https://skystudioai.com/app/skycut/pro','support@skycut.app'])
      assert.ok(text.includes(fact),`missing fact: ${fact}`);
    assert.doesNotMatch(text,/github|localhost|127\.0\.0\.1|vercel\.app|undefined|\[object Object\]/i);
    assert.doesNotMatch(text,/\b0\.\d+\.\d+\b/,'no hand written app version');
    assert.doesNotMatch(text,/rating|reviews|downloads so far|users trust|best |fastest|smoothest/i,'facts only');
  }
  for(const language of languages)for(const kind of INDEXABLE_PAGES)
    if(language==='en'||!kind)assert.ok(short.includes(`https://skycut.app/${language}/${kind?kind+'/':''}`));
  assert.ok(short.includes('https://skycut.app/llms-full.txt'));
  assert.ok(short.length<4000,'the short file stays short');
  const {default:english}=await import('../content/en.js');
  for(const group of cloudModelGroups)for(const model of group.models)assert.ok(full.includes(model.title),`missing model ${model.title}`);
  for(const row of [...featureGroups.flatMap(group=>group.rows),...characterRows,...localModelRows])
    assert.ok(full.includes(english.pricing.compare.features[row.id][0]),`missing feature ${row.id}`);
  assert.equal(await readFile(new URL('../public/llms.txt',import.meta.url),'utf8'),short,'run npm run build to refresh public/llms.txt');
  assert.equal(await readFile(new URL('../public/llms-full.txt',import.meta.url),'utf8'),full,'run npm run build to refresh public/llms-full.txt');
});

for(const language of languages) {
  test(`${language}: structured data repeats only what the page shows`,async()=>{
    const {default:c}=await import(`../content/${language}.js`);
    const home=render(c),graph=jsonGraph(home),visible=unescape(home.split('</head>')[1]);
    const faq=node(graph,'FAQPage');
    assert.equal(faq.mainEntity.length,c.faq.length);
    assert.equal(faq.mainEntity.length,(home.match(/<details><summary>/g)||[]).length);
    for(const question of faq.mainEntity) {
      assert.ok(visible.includes(question.name),'every marked question is on the page');
      assert.ok(visible.includes(question.acceptedAnswer.text),'every marked answer is on the page');
    }
    assert.equal(node(graph,'WebPage').hasPart['@id'],faq['@id']);
    const app=node(graph,'SoftwareApplication');
    assert.ok(app.featureList.length>=20);
    for(const feature of app.featureList)assert.ok(visible.includes(feature),`featureList names a row the comparison shows: ${feature}`);
    assert.equal(app.operatingSystem,APP_FACTS.operatingSystem);assert.equal(app.isAccessibleForFree,true);
    assert.deepEqual(app.inLanguage,['en','zh-Hans','es'],'the interface languages the app ships');
    assert.deepEqual(app.offers.map(offer=>offer.category),['free','subscription','subscription']);
    assert.ok(app.offers.every(offer=>offer.availability==='https://schema.org/InStock'));
    for(const invented of ['softwareVersion','aggregateRating','review','screenshot','datePublished','interactionStatistic'])
      assert.equal(app[invented],undefined,`${invented} needs a real source before it is published`);
    // Each still of the film says what it shows; four copies of one sentence tell a reader nothing.
    const stills=[...home.match(/<div class="film-stills">([\s\S]*?)<\/div>/)[1].matchAll(/alt="([^"]+)"/g)].map(match=>match[1]);
    assert.equal(stills.length,4);assert.equal(new Set(stills).size,4);assert.ok(!stills.includes(c.filmAlt));
    const organization=node(graph,'Organization');
    assert.equal(organization.alternateName,'Sky Studio AI');
    assert.ok(organization.sameAs.includes('https://www.wikidata.org/wiki/Q139824875'));
    assert.equal(organization.logo,'https://skystudioai.com/logo_webOnly.png');
    const docs=jsonGraph(render(c,'docs'));
    assert.equal(node(docs,'FAQPage'),undefined);
    const video=node(docs,'VideoObject');
    assert.equal(video.uploadDate,'2026-11-06','the day the installation video went online with the docs page');
    assert.equal(video.inLanguage,{en:'en',zh:'zh-CN',de:'de',es:'es'}[language]);
    const revisions=readRevisions();
    for(const kind of INDEXABLE_PAGES)
      assert.equal(node(jsonGraph(render(c,kind)),'WebPage').dateModified,revisions[`${language}/${kind||'home'}`].modified);
  });
}

test('every page carries the day it really changed: edit a page, then run npm run stamp:pages',async()=>{
  const rendered=[];
  for(const language of languages) {
    const {default:c}=await import(`../content/${language}.js`);
    for(const kind of INDEXABLE_PAGES)rendered.push({language,kind,html:render(c,kind)});
  }
  assert.deepEqual(stalePages(rendered),[],'these pages changed without a new date: run `npm run stamp:pages` in website/');
  const revisions=readRevisions();
  assert.equal(Object.keys(revisions).length,12);
  for(const stamp of Object.values(revisions))assert.match(stamp.modified,/^20\d{2}-\d{2}-\d{2}$/);
  // Stamping keeps the date of a page that did not change and dates only the one that did.
  const [first,second]=rendered;
  const edited=[{...first,html:first.html.replace('</main>','<p>new</p></main>')},second];
  const next=stamped(edited,'2031-01-02',revisions);
  assert.equal(next['en/home'].modified,'2031-01-02');assert.equal(next['en/docs'].modified,revisions['en/docs'].modified);
  // Neither the stamped date nor the copyright year counts as a change.
  assert.equal(fingerprint(first.html),fingerprint(first.html.replace(/,"dateModified":"[^"]*"/,',"dateModified":"1999-01-01"').replace(/© \d{4}/,'© 1999')));
  assert.notEqual(fingerprint(first.html),fingerprint(edited[0].html));
});
