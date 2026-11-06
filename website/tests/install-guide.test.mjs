// Installation guide contracts: native playback, one default subtitle track and static SEO.
// Browser playback and responsive layout are also checked against the local dev server.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,access} from 'node:fs/promises';
import {render} from '../scripts/template.mjs';
const root=new URL('../',import.meta.url);

for(const language of ['en','zh','de','es']) {
  test(`${language}: installation guide has one default subtitle track and matching VideoObject`,async()=>{
    const {default:c}=await import(`../content/${language}.js`);
    const html=render(c,'docs');
    const guide=html.match(/<section class="install-guide"[\s\S]*?<\/section>/)?.[0];
    assert.ok(guide,'the guide must be present in static HTML');
    assert.match(guide,/id="video"/);
    assert.ok(guide.includes(c.docsVideo.title));
    assert.ok(guide.includes(c.docsVideo.description));
    assert.ok(html.indexOf(c.docsSteps[0][0],html.indexOf('<main'))<html.indexOf(guide));
    assert.ok(html.indexOf(guide)<html.indexOf(c.docsSteps[1][0],html.indexOf('<main')));
    assert.equal((html.match(/<video\b/g)||[]).length,1);
    const video=guide.match(/<video\b[^>]*>/)[0];
    assert.match(video,/\bcontrols\b/);assert.match(video,/\bplaysinline\b/);
    assert.match(video,/preload="metadata"/);assert.match(video,/poster="\/media\/guides\/how-to-install-skycut-on-mac.jpg"/);
    assert.match(video,/width="1728" height="1080"/);assert.doesNotMatch(video,/autoplay|loop/);
    assert.match(guide,/<source src="\/media\/guides\/how-to-install-skycut-on-mac.mp4" type="video\/mp4">/);
    const requested=language==='zh'?'zh-Hans':language;
    const available=await access(new URL(`public/media/guides/how-to-install-skycut-on-mac.${requested}.vtt`,root)).then(()=>true,()=>false);
    const tag=available?requested:'en';
    const tracks=guide.match(/<track\b[^>]*>/g)||[];
    assert.equal(tracks.length,1);
    assert.ok(tracks[0].includes(`src="/media/guides/how-to-install-skycut-on-mac.${tag}.vtt"`));
    assert.ok(tracks[0].includes(`srclang="${tag}"`));
    assert.match(tracks[0],/kind="subtitles"/);assert.match(tracks[0],/\bdefault>/);
    for(const file of ['how-to-install-skycut-on-mac.mp4','how-to-install-skycut-on-mac.jpg',`how-to-install-skycut-on-mac.${tag}.vtt`])await access(new URL(`public/media/guides/${file}`,root));
    const graph=JSON.parse(html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1])['@graph'];
    const objects=graph.filter(node=>node['@type']==='VideoObject');
    assert.equal(objects.length,1);
    const object=objects[0];const page=graph.find(node=>node['@type']==='WebPage');
    assert.equal(object['@id'],`https://skycut.app/${language}/docs/#video`);
    assert.equal(page.video['@id'],object['@id']);assert.equal(object.isPartOf['@id'],page['@id']);
    assert.equal(object.name,c.docsVideo.title);assert.equal(object.description,c.docsVideo.description);
    assert.equal(object.contentUrl,'https://skycut.app/media/guides/how-to-install-skycut-on-mac.mp4');
    assert.equal(object.thumbnailUrl,'https://skycut.app/media/guides/how-to-install-skycut-on-mac.jpg');
    assert.equal(object.duration,'PT32.5S');
    assert.equal(object.caption.contentUrl,`https://skycut.app/media/guides/how-to-install-skycut-on-mac.${tag}.vtt`);
    assert.equal(object.caption.inLanguage,tag);assert.equal(object.caption.encodingFormat,'text/vtt');
    for(const kind of ['','privacy'])assert.doesNotMatch(render(c,kind),/"@type":"VideoObject"/);
  });
}

test('reviewed subtitles are valid WebVTT cues spanning the complete silent recording',async()=>{
  for(const language of ['zh-Hans','en']) {
    const vtt=await readFile(new URL(`public/media/guides/how-to-install-skycut-on-mac.${language}.vtt`,root),'utf8');
    assert.match(vtt,/^WEBVTT\n\n/);
    const cues=[...vtt.matchAll(/(\d\d):(\d\d):(\d\d\.\d{3}) --> (\d\d):(\d\d):(\d\d\.\d{3})\n([^\n]+)/g)];
    assert.equal(cues.length,10);
    let end=0;
    for(const cue of cues) {
      const start=Number(cue[1])*3600+Number(cue[2])*60+Number(cue[3]);
      const next=Number(cue[4])*3600+Number(cue[5])*60+Number(cue[6]);
      assert.equal(start,end);assert.ok(next>start);assert.ok(cue[7].trim());end=next;
    }
    assert.equal(end,32.5);
  }
});

test('Vercel explicitly serves every installation subtitle as text/vtt with nosniff retained',async()=>{
  const config=JSON.parse(await readFile(new URL('vercel.json',root),'utf8'));
  const rule=config.headers.find(rule=>new RegExp(`^${rule.source}$`).test('/media/guides/how-to-install-skycut-on-mac.zh-Hans.vtt')&&rule.headers.some(h=>h.key==='Content-Type'));
  assert.ok(rule);assert.ok(new RegExp(`^${rule.source}$`).test('/media/guides/how-to-install-skycut-on-mac.en.vtt'));
  assert.ok(rule.headers.some(h=>h.key==='Content-Type'&&h.value==='text/vtt; charset=utf-8'));
  assert.ok(config.headers.some(rule=>rule.source==='/(.*)'&&rule.headers.some(h=>h.key==='X-Content-Type-Options'&&h.value==='nosniff')));
});
