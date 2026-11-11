// Tell IndexNow (Bing and the engines that share it) which pages are live.
// Run by hand after a production deploy, never by the build:
//   npm run indexnow            every address in the sitemap
//   npm run indexnow -- --only=/guides/     only addresses containing that text
//   npm run indexnow -- --dry-run           print what would be sent
// The key is public by design: it is the file public/<key>.txt. The script first
// reads that file from the live site, so it cannot run before the deploy is out.
import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {ORIGIN,INDEXNOW_KEY} from './site-config.mjs';
export const keyLocation=`${ORIGIN}/${INDEXNOW_KEY}.txt`;
export const sitemapAddresses=sitemap=>[...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map(match=>match[1]);
export function indexNowPayload(addresses) {
  return {host:new URL(ORIGIN).host,key:INDEXNOW_KEY,keyLocation,urlList:addresses};
}
async function main(args) {
  const only=args.find(arg=>arg.startsWith('--only='))?.slice(7);
  const sitemap=await readFile(new URL('../public/sitemap.xml',import.meta.url),'utf8');
  const addresses=sitemapAddresses(sitemap).filter(address=>!only||address.includes(only));
  if(!addresses.length)throw new Error('no address to submit');
  if(args.includes('--dry-run')) {console.log(addresses.join('\n'));console.log(`${addresses.length} addresses, nothing sent`);return;}
  const live=await fetch(keyLocation,{signal:AbortSignal.timeout(20000)});
  if(!live.ok||(await live.text()).trim()!==INDEXNOW_KEY)throw new Error(`${keyLocation} is not live yet: deploy first`);
  const response=await fetch('https://api.indexnow.org/indexnow',{method:'POST',headers:{'Content-Type':'application/json; charset=utf-8'},
    body:JSON.stringify(indexNowPayload(addresses)),signal:AbortSignal.timeout(30000)});
  // 200 and 202 both mean accepted; anything else is reported, not hidden.
  if(response.status!==200&&response.status!==202)throw new Error(`IndexNow answered ${response.status}: ${(await response.text()).slice(0,200)}`);
  console.log(`IndexNow accepted ${addresses.length} addresses (${response.status})`);
}
if(import.meta.url===pathToFileURL(process.argv[1]).href)await main(process.argv.slice(2));
