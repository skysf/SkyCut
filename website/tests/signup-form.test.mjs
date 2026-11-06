// Exercise the actual browser form controller with DOM and HTTP boundaries replaced locally.
import test from 'node:test';
import assert from 'node:assert/strict';
import {attachSignup} from '../src/signup.js';
import copy from '../content/zh.js';
const tick=()=>new Promise(resolve=>setImmediate(resolve));
function formFixture(t,fetcher) {
  const events={},attributes=new Map();
  const message={textContent:''};
  const button={disabled:false,innerHTML:'订阅所选消息<svg></svg>',textContent:''};
  const form={
    values:{email:' Reader@Example.COM ',newsletter:'true',intel:null,windows:null,language:'zh',website:''},
    elements:{email:{checkValidity:()=>true,reportValidity:()=>{}}},
    querySelector:selector=>selector==='.form-message'?message:button,
    addEventListener:(name,callback)=>{events[name]=callback;},
    setAttribute:(key,value)=>attributes.set(key,value),removeAttribute:key=>attributes.delete(key),
    reset:()=>{form.resets++;},resets:0,
  };
  const globals={
    document:{querySelector:()=>form,querySelectorAll:()=>[]},
    FormData:class {constructor(target){this.values=target.values;}get(key){return this.values[key]??null;}},
    fetch:fetcher,
  };
  for(const [key,value] of Object.entries(globals)) {
    const descriptor=Object.getOwnPropertyDescriptor(globalThis,key);
    Object.defineProperty(globalThis,key,{configurable:true,writable:true,value});
    t.after(()=>{if(descriptor)Object.defineProperty(globalThis,key,descriptor);else delete globalThis[key];});
  }
  attachSignup(copy);
  return {form,message,button,attributes,submit:()=>events.submit({preventDefault(){}})};
}
test('unconfigured forms show not open yet and do not post',async t=>{
  const calls=[];
  const f=formFixture(t,async(url,options)=>{calls.push({url,options});return Response.json({ready:false});});
  await tick();assert.equal(f.message.textContent,copy.subscribeUnavailable);
  await f.submit();assert.equal(calls.length,1);assert.equal(f.button.disabled,false);assert.equal(f.form.resets,0);
});
test('pending submission changes the button and blocks duplicates before config and during the POST',async t=>{
  let resolveSettings,resolveSubmission;
  const calls=[];
  const f=formFixture(t,(url,options)=>{
    calls.push({url,options});
    return new Promise(resolve=>{if(options.method==='POST')resolveSubmission=resolve;else resolveSettings=resolve;});
  });
  const operation=f.submit();
  assert.equal(f.button.disabled,true);assert.equal(f.button.textContent,copy.subscribeSending);
  assert.equal(f.attributes.get('aria-busy'),'true');
  await f.submit();assert.equal(calls.length,1);
  resolveSettings(Response.json({ready:true}));await tick();
  await f.submit();assert.equal(calls.length,2);
  assert.deepEqual(JSON.parse(calls[1].options.body),{email:'Reader@Example.COM',newsletter:true,intel:false,windows:false,language:'zh',website:''});
  resolveSubmission(Response.json({code:'registered'}));await operation;
  assert.equal(f.message.textContent,copy.subscribeSuccess);assert.equal(f.form.resets,1);
  assert.equal(f.button.disabled,false);assert.equal(f.button.innerHTML,'订阅所选消息<svg></svg>');assert.equal(f.attributes.has('aria-busy'),false);
});
test('upstream errors and malformed responses say try later and release the submit lock',async t=>{
  let posts=0;
  const f=formFixture(t,async(_url,options)=>{
    if(options.method!=='POST')return Response.json({ready:true});
    posts++;return posts===1?Response.json({code:'upstream'},{status:502}):new Response('<html>error</html>',{status:502});
  });
  await f.submit();assert.equal(f.message.textContent,copy.subscribeError);assert.equal(f.button.disabled,false);
  await f.submit();assert.equal(f.message.textContent,copy.subscribeError);assert.equal(posts,2);assert.equal(f.form.resets,0);
});
test('client validation prevents submission and rate limits preserve the selected choices',async t=>{
  let posts=0;
  const f=formFixture(t,async(_url,options)=>{
    if(options.method!=='POST')return Response.json({ready:true});
    posts++;return Response.json({code:'rate_limited'},{status:429});
  });
  f.form.values.newsletter=null;await f.submit();assert.equal(posts,0);assert.equal(f.message.textContent,copy.subscribeInvalid);
  f.form.values.windows='true';await f.submit();assert.equal(posts,1);assert.equal(f.message.textContent,copy.subscribeBusy);assert.equal(f.form.resets,0);
});
