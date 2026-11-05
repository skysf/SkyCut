// Gentle film scaling and download panels on desktop. No content starts hidden.
import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
export function animatePage() {
  gsap.registerPlugin(ScrollTrigger);
  const mm=gsap.matchMedia();
  mm.add('(min-width: 1000px) and (prefers-reduced-motion: no-preference)',()=>{
    gsap.fromTo('.film-cover',{scale:.94},{scale:1,ease:'none',scrollTrigger:{trigger:'.film-cover',start:'top 95%',end:'top 25%',scrub:1}});
    gsap.to('.film-cover img',{filter:'brightness(.5)',ease:'none',scrollTrigger:{trigger:'.film-cover',start:'bottom 35%',end:'bottom 0%',scrub:1}});
    document.querySelectorAll('.platform-card').forEach((card,i)=>{
      gsap.fromTo(card,{y:32+i*24,rotation:1.5-i},{y:0,rotation:0,ease:'none',scrollTrigger:{trigger:'.platform-grid',start:'top 95%',end:'top 55%',scrub:1}});
    });
  });
}
