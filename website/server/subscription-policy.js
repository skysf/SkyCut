// Pure input/config policy for signup. This helper is outside api/ so it is not a public route.
const choices=['newsletter','intel','windows'];
const locales=['en','zh','de','es'];
export function validateSubscription(body) {
  if(!body || typeof body!=='object' || Array.isArray(body))return null;
  const allowed=new Set(['email','newsletter','intel','windows','language','website']);
  if(Object.keys(body).some(key=>!allowed.has(key)))return null;
  if(typeof body.email!=='string' || body.email.length>254)return null;
  const email=body.email.trim().toLowerCase();
  // Match the sheet's restriction on leading spreadsheet formula characters.
  if(!/^[^\s@<>=+\-][^\s@<>]*@[^\s@<>]+\.[^\s@<>]+$/.test(email))return null;
  if(choices.some(key=>typeof body[key]!=='boolean'))return null;
  if(!choices.some(key=>body[key]) || !locales.includes(body.language))return null;
  if(typeof body.website!=='string')return null;
  return {email,language:body.language,newsletter:body.newsletter,intel:body.intel,windows:body.windows,website:body.website};
}
export function subscriptionConfig(env=process.env) {
  const url=env.SRTFLOW_SIGNUP_SHEET_URL;
  const secret=env.SRTFLOW_SIGNUP_SHEET_SECRET;
  const ready=typeof url==='string' && url===url.trim() && /^https:\/\/script\.google\.com\/macros\/s\/[A-Za-z0-9_-]+\/exec$/.test(url)
    && typeof secret==='string' && secret.trim().length>=32;
  return {url,secret,ready};
}
export function permittedOrigins(env=process.env) {
  const values=['https://skycut.app','https://www.skycut.app'];
  for(const host of [env.VERCEL_URL,env.VERCEL_PROJECT_PRODUCTION_URL]) {
    if(host && /^[\w.-]+\.vercel\.app$/.test(host))values.push(`https://${host}`);
  }
  if(env.NODE_ENV!=='production')values.push('http://127.0.0.1:5173','http://localhost:5173','http://127.0.0.1:4173');
  return new Set(values);
}
