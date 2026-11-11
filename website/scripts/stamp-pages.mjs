// Record today's date for every public page whose static HTML changed since the
// last stamp. Run it in the same change that edits a page: `npm run stamp:pages`.
// `--date=YYYY-MM-DD` records another real day; pages that did not change keep theirs.
import {writeFile} from 'node:fs/promises';
import {render,languages} from './template.mjs';
import {INDEXABLE_PAGES} from './site-config.mjs';
import {readRevisions,revisionsFile,stamped} from './page-revisions.mjs';
const today=process.argv.find(arg=>arg.startsWith('--date='))?.slice(7)||new Date().toLocaleDateString('sv-SE');
if(!/^\d{4}-\d{2}-\d{2}$/.test(today))throw new Error(`not a date: ${today}`);
const rendered=[];
for(const language of languages) {
  const {default:copy}=await import(`../content/${language}.js`);
  for(const kind of INDEXABLE_PAGES)rendered.push({language,kind,html:render(copy,kind)});
}
const before=readRevisions(),after=stamped(rendered,today,before);
const changed=Object.keys(after).filter(key=>after[key]!==before[key]);
await writeFile(revisionsFile,`${JSON.stringify(after,null,2)}\n`);
console.log(changed.length?`Stamped ${today}: ${changed.join(', ')}`:'No page changed; dates kept.');
