// The small inline syntax guides are written in: **bold**, `code`, [text](link)
// and {{price}} placeholders. Everything else is escaped text; no HTML passes through.
import {escape as e} from './html.mjs';
import {prices} from '../content/pricing.js';
export function placeholders(language) {
  // Simplified Chinese quotes the Chinese site's prices; every other language the dollar prices.
  const p=prices(language==='zh'?'zh':'en');
  return {'pro.monthly':`${p.symbol}${p.monthly}`,'pro.yearly':`${p.symbol}${p.yearly}`,'free.price':`${p.symbol}0`};
}
export const fill=(text,language)=>text.replace(/\{\{([a-z.]+)\}\}/g,(match,key)=>{
  const value=placeholders(language)[key];
  if(!value)throw new Error(`unknown placeholder ${match}`);
  return value;
});
// Plain text, for metadata and structured data.
export const plain=(text,language)=>fill(text,language).replace(/\*\*([^*]+)\*\*/g,'$1').replace(/`([^`]+)`/g,'$1').replace(/\[([^\]]+)\]\([^)]+\)/g,'$1');
export function inline(text,language) {
  return e(fill(text,language))
    .replace(/`([^`]+)`/g,'<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>')
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g,(match,label,href)=>`<a href="${href}"${href.startsWith('http')?' target="_blank" rel="noopener"':''}>${label}</a>`);
}
