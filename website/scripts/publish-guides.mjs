// Write the real day a guide went online into its index.js, then restamp the pages.
//   npm run publish:guides -- --date=2026-11-12            drafts (published:null) get this day
//   npm run publish:guides -- --redate=2026-11-11:2026-11-12   guides dated the first day move to the second
// Use --redate when a change was dated for one day and the deploy slipped to another,
// before the page has ever been online. A guide that is already live keeps its
// published day; edit `updated` by hand when its text changes.
import {readFile,writeFile,readdir} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root=new URL('../content/guides/',import.meta.url);
const day=/^20\d{2}-\d{2}-\d{2}$/;
const date=process.argv.find(arg=>arg.startsWith('--date='))?.slice(7);
const redate=process.argv.find(arg=>arg.startsWith('--redate='))?.slice(9).split(':');
if(Boolean(date)===Boolean(redate))throw new Error('give exactly one of --date=YYYY-MM-DD or --redate=OLD:NEW');
if(date&&!day.test(date)||redate&&!(redate.length===2&&redate.every(part=>day.test(part))))throw new Error('dates are YYYY-MM-DD');
const changed=[];
for(const entry of await readdir(root,{withFileTypes:true})) {
  if(!entry.isDirectory())continue;
  const file=new URL(`${entry.name}/index.js`,root);
  const text=await readFile(file,'utf8');
  const next=date?text.replace("published:null,updated:null",`published:'${date}',updated:'${date}'`)
    :text.replace(`published:'${redate[0]}',updated:'${redate[0]}'`,`published:'${redate[1]}',updated:'${redate[1]}'`);
  if(next!==text) {await writeFile(file,next);changed.push(entry.name);}
}
// A slipped deploy also moves the page stamps written for that same unpublished change.
if(redate) {
  const revisions=new URL('../content/page-revisions.json',import.meta.url);
  const before=await readFile(revisions,'utf8'),after=before.replaceAll(`"modified": "${redate[0]}"`,`"modified": "${redate[1]}"`);
  if(after!==before) {await writeFile(revisions,after);changed.push('page stamps');}
}
console.log(changed.length?`Dated ${date||redate[1]}: ${changed.join(', ')}`:'No guide matched; nothing changed.');
// The navigation and sitemap follow the guides, so the page stamps and generated files follow too.
const run=script=>execFileSync(process.execPath,[fileURLToPath(new URL(script,import.meta.url)),...(script.includes('stamp')?[`--date=${date||redate[1]}`]:[])],{stdio:'inherit'});
if(changed.length) {run('./stamp-pages.mjs');run('./generate.mjs');}
