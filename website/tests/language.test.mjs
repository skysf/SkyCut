// Exercise the real browser entry point, including navigation, storage and manual selection.
import test from 'node:test';
import assert from 'node:assert/strict';
import {applyLanguage,browserLanguage,supported} from '../src/language.js';
const key='SrtFlow.website.language';

function visit(href,options,verify) {
  const saved=new Map(['location','navigator','localStorage','document'].map(name=>[name,Object.getOwnPropertyDescriptor(globalThis,name)]));
  const storage=options.storage || new Map();
  const redirects=[];
  const links=supported.map(lang=>({lang,click:null,addEventListener(event,handler){if(event==='click')this.click=handler;}}));
  const values={
    location:{href,replace:href=>redirects.push(href)},
    navigator:{languages:options.languages,language:options.language},
    localStorage:{
      getItem(name){if(options.blockStorage)throw Error('Storage disabled');return storage.get(name) ?? null;},
      setItem(name,value){if(options.blockStorage)throw Error('Storage disabled');storage.set(name,value);},
    },
    document:{querySelectorAll:()=>links},
  };
  for(const [name,value] of Object.entries(values))Object.defineProperty(globalThis,name,{value,configurable:true});
  try {
    applyLanguage();
    verify({redirects,storage,links});
  } finally {
    for(const [name,descriptor] of saved) {
      if(descriptor)Object.defineProperty(globalThis,name,descriptor);
      else delete globalThis[name];
    }
  }
}

test('the primary device language includes Chinese scripts and regions; unsupported primaries use English',()=>{
  for(const language of ['zh','zh-CN','zh-SG','zh-Hans','zh-Hant-TW','zh-TW','zh-HK','zh-MO','ZH-cn','zh_CN'])assert.equal(browserLanguage([language]),'zh',language);
  for(const [language,expected] of [['en-GB','en'],['de-AT','de'],['es-AR','es'],['fr-FR','en'],['ja-JP','en'],['ko-KR','en'],['ar','en']])assert.equal(browserLanguage([language]),expected,language);
  assert.equal(browserLanguage(['fr-FR','de-DE']),'en');
  assert.equal(browserLanguage(['ja-JP','zh-CN']),'en');
  assert.equal(browserLanguage([]),'en');
});

test('the actual homepage entry selects device language and retains query parameters and section links',()=>{
  for(const [language,expected] of [['zh','zh'],['zh-TW','zh'],['de-DE','de'],['es-MX','es'],['ja-JP','en']]) {
    visit('https://skycut.app/?utm_source=launch#download',{languages:[language]},({redirects})=>{
      assert.deepEqual(redirects,[`https://skycut.app/${expected}/?utm_source=launch#download`]);
    });
  }
});

test('empty or missing language arrays fall back to navigator.language',()=>{
  for(const languages of [[],undefined])visit('https://skycut.app/',{languages,language:'zh-CN'},({redirects})=>assert.deepEqual(redirects,['https://skycut.app/zh/']));
});

test('manual selection is remembered on the next root visit instead of being overridden by the device',()=>{
  const storage=new Map();
  visit('https://skycut.app/zh/',{languages:['zh-CN'],storage},({links,redirects})=>{
    assert.deepEqual(redirects,[]);
    links.find(link=>link.lang==='en').click();
  });
  assert.equal(storage.get(key),'en');
  visit('https://skycut.app/',{languages:['zh-CN'],storage},({redirects})=>assert.deepEqual(redirects,['https://skycut.app/en/']));
});

test('explicit language selection preserves the route and is saved even when the current locale already matches',()=>{
  for(const current of ['en','de'])visit(`https://skycut.app/${current}/docs/?lang=de&utm_source=help#setup`,{languages:['zh-CN']},({redirects,storage})=>{
    assert.deepEqual(redirects,['https://skycut.app/de/docs/?utm_source=help#setup']);
    assert.equal(storage.get(key),'de');
  });
});

test('storage failures and stale saved languages cannot prevent automatic localization',()=>{
  visit('https://skycut.app/',{languages:['zh-HK'],blockStorage:true},({redirects})=>assert.deepEqual(redirects,['https://skycut.app/zh/']));
  visit('https://skycut.app/',{languages:['es-ES'],storage:new Map([[key,'fr']])},({redirects})=>assert.deepEqual(redirects,['https://skycut.app/es/']));
  visit('https://skycut.app/de/',{languages:['zh'],blockStorage:true},({links,redirects})=>{
    assert.deepEqual(redirects,[]);
    assert.doesNotThrow(()=>links.find(link=>link.lang==='zh').click());
  });
});

test('explicit localized URLs remain stable for shared links and search indexing',()=>{
  visit('https://skycut.app/es/privacy/',{languages:['zh-CN'],storage:new Map([[key,'de']])},({redirects})=>assert.deepEqual(redirects,[]));
});
