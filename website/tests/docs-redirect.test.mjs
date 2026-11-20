// One docs address for everyone (user, 2026-11-20; the DMG install window prints only www.skycut.app/docs):
// /docs and /docs/ answer with a temporary redirect to the docs page in the visitor's primary Accept-Language entry,
// mapped the way the site's own entry point maps a device language (src/language.js). Pins the rules in vercel.json,
// their order and the English default.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {browserLanguage} from '../src/language.js';
import {LANGUAGES,pageURL} from '../scripts/site-config.mjs';

const config=JSON.parse(await readFile(new URL('../vercel.json',import.meta.url),'utf8'));
const SOURCES=['/docs','/docs/'];
const docsPage=language=>new URL(pageURL(language,'docs')).pathname;
// The primary subtag in either letter case, then the end of the header or what may follow a primary subtag:
// a subtag, a q value, the next entry or white space ('zha', Zhuang, is not 'zh').
const primary=letters=>`^${[...letters].map(letter=>`[${letter.toUpperCase()}${letter}]`).join('')}(?:[-_;,\\s].*)?$`;

// How Vercel applies vercel.json redirects: in order, the first rule whose source is the path and whose `has`
// conditions all hold wins; a header condition holds when the header is sent and its value matches the regex.
// Vercel's docs don't say whether that regex must match the whole header (Next.js, which shares the syntax, anchors it)
// or only a part, so every rule anchors itself and both readings must answer the same.
function redirect(path,acceptLanguage,reading) {
  for(const rule of config.redirects) {
    if(rule.source!==path)continue;
    const holds=(rule.has||[]).every(({type,key,value})=>{
      assert.equal(type,'header');assert.equal(key,'accept-language');
      if(acceptLanguage===undefined)return false;
      return new RegExp(reading==='whole'?`^${value}$`:value).test(acceptLanguage);
    });
    if(holds)return rule;
  }
  return undefined;
}
const READINGS=['whole','part'];

test('the one docs address sends each visitor to the docs in their primary language',()=>{
  assert.ok(config.redirects.every(rule=>/^\/[a-z-]*\/?$/.test(rule.source)),'the evaluator above reads every source as a literal path');
  const cases=[
    ['zh-CN','zh'],['zh-TW','zh'],['zh-HK','zh'],['zh-Hant-TW','zh'],['zh','zh'],['ZH-cn','zh'],['zh_CN','zh'],
    ['zh-CN,zh;q=0.9,en;q=0.8','zh'],['zh;q=0.9,en;q=0.8','zh'],['zh , en','zh'],
    ['es-ES','es'],['es-419,es;q=0.9','es'],['es','es'],
    ['de-DE','de'],['de-AT,de;q=0.9,en;q=0.8','de'],
    ['en-US,en;q=0.9','en'],['en-GB','en'],
    // No docs page in these languages yet: English.
    ['ja-JP','en'],['ru-RU','en'],['ko-KR','en'],['fr-FR,fr;q=0.9','en'],['pt-BR','en'],
    // Only the primary entry counts, as on the site's entry point: a later preference never takes over.
    ['en-US,zh-CN;q=0.9','en'],['ja-JP,zh-CN;q=0.9,es;q=0.8','en'],['ru-RU,de;q=0.9','en'],
    // Other languages whose codes start with the same letters (Zhuang, Central Alaskan Yupik, Delaware).
    ['zha','en'],['esu','en'],['del','en'],
    ['*','en'],['','en'],[undefined,'en'],
  ];
  for(const [header,language] of cases)for(const source of SOURCES)for(const reading of READINGS) {
    const rule=redirect(source,header,reading);
    assert.equal(rule?.destination,docsPage(language),`${source} with Accept-Language ${JSON.stringify(header)} (${reading})`);
    assert.equal(rule.permanent,false,'temporary (307): the mapping changes when ja / ru / zh-Hant docs exist');
  }
});

test('the docs redirect picks the language the site\'s own entry point would pick',()=>{
  const tags=['zh','zh-CN','zh-SG','zh-Hans','zh-Hant-TW','zh-TW','zh-HK','zh-MO','ZH-cn','zh_CN','en','en-GB','de','de-AT','de-CH',
    'es','es-AR','es-419','fr-FR','ja-JP','ko-KR','ru-RU','ar','pt-BR','it','zha','esu','del','*'];
  for(const tag of tags)for(const header of [tag,`${tag},en;q=0.8`,`${tag};q=0.9,fr;q=0.5`])for(const reading of READINGS)
    assert.equal(redirect('/docs',header,reading).destination,docsPage(browserLanguage([tag])),`${header} (${reading})`);
});

test('the docs rules are temporary, in order, with English last as the default; language addresses never redirect',()=>{
  const rules=config.redirects.filter(rule=>SOURCES.includes(rule.source));
  const expected=[];
  for(const language of ['zh','de','es'])for(const source of SOURCES)
    expected.push({source,has:[{type:'header',key:'accept-language',value:primary(language)}],destination:docsPage(language),permanent:false});
  for(const source of SOURCES)expected.push({source,destination:docsPage('en'),permanent:false});
  assert.deepEqual(rules,expected);
  // Vercel stops at the first rule that matches: the rule without a condition must come after every rule with one.
  for(const source of SOURCES) {
    const own=config.redirects.filter(rule=>rule.source===source);
    assert.equal(own.findIndex(rule=>!rule.has),own.length-1,`${source}: the default is last`);
  }
  // Every site language has its docs page as a target; a new docs language needs its rule here.
  assert.deepEqual(new Set(rules.map(rule=>rule.destination)),new Set(LANGUAGES.map(docsPage)));
  // No query or fragment in a target: Vercel then passes the visitor's query on (a ?lang= still reaches the page).
  assert.ok(rules.every(rule=>!/[?#]/.test(rule.destination)));
  // Explicit language addresses stay put whatever the browser says, so there is no redirect loop.
  for(const language of LANGUAGES)for(const path of [docsPage(language),docsPage(language).slice(0,-1)])
    assert.equal(redirect(path,'zh-CN','whole'),undefined,path);
});
