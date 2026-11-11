// Homepage sections. Shared shell, metadata and secondary pages live in template.mjs.
import { icon } from '../src/icons.js';
import {heroStill} from './hero-still.mjs';
import {escape} from './html.mjs';
import {showcases} from './showcases.mjs';
import {pricing} from './pricing.mjs';
export {escape};
const e = escape;
import {DOWNLOAD_URL} from './site-config.mjs';
export const downloadURL=DOWNLOAD_URL;
const shots = ['ship', 'penguin', 'dive', 'campfire'];
const photo = (name, alt = '', cls = '') => `<img class="${cls}" src="/media/${name.includes('.') ? name : name+'.webp'}" alt="${e(alt)}" width="640" height="360" loading="lazy">`;
const button = (href, label, secondary = false) => `<a class="button ${secondary ? 'button-outline' : ''}" href="${href}">${secondary ? icon('play') : ''}${e(label)}${secondary ? '' : icon('arrow')}</a>`;

function hero(c) {
  return `<section class="hero container" aria-labelledby="hero-title">
    <div class="hero-copy"><h1 id="hero-title">${e(c.hero[0])}<br><em>${e(c.hero[1])}</em></h1><p class="hero-intro">${e(c.intro)}</p>
      <div class="hero-actions">${button(downloadURL, c.download)}${button('#film', c.watch, true)}</div><p class="compatibility">${e(c.compatibility)}</p>
    </div>
    <div class="hero-visual" aria-label="${e(c.sceneLabel)}">
      ${heroStill(e(c.imageAlt))}
      <canvas id="timeline-scene" aria-hidden="true"></canvas>
      <button class="motion-toggle icon-button" aria-label="${e(c.motionPause)}" data-pause-label="${e(c.motionPause)}" data-play-label="${e(c.motionPlay)}">${icon('pause')}</button>
    </div>
    <div class="hero-badges">${c.badges.map(b => `<span>${e(b)}</span>`).join('')}</div>
  </section>`;
}

function film(c) {
  return `<section class="film-section section" id="film" aria-labelledby="film-title"><div class="container"><div class="section-heading"><div><h2 id="film-title">${e(c.filmTitle)}</h2><p>${e(c.filmBody)}</p></div><span class="film-name">${e(c.filmName)}</span></div>
    <button class="film-cover" data-film aria-label="${e(c.filmCaption)}">${photo('film', c.filmAlt)}<span class="film-play">${icon('play')}<span>${e(c.filmCaption)}</span></span></button>
    <div class="film-stills">${shots.map((s,i) => photo(s, c.filmStills[i])).join('')}</div>
    </div></section>
    <dialog class="film-dialog" aria-label="${e(c.filmName)}"><button class="dialog-close icon-button" aria-label="${e(c.close)}">${icon('close')}</button><video controls playsinline preload="none" poster="/media/film.webp" data-src="https://downloads.skylu.ai/founder/antarctica-720p.mp4"></video></dialog>`;
}

function platforms(c) {
  return `<section class="platforms container section" id="download" aria-labelledby="download-title"><div class="section-heading"><div><h2 id="download-title">${e(c.native)}</h2><p>${e(c.nativeBody)}</p></div><a class="text-link" href="/${c.lang}/docs/">${e(c.getting)}${icon('arrow')}</a></div>
    <div class="platform-grid">${c.platformNames.map((name,i) => `<article class="platform-card ${i === 0 ? 'available' : ''}">${icon(i === 2 ? 'windows' : 'mac')}<span class="platform-status">${e(i === 0 ? c.available : c.coming)}</span><h3>${e(name)}</h3>${i === 0 ? `<p>${e(c.compatibility)}</p>${button(downloadURL,c.download)}` : `<button class="button button-outline" data-subscribe="${i === 1 ? 'intel' : 'windows'}">${e(c.notify)}${icon('arrow')}</button>`}</article>`).join('')}</div>
  </section>`;
}

export function signup(c) {
  return `<section class="signup-section section" id="subscribe"><div class="container signup-layout"><div><h2>${e(c.newsletterTitle)}</h2><p>${e(c.newsletterBody)}</p></div>
    <form class="signup-form" novalidate><label for="email">${e(c.email)}</label><div class="email-input-row"><input type="email" name="email" id="email" autocomplete="email" inputmode="email" required maxlength="254" placeholder="${e(c.emailPlaceholder)}"><button class="button" type="submit">${e(c.signup)}${icon('arrow')}</button></div>
    <div class="signup-choices">${[['newsletter',c.newsletterChoice],['intel',c.intelChoice],['windows',c.windowsChoice]].map(([key,label]) => `<label class="choice"><input type="checkbox" name="${key}" value="true"><span>${e(label)}</span></label>`).join('')}</div>
    <label class="email-language" for="email-language">${e(c.languageLabel)}<select id="email-language" name="language">${[['en','English'],['zh','简体中文'],['de','Deutsch'],['es','Español']].map(([lang,name]) => `<option value="${lang}" ${lang === c.lang ? 'selected' : ''}>${name}</option>`).join('')}</select></label>
    <div class="honey" aria-hidden="true"><label>Website<input name="website" tabindex="-1" autocomplete="off"></label></div>
    <p class="form-note">${e(c.consent)} <a href="/${c.lang}/privacy/">${e(c.privacy)}</a></p><p class="form-message" role="status" aria-live="polite"></p><noscript><p>${e(c.noJs)}</p></noscript></form>
  </div></section>`;
}

export function homepage(c) {
  return `${hero(c)}${showcases(c)}${film(c)}${pricing(c)}${platforms(c)}<section class="faq container section"><h2>${e(c.faqTitle)}</h2><div>${c.faq.map(([q,a]) => `<details><summary>${e(q)}${icon('chevron')}</summary><p>${e(a)}</p></details>`).join('')}</div></section>${signup(c)}`;
}
