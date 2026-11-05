// Match the personal site's four languages, including strict Simplified Chinese detection.
export const supported = ['en','zh','de','es'];
export function browserLanguage(preferences = []) {
  for (const value of preferences) {
    const tag = value.toLowerCase();
    if (/^zh-(cn|sg)(-|$)|^zh-hans(-|$)/.test(tag)) return 'zh';
    if (/^zh/.test(tag)) return 'en';
    const base = tag.split('-')[0];
    if (['en','de','es'].includes(base)) return base;
  }
  return 'en';
}
export function applyLanguage() {
  const key = 'SrtFlow.website.language';
  const url = new URL(location.href);
  const explicit = url.searchParams.get('lang');
  let preferred;
  try {preferred = localStorage.getItem(key);} catch { /* Storage may be unavailable. */ }
  const target = supported.includes(explicit) ? explicit : supported.includes(preferred) ? preferred : browserLanguage(navigator.languages || [navigator.language]);
  if (url.pathname === '/' || supported.includes(explicit)) {
    const path = url.pathname.replace(/^\/(en|zh|de|es)(\/|$)/,'/');
    const next = `/${target}${path === '/' ? '/' : path}`;
    if (url.pathname !== next) {url.pathname=next;url.searchParams.delete('lang');location.replace(url.href);return;}
  }
  document.querySelectorAll('.language-menu a[lang]').forEach(link => link.addEventListener('click', () => {
    try {localStorage.setItem(key,link.lang);} catch { /* Preference storage is optional. */ }
  }));
}
