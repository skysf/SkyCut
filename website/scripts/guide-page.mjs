// Static HTML for the Guides section: one reading column, the answer first, then
// sections, questions and a closing box that leads to the download.
import {escape as e} from './html.mjs';
import {icon} from '../src/icons.js';
import {shell} from './template.mjs';
import {headTags,socialImage} from './seo.mjs';
import {brandNodes,SITE_ID,APP_ID} from './structured-data.mjs';
import {inline,plain} from './guide-markdown.mjs';
import {guideCopy} from '../content/guide-copy.js';
import {LANGUAGES,GUIDE_LANGUAGES,LANGUAGE_TAGS,DOWNLOAD_URL,FOUNDER_URL,PERSON_ID,ORGANIZATION_ID,pageURL,siteLanguage} from './site-config.mjs';
import {guidesIn,guideLanguages,hubPath,guidePath,absolute,isPublished} from './guide-model.mjs';

const ref=id=>({'@id':id});
// Guides are text pages people land on from search: fetch the Latin face with the
// stylesheet so the headline does not reflow when the font arrives.
const fontPreload='<link rel="preload" as="font" type="font/woff2" crossorigin href="/node_modules/@fontsource-variable/outfit/files/outfit-latin-wght-normal.woff2">';
const sectionID=index=>`s${index+1}`;
const formatDay=(day,language)=>new Intl.DateTimeFormat(LANGUAGE_TAGS[language],{year:'numeric',month:'long',day:'numeric',timeZone:'UTC'}).format(new Date(`${day}T00:00:00Z`));
const formatMonth=(month,language)=>new Intl.DateTimeFormat(LANGUAGE_TAGS[language],{year:'numeric',month:'long',timeZone:'UTC'}).format(new Date(`${month}-01T00:00:00Z`));

function block(item,language) {
  const t=text=>inline(text,language);
  if(typeof item==='string')return `<p>${t(item)}</p>`;
  if(item.steps)return `<ol class="guide-steps">${item.steps.map(([title,body])=>`<li><h3>${t(title)}</h3><p>${t(body)}</p></li>`).join('')}</ol>`;
  if(item.list)return `<ul>${item.list.map(entry=>`<li>${t(entry)}</li>`).join('')}</ul>`;
  if(item.table)return `<div class="guide-table"><table><thead><tr>${item.table.head.map(cell=>`<th scope="col">${t(cell)}</th>`).join('')}</tr></thead><tbody>${item.table.rows.map(row=>`<tr>${row.map((cell,i)=>i?`<td>${t(cell)}</td>`:`<th scope="row">${t(cell)}</th>`).join('')}</tr>`).join('')}</tbody></table></div>`;
  if(item.prompt)return `<blockquote class="guide-prompt"><p>${t(item.prompt)}</p></blockquote>`;
  if(item.note)return `<aside class="guide-note"><p>${t(item.note)}</p></aside>`;
  throw new Error('unknown guide block');
}
// Reading time at 238 words a minute; Chinese counts characters at 500 a minute.
function minutes(copy,language) {
  const text=[copy.answer,...copy.sections.flatMap(section=>[section.heading,JSON.stringify(section.blocks)]),...copy.faq.flat()].join(' ');
  return Math.max(1,Math.round(['zh','zh-hant','ja'].includes(language)?text.replace(/\s/g,'').length/500:text.split(/\s+/).length/238));
}
// The same page in the other languages. A site language without it gets its hub or home;
// a guide-only language is listed only when it has this page (or, for the hub, any guide).
function languagePaths(guide) {
  const has=language=>guide?Boolean(guide.languages[language]):guidesIn(language).length>0;
  return Object.fromEntries(GUIDE_LANGUAGES.filter(language=>LANGUAGES.includes(language)||has(language)).map(language=>[language,
    guide&&guide.languages[language]?guidePath(language,guide.slug):guidesIn(language).length?hubPath(language):`/${language}/`]));
}
const closing=(c,ui)=>`<aside class="guide-cta"><h2>${e(ui.ctaTitle)}</h2><p>${e(ui.ctaBody)}</p><div class="guide-cta-actions"><a class="button" href="${DOWNLOAD_URL}">${e(c.download)}${icon('arrow')}</a><a class="text-link" href="/${siteLanguage(c.lang)}/docs/">${e(ui.ctaDocs)}${icon('arrow')}</a></div><p class="guide-requirement">${e(ui.ctaRequirement)}</p></aside>`;
const card=(guide,language,ui)=>{
  const copy=guide.languages[language];
  return `<li><a class="guide-card" href="${guidePath(language,guide.slug)}"><span class="guide-kind">${e(ui.kinds[guide.type])}</span><h2>${e(copy.heading)}</h2><p>${e(plain(copy.description,language))}</p><span class="text-link">${e(ui.read)}${icon('arrow')}</span></a></li>`;
};

function articleGraph(c,guide,copy,url) {
  const language=c.lang,image=socialImage(language);
  const article={'@type':'Article','@id':`${url}#article`,headline:copy.heading,name:copy.title,description:plain(copy.description,language),
    inLanguage:LANGUAGE_TAGS[language],url,mainEntityOfPage:url,image,datePublished:guide.published,dateModified:guide.updated,
    author:ref(PERSON_ID),publisher:ref(ORGANIZATION_ID),isPartOf:ref(SITE_ID),about:ref(APP_ID)};
  return {'@context':'https://schema.org','@graph':[
    ...brandNodes(),
    // Named here as well: an @id alone tells a reader of this one page nothing.
    {'@type':'SoftwareApplication','@id':APP_ID,name:'SkyCut',url:pageURL(siteLanguage(language)),applicationCategory:'MultimediaApplication',operatingSystem:'macOS 15 or later'},
    article,
    {'@type':'BreadcrumbList','@id':`${url}#breadcrumb`,itemListElement:[
      {'@type':'ListItem',position:1,name:c.home,item:pageURL(siteLanguage(language))},
      {'@type':'ListItem',position:2,name:guideCopy[language].section,item:absolute(hubPath(language))},
      {'@type':'ListItem',position:3,name:copy.heading,item:url},
    ]},
    {'@type':'FAQPage','@id':`${url}#faq`,inLanguage:LANGUAGE_TAGS[language],
      mainEntity:copy.faq.map(([question,answer])=>({'@type':'Question',name:plain(question,language),acceptedAnswer:{'@type':'Answer',text:plain(answer,language)}}))},
  ]};
}

export function renderGuide(c,guide) {
  const language=c.lang,copy=guide.languages[language],ui=guideCopy[language];
  const url=absolute(guidePath(language,guide.slug)),live=isPublished(guide);
  const alternates=Object.fromEntries(guideLanguages(guide).map(l=>[l,absolute(guidePath(l,guide.slug))]));
  const head=headTags({c,title:`${copy.title} | SkyCut`,description:plain(copy.description,language),canonical:url,image:socialImage(language),
    indexable:live,alternates,type:'article',article:live?{published:guide.published,modified:guide.updated}:null,graph:live?articleGraph(c,guide,copy,url):null});
  const dates=live?`<span>${e(ui.published)} <time datetime="${guide.published}">${e(formatDay(guide.published,language))}</time></span>${guide.updated!==guide.published?`<span>${e(ui.updated)} <time datetime="${guide.updated}">${e(formatDay(guide.updated,language))}</time></span>`:''}`:`<span class="guide-draft">${e(ui.draft)}</span>`;
  const toc=copy.sections.length>=3?`<nav class="guide-toc" aria-labelledby="guide-toc-title"><h2 id="guide-toc-title">${e(ui.contents)}</h2><ol>${copy.sections.map((section,i)=>`<li><a href="#${sectionID(i)}">${inline(section.heading,language)}</a></li>`).join('')}<li><a href="#faq">${e(ui.questions)}</a></li></ol></nav>`:'';
  const others=guidesIn(language).filter(other=>other.slug!==guide.slug);
  const main=`<article class="guide container">
    <nav class="guide-crumbs" aria-label="Breadcrumb"><a href="/${siteLanguage(language)}/">${e(c.home)}</a><span aria-hidden="true">/</span><a href="${hubPath(language)}">${e(ui.section)}</a></nav>
    <header class="guide-header"><p class="guide-kind">${e(ui.kinds[guide.type])}</p><h1>${e(copy.heading)}</h1>
      <p class="guide-byline"><span>${e(ui.by)} <a href="${FOUNDER_URL}?lang=${siteLanguage(language)}" rel="author noopener" target="_blank">Sky Lu</a></span>${dates}<span>${minutes(copy,language)} ${e(ui.minutes)}</span></p></header>
    <div class="guide-answer"><p>${inline(copy.answer,language)}</p></div>
    ${toc}
    ${copy.sections.map((section,i)=>`<section id="${sectionID(i)}"><h2>${inline(section.heading,language)}</h2>${section.blocks.map(item=>block(item,language)).join('')}</section>`).join('')}
    <section id="faq" class="guide-faq"><h2>${e(ui.questions)}</h2>${copy.faq.map(([question,answer])=>`<h3>${inline(question,language)}</h3><p>${inline(answer,language)}</p>`).join('')}</section>
    ${closing(c,ui)}
    ${guide.sources.length?`<section class="guide-sources"><h2>${e(ui.sources)}</h2><ul>${guide.sources.map(source=>`<li>${e(source.name)} <span>${e(ui.checkedOn)} ${e(formatDay(source.checked,language))}</span></li>`).join('')}</ul></section>`:''}
    <p class="guide-footnote">${e(ui.checked.replace('{month}',formatMonth(guide.asOf,language)))} ${e(ui.disclosure)}</p>
    ${others.length?`<section class="guide-more"><h2>${e(ui.more)}</h2><ul class="guide-list">${others.map(other=>card(other,language,ui)).join('')}</ul></section>`:''}
  </article>`;
  return shell(c,{page:'guide',kind:'guides',head:head+fontPreload,main,languagePaths:languagePaths(guide),styles:['base','responsive','guides']});
}

export function renderGuideHub(c) {
  const language=c.lang,ui=guideCopy[language],list=guidesIn(language),url=absolute(hubPath(language));
  const live=list.filter(isPublished);
  const alternates=Object.fromEntries(GUIDE_LANGUAGES.filter(l=>guidesIn(l).some(isPublished)).map(l=>[l,absolute(hubPath(l))]));
  const graph={'@context':'https://schema.org','@graph':[...brandNodes(),
    {'@type':'CollectionPage','@id':`${url}#webpage`,url,name:ui.hubTitle,description:ui.hubDescription,inLanguage:LANGUAGE_TAGS[language],isPartOf:ref(SITE_ID),about:ref(APP_ID),publisher:ref(ORGANIZATION_ID),
      mainEntity:{'@type':'ItemList',itemListElement:live.map((guide,i)=>({'@type':'ListItem',position:i+1,url:absolute(guidePath(language,guide.slug)),name:guide.languages[language].heading}))}},
    {'@type':'BreadcrumbList','@id':`${url}#breadcrumb`,itemListElement:[
      {'@type':'ListItem',position:1,name:c.home,item:pageURL(siteLanguage(language))},{'@type':'ListItem',position:2,name:ui.section,item:url}]},
  ]};
  const head=headTags({c,title:ui.hubTitle,description:ui.hubDescription,canonical:url,image:socialImage(language),indexable:live.length>0,alternates,graph:live.length?graph:null});
  const main=`<section class="guide guide-hub container"><header class="guide-header"><h1>${e(ui.hubHeading)}</h1><p class="guide-lead">${e(ui.hubLead)}</p></header>
    <ul class="guide-list">${list.map(guide=>card(guide,language,ui)).join('')}</ul>${closing(c,ui)}</section>`;
  return shell(c,{page:'guides',kind:'guides',head:head+fontPreload,main,languagePaths:languagePaths(null),styles:['base','responsive','guides']});
}
