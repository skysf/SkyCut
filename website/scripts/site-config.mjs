// Shared public identity and route inventory for HTML, structured data and the sitemap.
export const ORIGIN='https://skycut.app';
export const LANGUAGES=['en','zh','de','es'];
export const LANGUAGE_TAGS={en:'en',zh:'zh-CN',de:'de',es:'es'};
export const PAGES=['','docs','privacy','confirmed'];
export const INDEXABLE_PAGES=['','docs','privacy'];
export const DOWNLOAD_URL='https://skylu.ai/download/skycut';
export const FOUNDER_URL='https://skylu.ai/founder/';
export const PERSON_ID='https://skylu.ai/#person';
export const STUDIO_URL='https://skystudioai.com/';
export const ORGANIZATION_ID=`${STUDIO_URL}#organization`;
export function pageURL(language,kind='') {
  return kind==='error'?`${ORIGIN}/404.html`:`${ORIGIN}/${language}/${kind?kind+'/':''}`;
}
