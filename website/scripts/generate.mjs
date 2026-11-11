// Generate language-specific static HTML before Vite. No secrets enter these pages.
import { mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { render, languages } from './template.mjs';
import {PAGES} from './site-config.mjs';
import {renderSitemap,renderRobots} from './sitemap.mjs';
import {renderLlms,renderLlmsFull} from './llms.mjs';
import {assertGuides,guideRoutes} from './guide-model.mjs';
import {renderGuide,renderGuideHub} from './guide-page.mjs';
const root = fileURLToPath(new URL('../', import.meta.url));
const pages=PAGES;
for (const language of languages) {
  const {default:copy} = await import(`../content/${language}.js`);
  for (const page of pages) {
    const dir = `${root}${language}/${page ? page + '/' : ''}`;
    await mkdir(dir, {recursive:true});
    await writeFile(`${dir}index.html`, render(copy,page));
  }
}
// Guides: only the languages that have one, and drafts only when asked for.
assertGuides();
const routes=guideRoutes();
for (const {language,guide,path} of routes) {
  const {default:copy} = await import(`../content/${language}.js`);
  await mkdir(`${root}${path.slice(1)}`, {recursive:true});
  await writeFile(`${root}${path.slice(1)}index.html`, guide ? renderGuide(copy,guide) : renderGuideHub(copy));
}
const {default:english} = await import('../content/en.js');
await writeFile(`${root}index.html`, render(english));
await writeFile(`${root}404.html`, render(english,'error'));
await writeFile(`${root}public/sitemap.xml`,renderSitemap());
await writeFile(`${root}public/robots.txt`,renderRobots());
await writeFile(`${root}public/llms.txt`,renderLlms());
await writeFile(`${root}public/llms-full.txt`,renderLlmsFull());
console.log(`Generated ${languages.length * pages.length} localized pages, ${routes.length} guide pages, homepage, 404, sitemap, robots and llms files.`);
