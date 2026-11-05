// Pure input/config policy for signup. This helper is outside api/ so it is not a public route.
const choices=['newsletter','intel','windows'];
const locales=['en','zh','de','es'];
export function validateSubscription(body) {
  if(!body || typeof body!=='object' || Array.isArray(body))return null;
  const allowed=new Set(['email','newsletter','intel','windows','language','website','token']);
  if(Object.keys(body).some(key=>!allowed.has(key)))return null;
  if(typeof body.email!=='string' || body.email.length>254)return null;
  const email=body.email.trim().toLowerCase();
  if(!/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(email))return null;
  if(choices.some(key=>typeof body[key]!=='boolean'))return null;
  if(!choices.some(key=>body[key]) || !locales.includes(body.language))return null;
  if(body.website!=='' || typeof body.token!=='string' || body.token.length<1 || body.token.length>2048)return null;
  return {email,language:body.language,choices:choices.filter(key=>body[key]),token:body.token};
}
function id(value) {return /^\d+$/.test(value || '') && Number(value)>0?Number(value):null;}
export function subscriptionConfig(env=process.env) {
  const lists=Object.fromEntries(choices.map(key=>[key,id(env[`SRTFLOW_BREVO_LIST_${key.toUpperCase()}`])]));
  const templates=Object.fromEntries(locales.map(key=>[key,id(env[`SRTFLOW_BREVO_DOI_${key.toUpperCase()}`])]));
  const key=env.SRTFLOW_BREVO_API_KEY;
  const siteKey=env.SRTFLOW_TURNSTILE_SITE_KEY;
  const secret=env.SRTFLOW_TURNSTILE_SECRET_KEY;
  return {lists,templates,key,siteKey,secret,ready:Boolean(key && siteKey && secret && Object.values(lists).every(Boolean) && Object.values(templates).every(Boolean))};
}
export function permittedOrigins(env=process.env) {
  const values=['https://skycut.app','https://www.skycut.app'];
  for(const host of [env.VERCEL_URL,env.VERCEL_PROJECT_PRODUCTION_URL]) {
    if(host && /^[\w.-]+\.vercel\.app$/.test(host))values.push(`https://${host}`);
  }
  if(env.NODE_ENV!=='production')values.push('http://127.0.0.1:5173','http://localhost:5173','http://127.0.0.1:4173');
  return new Set(values);
}
