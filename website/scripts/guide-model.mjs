// Which guides exist, where they live, and the rules every guide must pass before
// it is rendered. A guide without a `published` day is a draft: it is built only
// when SKYCUT_GUIDE_DRAFTS=1 (local review), never indexed, never in the sitemap.
import {guides as inventory} from '../content/guides/index.js';
import {guideCopy} from '../content/guide-copy.js';
import {GUIDE_LANGUAGES,ORIGIN} from './site-config.mjs';
export const GUIDE_TYPES=['guide','list','alternatives','compare'];
export const LIMITS={title:60,description:155,answerMin:160};
const day=/^20\d{2}-\d{2}-\d{2}$/;
export const draftsShown=()=>process.env.SKYCUT_GUIDE_DRAFTS==='1';
export const isPublished=guide=>day.test(guide.published||'');
export const visibleGuides=({drafts=draftsShown(),list=inventory}={})=>list.filter(guide=>drafts||isPublished(guide));
export const guideLanguages=guide=>GUIDE_LANGUAGES.filter(language=>guide.languages[language]);
export const guidesIn=(language,options)=>visibleGuides(options).filter(guide=>guide.languages[language]);
export const hubPath=language=>`/${language}/guides/`;
export const guidePath=(language,slug)=>`/${language}/guides/${slug}/`;
export const absolute=path=>`${ORIGIN}${path}`;
// Every page of the section that the current build produces.
export function guideRoutes(options) {
  const routes=[];
  for(const language of GUIDE_LANGUAGES) {
    const list=guidesIn(language,options);
    if(!list.length)continue;
    routes.push({language,guide:null,path:hubPath(language)});
    for(const guide of list)routes.push({language,guide,path:guidePath(language,guide.slug)});
  }
  return routes;
}
// Text a reader sees, for the wording checks.
function shownText(copy) {
  const blocks=copy.sections.flatMap(section=>[section.heading,...section.blocks.flatMap(block=>typeof block==='string'?[block]
    :block.steps?block.steps.flat():block.list?block.list:block.table?[...block.table.head,...block.table.rows.flat()]:[block.prompt||block.note||''])]);
  return [copy.title,copy.description,copy.heading,copy.answer,...blocks,...copy.faq.flat()];
}
const linkTargets=text=>[...text.matchAll(/\]\(([^)]+)\)/g)].map(match=>match[1]);
// Returns every reason a guide may not be built; an empty list means it is fine.
export function guideProblems(guide) {
  const found=[];
  const fail=(condition,message)=>{if(condition)found.push(`${guide.slug}: ${message}`);};
  fail(!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(guide.slug||''),'slug is lowercase words joined by hyphens');
  fail(!GUIDE_TYPES.includes(guide.type),`type is one of ${GUIDE_TYPES.join(', ')}`);
  fail(guide.published!==null&&!isPublished(guide),'published is null (draft) or the real day it went online');
  fail(isPublished(guide)&&!(day.test(guide.updated||'')&&guide.updated>=guide.published),'updated is a day on or after published');
  fail(!/^20\d{2}-\d{2}$/.test(guide.asOf||''),'asOf is the month the facts were checked (YYYY-MM)');
  fail(!Array.isArray(guide.sources)||guide.sources.some(source=>!source.name||!source.claim||!/^https:\/\//.test(source.url||'')||!day.test(source.checked||'')),'every source has a name, a claim, an https url and the day it was checked');
  fail(!guideLanguages(guide).length,'at least one language');
  fail(Object.keys(guide.languages||{}).some(language=>!GUIDE_LANGUAGES.includes(language)),`languages are ${GUIDE_LANGUAGES.join(', ')}`);
  for(const language of guideLanguages(guide)) {
    const copy=guide.languages[language],at=message=>`[${language}] ${message}`;
    fail(!guideCopy[language],at('the section has no interface copy in this language yet'));
    fail(!copy.title||copy.title.length>LIMITS.title,at(`title is 1 to ${LIMITS.title} characters`));
    fail(!copy.description||copy.description.length>LIMITS.description,at(`description is 1 to ${LIMITS.description} characters`));
    fail(!copy.heading,at('heading is required'));
    fail(!copy.answer||copy.answer.length<LIMITS.answerMin,at('the page opens with a real answer'));
    fail(!copy.sections?.length||copy.sections.some(section=>!section.heading||!section.blocks?.length),at('every section has a heading and content'));
    fail(!copy.faq?.length||copy.faq.some(pair=>pair.length!==2||!pair[0]||!pair[1]),at('the questions come in pairs'));
    if(found.length)continue;
    const text=shownText(copy);
    // Prices come from content/pricing.js through {{pro.monthly}} and friends.
    fail(text.some(part=>/[$¥€]\s?\d/.test(part)),at('write prices as {{pro.monthly}}, {{pro.yearly}} or {{free.price}}'));
    // Our own pages and the family's entry points only; other makers are named, not linked.
    fail(text.flatMap(linkTargets).some(target=>!/^(\/|#|https:\/\/(skylu\.ai|skystudioai\.com)\/)/.test(target)),at('links go to our own pages'));
    fail(text.some(part=>/(^|[^(])https?:\/\//.test(part.replace(/\]\([^)]+\)/g,''))),at('no bare web addresses in the text'));
    // Nothing public mentions a code host: other projects are named, and where they live stays in `sources[].url`.
    fail([...text,...guide.sources.map(source=>source.name)].some(part=>/github|gitlab|source code|open.?source repo/i.test(part)),at('no mention of GitHub or source repositories on the page'));
    // A superlative needs a measurement behind it; list titles may ask for "best".
    fail(text.some(part=>/\b(smoothest|fastest|most powerful|world'?s first|number one|#1|unrivall?ed)\b/i.test(part)),at('no superlatives without a measurement'));
    fail(guide.type!=='list'&&text.some(part=>/\bbest\b/i.test(part)),at('"best" belongs to list guides'));
  }
  return found;
}
export function assertGuides(list=inventory) {
  const found=list.flatMap(guideProblems);
  const slugs=list.map(guide=>guide.slug);
  if(new Set(slugs).size!==slugs.length)found.push('two guides share a slug');
  if(found.length)throw new Error(`Guides cannot be built:\n${found.join('\n')}`);
}
