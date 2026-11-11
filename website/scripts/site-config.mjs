// Shared public identity and route inventory for HTML, structured data and the sitemap.
export const ORIGIN='https://skycut.app';
export const LANGUAGES=['en','zh','de','es'];
// The lang attribute and JSON-LD inLanguage say what the page is written in.
export const LANGUAGE_TAGS={en:'en',zh:'zh-CN',de:'de',es:'es','zh-hant':'zh-Hant',ja:'ja'};
// hreflang says who the page is for. Every Chinese locale gets the one Chinese
// version (src/language.js), so its hreflang carries no region.
export const HREFLANG_TAGS={en:'en',zh:'zh',de:'de',es:'es'};
// Guides are also written in Traditional Chinese and Japanese; the rest of the site is not.
// Such a page borrows the navigation targets and prices of one site language.
export const GUIDE_ONLY_LANGUAGES=['zh-hant','ja'];
export const GUIDE_LANGUAGES=[...LANGUAGES,...GUIDE_ONLY_LANGUAGES];
const SITE_LANGUAGE_FOR={'zh-hant':'zh',ja:'en'};
export const siteLanguage=language=>SITE_LANGUAGE_FOR[language]||language;
// Inside a group of translations: Simplified and Traditional Chinese name their script when both exist.
export function hreflangFor(language,cluster) {
  if(language==='zh-hant')return 'zh-Hant';
  if(language==='zh'&&cluster.includes('zh-hant'))return 'zh-Hans';
  return HREFLANG_TAGS[language]||LANGUAGE_TAGS[language];
}
export const PAGES=['','docs','privacy'];
export const INDEXABLE_PAGES=['','docs','privacy'];
export const DOWNLOAD_URL='https://skylu.ai/download/skycut';
export const FOUNDER_URL='https://skylu.ai/founder/';
export const PERSON_ID='https://skylu.ai/#person';
export const STUDIO_URL='https://skystudioai.com/';
export const PRO_PURCHASE_URL='https://skystudioai.com/app/skycut/pro';
export const ORGANIZATION_ID=`${STUDIO_URL}#organization`;
export const SUPPORT_EMAIL='support@skycut.app';
// IndexNow key: public by design, served as /<key>.txt (public/<key>.txt). Changing it means replacing that file.
export const INDEXNOW_KEY='d060f29490b71ebe66f2da0c1bedffd7';
// The same facts Sky Studio publishes about itself (its shared/brandEntities.ts).
export const STUDIO_ENTITY={
  alternateName:'Sky Studio AI',logo:`${STUDIO_URL}logo_webOnly.png`,
  sameAs:['https://www.wikidata.org/wiki/Q139824875','https://www.youtube.com/@SkyStudio_AI','https://www.tiktok.com/@skystudio_ai'],
};
// What SkyCut runs on and the interface languages the app ships (Resources/*.lproj).
export const APP_FACTS={
  operatingSystem:'macOS 15 or later',processor:'Apple silicon arm64',device:'Mac',
  interfaceLanguages:['en','zh-Hans','es'],transcriptionSystem:'macOS 26',
};
// AI crawlers named in robots.txt (owner, 2026-11-11: allow both kinds, keep /api/ closed).
// Only tokens their operators document; everything else still falls under `*`.
export const AI_CRAWLERS={
  answers:['OAI-SearchBot','ChatGPT-User','Claude-SearchBot','Claude-User','PerplexityBot','Perplexity-User','DuckAssistBot','MistralAI-User','Meta-ExternalFetcher','Applebot'],
  training:['GPTBot','ClaudeBot','Google-Extended','Applebot-Extended','CCBot','meta-externalagent','Amazonbot'],
};
export function pageURL(language,kind='') {
  return kind==='error'?`${ORIGIN}/404.html`:`${ORIGIN}/${language}/${kind?kind+'/':''}`;
}
