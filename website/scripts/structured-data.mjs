// Factual entity graph. Founder identity matches https://skylu.ai/founder/.
// No invented prices, ratings, release dates or availability for future platforms.
import {ORIGIN,LANGUAGES,LANGUAGE_TAGS,DOWNLOAD_URL,PRO_PURCHASE_URL,FOUNDER_URL,PERSON_ID,STUDIO_URL,ORGANIZATION_ID,STUDIO_ENTITY,APP_FACTS,pageURL} from './site-config.mjs';
import {INSTALL_GUIDE,installGuideTrack} from './install-guide.mjs';
import {modifiedDate} from './page-revisions.mjs';
import {featureGroups} from '../content/feature-matrix.js';
const ref=id=>({'@id':id});
const inStock='https://schema.org/InStock';
// 只标记首页可见的免费版与订阅；周期和税前标价按方案，不推测所在地税率。
function offers(p) {
  return [
    {'@type':'Offer',name:p.free,category:'free',price:0,priceCurrency:p.currency,availability:inStock,url:DOWNLOAD_URL},
    ...[[p.monthlyLabel,p.monthly,'P1M'],[p.yearlyLabel,p.yearly,'P1Y']].map(([label,price,duration])=>({
      '@type':'Offer',name:`${p.pro} ${label}`,category:'subscription',price,priceCurrency:p.currency,availability:inStock,url:PRO_PURCHASE_URL,
      priceSpecification:{'@type':'UnitPriceSpecification',price,priceCurrency:p.currency,billingDuration:duration,valueAddedTaxIncluded:false},
    })),
  ];
}
// The feature names a visitor reads in the comparison table, in the page's language.
export const featureList=c=>featureGroups.flatMap(group=>group.rows.map(row=>c.pricing.compare.features[row.id][0]));
// The same questions and answers the homepage shows; nothing exists only in markup.
const faqPage=(c,pageID)=>({'@type':'FAQPage','@id':`${pageURL(c.lang)}#faq`,inLanguage:LANGUAGE_TAGS[c.lang],isPartOf:ref(pageID),
  mainEntity:c.faq.map(([question,answer])=>({'@type':'Question',name:question,acceptedAnswer:{'@type':'Answer',text:answer}}))});
// The founder, the organization and the site: the same three nodes on every page,
// because an answer engine reads one page at a time.
export const brandNodes=()=>[
  {'@type':'Person','@id':PERSON_ID,name:'Sky Lu',alternateName:'陆天宇',url:FOUNDER_URL,
    image:'https://skylu.ai/assets/images/founder/sky-lu-portrait.webp',jobTitle:'Founder',worksFor:ref(ORGANIZATION_ID),
    sameAs:['https://www.youtube.com/@SkyStudio_AI','https://x.com/thatskylu','https://www.udemy.com/user/skylu-4/']},
  {'@type':'Organization','@id':ORGANIZATION_ID,name:'Sky Studio',alternateName:STUDIO_ENTITY.alternateName,url:STUDIO_URL,
    logo:STUDIO_ENTITY.logo,sameAs:STUDIO_ENTITY.sameAs,founder:ref(PERSON_ID)},
  {'@type':'WebSite','@id':SITE_ID,name:'SkyCut',url:`${ORIGIN}/`,publisher:ref(ORGANIZATION_ID),creator:ref(PERSON_ID),inLanguage:LANGUAGES.map(l=>LANGUAGE_TAGS[l])},
];
export const SITE_ID=`${ORIGIN}/#website`;
export const APP_ID=`${ORIGIN}/#software`;
export function structuredData(c,kind,meta) {
  if(!meta.indexable)return null;
  const appID=APP_ID,siteID=SITE_ID;
  const pageID=`${meta.canonical}#webpage`;
  const modified=modifiedDate(c.lang,kind);
  const image={'@type':'ImageObject','@id':`${ORIGIN}/#image-${c.lang}`,url:meta.image,width:1200,height:630,caption:c.seo.imageAlt};
  const page={
    '@type':'WebPage','@id':pageID,url:meta.canonical,name:meta.title,description:meta.description,
    inLanguage:LANGUAGE_TAGS[c.lang],isPartOf:ref(siteID),about:ref(appID),
    author:ref(PERSON_ID),publisher:ref(ORGANIZATION_ID),primaryImageOfPage:ref(image['@id']),
    ...(modified?{dateModified:modified}:{}),
  };
  const graph=[
    ...brandNodes(),
    {'@type':'SoftwareApplication','@id':appID,name:'SkyCut',url:pageURL(c.lang),description:c.seo.descriptions.home,
      applicationCategory:'MultimediaApplication',applicationSubCategory:'Video editing software',applicationSuite:'Sky Studio',
      operatingSystem:APP_FACTS.operatingSystem,processorRequirements:APP_FACTS.processor,availableOnDevice:APP_FACTS.device,
      inLanguage:APP_FACTS.interfaceLanguages,isAccessibleForFree:true,downloadUrl:DOWNLOAD_URL,installUrl:DOWNLOAD_URL,
      featureList:featureList(c),
      creator:ref(PERSON_ID),publisher:ref(ORGANIZATION_ID),softwareHelp:{'@type':'WebPage',url:pageURL(c.lang,'docs')},image:meta.image,
      ...(!kind?{offers:offers(c.pricing)}:{})},
    image,page,
  ];
  if(!kind) {
    page.mainEntity=ref(appID);
    const faq=faqPage(c,pageID);
    page.hasPart=ref(faq['@id']);
    graph.push(faq);
  } else {
    const breadcrumbID=`${meta.canonical}#breadcrumb`;
    page.breadcrumb=ref(breadcrumbID);
    graph.push({'@type':'BreadcrumbList','@id':breadcrumbID,itemListElement:[
      {'@type':'ListItem',position:1,name:c.home,item:pageURL(c.lang)},
      {'@type':'ListItem',position:2,name:kind==='docs'?c.docsTitle:c.privacyTitle,item:meta.canonical},
    ]});
  }
  if(kind==='docs') {
    const track=installGuideTrack(c.lang);
    const videoID=`${meta.canonical}#video`;
    page.video=ref(videoID);
    graph.push({
      '@type':'VideoObject','@id':videoID,name:c.docsVideo.title,description:c.docsVideo.description,
      contentUrl:`${ORIGIN}${INSTALL_GUIDE.src}`,thumbnailUrl:`${ORIGIN}${INSTALL_GUIDE.poster}`,
      uploadDate:INSTALL_GUIDE.published,duration:INSTALL_GUIDE.duration,encodingFormat:'video/mp4',
      width:INSTALL_GUIDE.width,height:INSTALL_GUIDE.height,inLanguage:LANGUAGE_TAGS[c.lang],isPartOf:ref(pageID),
      caption:{'@type':'MediaObject',contentUrl:`${ORIGIN}${track.src}`,encodingFormat:'text/vtt',inLanguage:track.language},
    });
  }
  return {'@context':'https://schema.org','@graph':graph};
}
export const serializeStructuredData=data=>JSON.stringify(data).replace(/</g,'\\u003c');
