// Generate language-specific static HTML before Vite. No secrets enter these pages.
import { mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { render, languages } from './template.mjs';
import {PAGES} from './site-config.mjs';
import {renderSitemap,renderRobots} from './sitemap.mjs';
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
const {default:english} = await import('../content/en.js');
await writeFile(`${root}index.html`, render(english));
await writeFile(`${root}404.html`, render(english,'error'));
await writeFile(`${root}public/sitemap.xml`,renderSitemap());
await writeFile(`${root}public/robots.txt`,renderRobots());
console.log(`Generated ${languages.length * pages.length} localized pages, homepage, 404 and sitemap.`);
