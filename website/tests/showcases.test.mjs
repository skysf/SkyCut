// Sequence contracts for the animated product demos, including their static fallback.
import test from 'node:test';
import assert from 'node:assert/strict';
import {SHOWCASE_TIMING, showcaseFrame, phaseTime} from '../src/showcase-state.js';
import {render} from '../scripts/template.mjs';
import chinese from '../content/zh.js';
import {access,stat} from 'node:fs/promises';
import {SHOWCASE_MEDIA,LANGUAGE_CODES,captionIndexAt} from '../src/showcase-media.js';

test('film workflow cannot place clips before generating shots or characters before the script',()=>{
  assert.equal(showcaseFrame('create',0).clips,0);
  assert.equal(showcaseFrame('create',3).character,false);
  assert.equal(showcaseFrame('create',7.99).scriptCount,3);
  assert.equal(showcaseFrame('create',8).character,true);
  assert.equal(showcaseFrame('create',12.49).shots,0);
  assert.equal(showcaseFrame('create',17.49).shots,3);
  assert.equal(showcaseFrame('create',17.49).clips,0);
  assert.equal(showcaseFrame('create',25).clips,3);
  assert.equal(showcaseFrame('create',32.5).finished,true);
  assert.deepEqual(showcaseFrame('create',39),showcaseFrame('create',0));
});
test('720p changes to 1080p only after enhancement completes',()=>{
  assert.equal(showcaseFrame('upscale',0).resolution,'1280×720');
  assert.ok(showcaseFrame('upscale',6).enhancement>0);
  assert.equal(showcaseFrame('upscale',9.99).resolution,'1280×720');
  assert.equal(showcaseFrame('upscale',10).enhancement,1);
  assert.equal(showcaseFrame('upscale',10).resolution,'1920×1080');
});
test('translations arrive progressively before alignment and the final result',()=>{
  assert.equal(showcaseFrame('translate',0).translationCount,0);
  assert.equal(showcaseFrame('translate',3).translationCount,1);
  assert.equal(showcaseFrame('translate',9.99).translationCount,7);
  assert.equal(showcaseFrame('translate',14).finished,false);
  assert.equal(showcaseFrame('translate',19).finished,true);
});
test('phase controls seek inside valid steps and all clocks wrap safely',()=>{
  for (const [kind,timing] of Object.entries(SHOWCASE_TIMING)) {
    for (let phase=0;phase<timing.length-2;phase++) assert.equal(showcaseFrame(kind,phaseTime(kind,phase)).phase,phase);
    assert.equal(showcaseFrame(kind,-10).phase,0);
    assert.equal(showcaseFrame(kind,timing.at(-1)*1000).phase,0);
    assert.throws(()=>phaseTime(kind,-1),RangeError);
  }
});
test('production markup connects three readable workflows and two subtitle tracks',()=>{
  const html=render(chinese);
  assert.equal((html.match(/data-showcase="/g)||[]).length,3);
  assert.equal((html.match(/class="show-window show-chat"/g)||[]).length,3);
  assert.equal((html.match(/class="show-window show-editor"/g)||[]).length,3);
  assert.equal((html.match(/class="show-subtitle-lane/g)||[]).length,2);
  assert.equal((html.match(/data-show-language=/g)||[]).length,7);
  assert.ok(html.includes('交互演示'));
  assert.doesNotMatch(html,/data-ask|feature-card|github\.com/i);
  chinese.showcase.scenes.forEach(scene=>assert.doesNotMatch(scene.title+scene.prompt,/[，。！？：；、]/));
});
test('all seven subtitle languages cover every spoken cue and preserve the silent gaps',()=>{
  assert.deepEqual(LANGUAGE_CODES,['en','fr','ja','de','es','zh','zh-Hant']);
  for(const code of LANGUAGE_CODES) {
    assert.equal(chinese.showcase.captions[code].length,4);
    chinese.showcase.captions[code].forEach(line=>assert.ok(line.trim().length));
  }
  assert.equal(captionIndexAt(.69),-1);
  assert.equal(captionIndexAt(.7),0);
  assert.equal(captionIndexAt(3.18),1);
  assert.equal(captionIndexAt(7.2),-1);
  assert.equal(captionIndexAt(7.36),3);
  assert.equal(captionIndexAt(9.5),-1);
});
test('actual Antarctic assets exist locally and keep the complete demo payload small',async()=>{
  const assets=new Set(Object.values(SHOWCASE_MEDIA).flatMap(media=>[media.video,media.poster,media.enhanced].filter(Boolean)));
  let size=0;
  for(const asset of assets) {
    const url=new URL(`../public${asset}`,import.meta.url);
    await access(url);size+=(await stat(url)).size;
  }
  assert.ok(size<7_000_000);
  assert.equal(SHOWCASE_MEDIA.translate.duration,10);
});
