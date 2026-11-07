// 核对真实页面上的标价 对比表与模型入口 不调用付款或云端模型服务
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,access} from 'node:fs/promises';
import {render,languages} from '../scripts/template.mjs';
import {pricing} from '../scripts/pricing.mjs';
import {prices,annualBreakdown} from '../content/pricing.js';
import {featureGroups,characterRows,localModelRows} from '../content/feature-matrix.js';
import {cloudModelGroups,skyStudioApiSource,skyStudioRevision,localVoiceLanguages,localVoiceRoles,soundEffectPresets} from '../content/ai-models.js';
const sectionOf=c=>render(c).match(/<section class="pricing\b[\s\S]*?<\/section>/)[0];
const rowOf=(html,id)=>html.match(new RegExp(`<tr data-feature="${id}">([\\s\\S]*?)<\\/tr>`))?.[1];
const accessOf=(html,id)=>[...rowOf(html,id).matchAll(/<td data-access="([^"]+)"/g)].map(m=>m[1]);
const expected={
  en:['7 days of Pro','1,000 Sky Studio credits for each paid year','No credits included','2 Macs','exclude tax','Local taxes','Cancel auto renewal anytime','nonrefundable','required by law','purchased separately'],
  zh:['7 天 Pro','每个付费年送 1,000 Sky Studio 积分','月付不送积分','2 台 Mac','不含税','所在地另加','随时取消自动续费','已付费用不退','法律另有规定','积分另购'],
  de:['7 Tage Pro','1 000 Sky Studio Credits pro bezahltem Jahr','Keine Credits enthalten','2 Macs','ohne Steuern','Lokale Steuern','jederzeit kündbar','Keine Erstattung','gesetzlich vorgeschrieben','separat gekaufte'],
  es:['7 días de Pro','1 000 créditos de Sky Studio por cada año pagado','Sin créditos incluidos','2 Macs','sin impuestos','impuestos locales','cuando quieras','no son reembolsables','la ley disponga','comprados aparte'],
};
const featureLabels={
  zh:{'model-narration':'旁白生成','model-effects':'音效生成','model-background':'图片背景去除',synth:'内置音效合成器',kokoro:'内置多语言声音合成'},
  en:{'model-narration':'Narration generation','model-effects':'Sound effect generation','model-background':'Image background removal',synth:'Built-in sound effect synth',kokoro:'Built-in multilingual voices'},
  de:{'model-narration':'Sprecherstimmen erzeugen','model-effects':'Soundeffekte erzeugen','model-background':'Bildhintergründe entfernen',synth:'Integrierter Soundeffekt-Synthesizer',kokoro:'Integrierte mehrsprachige Stimmen'},
  es:{'model-narration':'Generación de locución','model-effects':'Generación de efectos de sonido','model-background':'Eliminación del fondo de imágenes',synth:'Sintetizador de efectos de sonido integrado',kokoro:'Voces multilingües integradas'},
};
for(const language of languages) {
  test(`${language}: pricing keeps real prices terms and the sole purchase destination`,async()=>{
    const {default:c}=await import(`../content/${language}.js`);
    const section=sectionOf(c),text=section.replace(/<[^>]*>/g,' ');
    for(const phrase of expected[language])assert.ok(text.includes(phrase),phrase);
    for(const term of ['Claude Code',language==='zh'?'Claude 桌面版':'Claude Desktop','Codex','MCP','Sky Studio'])assert.ok(text.includes(term));
    assert.doesNotMatch(text,/[。！？；，、：!?;:]|\b\d+%/);
    assert.doesNotMatch(section,/undefined|\[object Object\]|<form|dodo|iframe/i);
    const p=prices(language);
    assert.deepEqual([...section.matchAll(/<strong(?: [^>]*)?>([^<]+)<\/strong>/g)].map(m=>m[1]),[`${p.symbol}0`,`${p.symbol}${p.monthly}`,`${p.symbol}${(p.yearly/12).toFixed(2)}`]);
    const links=[...section.matchAll(/<a\b[^>]*>/g)].map(m=>m[0]);assert.equal(links.length,3);
    assert.ok(links.some(link=>link.includes('href="https://skylu.ai/download/skycut"')));
    assert.ok(links.some(link=>/href="https:\/\/skystudioai.com\/app\/skycut\/pro" target="_blank" rel="noopener noreferrer"/.test(link)));
    const free=section.match(/<article class="pricing-card pricing-free"[\s\S]*?<\/article>/)[0];
    for(const key of ['freePrice','freeSummary','freeCompare'])assert.ok(free.includes(c.pricing[key]));
    assert.match(free,/href="#pricing-comparison"/);assert.match(section,/id="pricing-comparison"/);
    if(language==='zh')assert.ok(text.includes('微信支付一次性买一年 ¥999 不会自动续费'));
    else assert.doesNotMatch(section,/微信|WeChat|¥|CNY/);
    for(const kind of ['docs','privacy','error']) {
      const page=render(c,kind);assert.ok(page.includes(`href="/${language}/#pricing"`));assert.doesNotMatch(page,/id="pricing"/);
    }
  });
  test(`${language}: each comparison row has aligned Free and Pro cells and models have explicit access and billing`,async()=>{
    const {default:c}=await import(`../content/${language}.js`);
    const section=sectionOf(c),table=section.match(/<table>[\s\S]*?<\/table>/)[0];
    const expectedRows=[...featureGroups.flatMap(g=>g.rows.map(r=>r.id)),...characterRows.map(r=>r.id),...localModelRows.map(r=>r.id),...cloudModelGroups.map(g=>`model-${g.id}`)];
    assert.deepEqual([...table.matchAll(/data-feature="([^"]+)"/g)].map(m=>m[1]),expectedRows);
    for(const id of expectedRows) {
      const row=rowOf(table,id);assert.equal((row.match(/<th scope="row"/g)||[]).length,1);assert.equal((row.match(/<td /g)||[]).length,2);
    }
    const paid=table.match(/<tbody class="comparison-advantages">([\s\S]*?)<\/tbody>/)[1];
    assert.match(paid,/data-feature="aiEditing"/);assert.match(paid,/data-feature="watermark"/);assert.match(paid,/data-feature="annualCredits"/);
    assert.deepEqual(accessOf(table,'aiEditing'),['unavailable','ai']);
    assert.deepEqual(accessOf(table,'watermark'),['watermarked','clean']);
    assert.deepEqual(accessOf(table,'annualCredits'),['none','annualCredits']);
    for(const id of ['characterRead','characterManage'])assert.deepEqual(accessOf(table,id),['unavailable','aiNoCredits']);
    for(const id of ['characterGenerate','characterCreate','characterHeadshot'])assert.deepEqual(accessOf(table,id),['unavailable','cloudAI']);
    for(const item of characterRows)for(const phrase of c.pricing.compare.features[item.id])assert.ok(rowOf(table,item.id).includes(phrase));
    assert.ok(table.includes(c.pricing.compare.charactersTitle));assert.ok(table.includes(c.pricing.compare.charactersNote));
    for(const id of ['imageAngle','imageUpscale']) {
      const imageRow=rowOf(table,`model-${id}`);
      assert.ok(imageRow.includes(c.pricing.compare.models[id]));assert.ok(imageRow.includes(c.pricing.compare.modelDetails[id]));
      assert.deepEqual(accessOf(table,`model-${id}`),['unavailable','cloudAI']);
    }
    assert.match(rowOf(table,'model-imageUpscale'),/2/);assert.match(rowOf(table,'model-imageUpscale'),/4/);
    for(const group of featureGroups.filter(g=>g.id!=='pro'))for(const item of group.rows)assert.deepEqual(accessOf(table,item.id),['included','included']);
    for(const id of ['speech','translation'])assert.deepEqual(accessOf(table,id),['localUI','localBoth']);
    for(const id of ['vision','shots','kokoro','synth'])assert.deepEqual(accessOf(table,id),['unavailable','localAI']);
    assert.match(rowOf(table,'speech'),/macOS 26/);assert.match(rowOf(table,'translation'),/macOS 15/);
    assert.deepEqual(accessOf(table,'model-upscale'),['cloudUI','cloudBoth']);
    for(const group of cloudModelGroups.filter(g=>g.id!=='upscale'))assert.deepEqual(accessOf(table,`model-${group.id}`),['unavailable','cloudAI']);
    for(const model of cloudModelGroups.flatMap(g=>g.models))assert.ok(table.includes(model.title),model.title);
    for(const [id,label] of Object.entries(featureLabels[language]))assert.ok(rowOf(table,id).includes(`<span class="comparison-label">${label}</span>`),label);
    assert.doesNotMatch(section.replace(/<[^>]*>/g,' '),/Kokoro/i);
    assert.ok(rowOf(table,'kokoro').includes(c.pricing.compare.features.kokoro[1]));
    for(const lang of localVoiceLanguages)assert.ok(rowOf(table,'kokoro').includes(c.pricing.compare.languages[lang]));
    const synth=rowOf(table,'synth');
    assert.ok(synth.includes(c.pricing.compare.features.synth[1]));assert.ok(synth.includes(String(soundEffectPresets.length)));
    assert.doesNotMatch(synth,/<ul\b/);
    for(const preset of soundEffectPresets)assert.doesNotMatch(synth.replace(/<[^>]*>/g,' '),new RegExp(`\\b${preset}\\b`,'i'));
    assert.ok(table.includes(c.pricing.compare.access.noCredits));assert.ok(table.includes(c.pricing.compare.access.usesCredits));
    assert.ok(section.includes(c.pricing.compare.catalogNote));assert.doesNotMatch(table,/2 Macs|2 台 Mac/);
    const cards=section.match(/<div class="pricing-grid">([\s\S]*?)<div class="pricing-comparison"/)[1];
    assert.doesNotMatch(cards,/pricing-features|data-feature=|<ul/);
  });
  test(`${language}: annual equivalents and savings come from the displayed price data while JSON-LD retains real prices`,async()=>{
    const {default:c}=await import(`../content/${language}.js`);
    const p=prices(language),section=sectionOf(c);
    const yearly=section.match(/<div class="pricing-billing pricing-yearly">[\s\S]*?<\/div>/)[0];
    assert.ok(yearly.includes(`<strong data-annual-monthly>${p.symbol}${(p.yearly/12).toFixed(2)}</strong><span>${c.pricing.month}</span>`));
    assert.ok(yearly.includes(`class="pricing-billed-yearly">${c.pricing.billedYearly} <b data-annual-total>${p.symbol}${p.yearly}</b> ${c.pricing.year}`));
    assert.ok(section.includes(`data-annual-saving>${p.symbol}${p.monthly*12-p.yearly}</b>`));
    const saving=yearly.match(/<p class="pricing-saving">([\s\S]*?)<\/p>/)[1].replace(/<[^>]*>/g,'');
    assert.equal(saving,c.pricing.saving.replace('{amount}',`${p.symbol}${p.monthly*12-p.yearly}`));
    assert.ok(yearly.indexOf('data-annual-monthly')<yearly.indexOf('pricing-billed-yearly'));
    const custom=pricing({...c,pricing:{...c.pricing,monthly:25,yearly:210}});
    assert.ok(custom.includes(`data-annual-monthly>${p.symbol}17.50</strong>`));assert.ok(custom.includes(`data-annual-saving>${p.symbol}90</b>`));
    assert.ok(custom.includes(`data-annual-total>${p.symbol}210</b>`));
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
test('the SkyCut-only snapshot accounts for 33 catalog records and all nine image entries',()=>{
  const models=cloudModelGroups.flatMap(g=>g.models);
  assert.equal(skyStudioRevision,'94c3dcd3c86ce005d15a34e1dba13ebe3fab7a00');
  assert.equal(models.length,27);assert.equal(new Set(models.map(m=>m.id)).size,27);
  assert.equal(models.reduce((sum,m)=>sum+m.kinds.length,0),33);
  assert.deepEqual(models.filter(m=>m.kinds.includes('image')).map(m=>[m.id,m.title,m.operation||null]),[
    ['seedream5-flash','Seedream 5.0 Flash',null],['nano2','Nano Banana 2',null],
    ['nano2-lite','Nano Banana 2 Lite',null],['nano-banana-pro','Nano Banana Pro',null],
    ['gpt-image-2','GPT Image 2',null],['seedream5-pro','Seedream 5.0 Pro',null],
    ['qwen-angles','Qwen Angles','camera_angle'],['image-upscale','Image Upscale','upscale'],
    ['ideogram-remove-background','Ideogram Remove Background',null],
  ]);
  assert.deepEqual(cloudModelGroups.find(g=>g.id==='upscale').models.map(m=>m.kinds),[['upscale'],['upscale']]);
  assert.ok(models.every(m=>!['pro','nano-banana','seedream5-lite','dreamina','character-import'].includes(m.id)));
  assert.deepEqual([...new Set(models.flatMap(m=>m.kinds))].sort(),['image','image_to_video','lipsync','music','sound_effect','text_to_video','upscale','voice','voice_clone']);
  assert.ok(models.every(m=>m.title && m.kinds.length));
});
test('features cite App sources or the pinned Character contract and local voice and sound counts match the App',async()=>{
  const rows=[...featureGroups.flatMap(g=>g.rows),...characterRows,...localModelRows];
  assert.equal(new Set(rows.map(r=>r.id)).size,rows.length);
  for(const row of rows)for(const source of row.sources) {
    if(source.startsWith('https://')) {
      const url=new URL(source);assert.equal(source.split('#')[0],skyStudioApiSource);
      assert.ok(['#saved-character-references-2026-11-07','#native-character-creation-and-management-2026-11-07'].includes(url.hash));
    } else await access(new URL('../../'+source,import.meta.url));
  }
  const roles=await readFile(new URL('../../Sources/SrtFlow/AIVoiceRole.swift',import.meta.url),'utf8');
  assert.equal((roles.match(/AIVoiceRole\(name:/g)||[]).length,localVoiceRoles);
  const languages=[...roles.match(/static let kokoroLanguages[^=]*= \[([^\]]+)\]/)[1].matchAll(/"([a-z]+)"/g)].map(m=>m[1]);
  assert.deepEqual(languages.sort(),[...localVoiceLanguages].sort());
  const synth=await readFile(new URL('../../Sources/SrtFlow/SoundEffects/SoundEffectPreset.swift',import.meta.url),'utf8');
  const cases=synth.slice(synth.indexOf('enum SoundEffectPreset'),synth.indexOf('/// 默认多长'));
  const presets=[...cases.matchAll(/case ([a-z, ]+)/g)].flatMap(m=>m[1].split(',').map(s=>s.trim()));
  assert.deepEqual(presets,soundEffectPresets);
});
