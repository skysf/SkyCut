// One canonical route inventory for all localized sitemap entries and robot discovery.
import {LANGUAGES,LANGUAGE_TAGS,INDEXABLE_PAGES,ORIGIN,pageURL} from './site-config.mjs';
export function renderSitemap() {
  return `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">
${INDEXABLE_PAGES.flatMap(kind=>LANGUAGES.map(language=>`  <url>
    <loc>${pageURL(language,kind)}</loc>
${LANGUAGES.map(l=>`    <xhtml:link rel="alternate" hreflang="${LANGUAGE_TAGS[l]}" href="${pageURL(l,kind)}"/>`).join('\n')}
    <xhtml:link rel="alternate" hreflang="x-default" href="${pageURL('en',kind)}"/>
  </url>`)).join('\n')}
</urlset>\n`;
}
export function renderRobots() {
  return `User-agent: *\nAllow: /\nDisallow: /api/\n\nSitemap: ${ORIGIN}/sitemap.xml\n`;
}
