// Progressive enhancements only. Static HTML carries navigation, copy and downloads.
import { applyLanguage } from './language.js';
import { attachSignup } from './signup.js';
applyLanguage();
const copy = JSON.parse(document.querySelector('#site-copy')?.dataset.copy || '{}');
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');

const menu = document.querySelector('.mobile-menu-button');
const mobileNav = document.querySelector('.mobile-nav');
function closeMenu() {mobileNav.hidden=true;menu?.setAttribute('aria-expanded','false');}
menu?.addEventListener('click',()=>{mobileNav.hidden=!mobileNav.hidden;menu.setAttribute('aria-expanded',String(!mobileNav.hidden));});
mobileNav?.querySelectorAll('a').forEach(a=>a.addEventListener('click',closeMenu));
document.addEventListener('keydown',event=>{if(event.key==='Escape')closeMenu();});
document.addEventListener('click',event=>document.querySelectorAll('.language-menu[open]').forEach(d=>{if(!d.contains(event.target))d.open=false;}));

const film = document.querySelector('.film-dialog');
const video = film?.querySelector('video');
document.querySelector('[data-film]')?.addEventListener('click',()=>{
  if(!video.src) {
    video.src = innerWidth>900 && !navigator.connection?.saveData ? video.dataset.src.replace('720p','1080p') : video.dataset.src;
  }
  film.showModal();
  void video.play().catch(()=>{});
});
film?.querySelector('.dialog-close')?.addEventListener('click',()=>film.close());
film?.addEventListener('click',event=>{if(event.target===film)film.close();});
film?.addEventListener('close',()=>video.pause());

attachSignup(copy);
const visual=document.querySelector('.hero-visual');
if(visual && !reducedMotion.matches) {
  const observer=new IntersectionObserver(entries=>{
    if(entries.some(e=>e.isIntersecting)) {
      observer.disconnect();
      void import('./scene.js').then(({mountScene})=>mountScene(visual)).catch(()=>{});
    }
  },{rootMargin:'150px'});
  observer.observe(visual);
}
if(document.body.dataset.page==='home' && !reducedMotion.matches) {
  void import('./motion.js').then(({animatePage})=>animatePage()).catch(()=>{});
}

if(document.querySelector('[data-showcase-copy]')) {
  void import('./showcases.js').then(({mountShowcases})=>mountShowcases()).catch(error=>console.error('SkyCut demo unavailable',error));
}
