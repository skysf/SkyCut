// Match the device's primary language on entry; explicit locale URLs stay shareable and indexable.
export const supported = ['en','zh','de','es'];
export function browserLanguage(preferences = []) {
  const base = String(preferences[0] || '').trim().toLowerCase().split(/[-_]/)[0];
  return supported.includes(base) ? base : 'en';
}
export function applyLanguage() {
  const key = 'SrtFlow.website.language';
  const url = new URL(location.href);
  const explicit = url.searchParams.get('lang');
  const hasExplicit = supported.includes(explicit);
  let preferred;
  try {preferred = localStorage.getItem(key);} catch { /* Storage may be unavailable. */ }
  if (hasExplicit) {
    try {localStorage.setItem(key,explicit);} catch { /* Preference storage is optional. */ }
  }
  const preferences = navigator.languages?.length ? navigator.languages : [navigator.language];
  const target = hasExplicit ? explicit : supported.includes(preferred) ? preferred : browserLanguage(preferences);
  if (url.pathname === '/' || hasExplicit) {
    const path = url.pathname.replace(/^\/(en|zh|de|es)(\/|$)/,'/');
    url.pathname = `/${target}${path === '/' ? '/' : path}`;
    if (hasExplicit) url.searchParams.delete('lang');
    if (location.href !== url.href) {location.replace(url.href);return;}
  }
  document.querySelectorAll('.language-menu a[lang]').forEach(link => link.addEventListener('click', () => {
    try {localStorage.setItem(key,link.lang);} catch { /* Preference storage is optional. */ }
  }));
}
