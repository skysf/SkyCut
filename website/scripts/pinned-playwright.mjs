// Shared by the manual browser checks: the pinned Playwright that `npx` puts on PATH, headless
// launchers for the three engines, and the built site on a local port. No window is opened.
// Playwright is not a dependency of this package and CI does not run these checks.
import {createRequire} from 'node:module';
import {execFileSync} from 'node:child_process';
import {realpathSync} from 'node:fs';
import {access} from 'node:fs/promises';
import {dirname,join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {preview} from 'vite';

export const PLAYWRIGHT='1.65.0';
const root=fileURLToPath(new URL('../',import.meta.url));
export const option=name=>{const at=process.argv.indexOf(`--${name}`);return at>0?process.argv[at+1]:null;};

// `npx -p playwright@x node …` puts the package's command on PATH; follow it back to the package itself.
function loadPlaywright(script){
  let home;
  try{home=dirname(realpathSync(execFileSync('which',['playwright'],{encoding:'utf8'}).trim()));}catch{
    throw new Error(`Playwright is not on PATH. Run: npx -y -p playwright@${PLAYWRIGHT} node scripts/${script}`);
  }
  const require=createRequire(join(home,'package.json')),version=require('./package.json').version;
  if(version!==PLAYWRIGHT)throw new Error(`This check is pinned to playwright@${PLAYWRIGHT}, found ${version}`);
  return require('./index.js');
}

// Returns {playwright, launch, base, close}: `launch[engine]()` starts a headless browser, `base` is the
// address of the built site, `close()` stops serving it.
export async function headlessSite(script){
  if(process.platform!=='darwin')throw new Error('This check needs a Mac: headless Chromium only gets a real GPU through Metal here.');
  await access(join(root,'dist/en/index.html')).catch(()=>{throw new Error('Build the site first: npm run build');});
  const playwright=loadPlaywright(script);
  const launch={
    chromium:()=>playwright.chromium.launch({headless:true,args:['--use-angle=metal','--enable-gpu','--ignore-gpu-blocklist','--mute-audio']}),
    webkit:()=>playwright.webkit.launch({headless:true}),
    firefox:()=>playwright.firefox.launch({headless:true,firefoxUserPrefs:{'media.volume_scale':'0.0'}})
  };
  const server=await preview({root,logLevel:'silent',preview:{port:0,strictPort:false,host:'127.0.0.1'}});
  return {playwright,launch,base:`http://127.0.0.1:${server.httpServer.address().port}`,
    close:()=>new Promise(resolve=>server.httpServer.close(resolve))};
}

// PASS / FAIL lines and the final tally shared by the checks.
export function tally(){
  let failed=0,passed=0;
  return {
    check(name,ok,detail=''){if(ok)passed++;else failed++;console.log(`${ok?'PASS':'FAIL'} ${name}${detail?`  ${detail}`:''}`);},
    finish(){console.log(failed?`${failed} of ${failed+passed} checks FAILED`:`All ${passed} checks passed`);process.exit(failed?1:0);}
  };
}
