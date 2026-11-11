// Static page rendering and SEO. Layout animation is progressively enhanced in src/main.js.
import { homepage, escape as e } from './sections.mjs';
import { icon } from '../src/icons.js';
import {seoHead} from './seo.mjs';
import {installGuide} from './install-guide.mjs';
import {LANGUAGES,LANGUAGE_TAGS,FOUNDER_URL,STUDIO_URL,siteLanguage} from './site-config.mjs';
import {guidesIn,hubPath} from './guide-model.mjs';
import {guideCopy} from '../content/guide-copy.js';
export const languages=LANGUAGES;
const titles = { docs: 'docsTitle', privacy: 'privacyTitle', error: 'errorTitle' };
// The Guides entry appears in a language once that language has a guide to show.
const guidesLink=(c,current=false)=>guidesIn(c.lang).length?`<a ${current?'aria-current="page" ':''}href="${hubPath(c.lang)}">${e(guideCopy[c.lang].section)}</a>`:'';
const languageNames={en:'English',zh:'简体中文',de:'Deutsch',es:'Español','zh-hant':'繁體中文',ja:'日本語'};
const languageShort={zh:'简中','zh-hant':'繁中',ja:'日本語'};
// `languagePaths` maps each language to this page's address in that language; its keys are the menu.
// A guide-only language links to the pages of the site language it borrows (`site`).
function navigation(c, kind, languagePaths) {
  const site=siteLanguage(c.lang);
  return `<a class="skip-link" href="#main">${e(c.skip)}</a><header class="site-header container"><a class="wordmark" href="/${site}/" aria-label="SkyCut ${e(c.home)}">SkyCut</a>
    <nav class="desktop-nav" aria-label="${e(c.menu)}"><a href="/${site}/#features">${e(c.nav[0])}</a><a href="/${site}/#pricing">${e(c.pricing.title)}</a><a ${kind === 'docs' ? 'aria-current="page"' : ''} href="/${site}/docs/">${e(c.nav[1])}</a>${guidesLink(c,kind==='guides')}</nav>
    <div class="header-actions"><details class="language-menu"><summary>${icon('globe')}<span>${languageShort[c.lang] || c.lang.toUpperCase()}</span>${icon('chevron')}</summary><div>${Object.keys(languagePaths).map(lang => `<a href="${languagePaths[lang]}" lang="${lang}" hreflang="${lang}" ${lang === c.lang ? 'aria-current="true"' : ''}>${languageNames[lang]}</a>`).join('')}</div></details><a class="button button-small header-download" href="/${site}/#download">${e(c.download)}${icon('arrow')}</a><button class="mobile-menu-button icon-button" aria-label="${e(c.menu)}" aria-expanded="false" aria-controls="mobile-nav">${icon('menu')}</button></div>
    <nav class="mobile-nav" id="mobile-nav" aria-label="${e(c.menu)}" hidden><a href="/${site}/#features">${e(c.nav[0])}</a><a href="/${site}/#pricing">${e(c.pricing.title)}</a><a href="/${site}/docs/">${e(c.nav[1])}</a>${guidesLink(c)}<a href="/${site}/#download">${e(c.download)}</a></nav></header>`;
}
function footer(c) {
  const site=siteLanguage(c.lang);
  return `<footer class="site-footer container"><div><a class="wordmark" href="/${site}/">SkyCut</a><p>${e(c.footer)}</p></div><div class="footer-links"><a href="/${site}/#pricing">${e(c.pricing.title)}</a><a href="/${site}/docs/">${e(c.nav[1])}</a>${guidesLink(c)}<a href="/${site}/privacy/">${e(c.privacy)}</a><a href="mailto:support@skystudioai.com">${e(c.support)}</a></div><div class="footer-bottom"><div class="footer-credit"><a href="${FOUNDER_URL}?lang=${site}" target="_blank" rel="author noopener">${e(c.seo.founderLabel)}${icon('arrow')}</a><a href="${STUDIO_URL}" target="_blank" rel="noopener">${e(c.seo.familyLabel)}${icon('arrow')}</a></div><span>© ${new Date().getUTCFullYear()} SkyCut</span></div></footer>`;
}
function document(c, kind) {
  const site=c.lang;
  if (kind === 'docs') return `<section class="document container"><a class="text-link" href="/${site}/">← ${e(c.back)}</a><h1>${e(c.docsTitle)}</h1><p class="lead">${e(c.docsLead)}</p><div class="steps">${c.docsSteps.map(([h,p],i) => `<article><span class="step-number">${i + 1}</span><div><h2>${e(h)}</h2><p>${e(p)}</p></div></article>${i===0?installGuide(c):''}`).join('')}</div><aside class="note"><h2>${e(c.docsCompatibility)}</h2><p>${e(c.docsCompatibilityBody)}</p></aside><h2>${e(c.docsClients)}</h2><p>${e(c.docsClientsBody)}</p><div class="hero-actions"><a class="button" href="https://skystudioai.com/app?skycut=1" target="_blank" rel="noopener">${e(c.docsKey)}${icon('arrow')}</a></div></section>`;
  if (kind === 'privacy') return `<section class="document container"><a class="text-link" href="/${site}/">← ${e(c.back)}</a><h1>${e(c.privacyTitle)}</h1><p class="lead">${e(c.privacyLead)}</p>${c.privacySections.map(([h,p]) => `<h2>${e(h)}</h2><p>${e(p)}</p>`).join('')}<a class="text-link" href="mailto:support@skycut.app">support@skycut.app${icon('arrow')}</a></section>`;
  return `<section class="document centered container"><h1>${e(c[titles[kind]])}</h1><p class="lead">${e(c.errorBody)}</p><a class="button" href="/${site}/">${e(c.back)}${icon('arrow')}</a></section>`;
}
const siteStyles=['base','home','responsive','showcases','pricing'];
// The document around every page: head, navigation, main and footer.
export function shell(c,{page,kind='',head,main,languagePaths,styles=siteStyles}) {
  const strings = {lang:c.lang, signup:c.signup, subscribeSending:c.subscribeSending, subscribeSuccess:c.subscribeSuccess, subscribeUnavailable:c.subscribeUnavailable, subscribeError:c.subscribeError, subscribeInvalid:c.subscribeInvalid, subscribeBusy:c.subscribeBusy};
  return `<!doctype html><html lang="${LANGUAGE_TAGS[c.lang]}"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">${head}<meta name="theme-color" content="#f3f0e8"><meta name="color-scheme" content="light"><link rel="icon" href="/favicon.ico" sizes="any"><link rel="icon" href="/favicon-32.png" type="image/png" sizes="32x32"><link rel="icon" href="/favicon-64.png" type="image/png" sizes="64x64"><link rel="apple-touch-icon" href="/apple-touch-icon.png" sizes="180x180">${styles.map(s=>`<link rel="stylesheet" href="/src/styles/${s}.css">`).join('')}<script type="module" src="/src/main.js"></script></head><body data-language="${c.lang}" data-page="${page}"><div id="site-copy" hidden data-copy="${e(JSON.stringify(strings))}"></div>${navigation(c,kind,languagePaths)}<main id="main">${main}</main>${footer(c)}</body></html>`;
}
export function render(c, kind = '') {
  const languagePaths=Object.fromEntries(languages.map(lang=>[lang,`/${lang}/${kind && kind!=='error' ? kind + '/' : ''}`]));
  return shell(c,{page:kind||'home',kind,head:seoHead(c,kind),main:kind ? document(c,kind) : homepage(c),languagePaths});
}
