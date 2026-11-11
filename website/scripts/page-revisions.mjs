// When each public page last changed. A date is only ever written by
// `npm run stamp:pages`, on the day the page's static HTML really changed, so
// sitemap lastmod and JSON-LD dateModified never come from a build clock.
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
const file=new URL('../content/page-revisions.json',import.meta.url);
export const revisionsFile=file;
export const readRevisions=()=>JSON.parse(readFileSync(file,'utf8'));
const key=(language,kind)=>`${language}/${kind||'home'}`;
// The fingerprint ignores the two values that change without the page changing:
// the stamped date itself and the footer's copyright year.
export function fingerprint(html) {
  const stable=html.replace(/,"dateModified":"[^"]*"/g,'').replace(/© \d{4}/g,'©');
  return createHash('sha256').update(stable).digest('hex').slice(0,16);
}
export function modifiedDate(language,kind,revisions=readRevisions()) {
  return revisions[key(language,kind)]?.modified||null;
}
// Returns the pages whose recorded fingerprint no longer matches what is rendered.
export function stalePages(rendered,revisions=readRevisions()) {
  return rendered.filter(({language,kind,html})=>revisions[key(language,kind)]?.hash!==fingerprint(html)).map(({language,kind})=>key(language,kind));
}
export function stamped(rendered,today,revisions=readRevisions()) {
  const next={};
  for(const {language,kind,html} of rendered) {
    const hash=fingerprint(html),previous=revisions[key(language,kind)];
    next[key(language,kind)]=previous?.hash===hash?previous:{hash,modified:today};
  }
  return next;
}
