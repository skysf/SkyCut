// Exercise the production handler over HTTP. No real contacts or email requests are created.
import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {once} from 'node:events';
import {createHandler} from '../api/subscribe.js';
const env={NODE_ENV:'production',SRTFLOW_BREVO_API_KEY:'test-only-key',SRTFLOW_TURNSTILE_SITE_KEY:'public-test-site-key',SRTFLOW_TURNSTILE_SECRET_KEY:'test-only-secret',SRTFLOW_BREVO_LIST_NEWSLETTER:'11',SRTFLOW_BREVO_LIST_INTEL:'22',SRTFLOW_BREVO_LIST_WINDOWS:'33',SRTFLOW_BREVO_DOI_EN:'101',SRTFLOW_BREVO_DOI_ZH:'102',SRTFLOW_BREVO_DOI_DE:'103',SRTFLOW_BREVO_DOI_ES:'104'};
const body={email:'reader@example.com',newsletter:false,intel:true,windows:false,language:'en',website:'',token:'test-token'};
let counter=0;
async function harness({environment=env,fetcher}={},run) {
  const calls=[];
  const fakeFetch=fetcher || (async (url,options)=>{
    calls.push({url,options});
    return url.includes('siteverify')?Response.json({success:true,hostname:'skycut.app',action:'subscribe'}):new Response(null,{status:204});
  });
  const server=createServer(createHandler({env:environment,fetcher:fakeFetch}));
  server.listen(0,'127.0.0.1');await once(server,'listening');
  const base=`http://127.0.0.1:${server.address().port}`;
  const ip=`192.0.2.${++counter}`;
  const post=(value=body,headers={})=>fetch(base+'/api/subscribe',{method:'POST',headers:{'Content-Type':'application/json',Origin:'https://skycut.app','X-Forwarded-For':ip,...headers},body:typeof value==='string'?value:JSON.stringify(value)});
  try{await run({post,base,calls});}finally{server.close();server.closeAllConnections();await once(server,'close');}
}
test('unconfigured production route fails closed without calling any provider',async()=>{
  await harness({environment:{NODE_ENV:'production'}},async({post,base,calls})=>{
    const settings=await fetch(base+'/api/subscribe').then(r=>r.json());assert.equal(settings.ready,false);assert.equal(settings.siteKey,null);
    const response=await post();assert.equal(response.status,503);assert.equal((await response.json()).code,'unavailable');assert.equal(calls.length,0);
  });
});
test('public config exposes no private keys or list/template identifiers',async()=>{
  await harness({},async({base})=>{
    const r=await fetch(base+'/api/subscribe');assert.equal(r.headers.get('cache-control'),'no-store');
    assert.deepEqual(await r.json(),{code:'configuration',ready:true,siteKey:'public-test-site-key'});
  });
});
test('only explicitly selected lists enter double opt-in and nothing is subscribed directly',async()=>{
  await harness({},async({post,calls})=>{
    const response=await post({...body,email:' Reader@Example.COM ',language:'de',windows:true});
    assert.equal(response.status,200);assert.equal((await response.json()).code,'confirmation_sent');assert.equal(calls.length,2);
    const request=calls[1];assert.equal(request.url,'https://api.brevo.com/v3/contacts/doubleOptinConfirmation');
    const payload=JSON.parse(request.options.body);assert.deepEqual(payload.includeListIds,[22,33]);assert.equal(payload.templateId,103);assert.equal(payload.email,'reader@example.com');assert.equal(payload.attributes.SRTFLOW_LANGUAGE,'de');assert.equal(payload.redirectionUrl,'https://skycut.app/de/confirmed/');assert.equal(request.options.headers['api-key'],env.SRTFLOW_BREVO_API_KEY);
  });
});
test('newsletter can be selected independently of either unreleased platform',async()=>{
  await harness({},async({post,calls})=>{
    await post({...body,intel:false,newsletter:true,language:'es'});
    const payload=JSON.parse(calls[1].options.body);assert.deepEqual(payload.includeListIds,[11]);assert.equal(payload.templateId,104);
  });
});
test('reject malicious origins before reading or sending contact details',async()=>{
  await harness({},async({post,calls})=>{
    assert.equal((await post(body,{Origin:'https://skycut.app.attacker.example'})).status,403);assert.equal(calls.length,0);
  });
});
test('reject invalid inputs, hidden-field spam, unknown names and oversized bodies',async()=>{
  await harness({},async({post,calls})=>{
    for(const invalid of [{...body,email:'bad'},{...body,intel:false},{...body,newsletter:'true'},{...body,website:'spam'},{...body,language:'fr'},{...body,listIds:[999]},{...body,token:''}]) assert.equal((await post(invalid)).status,400);
    assert.equal((await post('{broken')).status,400);
    assert.equal((await post({...body,email:'a'.repeat(5000)})).status,413);assert.equal(calls.length,0);
  });
});
test('a forged challenge or mismatched hostname cannot reach Brevo',async()=>{
  for(const proof of [{success:false},{success:true,hostname:'attacker.example',action:'subscribe'},{success:true,hostname:'skycut.app',action:'login'}]) {
    let calls=0;
    await harness({fetcher:async()=>{calls++;return Response.json(proof);}},async({post})=>{
      const r=await post();assert.equal(r.status,400);assert.equal(calls,1);
    });
  }
});
test('upstream failures are never reported as successful signups and are not retried',async()=>{
  let calls=0;
  await harness({fetcher:async()=>{calls++;return calls===1?Response.json({success:true,hostname:'skycut.app',action:'subscribe'}):new Response(null,{status:500});}},async({post})=>{
    const r=await post();assert.equal(r.status,502);assert.equal((await r.json()).code,'delivery');assert.equal(calls,2);
  });
});
test('rate limit rejects a burst, including repeated valid challenges',async()=>{
  await harness({},async({post,calls})=>{
    for(let i=0;i<5;i++) assert.equal((await post()).status,200);
    const r=await post();assert.equal(r.status,429);assert.equal(r.headers.get('retry-after'),'60');assert.equal(calls.length,10);
  });
});
test('only this Vercel deployment and its production alias are allowed as preview origins',async()=>{
  await harness({environment:{...env,VERCEL_URL:'skycut-test-team.vercel.app',VERCEL_PROJECT_PRODUCTION_URL:'skycut-website.vercel.app'},fetcher:async (url,options)=>url.includes('siteverify')?Response.json({success:true,hostname:JSON.parse(options.body).response==='alias-token'?'skycut-website.vercel.app':'skycut-test-team.vercel.app',action:'subscribe'}):new Response(null,{status:204})},async({post})=>{
    assert.equal((await post(body,{Origin:'https://skycut-test-team.vercel.app'})).status,200);
    assert.equal((await post({...body,token:'alias-token'},{Origin:'https://skycut-website.vercel.app'})).status,200);
    assert.equal((await post(body,{Origin:'https://unrelated.vercel.app'})).status,403);
  });
});
