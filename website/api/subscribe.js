// Vercel Node endpoint: validate and save choices to the signup sheet. No email sends.
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
export function createHandler({env=process.env,fetcher=fetch,clock=Date.now,requestTimeoutMs=15000}={}) {
  return async function subscribe(req,res) {
    const json=(status,payload)=>{res.statusCode=status;res.setHeader('Content-Type','application/json; charset=utf-8');res.setHeader('Cache-Control','no-store');res.end(JSON.stringify(payload));};
    const send=(status,code)=>json(status,{code});
    const config=subscriptionConfig(env);
    if(req.method==='GET')return json(200,{ready:config.ready});
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
    // A filled honeypot receives the same acknowledgement without reaching the sheet.
    if(subscription.website)return send(200,'registered');
    try {
      const {email,newsletter,intel,windows,language}=subscription;
      const result=await fetcher(config.url,{
        method:'POST',headers:{'Content-Type':'application/json'},redirect:'follow',
        body:JSON.stringify({secret:config.secret,email,newsletter,intel,windows,language}),
        signal:AbortSignal.timeout(requestTimeoutMs)
      });
      if(!result.ok)return send(502,'upstream');
      const acknowledgement=await result.json();
      if(acknowledgement?.ok!==true || Object.keys(acknowledgement).length!==1)return send(502,'upstream');
      return send(200,'registered');
    } catch {return send(502,'upstream');}
  };
}
export default createHandler();
