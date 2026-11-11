// One canonical route inventory for all localized sitemap entries and robot discovery.
import {LANGUAGES,GUIDE_LANGUAGES,INDEXABLE_PAGES,ORIGIN,AI_CRAWLERS,pageURL,hreflangFor} from './site-config.mjs';
import {readRevisions,modifiedDate} from './page-revisions.mjs';
import {visibleGuides,guideLanguages,guidesIn,hubPath,guidePath,absolute} from './guide-model.mjs';
const entry=(loc,modified,alternates)=>`  <url>
    <loc>${loc}</loc>${modified?`\n    <lastmod>${modified}</lastmod>`:''}
${Object.entries(alternates).map(([language,href])=>`    <xhtml:link rel="alternate" hreflang="${hreflangFor(language,Object.keys(alternates))}" href="${href}"/>`).join('\n')}
    <xhtml:link rel="alternate" hreflang="x-default" href="${alternates.en||Object.values(alternates)[0]}"/>
  </url>`;
// Published guides only: a draft has no address the public should find.
function guideEntries(list) {
  const options={drafts:false,...(list?{list}:{})};
  const published=visibleGuides(options);
  const hubs=GUIDE_LANGUAGES.filter(language=>guidesIn(language,options).length);
  const hubAlternates=Object.fromEntries(hubs.map(language=>[language,absolute(hubPath(language))]));
  return [
    ...hubs.map(language=>entry(absolute(hubPath(language)),guidesIn(language,options).map(guide=>guide.updated).sort().at(-1),hubAlternates)),
    ...published.flatMap(guide=>{
      const alternates=Object.fromEntries(guideLanguages(guide).map(language=>[language,absolute(guidePath(language,guide.slug))]));
      return guideLanguages(guide).map(language=>entry(alternates[language],guide.updated,alternates));
    }),
  ];
}
// `list` replaces the guide inventory in tests.
export function renderSitemap(revisions=readRevisions(),list) {
  const pages=INDEXABLE_PAGES.flatMap(kind=>LANGUAGES.map(language=>entry(pageURL(language,kind),modifiedDate(language,kind,revisions),Object.fromEntries(LANGUAGES.map(l=>[l,pageURL(l,kind)])))));
  return `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">
${[...pages,...guideEntries(list)].join('\n')}
</urlset>\n`;
}
// A crawler that finds its own group ignores `*`, so each group repeats the /api/ rule.
const group=(comment,agents)=>`# ${comment}\n${agents.map(agent=>`User-agent: ${agent}`).join('\n')}\nAllow: /\nDisallow: /api/\n`;
export function renderRobots() {
  return `User-agent: *\nAllow: /\nDisallow: /api/\n
${group('AI search and answer agents are welcome',AI_CRAWLERS.answers)}
${group('AI training crawlers are welcome too',AI_CRAWLERS.training)}
Sitemap: ${ORIGIN}/sitemap.xml\n`;
}
