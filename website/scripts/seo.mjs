// Static, route-specific search metadata and social cards. No client-side SEO injection.
import {escape as e} from './html.mjs';
import {ORIGIN,LANGUAGES,GUIDE_LANGUAGES,INDEXABLE_PAGES,FOUNDER_URL,pageURL,hreflangFor,siteLanguage} from './site-config.mjs';
import {structuredData,serializeStructuredData} from './structured-data.mjs';
const titleKeys={docs:'docsTitle',privacy:'privacyTitle',error:'errorTitle'};
const locales={en:'en_US',zh:'zh_CN',de:'de_DE',es:'es_ES','zh-hant':'zh_TW',ja:'ja_JP'};
// Indexable pages let search and answer engines quote as much as they need.
export const INDEX_DIRECTIVES='index,follow,max-snippet:-1,max-image-preview:large,max-video-preview:-1';
// Guide-only languages share the card of the site language they borrow from.
export const socialImage=language=>`${ORIGIN}/media/og-card-${siteLanguage(language)}.png`;
export function pageMetadata(c,kind='') {
  return {
    canonical:pageURL(c.lang,kind),
    title:kind?`${c.seo.titles[kind]||c[titleKeys[kind]]} | SkyCut`:c.seo.title,
    description:c.seo.descriptions[kind||'home'],
    image:socialImage(c.lang),indexable:INDEXABLE_PAGES.includes(kind),
  };
}
// One head for every kind of page. `alternates` maps a site language to the URL of
// the same page in that language; a page with no translations passes an empty map.
export function headTags({c,title,description,canonical,image,indexable,alternates={},type='website',article=null,graph=null}) {
  const languages=GUIDE_LANGUAGES.filter(l=>alternates[l]);
  const alternate=languages.map(l=>`<link rel="alternate" hreflang="${hreflangFor(l,languages)}" href="${alternates[l]}">`).join('')
    +(languages.length?`<link rel="alternate" hreflang="x-default" href="${alternates.en||alternates[languages[0]]}">`:'');
  return `<title>${e(title)}</title>
<meta name="description" content="${e(description)}">
<meta name="author" content="Sky Lu"><meta name="application-name" content="SkyCut">
<meta name="robots" content="${indexable?INDEX_DIRECTIVES:'noindex,follow'}">
<link rel="author" href="${FOUNDER_URL}"><link rel="canonical" href="${canonical}">${alternate}
<meta property="og:type" content="${type}"><meta property="og:site_name" content="SkyCut">
<meta property="og:title" content="${e(title)}"><meta property="og:description" content="${e(description)}">
<meta property="og:url" content="${canonical}"><meta property="og:locale" content="${locales[c.lang]}">
${languages.filter(l=>l!==c.lang).map(l=>`<meta property="og:locale:alternate" content="${locales[l]}">`).join('')}
${article?`<meta property="article:published_time" content="${article.published}"><meta property="article:modified_time" content="${article.modified}"><meta property="article:author" content="${FOUNDER_URL}">`:''}
<meta property="og:image" content="${image}"><meta property="og:image:secure_url" content="${image}">
<meta property="og:image:type" content="image/png"><meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">
<meta property="og:image:alt" content="${e(c.seo.imageAlt)}">
<meta name="twitter:card" content="summary_large_image"><meta name="twitter:creator" content="@thatskylu">
<meta name="twitter:title" content="${e(title)}"><meta name="twitter:description" content="${e(description)}">
<meta name="twitter:image" content="${image}"><meta name="twitter:image:alt" content="${e(c.seo.imageAlt)}">
${graph?`<script type="application/ld+json">${serializeStructuredData(graph)}</script>`:''}`;
}
export function seoHead(c,kind='') {
  const meta=pageMetadata(c,kind);
  const alternates=kind==='error'?{}:Object.fromEntries(LANGUAGES.map(l=>[l,pageURL(l,kind)]));
  return headTags({c,...meta,alternates,graph:structuredData(c,kind,meta)});
}
