// 方案的定价、语言与购买边界通过实际静态首页核对，不调用付款服务。
import test from 'node:test';
import assert from 'node:assert/strict';
import {render,languages} from '../scripts/template.mjs';

const expected = {
  en: ['7 days of Pro','Manual editing as usual','Sky Studio watermark','AI editing requires Pro','1,000 Sky Studio credits for each paid year','No credits included','2 Macs','exclude tax','Local taxes','Cancel auto renewal anytime','nonrefundable','required by law','purchased separately'],
  zh: ['7 天 Pro','手动剪辑照常用','Sky Studio 水印','AI 剪辑需要 Pro','每个付费年送 1,000 Sky Studio 积分','月付不送积分','2 台 Mac','不含税','所在地另加','随时取消自动续费','已付费用不退','法律另有规定','积分另购'],
  de: ['7 Tage Pro','Manuell schneiden','Sky Studio Wasserzeichen','KI-Schnitt erfordert Pro','1 000 Sky Studio Credits pro bezahltem Jahr','Keine Credits enthalten','2 Macs','ohne Steuern','Lokale Steuern','jederzeit kündbar','Keine Erstattung','gesetzlich vorgeschrieben','separat gekaufte'],
  es: ['7 días de Pro','Edición manual','marca de agua de Sky Studio','edición con IA requiere Pro','1 000 créditos de Sky Studio por cada año pagado','Sin créditos incluidos','2 Macs','sin impuestos','impuestos locales','cuando quieras','no son reembolsables','la ley disponga','comprados aparte'],
};

for(const language of languages) {
  test(`${language}: visible pricing matches the plan and links only to Sky Studio for purchase`,async()=>{
    const {default:c}=await import(`../content/${language}.js`);
    const html=render(c);
    const section=html.match(/<section class="pricing\b[\s\S]*?<\/section>/)[0];
    const text=section.replace(/<[^>]*>/g,' ');
    for(const phrase of expected[language]) assert.ok(text.includes(phrase),phrase);
    for(const term of ['Claude','Codex','MCP','Sky Studio']) assert.ok(text.includes(term));
    assert.doesNotMatch(text,/[。！？；，、：!?;:]|\b\d+%/);
    const amounts=[...section.matchAll(/<strong>([^<]+)<\/strong>/g)].map(match=>match[1]);
    assert.deepEqual(amounts,language==='zh'?['¥129','¥999']:['$19','$149']);
    const links=[...section.matchAll(/<a\b[^>]*>/g)].map(match=>match[0]);
    assert.equal(links.length,2);
    assert.ok(links[0].includes('href="https://skylu.ai/download/skycut"'));
    assert.match(links[1],/href="https:\/\/skystudioai.com\/app\/skycut\/pro" target="_blank" rel="noopener noreferrer"/);
    assert.doesNotMatch(section,/<form|dodo|iframe/i);
    if(language==='zh') assert.ok(text.includes('微信支付一次性买一年 ¥999 不会自动续费'));
    else assert.doesNotMatch(section,/微信|WeChat|¥|CNY/);
    for(const kind of ['docs','privacy','confirmed','error']) {
      const page=render(c,kind);
      assert.ok(page.includes(`href="/${language}/#pricing"`));
      assert.doesNotMatch(page,/id="pricing"/);
    }
  });
}
