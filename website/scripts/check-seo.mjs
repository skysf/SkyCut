// Audit the real Vite output after build. Missing pages or assets must fail loudly.
import assert from 'node:assert/strict';
import {readFile,access} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
const dist=fileURLToPath(new URL('../dist/',import.meta.url));
const languages=['en','zh','de','es'];
let audited=0;
for(const language of languages) {
  for(const kind of ['','docs','privacy','confirmed']) {
    const html=await readFile(join(dist,language,kind,'index.html'),'utf8');
    assert.equal((html.match(/rel="canonical"/g)||[]).length,1);
    assert.ok(html.includes(`href="https://skycut.app/${language}/${kind?kind+'/':''}"`));
    assert.match(html,/<meta name="author" content="Sky Lu">/);
    assert.match(html,new RegExp(`<meta name="robots" content="${kind==='confirmed'?'noindex,follow':'index,follow,max-image-preview:large'}">`));
    if(kind!=='confirmed') {
      const script=html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)?.[1];
      assert.ok(script,'Vite must preserve static JSON-LD');
      const graph=JSON.parse(script)['@graph'];
      assert.ok(graph.some(node=>node['@type']==='SoftwareApplication' && node.publisher['@id']==='https://skystudioai.com/#organization'));
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
const sitemap=await readFile(join(dist,'sitemap.xml'),'utf8');
assert.equal((sitemap.match(/<loc>/g)||[]).length,12);
assert.doesNotMatch(sitemap,/confirmed|404|updates|localhost|vercel\.app/);
assert.match(await readFile(join(dist,'robots.txt'),'utf8'),/Sitemap: https:\/\/skycut.app\/sitemap.xml/);
console.log(`SEO audit passed for ${audited} localized pages, root, 404, sitemap, robots and four social cards`);
