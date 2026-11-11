// Progressive enhancements only. Static HTML carries navigation, copy and downloads.
import { applyLanguage } from './language.js';
import { attachSignup } from './signup.js';
import { wantsLiveScene } from './scene-governor.js';
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
// The hero already shows a still baked from the same scene. The live one replaces it only where
// WebGL 2 exists and motion is welcome, and only after that still has painted.
const visual=document.querySelector('.hero-visual');
if(visual && 'WebGL2RenderingContext' in window) {
  let mounted=false;
  const still=visual.querySelector('.scene-still img');
  const painted=!still||still.complete?Promise.resolve():new Promise(resolve=>{
    still.addEventListener('load',resolve,{once:true});still.addEventListener('error',resolve,{once:true});
  });
  const observer=new IntersectionObserver(entries=>{
    if(mounted||!entries.some(e=>e.isIntersecting)||!wantsLiveScene({webgl2:true,reducedMotion:reducedMotion.matches}))return;
    mounted=true;observer.disconnect();
    void painted.then(()=>import('./scene.js')).then(({mountScene})=>mountScene(visual)).catch(()=>{});
  },{rootMargin:'150px'});
  observer.observe(visual);
  // Asking again makes the observer report the current position once motion is allowed.
  reducedMotion.addEventListener('change',()=>{if(!mounted){observer.unobserve(visual);observer.observe(visual);}});
}
if(document.body.dataset.page==='home' && !reducedMotion.matches) {
  void import('./motion.js').then(({animatePage})=>animatePage()).catch(()=>{});
}

if(document.querySelector('[data-showcase-copy]')) {
  void import('./showcases.js').then(({mountShowcases})=>mountShowcases()).catch(error=>console.error('SkyCut demo unavailable',error));
}
