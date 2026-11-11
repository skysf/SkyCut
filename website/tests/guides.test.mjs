// The Guides section: drafts stay private, published guides carry real dates and
// Article data, and the wording rules stop a guide that breaks them.
import test from 'node:test';
import assert from 'node:assert/strict';
import english from '../content/en.js';
import {guides} from '../content/guides/index.js';
import {guideCopy} from '../content/guide-copy.js';
import {prices} from '../content/pricing.js';
import {render} from '../scripts/template.mjs';
import {renderGuide,renderGuideHub} from '../scripts/guide-page.mjs';
import {renderSitemap} from '../scripts/sitemap.mjs';
import {assertGuides,guideProblems,guideRoutes,isPublished,LIMITS} from '../scripts/guide-model.mjs';
import {INDEX_DIRECTIVES} from '../scripts/seo.mjs';
const meta=(html,name)=>html.match(new RegExp(`<meta (?:name|property)="${name}" content="([^"]*)"`))?.[1];
const jsonGraph=html=>JSON.parse(html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1])['@graph'];
const node=(graph,type)=>graph.find(item=>item['@type']===type);
const sample=guides[0];
const published={...sample,published:'2026-11-20',updated:'2026-11-22'};
const edit=change=>{const copy=structuredClone(sample);change(copy,copy.languages.en);return copy;};

test('every guide in the inventory passes the publishing rules',()=>{
  assert.doesNotThrow(()=>assertGuides());
  for(const guide of guides)for(const copy of Object.values(guide.languages)) {
    assert.ok(copy.title.length<=LIMITS.title);assert.ok(copy.description.length<=LIMITS.description);
  }
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
  if(!guides.some(isPublished))assert.doesNotMatch(render(english),/\/en\/guides\//,'no entry in the navigation until a guide is published');
});

test('a published guide is an indexable article by Sky Lu with real dates and an answer first',()=>{
  const html=renderGuide(english,published),url=`https://skycut.app/en/guides/${sample.slug}/`;
  assert.equal(meta(html,'robots'),INDEX_DIRECTIVES);
  assert.ok(html.includes(`<link rel="canonical" href="${url}">`));
  assert.ok(html.includes(`hreflang="en" href="${url}"`));assert.ok(html.includes(`hreflang="x-default" href="${url}"`));
  assert.doesNotMatch(html,/hreflang="(zh|de|es)" href="[^"]*guides/,'no alternate for a language the guide is not written in');
  assert.equal(meta(html,'og:type'),'article');assert.equal(meta(html,'article:published_time'),'2026-11-20');
  assert.equal((html.match(/<h1\b/g)||[]).length,1);
  const body=html.split('</head>')[1];
  assert.ok(body.indexOf('class="guide-answer"')<body.indexOf('<section id="s1"'),'the answer comes before the first section');
  assert.match(body,/<time datetime="2026-11-20">November 20, 2026<\/time>/);assert.match(body,/<time datetime="2026-11-22">/);
  const usd=prices('en');
  assert.ok(body.includes(`$${usd.monthly} a month`));assert.ok(body.includes(`$${usd.yearly} a year`));
  assert.doesNotMatch(html,/\{\{[a-z.]+\}\}|undefined|\[object Object\]/);
  assert.ok(body.includes('href="https://skylu.ai/download/skycut"'),'the guide ends at the download');
  assert.ok(body.includes('Apple silicon Mac with macOS 15 or later')&&body.includes('no Windows or Intel version'));
  assert.doesNotMatch(body,/github\.com|href="https?:\/\/(?!skylu\.ai|skystudioai\.com)/,'other makers are named, never linked');
  const graph=jsonGraph(html),article=node(graph,'Article');
  assert.equal(article.datePublished,'2026-11-20');assert.equal(article.dateModified,'2026-11-22');
  assert.equal(article.author['@id'],'https://skylu.ai/#person');assert.equal(node(graph,'Person').name,'Sky Lu');
  assert.equal(article.publisher['@id'],'https://skystudioai.com/#organization');assert.equal(article.mainEntityOfPage,url);
  assert.deepEqual(node(graph,'BreadcrumbList').itemListElement.map(item=>item.item),['https://skycut.app/en/','https://skycut.app/en/guides/',url]);
  const faq=node(graph,'FAQPage');
  assert.equal(faq.mainEntity.length,sample.languages.en.faq.length);
  const text=body.replace(/<[^>]+>/g,'').replace(/&#39;/g,"'").replace(/&amp;/g,'&');
  for(const question of faq.mainEntity) {
    assert.ok(text.includes(question.name));assert.ok(text.includes(question.acceptedAnswer.text),'marked answers are the visible answers');
  }
  const sitemap=renderSitemap(undefined,[published]);
  assert.ok(sitemap.includes(`<loc>${url}</loc>\n    <lastmod>2026-11-22</lastmod>`));
  assert.ok(sitemap.includes('<loc>https://skycut.app/en/guides/</loc>\n    <lastmod>2026-11-22</lastmod>'));
});

test('the hub lists guides and stays out of the index until one is published',()=>{
  // Review builds show drafts; the hub of a language with only drafts is not indexable.
  const before=process.env.SKYCUT_GUIDE_DRAFTS;
  process.env.SKYCUT_GUIDE_DRAFTS='1';
  try {
    const html=renderGuideHub(english);
    assert.ok(html.includes(sample.languages.en.heading));
    assert.equal(meta(html,'robots'),guides.some(isPublished)?INDEX_DIRECTIVES:'noindex,follow');
    assert.ok(html.includes('href="https://skylu.ai/download/skycut"'));
  } finally {if(before===undefined)delete process.env.SKYCUT_GUIDE_DRAFTS;else process.env.SKYCUT_GUIDE_DRAFTS=before;}
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
  refused(g=>{g.sources=[{claim:'x',url:'http://insecure.example',checked:'2026-11-11'}];},/every source has/);
  refused(g=>{g.slug='Not A Slug';},/slug is lowercase/);
  assert.throws(()=>assertGuides([sample,sample]),/share a slug/);
  assert.deepEqual(guideProblems(sample),[]);
});
