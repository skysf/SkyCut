// Exercise the production handler and a local sheet service over HTTP. Never contact Google.
import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {once} from 'node:events';
import {readFile} from 'node:fs/promises';
import {createHandler} from '../api/subscribe.js';
const env={NODE_ENV:'production',SRTFLOW_SIGNUP_SHEET_URL:'https://script.google.com/macros/s/test-deployment_id/exec',SRTFLOW_SIGNUP_SHEET_SECRET:'test-only-shared-secret-at-least-32-characters'};
const body={email:'reader@example.com',newsletter:false,intel:true,windows:false,language:'en',website:''};
let counter=0;
async function listen(server) {
  server.listen(0,'127.0.0.1');await once(server,'listening');
  return `http://127.0.0.1:${server.address().port}`;
}
async function close(server) {
  server.close();server.closeAllConnections();await once(server,'close');
}
async function harness({environment=env,respond,requestTimeoutMs,clock}={},run) {
  const calls=[],upstream=[];
  const sheet=createServer(async(req,res)=>{
    const chunks=[];for await(const chunk of req)chunks.push(chunk);
    upstream.push({method:req.method,path:req.url,headers:req.headers,body:Buffer.concat(chunks).toString('utf8')});
    res.setHeader('Content-Type','application/json');
    if(respond)await respond(req,res);
    else res.end(JSON.stringify({ok:true}));
  });
  const sheetBase=await listen(sheet);
  const server=createServer(createHandler({env:environment,requestTimeoutMs,clock,fetcher:(url,options)=>{
    calls.push({url,options});
    // Even a wrong production URL can only reach this loopback fake.
    return fetch(sheetBase+'/exec',options);
  }}));
  const base=await listen(server);
  const ip=`192.0.2.${++counter}`;
  const post=(value=body,headers={})=>fetch(base+'/api/subscribe',{method:'POST',headers:{'Content-Type':'application/json',Origin:'https://skycut.app','X-Forwarded-For':ip,...headers},body:typeof value==='string'?value:JSON.stringify(value)});
  try{await run({post,base,calls,upstream});}finally{await close(server);await close(sheet);}
}
test('unconfigured production route exposes only ready false and rejects submissions',async()=>{
  await harness({environment:{NODE_ENV:'production'}},async({post,base,calls})=>{
    const response=await fetch(base+'/api/subscribe');
    assert.equal(response.headers.get('cache-control'),'no-store');
    assert.deepEqual(await response.json(),{ready:false});
    const result=await post();assert.equal(result.status,503);assert.deepEqual(await result.json(),{code:'unavailable'});assert.equal(calls.length,0);
  });
});
test('invalid URLs and missing or short secrets fail closed without an upstream request',async()=>{
  const invalidURLs=[undefined,'','http://script.google.com/macros/s/id/exec','https://attacker.example/macros/s/id/exec','https://script.google.com.attacker.example/macros/s/id/exec','https://script.google.com@attacker.example/macros/s/id/exec','https://script.google.com:443/macros/s/id/exec','https://script.google.com/macros/s//exec','https://script.google.com/macros/s/id/dev','https://script.google.com/macros/s/id/exec?x=1','https://script.google.com/macros/s/id/exec#x','https://script.google.com/macros/s/id/exec\n'];
  const environments=[...invalidURLs.map(url=>({...env,SRTFLOW_SIGNUP_SHEET_URL:url})),...[undefined,'','a'.repeat(31),' '.repeat(32)].map(secret=>({...env,SRTFLOW_SIGNUP_SHEET_SECRET:secret}))];
  for(const environment of environments)await harness({environment},async({post,base,calls})=>{
    assert.deepEqual(await fetch(base+'/api/subscribe').then(r=>r.json()),{ready:false});
    assert.equal((await post()).status,503);assert.equal(calls.length,0);
  });
});
test('valid configuration exposes only readiness and a 32 character secret is sufficient',async()=>{
  await harness({environment:{...env,SRTFLOW_SIGNUP_SHEET_SECRET:'a'.repeat(32)}},async({base})=>{
    assert.deepEqual(await fetch(base+'/api/subscribe').then(r=>r.json()),{ready:true});
  });
});
test('successful submission sends exactly the sheet contract with normalized email and the server secret',async()=>{
  await harness({},async({post,calls,upstream})=>{
    const response=await post({...body,email:' Reader@Example.COM ',language:'de',windows:true});
    assert.equal(response.status,200);assert.deepEqual(await response.json(),{code:'registered'});
    assert.equal(calls.length,1);assert.equal(calls[0].url,env.SRTFLOW_SIGNUP_SHEET_URL);
    assert.equal(upstream[0].method,'POST');assert.equal(upstream[0].headers['content-type'],'application/json');
    assert.deepEqual(JSON.parse(upstream[0].body),{secret:env.SRTFLOW_SIGNUP_SHEET_SECRET,email:'reader@example.com',newsletter:false,intel:true,windows:true,language:'de'});
  });
});
test('every platform and newsletter can be selected independently in all four languages',async()=>{
  for(const language of ['en','zh','de','es'])await harness({},async({post,upstream})=>{
    for(const choice of ['newsletter','intel','windows']) {
      const selections={newsletter:false,intel:false,windows:false,[choice]:true};
      assert.equal((await post({...body,...selections,language})).status,200);
      assert.deepEqual(JSON.parse(upstream.at(-1).body),{secret:env.SRTFLOW_SIGNUP_SHEET_SECRET,email:body.email,...selections,language});
    }
  });
});
test('a real 302 follows as a GET and only the final JSON acknowledgement means success',async()=>{
  await harness({respond:(req,res)=>{
    if(req.url==='/exec') {res.writeHead(302,{Location:'/result'});res.end();}
    else res.end(JSON.stringify({ok:true}));
  }},async({post,calls,upstream})=>{
    assert.equal((await post()).status,200);assert.equal(calls.length,1);
    assert.deepEqual(upstream.map(r=>[r.method,r.path]),[['POST','/exec'],['GET','/result']]);
    assert.equal(upstream[1].body,'');
  });
});
test('negative, malformed or unexpected JSON and HTML never acknowledge a signup or retry',async()=>{
  for(const value of [{ok:false,error:'forbidden'},{ok:false,error:'bad_email'},{ok:false,error:'bad_request'},null,{},[],{ok:'true'},{ok:true,error:'forbidden'},'<html>Google error</html>','{broken']) {
    await harness({respond:(_req,res)=>res.end(typeof value==='string'?value:JSON.stringify(value))},async({post,calls})=>{
      const r=await post();assert.equal(r.status,502);assert.deepEqual(await r.json(),{code:'upstream'});assert.equal(calls.length,1);
    });
  }
});
test('non 2xx responses fail even with a success body and are not retried',async()=>{
  for(const status of [400,403,429,500,503])await harness({respond:(_req,res)=>{res.statusCode=status;res.end(JSON.stringify({ok:true}));}},async({post,calls})=>{
    const r=await post();assert.equal(r.status,502);assert.deepEqual(await r.json(),{code:'upstream'});assert.equal(calls.length,1);
  });
});
test('a stalled sheet request times out without an automatic retry',async()=>{
  await harness({requestTimeoutMs:50,respond:()=>{}},async({post,calls})=>{
    const r=await post();assert.equal(r.status,502);assert.deepEqual(await r.json(),{code:'upstream'});
    assert.equal(calls.length,1);assert.equal(calls[0].options.signal.aborted,true);
  });
});
test('timeout also covers a response whose JSON body stalls',async()=>{
  await harness({requestTimeoutMs:50,respond:(_req,res)=>{res.flushHeaders();res.write('{');}},async({post,calls})=>{
    const r=await post();assert.equal(r.status,502);assert.equal((await r.json()).code,'upstream');assert.equal(calls.length,1);
  });
});
test('production requests have a fifteen second timeout budget',async t=>{
  const timeout=AbortSignal.timeout.bind(AbortSignal),budgets=[];
  t.mock.method(AbortSignal,'timeout',milliseconds=>{budgets.push(milliseconds);return timeout(milliseconds);});
  await harness({},async({post})=>{assert.equal((await post()).status,200);});
  assert.deepEqual(budgets,[15000]);
});
test('a connection failure is an upstream error and is not retried',async()=>{
  await harness({respond:(_req,res)=>res.destroy()},async({post,calls})=>{
    const r=await post();assert.equal(r.status,502);assert.deepEqual(await r.json(),{code:'upstream'});assert.equal(calls.length,1);
  });
});
test('a filled honeypot returns ordinary success without writing the sheet',async()=>{
  await harness({},async({post,calls,upstream})=>{
    const r=await post({...body,website:'https://spam.example'});
    assert.equal(r.status,200);assert.deepEqual(await r.json(),{code:'registered'});
    assert.equal(calls.length,0);assert.equal(upstream.length,0);
  });
});
test('forged and absent origins are rejected before any upstream request',async()=>{
  await harness({},async({post,base,calls})=>{
    for(const origin of ['https://skycut.app.attacker.example','http://skycut.app','null','https://unrelated.vercel.app'])assert.equal((await post(body,{Origin:origin})).status,403);
    assert.equal((await fetch(base+'/api/subscribe',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)})).status,403);
    assert.equal(calls.length,0);
  });
});
test('only configured Vercel hosts and the official domains are permitted in production',async()=>{
  await harness({environment:{...env,VERCEL_URL:'skycut-test-team.vercel.app',VERCEL_PROJECT_PRODUCTION_URL:'skycut-website.vercel.app'}},async({post})=>{
    for(const origin of ['https://skycut.app','https://www.skycut.app','https://skycut-test-team.vercel.app','https://skycut-website.vercel.app'])assert.equal((await post(body,{Origin:origin})).status,200);
    assert.equal((await post(body,{Origin:'http://127.0.0.1:5173'})).status,403);
  });
});
test('malformed fields, unknown fields, formulas and oversized bodies are rejected',async()=>{
  await harness({},async({post,calls})=>{
    const invalid=[null,[],{},'null',...['bad','a@b','x'.repeat(255)+'@example.com','=reader@example.com','+reader@example.com','-reader@example.com','a<b@example.com'].map(email=>({...body,email})),{...body,intel:false},{...body,newsletter:'true'},{...body,windows:undefined},{...body,website:null},{...body,language:'fr'},{...body,unexpected:true},{...body,secret:'injected'}];
    for(const value of invalid)assert.equal((await post(value)).status,400);
    assert.equal((await post('{broken')).status,400);
    assert.equal((await post(body,{'Content-Type':'text/plain'})).status,415);
    assert.equal((await post({...body,email:'a'.repeat(5000)})).status,413);assert.equal(calls.length,0);
  });
});
test('rate limiting permits five attempts and expires after a minute',async()=>{
  let now=100000;
  await harness({clock:()=>now},async({post,calls})=>{
    for(let i=0;i<5;i++)assert.equal((await post()).status,200);
    const r=await post();assert.equal(r.status,429);assert.equal(r.headers.get('retry-after'),'60');assert.equal(calls.length,5);
    now+=60001;assert.equal((await post()).status,200);assert.equal(calls.length,6);
  });
});
test('unsupported methods advertise the allowed methods',async()=>{
  await harness({},async({base,calls})=>{
    const r=await fetch(base+'/api/subscribe',{method:'PUT'});assert.equal(r.status,405);assert.equal(r.headers.get('allow'),'GET, POST');assert.equal(calls.length,0);
  });
});
test('Vercel explicitly allows at least twenty seconds for the signup function',async()=>{
  const config=JSON.parse(await readFile(new URL('../vercel.json',import.meta.url),'utf8'));
  assert.ok(config.functions['api/subscribe.js'].maxDuration>=20);
});
