// Shared installation video and single-language subtitle selection for static docs and SEO.
// Playback stays with the browser's native controls; no client-side player is needed.
import {existsSync} from 'node:fs';
import {escape as e} from './html.mjs';
import {LANGUAGE_TAGS} from './site-config.mjs';

export const INSTALL_GUIDE={
  src:'/media/guides/how-to-install-skycut-on-mac.mp4',poster:'/media/guides/how-to-install-skycut-on-mac.jpg',
  width:1728,height:1080,duration:'PT32.5S',
};

export function installGuideTrack(language) {
  const requested=language==='zh'?'zh-Hans':LANGUAGE_TAGS[language];
  const available=existsSync(new URL(`../public/media/guides/how-to-install-skycut-on-mac.${requested}.vtt`,import.meta.url));
  const tag=available?requested:'en';
  return {
    src:`/media/guides/how-to-install-skycut-on-mac.${tag}.vtt`,language:tag,
    label:new Intl.DisplayNames([tag],{type:'language'}).of(tag),
  };
}

export function installGuide(c) {
  const track=installGuideTrack(c.lang);
  return `<section class="install-guide" id="video" aria-labelledby="install-guide-title">
    <h2 id="install-guide-title"><a href="#video">${e(c.docsVideo.title)}</a></h2>
    <p id="install-guide-description">${e(c.docsVideo.description)}</p>
    <video controls playsinline preload="metadata" poster="${INSTALL_GUIDE.poster}" width="${INSTALL_GUIDE.width}" height="${INSTALL_GUIDE.height}" aria-labelledby="install-guide-title" aria-describedby="install-guide-description">
      <source src="${INSTALL_GUIDE.src}" type="video/mp4">
      <track kind="subtitles" src="${track.src}" srclang="${track.language}" label="${e(track.label)}" default>
      <a href="${INSTALL_GUIDE.src}">${e(c.docsVideo.fallback)}</a>
    </video>
  </section>`;
}
