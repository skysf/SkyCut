// 核对真实页面上的标价 对比表与模型入口 不调用付款或云端模型服务
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,access} from 'node:fs/promises';
import {render,languages} from '../scripts/template.mjs';
import {pricing} from '../scripts/pricing.mjs';
import {prices,annualBreakdown} from '../content/pricing.js';
import {featureGroups,localModelRows} from '../content/feature-matrix.js';
import {cloudModelGroups,localVoiceLanguages,localVoiceRoles,soundEffectPresets} from '../content/ai-models.js';
const sectionOf=c=>render(c).match(/<section class="pricing\b[\s\S]*?<\/section>/)[0];
const rowOf=(html,id)=>html.match(new RegExp(`<tr data-feature="${id}">([\\s\\S]*?)<\\/tr>`))?.[1];
const accessOf=(html,id)=>[...rowOf(html,id).matchAll(/<td data-access="([^"]+)"/g)].map(m=>m[1]);
const expected={
  en:['7 days of Pro','1,000 Sky Studio credits for each paid year','No credits included','2 Macs','exclude tax','Local taxes','Cancel auto renewal anytime','nonrefundable','required by law','purchased separately'],
  zh:['7 天 Pro','每个付费年送 1,000 Sky Studio 积分','月付不送积分','2 台 Mac','不含税','所在地另加','随时取消自动续费','已付费用不退','法律另有规定','积分另购'],
  de:['7 Tage Pro','1 000 Sky Studio Credits pro bezahltem Jahr','Keine Credits enthalten','2 Macs','ohne Steuern','Lokale Steuern','jederzeit kündbar','Keine Erstattung','gesetzlich vorgeschrieben','separat gekaufte'],
  es:['7 días de Pro','1 000 créditos de Sky Studio por cada año pagado','Sin créditos incluidos','2 Macs','sin impuestos','impuestos locales','cuando quieras','no son reembolsables','la ley disponga','comprados aparte'],
};
for(const language of languages) {
  test(`${language}: pricing keeps real prices terms and the sole purchase destination`,async()=>{
    const {default:c}=await import(`../content/${language}.js`);
    const section=sectionOf(c),text=section.replace(/<[^>]*>/g,' ');
    for(const phrase of expected[language])assert.ok(text.includes(phrase),phrase);
    for(const term of ['Claude Code',language==='zh'?'Claude 桌面版':'Claude Desktop','Codex','MCP','Sky Studio'])assert.ok(text.includes(term));
    assert.doesNotMatch(text,/[。！？；，、：!?;:]|\b\d+%/);
    assert.doesNotMatch(section,/undefined|\[object Object\]|<form|dodo|iframe/i);
    assert.deepEqual([...section.matchAll(/<strong>([^<]+)<\/strong>/g)].map(m=>m[1]),language==='zh'?['¥129','¥999']:['$19','$149']);
    const links=[...section.matchAll(/<a\b[^>]*>/g)].map(m=>m[0]);assert.equal(links.length,2);
    assert.ok(links[0].includes('href="https://skylu.ai/download/skycut"'));
    assert.match(links[1],/href="https:\/\/skystudioai.com\/app\/skycut\/pro" target="_blank" rel="noopener noreferrer"/);
    if(language==='zh')assert.ok(text.includes('微信支付一次性买一年 ¥999 不会自动续费'));
    else assert.doesNotMatch(section,/微信|WeChat|¥|CNY/);
    for(const kind of ['docs','privacy','error']) {
      const page=render(c,kind);assert.ok(page.includes(`href="/${language}/#pricing"`));assert.doesNotMatch(page,/id="pricing"/);
    }
  });
  test(`${language}: each comparison row has aligned Free and Pro cells and models have explicit access and billing`,async()=>{
    const {default:c}=await import(`../content/${language}.js`);
    const section=sectionOf(c),table=section.match(/<table>[\s\S]*?<\/table>/)[0];
    const expectedRows=[...featureGroups.flatMap(g=>g.rows.map(r=>r.id)),...localModelRows.map(r=>r.id),...cloudModelGroups.map(g=>`model-${g.id}`)];
    assert.deepEqual([...table.matchAll(/data-feature="([^"]+)"/g)].map(m=>m[1]),expectedRows);
    for(const id of expectedRows) {
      const row=rowOf(table,id);assert.equal((row.match(/<th scope="row"/g)||[]).length,1);assert.equal((row.match(/<td /g)||[]).length,2);
    }
    const paid=table.match(/<tbody class="comparison-advantages">([\s\S]*?)<\/tbody>/)[1];
    assert.match(paid,/data-feature="aiEditing"/);assert.match(paid,/data-feature="watermark"/);assert.match(paid,/data-feature="annualCredits"/);
    assert.deepEqual(accessOf(table,'aiEditing'),['unavailable','ai']);
    assert.deepEqual(accessOf(table,'watermark'),['watermarked','clean']);
    assert.deepEqual(accessOf(table,'annualCredits'),['none','annualCredits']);
    for(const group of featureGroups.filter(g=>g.id!=='pro'))for(const item of group.rows)assert.deepEqual(accessOf(table,item.id),['included','included']);
    for(const id of ['speech','translation'])assert.deepEqual(accessOf(table,id),['localUI','localBoth']);
    for(const id of ['vision','shots','kokoro','synth'])assert.deepEqual(accessOf(table,id),['unavailable','localAI']);
    assert.match(rowOf(table,'speech'),/macOS 26/);assert.match(rowOf(table,'translation'),/macOS 15/);
    assert.deepEqual(accessOf(table,'model-upscale'),['cloudUI','cloudBoth']);
    for(const group of cloudModelGroups.filter(g=>g.id!=='upscale'))assert.deepEqual(accessOf(table,`model-${group.id}`),['unavailable','cloudAI']);
    for(const model of cloudModelGroups.flatMap(g=>g.models))assert.ok(table.includes(model.title),model.title);
    for(const lang of localVoiceLanguages)assert.ok(rowOf(table,'kokoro').includes(c.pricing.compare.languages[lang]));
    for(const preset of soundEffectPresets)assert.ok(rowOf(table,'synth').includes(`>${preset}</li>`));
    assert.ok(table.includes(c.pricing.compare.access.noCredits));assert.ok(table.includes(c.pricing.compare.access.usesCredits));
    assert.ok(section.includes(c.pricing.compare.catalogNote));assert.doesNotMatch(table,/2 Macs|2 台 Mac/);
    const cards=section.match(/<div class="pricing-grid">([\s\S]*?)<div class="pricing-comparison"/)[1];
    assert.doesNotMatch(cards,/pricing-features|data-feature=|<ul/);
  });
  test(`${language}: annual equivalents and savings come from the displayed price data while JSON-LD retains real prices`,async()=>{
    const {default:c}=await import(`../content/${language}.js`);
    const p=prices(language),section=sectionOf(c);
    assert.ok(section.includes(`data-annual-monthly>${p.symbol}${(p.yearly/12).toFixed(2)}</b>`));
    assert.ok(section.includes(`data-annual-saving>${p.symbol}${p.monthly*12-p.yearly}</b>`));
    assert.ok(section.includes(c.pricing.billedYearly));
    const custom=pricing({...c,pricing:{...c.pricing,monthly:25,yearly:210}});
    assert.ok(custom.includes(`data-annual-monthly>${p.symbol}17.50</b>`));assert.ok(custom.includes(`data-annual-saving>${p.symbol}90</b>`));
    const graph=JSON.parse(render(c).match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1])['@graph'];
    const offers=graph.find(node=>node['@type']==='SoftwareApplication').offers;
    assert.deepEqual(offers.map(offer=>offer.price),[0,p.monthly,p.yearly]);
    assert.deepEqual(offers.slice(1).map(offer=>offer.priceSpecification.billingDuration),['P1M','P1Y']);
  });
}
test('annual price arithmetic rounds monthly equivalents to two decimals and handles other tariffs',()=>{
  assert.deepEqual(annualBreakdown(prices('en')),{perMonth:'12.42',saving:'79'});
  assert.deepEqual(annualBreakdown(prices('zh')),{perMonth:'83.25',saving:'549'});
  assert.deepEqual(annualBreakdown({monthly:20,yearly:120}),{perMonth:'10.00',saving:'120'});
  assert.deepEqual(annualBreakdown({monthly:9.99,yearly:99.5}),{perMonth:'8.29',saving:'20.38'});
});
test('the SkyCut-only snapshot accounts for all 27 catalog records without adding unrelated Studio models',()=>{
  const models=cloudModelGroups.flatMap(g=>g.models);
  assert.equal(models.length,21);assert.equal(new Set(models.map(m=>m.id)).size,21);
  assert.equal(models.reduce((sum,m)=>sum+m.kinds.length,0),27);
  assert.deepEqual([...new Set(models.flatMap(m=>m.kinds))].sort(),['image','image_to_video','lipsync','music','sound_effect','text_to_video','upscale','voice','voice_clone']);
  assert.ok(models.every(m=>m.title && m.kinds.length));
});
test('every feature row has a real source and local voice and sound counts match the App',async()=>{
  const rows=[...featureGroups.flatMap(g=>g.rows),...localModelRows];
  assert.equal(new Set(rows.map(r=>r.id)).size,rows.length);
  for(const row of rows)for(const source of row.sources)await access(new URL('../../'+source,import.meta.url));
  const roles=await readFile(new URL('../../Sources/SrtFlow/AIVoiceRole.swift',import.meta.url),'utf8');
  assert.equal((roles.match(/AIVoiceRole\(name:/g)||[]).length,localVoiceRoles);
  const languages=[...roles.match(/static let kokoroLanguages[^=]*= \[([^\]]+)\]/)[1].matchAll(/"([a-z]+)"/g)].map(m=>m[1]);
  assert.deepEqual(languages.sort(),[...localVoiceLanguages].sort());
  const synth=await readFile(new URL('../../Sources/SrtFlow/SoundEffects/SoundEffectPreset.swift',import.meta.url),'utf8');
  const cases=synth.slice(synth.indexOf('enum SoundEffectPreset'),synth.indexOf('/// 默认多长'));
  const presets=[...cases.matchAll(/case ([a-z, ]+)/g)].flatMap(m=>m[1].split(',').map(s=>s.trim()));
  assert.deepEqual(presets,soundEffectPresets);
});
