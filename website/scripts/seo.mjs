// Static, route-specific search metadata and social cards. No client-side SEO injection.
import {escape as e} from './html.mjs';
import {ORIGIN,LANGUAGES,LANGUAGE_TAGS,INDEXABLE_PAGES,FOUNDER_URL,pageURL} from './site-config.mjs';
import {structuredData,serializeStructuredData} from './structured-data.mjs';
const titleKeys={docs:'docsTitle',privacy:'privacyTitle',error:'errorTitle'};
const locales={en:'en_US',zh:'zh_CN',de:'de_DE',es:'es_ES'};
export function pageMetadata(c,kind='') {
  return {
    canonical:pageURL(c.lang,kind),
    title:kind?`${c[titleKeys[kind]]} | SkyCut`:c.seo.title,
    description:c.seo.descriptions[kind||'home'],
    image:`${ORIGIN}/media/og-card-${c.lang}.png`,indexable:INDEXABLE_PAGES.includes(kind),
  };
}
export function seoHead(c,kind='') {
  const meta=pageMetadata(c,kind);
  const graph=structuredData(c,kind,meta);
  const alternate=kind==='error'?'':LANGUAGES.map(l=>`<link rel="alternate" hreflang="${LANGUAGE_TAGS[l]}" href="${pageURL(l,kind)}">`).join('')+`<link rel="alternate" hreflang="x-default" href="${pageURL('en',kind)}">`;
  return `<title>${e(meta.title)}</title>
<meta name="description" content="${e(meta.description)}">
<meta name="author" content="Sky Lu"><meta name="application-name" content="SkyCut">
<meta name="robots" content="${meta.indexable?'index,follow,max-image-preview:large':'noindex,follow'}">
<link rel="author" href="${FOUNDER_URL}"><link rel="canonical" href="${meta.canonical}">${alternate}
<meta property="og:type" content="website"><meta property="og:site_name" content="SkyCut">
<meta property="og:title" content="${e(meta.title)}"><meta property="og:description" content="${e(meta.description)}">
<meta property="og:url" content="${meta.canonical}"><meta property="og:locale" content="${locales[c.lang]}">
${kind==='error'?'':LANGUAGES.filter(l=>l!==c.lang).map(l=>`<meta property="og:locale:alternate" content="${locales[l]}">`).join('')}
<meta property="og:image" content="${meta.image}"><meta property="og:image:secure_url" content="${meta.image}">
<meta property="og:image:type" content="image/png"><meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">
<meta property="og:image:alt" content="${e(c.seo.imageAlt)}">
<meta name="twitter:card" content="summary_large_image"><meta name="twitter:creator" content="@thatskylu">
<meta name="twitter:title" content="${e(meta.title)}"><meta name="twitter:description" content="${e(meta.description)}">
<meta name="twitter:image" content="${meta.image}"><meta name="twitter:image:alt" content="${e(c.seo.imageAlt)}">
${graph?`<script type="application/ld+json">${serializeStructuredData(graph)}</script>`:''}`;
}
