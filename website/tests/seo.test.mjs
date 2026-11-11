// Public search identity, canonical routes and crawler-visible localization contracts.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {render} from '../scripts/template.mjs';
import {renderSitemap,renderRobots} from '../scripts/sitemap.mjs';
import {serializeStructuredData} from '../scripts/structured-data.mjs';
import {INDEX_DIRECTIVES} from '../scripts/seo.mjs';
import {readRevisions} from '../scripts/page-revisions.mjs';
const languages=['en','zh','de','es'];
const tags={en:'en',zh:'zh-CN',de:'de',es:'es'};
// hreflang targets every Chinese locale with the one Chinese version, so it has no region.
const hreflang={en:'en',zh:'zh',de:'de',es:'es'};
const jsonGraph=html=>JSON.parse(html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1])['@graph'];
const meta=(html,name)=>html.match(new RegExp(`<meta (?:name|property)="${name}" content="([^"]*)"`))?.[1];
for(const language of languages) {
  test(`${language}: search metadata describes the actual route and the founder product family is visible`,async()=>{
    const {default:c}=await import(`../content/${language}.js`);
    const descriptions=[];
    for(const page of ['','docs','privacy']) {
      const html=render(c,page);const canonical=`https://skycut.app/${language}/${page?page+'/':''}`;
      assert.equal((html.match(/<title>/g)||[]).length,1);
      assert.match(html,new RegExp(`<link rel="canonical" href="${canonical}">`));
      assert.equal(meta(html,'og:url'),canonical);
      assert.equal(meta(html,'author'),'Sky Lu');
      assert.equal(meta(html,'robots'),INDEX_DIRECTIVES);
      assert.equal(INDEX_DIRECTIVES,'index,follow,max-snippet:-1,max-image-preview:large,max-video-preview:-1');
      assert.equal(meta(html,'twitter:title'),meta(html,'og:title'));
      assert.equal(meta(html,'twitter:description'),meta(html,'description'));
      descriptions.push(meta(html,'description'));
      assert.match(html,/rel="author noopener">[^<]*Sky Lu/);
      assert.ok(html.includes(`https://skylu.ai/founder/?lang=${language}`));
      assert.ok(html.includes(c.seo.familyLabel));
      for(const other of languages)assert.ok(html.includes(`hreflang="${hreflang[other]}" href="https://skycut.app/${other}/${page?page+'/':''}"`));
      assert.doesNotMatch(html,/hreflang="zh-CN"/,'a region on the Chinese hreflang would send other Chinese locales to English');
      const graph=jsonGraph(html);
      const person=graph.find(node=>node['@type']==='Person');
      const organization=graph.find(node=>node['@type']==='Organization');
      const app=graph.find(node=>node['@type']==='SoftwareApplication');
      const webpage=graph.find(node=>node['@type']==='WebPage');
      assert.equal(person['@id'],'https://skylu.ai/#person');
      assert.equal(person.name,'Sky Lu');assert.equal(person.alternateName,'陆天宇');
      assert.equal(person.url,'https://skylu.ai/founder/');
      assert.equal(organization['@id'],'https://skystudioai.com/#organization');
      assert.equal(organization.founder['@id'],person['@id']);
      assert.equal(app.creator['@id'],person['@id']);assert.equal(app.publisher['@id'],organization['@id']);
      assert.equal(app.applicationSuite,'Sky Studio');assert.match(app.processorRequirements,/Apple silicon/);
      assert.doesNotMatch(app.operatingSystem,/Windows|Intel/);
      assert.equal(app.aggregateRating,undefined);
      if(page) assert.equal(app.offers,undefined);
      else {
        const currency=language==='zh'?'CNY':'USD';
        assert.deepEqual(app.offers.map(offer=>offer.price),language==='zh'?[0,129,999]:[0,19,149]);
        assert.ok(app.offers.every(offer=>offer.priceCurrency===currency));
        assert.equal(app.offers[0].url,'https://skylu.ai/download/skycut');
        for(const [i,duration] of [[1,'P1M'],[2,'P1Y']]) {
          const offer=app.offers[i];
          assert.equal(offer.url,'https://skystudioai.com/app/skycut/pro');
          assert.deepEqual(offer.priceSpecification,{'@type':'UnitPriceSpecification',price:offer.price,priceCurrency:currency,billingDuration:duration,valueAddedTaxIncluded:false});
        }
      }
      assert.equal(webpage.url,canonical);assert.equal(webpage.inLanguage,tags[language]);
      assert.doesNotMatch(html,/localhost|127\.0\.0\.1|github\.com|vercel\.app/);
    }
    assert.equal(new Set(descriptions).size,3,'home docs and privacy must not reuse one generic description');
  });
}
test('the sitemap contains only the twelve public canonical pages with reciprocal language links',()=>{
  const sitemap=renderSitemap();
  assert.match(sitemap,/xmlns:xhtml="http:\/\/www\.w3\.org\/1999\/xhtml"/);
  const entries=[...sitemap.matchAll(/<url>([\s\S]*?)<\/url>/g)].map(m=>m[1]);
  assert.equal(entries.length,12);
  assert.equal(new Set(entries.map(entry=>entry.match(/<loc>(.*?)<\/loc>/)[1])).size,12);
  for(const entry of entries) {
    const url=entry.match(/<loc>(.*?)<\/loc>/)[1];
    const path=new URL(url).pathname;
    assert.match(path,/^\/(en|zh|de|es)\/(docs\/|privacy\/)?$/);
    assert.equal((entry.match(/<xhtml:link /g)||[]).length,5);
    const route=path.split('/')[2];
    for(const language of languages)assert.ok(entry.includes(`hreflang="${hreflang[language]}" href="https://skycut.app/${language}/${route?route+'/':''}"`));
    const stamp=readRevisions()[`${path.split('/')[1]}/${route||'home'}`];
    assert.match(stamp.modified,/^\d{4}-\d{2}-\d{2}$/);
    assert.ok(entry.includes(`<lastmod>${stamp.modified}</lastmod>`),'lastmod is the recorded day the page changed, never a build date');
    assert.ok(entry.includes(`hreflang="x-default" href="https://skycut.app/en/${route?route+'/':''}"`));
  }
  assert.doesNotMatch(sitemap,/404|updates|localhost|vercel|<priority>|<changefreq>/);
  const robots=renderRobots();
  assert.match(robots,/Sitemap: https:\/\/skycut\.app\/sitemap\.xml/);
  assert.match(robots,/Disallow: \/api\//);
  assert.doesNotMatch(robots,/Disallow: \/(en|zh|de|es)\//,'noindex pages must remain crawlable');
});
test('the 404 page has its own canonical and cannot be indexed as a homepage',async()=>{
  const {default:c}=await import('../content/en.js');const html=render(c,'error');
  assert.equal(meta(html,'robots'),'noindex,follow');
  assert.match(html,/<link rel="canonical" href="https:\/\/skycut.app\/404.html">/);
  assert.doesNotMatch(html.split('</head>')[0],/hreflang=|application\/ld\+json/);
});
test('all four social cards are actual 1200x630 PNG images and metadata references the right language',async()=>{
  for(const language of languages) {
    const {default:c}=await import(`../content/${language}.js`);
    const html=render(c);const url=`https://skycut.app/media/og-card-${language}.png`;
    assert.equal(meta(html,'og:image'),url);assert.equal(meta(html,'twitter:image'),url);
    assert.equal(meta(html,'og:image:width'),'1200');assert.equal(meta(html,'og:image:height'),'630');
    assert.ok(meta(html,'og:image:alt').includes('Sky Lu'));
    const bytes=await readFile(new URL(`../public/media/og-card-${language}.png`,import.meta.url));
    assert.deepEqual([...bytes.subarray(0,8)],[137,80,78,71,13,10,26,10]);
    assert.equal(bytes.readUInt32BE(16),1200);assert.equal(bytes.readUInt32BE(20),630);
  }
});
test('structured data preserves valid JSON without prematurely closing its HTML script',()=>{
  const value={name:'</script><script>alert(1)</script>',text:'Sky Lu & Sky Studio'};
  const encoded=serializeStructuredData(value);assert.doesNotMatch(encoded,/<\/script>/);
  assert.deepEqual(JSON.parse(encoded),value);
});
