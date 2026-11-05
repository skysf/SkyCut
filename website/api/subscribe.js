// Vercel Node endpoint: validate, challenge and request Brevo double opt-in. No mailing-list sends.
import {createHash} from 'node:crypto';
import {validateSubscription,subscriptionConfig,permittedOrigins} from '../server/subscription-policy.js';
const attempts=new Map();
function rateLimited(ip,now) {
  const key=createHash('sha256').update(ip).digest('hex');
  const prior=attempts.get(key);
  if(!prior || now-prior.start>60000) {attempts.set(key,{start:now,count:1});}
  else if(++prior.count>5)return true;
  if(attempts.size>1000)for(const [k,v] of attempts)if(now-v.start>60000)attempts.delete(k);
  if(attempts.size>2000)attempts.clear();
  return false;
}
async function readBody(req) {
  if(req.body!==undefined) {
    if(Buffer.byteLength(typeof req.body==='string'?req.body:JSON.stringify(req.body))>4096)throw new Error('body_size');
    return typeof req.body==='string'?JSON.parse(req.body):req.body;
  }
  const chunks=[];let bytes=0;
  for await(const chunk of req) {bytes+=Buffer.byteLength(chunk);if(bytes>4096)throw new Error('body_size');chunks.push(chunk);}
  return JSON.parse(Buffer.concat(chunks.map(c=>Buffer.from(c))).toString('utf8'));
}
export function createHandler({env=process.env,fetcher=fetch,clock=Date.now}={}) {
  return async function subscribe(req,res) {
    const send=(status,code,extra={})=>{res.statusCode=status;res.setHeader('Content-Type','application/json; charset=utf-8');res.setHeader('Cache-Control','no-store');res.end(JSON.stringify({code,...extra}));};
    const config=subscriptionConfig(env);
    if(req.method==='GET')return send(200,'configuration',{ready:config.ready,siteKey:config.ready?config.siteKey:null});
    if(req.method!=='POST') {res.setHeader('Allow','GET, POST');return send(405,'method');}
    const origin=req.headers.origin;
    if(!permittedOrigins(env).has(origin))return send(403,'origin');
    if(!String(req.headers['content-type']||'').toLowerCase().startsWith('application/json'))return send(415,'invalid');
    let body;
    try {body=await readBody(req);}catch(error) {return send(error.message==='body_size'?413:400,'invalid');}
    const subscription=validateSubscription(body);
    if(!subscription)return send(400,'invalid');
    if(!config.ready)return send(503,'unavailable');
    const ip=String(req.headers['x-forwarded-for'] || req.socket?.remoteAddress || '').split(',')[0].trim();
    if(rateLimited(ip,clock())) {res.setHeader('Retry-After','60');return send(429,'rate_limited');}
    try {
      const challengeResponse=await fetcher('https://challenges.cloudflare.com/turnstile/v0/siteverify',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({secret:config.secret,response:subscription.token,remoteip:ip}),signal:AbortSignal.timeout(8000)});
      if(!challengeResponse.ok)return send(503,'unavailable');
      const proof=await challengeResponse.json();
      const hostname=new URL(origin).hostname;
      if(!proof.success || proof.hostname!==hostname || proof.action!=='subscribe')return send(400,'challenge');
      const result=await fetcher('https://api.brevo.com/v3/contacts/doubleOptinConfirmation',{
        method:'POST',headers:{'Content-Type':'application/json','api-key':config.key},
        body:JSON.stringify({email:subscription.email,includeListIds:subscription.choices.map(k=>config.lists[k]),templateId:config.templates[subscription.language],redirectionUrl:`${origin}/${subscription.language}/confirmed/`,attributes:{SRTFLOW_LANGUAGE:subscription.language,SRTFLOW_CONSENT_AT:new Date(clock()).toISOString(),SRTFLOW_SOURCE:'https://skycut.app'}}),
        signal:AbortSignal.timeout(10000)
      });
      if(!result.ok)return send(result.status===429?429:502,result.status===429?'rate_limited':'delivery');
      return send(200,'confirmation_sent');
    } catch {return send(503,'unavailable');}
  };
}
export default createHandler();
