// Factual entity graph. Founder identity matches https://skylu.ai/founder/.
// No invented prices, ratings, release dates or availability for future platforms.
import {ORIGIN,LANGUAGES,LANGUAGE_TAGS,DOWNLOAD_URL,FOUNDER_URL,PERSON_ID,STUDIO_URL,ORGANIZATION_ID,pageURL} from './site-config.mjs';
const ref=id=>({'@id':id});
export function structuredData(c,kind,meta) {
  if(!meta.indexable)return null;
  const appID=`${ORIGIN}/#software`;
  const siteID=`${ORIGIN}/#website`;
  const pageID=`${meta.canonical}#webpage`;
  const image={'@type':'ImageObject','@id':`${ORIGIN}/#image-${c.lang}`,url:meta.image,width:1200,height:630,caption:c.seo.imageAlt};
  const page={
    '@type':'WebPage','@id':pageID,url:meta.canonical,name:meta.title,description:meta.description,
    inLanguage:LANGUAGE_TAGS[c.lang],isPartOf:ref(siteID),about:ref(appID),
    author:ref(PERSON_ID),publisher:ref(ORGANIZATION_ID),primaryImageOfPage:ref(image['@id']),
  };
  const graph=[
    {'@type':'Person','@id':PERSON_ID,name:'Sky Lu',alternateName:'陆天宇',url:FOUNDER_URL,
      image:'https://skylu.ai/assets/images/founder/sky-lu-portrait.webp',jobTitle:'Founder',worksFor:ref(ORGANIZATION_ID),
      sameAs:['https://www.youtube.com/@SkyStudio_AI','https://x.com/thatskylu','https://www.udemy.com/user/skylu-4/']},
    {'@type':'Organization','@id':ORGANIZATION_ID,name:'Sky Studio',url:STUDIO_URL,founder:ref(PERSON_ID)},
    {'@type':'WebSite','@id':siteID,name:'SkyCut',url:`${ORIGIN}/`,publisher:ref(ORGANIZATION_ID),creator:ref(PERSON_ID),inLanguage:LANGUAGES.map(l=>LANGUAGE_TAGS[l])},
    {'@type':'SoftwareApplication','@id':appID,name:'SkyCut',url:pageURL(c.lang),description:c.seo.descriptions.home,
      applicationCategory:'MultimediaApplication',applicationSuite:'Sky Studio',operatingSystem:'macOS 15 or later',
      processorRequirements:'Apple silicon arm64',availableOnDevice:'Mac',downloadUrl:DOWNLOAD_URL,
      creator:ref(PERSON_ID),publisher:ref(ORGANIZATION_ID),softwareHelp:{'@type':'WebPage',url:pageURL(c.lang,'docs')},image:meta.image},
    image,page,
  ];
  if(!kind)page.mainEntity=ref(appID);
  else {
    const breadcrumbID=`${meta.canonical}#breadcrumb`;
    page.breadcrumb=ref(breadcrumbID);
    graph.push({'@type':'BreadcrumbList','@id':breadcrumbID,itemListElement:[
      {'@type':'ListItem',position:1,name:c.home,item:pageURL(c.lang)},
      {'@type':'ListItem',position:2,name:kind==='docs'?c.docsTitle:c.privacyTitle,item:meta.canonical},
    ]});
  }
  return {'@context':'https://schema.org','@graph':graph};
}
export const serializeStructuredData=data=>JSON.stringify(data).replace(/</g,'\\u003c');
