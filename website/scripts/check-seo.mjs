// Audit the real Vite output after build. Missing pages or assets must fail loudly.
import assert from 'node:assert/strict';
import {readFile,access} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
const dist=fileURLToPath(new URL('../dist/',import.meta.url));
const languages=['en','zh','de','es'];
let audited=0;
const sitemap=await readFile(join(dist,'sitemap.xml'),'utf8');
const guideLocations=[...sitemap.matchAll(/<loc>(https:\/\/skycut\.app(\/[a-z-]+\/guides\/[^<]*))<\/loc>\n    <lastmod>([^<]+)<\/lastmod>/g)];
for(const language of languages) {
  for(const kind of ['','docs','privacy']) {
    const html=await readFile(join(dist,language,kind,'index.html'),'utf8');
    assert.equal((html.match(/rel="canonical"/g)||[]).length,1);
    assert.ok(html.includes(`href="https://skycut.app/${language}/${kind?kind+'/':''}"`));
    assert.match(html,/<meta name="author" content="Sky Lu">/);
    assert.match(html,/<meta name="robots" content="index,follow,max-snippet:-1,max-image-preview:large,max-video-preview:-1">/);
    assert.ok(html.includes(`hreflang="zh" href="https://skycut.app/zh/${kind?kind+'/':''}"`),'Chinese hreflang has no region');
    assert.doesNotMatch(html,/hreflang="zh-CN"/);
    const script=html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)?.[1];
    assert.ok(script,'Vite must preserve static JSON-LD');
    const graph=JSON.parse(script)['@graph'];
    assert.ok(graph.some(node=>node['@type']==='SoftwareApplication' && node.publisher['@id']==='https://skystudioai.com/#organization'));
    const canonical=`https://skycut.app/${language}/${kind?kind+'/':''}`;
    const modified=graph.find(node=>node['@type']==='WebPage').dateModified;
    assert.match(modified,/^20\d{2}-\d{2}-\d{2}$/,'every page says when it last changed');
    assert.ok(sitemap.includes(`<loc>${canonical}</loc>\n    <lastmod>${modified}</lastmod>`),'sitemap lastmod and JSON-LD dateModified are the same recorded day');
    assert.ok(graph.find(node=>node['@type']==='Organization').sameAs.includes('https://www.wikidata.org/wiki/Q139824875'));
    if(kind==='docs') {
      const video=graph.find(node=>node['@type']==='VideoObject');
      assert.ok(video,'docs must expose the installation video in static JSON-LD');
      assert.equal(video['@id'],`https://skycut.app/${language}/docs/#video`);
      assert.equal(video.duration,'PT32.5S');
      assert.equal(video.uploadDate,'2026-11-06');
      assert.equal(video.contentUrl,'https://skycut.app/media/guides/how-to-install-skycut-on-mac.mp4');
      assert.equal(video.thumbnailUrl,'https://skycut.app/media/guides/how-to-install-skycut-on-mac.jpg');
      assert.match(html,/id="video"/);
      assert.equal((html.match(/<track\b/g)||[]).length,1);
      assert.ok(html.includes(`src="${new URL(video.caption.contentUrl).pathname}"`));
      for(const url of [video.contentUrl,video.thumbnailUrl,video.caption.contentUrl]) {
        const path=new URL(url).pathname;
        const bytes=await readFile(join(dist,path));
        assert.ok(bytes.equals(await readFile(new URL(`../public${path}`,import.meta.url))),'built guide assets must match the reviewed public assets');
      }
    }
    if(!kind) {
      const offers=graph.find(node=>node['@type']==='SoftwareApplication').offers;
      assert.deepEqual(offers.map(offer=>offer.price),language==='zh'?[0,129,999]:[0,19,149]);
      assert.ok(offers.every(offer=>offer.priceCurrency===(language==='zh'?'CNY':'USD')));
      assert.deepEqual(offers.slice(1).map(offer=>offer.priceSpecification.billingDuration),['P1M','P1Y']);
      assert.ok(offers.slice(1).every(offer=>offer.url==='https://skystudioai.com/app/skycut/pro' && offer.priceSpecification.valueAddedTaxIncluded===false));
      assert.match(html,/id="pricing"/);
      const faq=graph.find(node=>node['@type']==='FAQPage');
      assert.ok(faq,'the homepage questions are marked up');
      assert.equal(faq.mainEntity.length,(html.match(/<details><summary>/g)||[]).length,'one marked question per visible question');
      const app=graph.find(node=>node['@type']==='SoftwareApplication');
      assert.ok(app.featureList.length>=20 && app.isAccessibleForFree===true);
      assert.equal(app.softwareVersion,undefined);assert.equal(app.aggregateRating,undefined);
    }
    assert.ok(html.includes(`https://skycut.app/media/og-card-${language}.png`));
    for(const match of html.matchAll(/(?:src|href)="(\/assets\/[^"#]+)"/g))await access(join(dist,match[1]));
    audited++;
  }
  const bytes=await readFile(join(dist,'media',`og-card-${language}.png`));
  assert.equal(bytes.readUInt32BE(16),1200);assert.equal(bytes.readUInt32BE(20),630);
  assert.ok(bytes.equals(await readFile(new URL(`../public/media/og-card-${language}.png`,import.meta.url))),'built social cards must match the current public assets');
}
const root=await readFile(join(dist,'index.html'),'utf8');
for(const [file,size] of [['favicon-32.png',32],['favicon-64.png',64],['apple-touch-icon.png',180]]) {
  const bytes=await readFile(join(dist,file));
  assert.equal(bytes.readUInt32BE(16),size);assert.equal(bytes.readUInt32BE(20),size);
  assert.ok(root.includes(`href="/${file}"`));
}
const favicon=await readFile(join(dist,'favicon.ico'));
assert.equal(favicon.readUInt16LE(2),1);assert.equal(favicon.readUInt16LE(4),3);
assert.match(root,/<link rel="canonical" href="https:\/\/skycut.app\/en\/">/);
assert.match(root,/"@type":"WebSite"/);
const notFound=await readFile(join(dist,'404.html'),'utf8');
assert.match(notFound,/content="noindex,follow"/);
assert.match(notFound,/href="https:\/\/skycut.app\/404.html"/);
assert.equal((sitemap.match(/<loc>/g)||[]).length,12+guideLocations.length);
assert.equal((sitemap.match(/<lastmod>20\d{2}-\d{2}-\d{2}<\/lastmod>/g)||[]).length,12+guideLocations.length);
assert.doesNotMatch(sitemap,/404|updates|localhost|vercel\.app/);
// Guides: every address the sitemap lists is a built, indexable page with its dates;
// a guide page the sitemap does not list is a draft and must not be indexable.
for(const [,url,path,modified] of guideLocations) {
  const html=await readFile(join(dist,path,'index.html'),'utf8');
  assert.ok(html.includes(`<link rel="canonical" href="${url}">`));
  assert.match(html,/<meta name="robots" content="index,follow,max-snippet:-1,max-image-preview:large,max-video-preview:-1">/);
  const graph=JSON.parse(html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1])['@graph'];
  const article=graph.find(node=>node['@type']==='Article');
  if(article) {
    assert.equal(article.dateModified,modified);assert.match(article.datePublished,/^20\d{2}-\d{2}-\d{2}$/);
    assert.equal(article.author['@id'],'https://skylu.ai/#person');
    assert.ok(html.includes('https://skylu.ai/download/skycut'),'a guide ends at the download');
    assert.doesNotMatch(html,/\{\{[a-z.]+\}\}/);
  } else assert.ok(graph.some(node=>node['@type']==='CollectionPage'));
}
for(const language of [...languages,'zh-hant','ja']) {
  let hub;
  try {hub=await readFile(join(dist,language,'guides','index.html'),'utf8');} catch {continue;}
  if(!sitemap.includes(`<loc>https://skycut.app/${language}/guides/</loc>`))assert.match(hub,/content="noindex,follow"/,'a draft build of the guides is never indexable');
}
const robots=await readFile(join(dist,'robots.txt'),'utf8');
assert.match(robots,/Sitemap: https:\/\/skycut.app\/sitemap.xml/);
// Owner, 2026-11-11: AI crawlers for answers and for training are both welcome; /api/ stays closed.
for(const agent of ['OAI-SearchBot','ChatGPT-User','Claude-SearchBot','Claude-User','PerplexityBot','GPTBot','ClaudeBot','Google-Extended','Applebot-Extended','CCBot'])
  assert.match(robots,new RegExp(`^User-agent: ${agent}$`,'m'),`${agent} is named in robots.txt`);
assert.equal((robots.match(/^Disallow: \/api\/$/gm)||[]).length,3,'each group keeps /api/ closed');
assert.doesNotMatch(robots,/^Disallow: \/$/m,'no crawler is shut out');
for(const file of ['llms.txt','llms-full.txt']) {
  const text=await readFile(join(dist,file),'utf8');
  assert.match(text,/^# SkyCut/);assert.match(text,/\$19 per month/);assert.match(text,/no Windows version/);
  assert.doesNotMatch(text,/github|localhost|vercel\.app/i);
  assert.equal(text,await readFile(new URL(`../public/${file}`,import.meta.url),'utf8'),`${file} in the build is the generated one`);
}
console.log(`SEO audit passed for ${audited} localized pages, root, 404, sitemap, robots, llms files and four social cards`);
