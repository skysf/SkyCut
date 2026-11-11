// The Guides section: drafts stay private, published guides carry real dates and
// Article data, translations stay in step, and the wording rules stop a guide that breaks them.
import test from 'node:test';
import assert from 'node:assert/strict';
import english from '../content/en.js';
import {guides} from '../content/guides/index.js';
import {guideCopy} from '../content/guide-copy.js';
import {shellCopy} from '../content/guide-shell.js';
import {prices} from '../content/pricing.js';
import {render} from '../scripts/template.mjs';
import {renderGuide,renderGuideHub} from '../scripts/guide-page.mjs';
import {renderSitemap} from '../scripts/sitemap.mjs';
import {assertGuides,guideProblems,guideRoutes,guideLanguages,isPublished,LIMITS} from '../scripts/guide-model.mjs';
import {GUIDE_LANGUAGES,LANGUAGE_TAGS} from '../scripts/site-config.mjs';
import {INDEX_DIRECTIVES} from '../scripts/seo.mjs';
const meta=(html,name)=>html.match(new RegExp(`<meta (?:name|property)="${name}" content="([^"]*)"`))?.[1];
const jsonGraph=html=>JSON.parse(html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1])['@graph'];
const node=(graph,type)=>graph.find(item=>item['@type']===type);
const visibleText=html=>html.split('</head>')[1].replace(/<[^>]+>/g,'').replace(/&#39;/g,"'").replace(/&amp;/g,'&').replace(/&quot;/g,'"');
const first=guides[0];
// One English-only guide makes the single-language cases easy to read.
const sample={...first,languages:{en:first.languages.en}};
const published={...sample,published:'2026-11-20',updated:'2026-11-22'};
const edit=change=>{const copy=structuredClone(sample);change(copy,copy.languages.en);return copy;};
// The shape of an article: how many sections, blocks of each kind, steps, rows, questions and price placeholders.
const shape=copy=>JSON.stringify({sections:copy.sections.map(section=>section.blocks.map(block=>typeof block==='string'?'p':block.steps?`steps${block.steps.length}`:block.list?`list${block.list.length}`:block.table?`table${block.table.rows.length}x${block.table.head.length}`:Object.keys(block)[0])),
  faq:copy.faq.length,prices:(JSON.stringify(copy).match(/\{\{[a-z.]+\}\}/g)||[]).sort()});

test('every guide in the inventory passes the publishing rules',()=>{
  assert.doesNotThrow(()=>assertGuides());
  for(const guide of guides)for(const [language,copy] of Object.entries(guide.languages)) {
    assert.ok(copy.title.length<=LIMITS.title,`${guide.slug} ${language} title`);assert.ok(copy.description.length<=LIMITS.description,`${guide.slug} ${language} description`);
    assert.ok(guideCopy[language],'the section has interface copy for every language a guide is written in');
  }
  // A date on a guide is a day that has come, never a plan.
  const today=new Date(Date.now()+14*3600*1000).toISOString().slice(0,10);
  for(const guide of guides.filter(isPublished))assert.ok(guide.published<=today&&guide.updated<=today,`${guide.slug} is dated in the future`);
});

test('translations of a guide keep the same structure, prices and requirement',async()=>{
  for(const guide of guides) {
    const languages=guideLanguages(guide),reference=guide.languages[languages[0]];
    for(const language of languages) {
      const copy=guide.languages[language];
      assert.equal(shape(copy),shape(reference),`${guide.slug}: ${language} has the same sections, steps, rows, questions and price placeholders as ${languages[0]}`);
      const html=renderGuide(await shellCopy(language),guide),text=visibleText(html);
      const price=prices(language==='zh'?'zh':'en');
      if(shape(copy).includes('pro.monthly'))assert.ok(text.includes(`${price.symbol}${price.monthly}`),`${language} shows the ${price.currency} price`);
      assert.ok(text.includes('macOS 15'),'every language names the system requirement');
      assert.ok(text.includes('Windows')&&text.includes('Intel'),'every language says there is no Windows or Intel version');
      assert.ok(html.includes(`<html lang="${LANGUAGE_TAGS[language]}">`));
      assert.doesNotMatch(html,/\{\{[a-z.]+\}\}|undefined|\[object Object\]/);
      // Owner, 2026-11-11: nothing public mentions GitHub; where a source lives stays in the guide's file.
      assert.doesNotMatch(html,/github/i,`${guide.slug} ${language} mentions GitHub`);
    }
  }
});

test('guide-only languages borrow a site language for navigation and name their script in hreflang',async()=>{
  const guide=guides.find(item=>item.languages['zh-hant']&&item.languages.ja&&item.languages.zh&&item.languages.en);
  assert.ok(guide,'at least one guide exists in Traditional Chinese and Japanese');
  const traditional=renderGuide(await shellCopy('zh-hant'),guide),japanese=renderGuide(await shellCopy('ja'),guide);
  assert.ok(traditional.includes('<html lang="zh-Hant">'));assert.ok(japanese.includes('<html lang="ja">'));
  // Site links go to the borrowed language; the guide links stay in the reader's language.
  assert.ok(traditional.includes('href="/zh/#pricing"')&&traditional.includes('href="/zh-hant/guides/"'));
  assert.ok(japanese.includes('href="/en/#pricing"')&&japanese.includes('href="/ja/guides/"'));
  assert.doesNotMatch(traditional,/href="\/zh-hant\/(#|docs|privacy)/);assert.doesNotMatch(japanese,/href="\/ja\/(#|docs|privacy)/);
  const head=traditional.split('</head>')[0];
  for(const [tag,language] of [['en','en'],['zh-Hans','zh'],['zh-Hant','zh-hant'],['ja','ja'],['de','de'],['es','es']])
    if(guide.languages[language])assert.ok(head.includes(`hreflang="${tag}" href="https://skycut.app/${language}/guides/${guide.slug}/"`),`${tag} alternate`);
  assert.ok(head.includes(`hreflang="x-default" href="https://skycut.app/en/guides/${guide.slug}/"`));
  assert.doesNotMatch(head,/hreflang="zh" /,'with both scripts present, neither claims all of Chinese');
  assert.equal(meta(traditional,'og:locale'),'zh_TW');assert.equal(meta(japanese,'og:locale'),'ja_JP');
  // The language menu offers the six versions of this guide; a site page still offers four.
  const menu=traditional.match(/<details class="language-menu">[\s\S]*?<\/details>/)[0];
  assert.equal((menu.match(/<a /g)||[]).length,guideLanguages(guide).length);
  assert.ok(menu.includes('繁體中文')&&menu.includes('日本語'));
  assert.equal((render(english).match(/<details class="language-menu">[\s\S]*?<\/details>/)[0].match(/<a /g)||[]).length,4);
  // Traditional Chinese quotes dollar prices and says so; the app has no Traditional interface and the page says that too.
  const text=visibleText(traditional);
  assert.ok(text.includes('$19')&&text.includes('美元'));assert.ok(text.includes('簡體中文'));
  assert.ok(visibleText(japanese).includes('日本語表示はありません'));
  assert.deepEqual(GUIDE_LANGUAGES,['en','zh','de','es','zh-hant','ja']);
});

test('a draft is built only for review: no route, no sitemap entry, not indexable',()=>{
  const draft={...sample,published:null,updated:null};
  assert.equal(isPublished(draft),false);
  assert.deepEqual(guideRoutes({drafts:false,list:[draft]}),[]);
  assert.equal(guideRoutes({drafts:true,list:[draft]}).length,2,'the hub and the article');
  assert.doesNotMatch(renderSitemap(undefined,[draft]),/guides/);
  const html=renderGuide(english,draft);
  assert.equal(meta(html,'robots'),'noindex,follow');
  assert.doesNotMatch(html,/application\/ld\+json|article:published_time/);
  assert.ok(html.includes(guideCopy.en.draft));
});

test('a published guide is an indexable article by Sky Lu with real dates and an answer first',()=>{
  const html=renderGuide(english,published),url=`https://skycut.app/en/guides/${sample.slug}/`;
  assert.equal(meta(html,'robots'),INDEX_DIRECTIVES);
  assert.ok(html.includes(`<link rel="canonical" href="${url}">`));
  assert.ok(html.includes(`hreflang="en" href="${url}"`));assert.ok(html.includes(`hreflang="x-default" href="${url}"`));
  assert.doesNotMatch(html.split('</head>')[0],/hreflang="(zh|zh-Hans|zh-Hant|ja|de|es)" href="[^"]*guides/,'no alternate for a language the guide is not written in');
  assert.equal(meta(html,'og:type'),'article');assert.equal(meta(html,'article:published_time'),'2026-11-20');
  assert.equal((html.match(/<h1\b/g)||[]).length,1);
  const body=html.split('</head>')[1];
  assert.ok(body.indexOf('class="guide-answer"')<body.indexOf('<section id="s1"'),'the answer comes before the first section');
  assert.match(body,/<time datetime="2026-11-20">November 20, 2026<\/time>/);assert.match(body,/<time datetime="2026-11-22">/);
  const usd=prices('en');
  assert.ok(body.includes(`$${usd.monthly} a month`));assert.ok(body.includes(`$${usd.yearly} a year`));
  assert.ok(body.includes('href="https://skylu.ai/download/skycut"'),'the guide ends at the download');
  assert.ok(body.includes('Apple silicon Mac with macOS 15 or later')&&body.includes('no Windows or Intel version'));
  // The trial is described the way the plan defines it.
  assert.ok(body.includes('7-day Pro trial starts the first time you connect SkyCut to your Sky Studio account'));
  assert.ok(body.includes('once per account and once per Mac'));assert.doesNotMatch(body,/every new account|New accounts get/);
  // Other makers are named and sourced, never linked.
  assert.doesNotMatch(body,/href="https?:\/\/(?!skylu\.ai|skystudioai\.com)/);
  const sources=body.match(/<section class="guide-sources">[\s\S]*?<\/section>/)[0];
  assert.equal((sources.match(/<li>/g)||[]).length,sample.sources.length);assert.doesNotMatch(sources,/<a |https?:/);
  for(const source of sample.sources)assert.ok(visibleText(`</head>${sources}`).includes(source.name));
  const graph=jsonGraph(html),article=node(graph,'Article');
  assert.equal(article.datePublished,'2026-11-20');assert.equal(article.dateModified,'2026-11-22');
  assert.equal(article.author['@id'],'https://skylu.ai/#person');assert.equal(node(graph,'Person').name,'Sky Lu');
  assert.equal(article.publisher['@id'],'https://skystudioai.com/#organization');assert.equal(article.mainEntityOfPage,url);
  assert.deepEqual(node(graph,'BreadcrumbList').itemListElement.map(item=>item.item),['https://skycut.app/en/','https://skycut.app/en/guides/',url]);
  const faq=node(graph,'FAQPage'),text=visibleText(html);
  assert.equal(faq.mainEntity.length,sample.languages.en.faq.length);
  for(const question of faq.mainEntity) {
    assert.ok(text.includes(question.name));assert.ok(text.includes(question.acceptedAnswer.text),'marked answers are the visible answers');
  }
  const sitemap=renderSitemap(undefined,[published]);
  assert.ok(sitemap.includes(`<loc>${url}</loc>\n    <lastmod>2026-11-22</lastmod>`));
  assert.ok(sitemap.includes('<loc>https://skycut.app/en/guides/</loc>\n    <lastmod>2026-11-22</lastmod>'));
});

test('the hub lists the guides of its language and appears in the navigation once one is published',async()=>{
  for(const language of GUIDE_LANGUAGES.filter(language=>guides.some(guide=>isPublished(guide)&&guide.languages[language]))) {
    const html=renderGuideHub(await shellCopy(language));
    for(const guide of guides.filter(guide=>isPublished(guide)&&guide.languages[language]))assert.ok(html.includes(`href="/${language}/guides/${guide.slug}/"`));
    assert.equal(meta(html,'robots'),INDEX_DIRECTIVES);
    assert.ok(html.includes('href="https://skylu.ai/download/skycut"'));
    assert.ok(node(jsonGraph(html),'CollectionPage'));
  }
  if(guides.some(guide=>isPublished(guide)&&guide.languages.en)) {
    const home=render(english);
    for(const part of ['desktop-nav','mobile-nav','footer-links'])
      assert.ok(home.match(new RegExp(`class="${part}"[\\s\\S]*?</(?:nav|div)>`))[0].includes('href="/en/guides/"'),`${part} links to the guides`);
  }
});

test('the publishing rules refuse a guide that breaks them',()=>{
  const refused=(change,pattern)=>assert.match(guideProblems(edit(change)).join('\n'),pattern);
  refused((g,en)=>{en.title='x'.repeat(61);},/title is 1 to 60/);
  refused((g,en)=>{en.description='x'.repeat(156);},/description is 1 to 155/);
  refused((g,en)=>{en.answer='Too short.';},/opens with a real answer/);
  refused((g,en)=>{en.faq[0][1]='Pro costs $19 a month.';},/write prices as/);
  refused((g,en)=>{en.sections[0].blocks.push('See [another editor](https://example.com/editor).');},/links go to our own pages/);
  refused((g,en)=>{en.sections[0].blocks.push('Visit https://example.com for more.');},/no bare web addresses/);
  refused((g,en)=>{en.sections[0].blocks.push('SkyCut is the smoothest editor on the Mac.');},/no superlatives/);
  refused((g,en)=>{en.heading='The best way to edit video';},/"best" belongs to list guides/);
  refused(g=>{g.asOf='';},/asOf is the month/);
  refused(g=>{g.published='soon';},/published is null/);
  refused(g=>{g.published='2026-11-20';g.updated='2026-11-01';},/updated is a day on or after published/);
  refused(g=>{g.sources=[{name:'x',claim:'x',url:'http://insecure.example',checked:'2026-11-11'}];},/every source has/);
  refused(g=>{delete g.sources[0].name;},/every source has a name/);
  refused(g=>{g.sources[0].name='some-project (GitHub repository)';},/no mention of GitHub/);
  refused((g,en)=>{en.sections[0].blocks.push('SkyCut is on GitHub.');},/no mention of GitHub/);
  refused((g,en)=>{en.faq[0][1]='Read the source code to see how it works.';},/no mention of GitHub/);
  refused(g=>{g.slug='Not A Slug';},/slug is lowercase/);
  refused(g=>{g.languages.fr=g.languages.en;},/languages are/);
  assert.throws(()=>assertGuides([sample,sample]),/share a slug/);
  assert.deepEqual(guideProblems(sample),[]);
});
