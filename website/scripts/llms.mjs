// /llms.txt and /llms-full.txt (https://llmstxt.org): one English fact sheet for
// AI assistants. Prose lives here with normal punctuation; every number, price,
// model and feature row comes from the same sources the pages use, so the files
// cannot drift from the site. English only: assistants translate when they answer,
// and the localized pages are linked.
import english from '../content/en.js';
import {prices} from '../content/pricing.js';
import {featureGroups,characterRows,localModelRows} from '../content/feature-matrix.js';
import {cloudModelGroups,localVoiceLanguages} from '../content/ai-models.js';
import {ORIGIN,LANGUAGES,DOWNLOAD_URL,PRO_PURCHASE_URL,FOUNDER_URL,STUDIO_URL,SUPPORT_EMAIL,APP_FACTS,pageURL} from './site-config.mjs';

const usd=prices('en'),cny=prices('zh');
const compare=english.pricing.compare,access=compare.access;
const languageNames={en:'English',zh:'简体中文',de:'Deutsch',es:'Español'};
const accessText={
  included:access.included,unavailable:access.unavailable,ai:access.ai,watermarked:access.watermarked,clean:access.clean,none:access.none,
  annualCredits:english.pricing.yearlyCredits,localUI:`${access.inApp}, ${access.noCredits}`,localBoth:`${access.both}, ${access.noCredits}`,
  localAI:`${access.ai}, ${access.noCredits}`,aiNoCredits:`${access.ai}, ${access.noCredits}`,cloudAI:`${access.ai}, ${access.usesCredits}`,
  cloudUI:`${access.inApp}, ${access.usesCredits}`,cloudBoth:`${access.both}, ${access.usesCredits}`,
};
const cell=text=>String(text).replace(/\|/g,'/');
const table=rows=>`| Feature | What it covers | Free | Pro |\n| --- | --- | --- | --- |\n${rows.map(row=>`| ${cell(compare.features[row.id][0])} | ${cell(compare.features[row.id][1])} | ${cell(accessText[row.free])} | ${cell(accessText[row.pro])} |`).join('\n')}`;

const summary=`SkyCut is an AI video editor for Mac. You edit on a native multitrack timeline, or connect Claude Code, Claude Desktop or Codex and direct the edit in your own words. It runs on Apple silicon Macs with ${APP_FACTS.operatingSystem} and is made by Sky Lu as part of the Sky Studio product family.`;
const keyFacts=[
  `Platform: Mac only. Apple silicon (arm64) and ${APP_FACTS.operatingSystem}. There is no Intel Mac version and no Windows version.`,
  `Price: the Free plan costs ${usd.symbol}0 and has no time limit. Pro costs ${usd.symbol}${usd.monthly} per month or ${usd.symbol}${usd.yearly} per year in ${usd.currency} (${cny.symbol}${cny.monthly} or ${cny.symbol}${cny.yearly} in ${cny.currency} on the Chinese site). Prices exclude tax.`,
  'Free includes the full manual editor, subtitles, screen recording and the file tools. Videos exported on Free carry a Sky Studio watermark.',
  'Pro adds AI editing through MCP, exports without the watermark, and lets AI call cloud models. New accounts get 7 days of Pro.',
  'AI editing: SkyCut includes a local MCP server with built-in setup for Claude Code, Claude Desktop and Codex. You bring your own AI client. The AI works on the real timeline, where you can inspect, change or undo what it did.',
  'Cloud generation (images, video, music, narration, sound effects, lip sync, upscaling) uses Sky Studio credits, which are bought separately. Yearly Pro includes 1,000 Sky Studio credits for each paid year; monthly Pro includes none.',
  `Download: ${DOWNLOAD_URL}`,
  `Buy Pro: ${PRO_PURCHASE_URL} (sign in to Sky Studio first)`,
  `Contact: ${SUPPORT_EMAIL}`,
];
const pages=()=>[
  `[SkyCut home](${pageURL('en')}): overview, AI workflow demos, pricing and the full Free and Pro comparison`,
  `[Getting started](${pageURL('en','docs')}): install SkyCut, import footage, connect an AI client, review and export`,
  `[Privacy](${pageURL('en','privacy')}): what the website collects and why`,
];
const localized=()=>LANGUAGES.filter(l=>l!=='en').map(l=>`[${languageNames[l]}](${pageURL(l)})`);
const family=[
  `[Sky Lu](${FOUNDER_URL}): founder of Sky Studio and creator of SkyCut`,
  `[Sky Studio](${STUDIO_URL}): the AI image, video and audio generation platform in the same family; SkyCut Pro and credits are bought with a Sky Studio account`,
];
const bullets=items=>items.map(item=>`- ${item}`).join('\n');

export function renderLlms() {
  return `# SkyCut

> ${summary}

Key facts:

${bullets(keyFacts)}

## Pages

${bullets([...pages(),`[Full fact sheet](${ORIGIN}/llms-full.txt): every feature, plan difference and AI model in one file`])}

## Other languages

${bullets(localized())}

## Optional

${bullets(family)}
`;
}

const questions=[
  ['What is SkyCut?',summary],
  ['Which Mac do I need?',`An Apple silicon Mac running ${APP_FACTS.operatingSystem}. Automatic transcription uses Apple speech recognition and needs ${APP_FACTS.transcriptionSystem}. Intel Mac and Windows versions are not available.`],
  ['Is SkyCut free?',`Yes. The Free plan has no time limit and includes the full manual editor; exported videos carry a Sky Studio watermark. Pro (${usd.symbol}${usd.monthly} per month or ${usd.symbol}${usd.yearly} per year) removes the watermark and adds AI editing.`],
  ['How does AI editing work?','SkyCut includes a local MCP server. In Settings, Connect AI sets up Claude Desktop, Claude Code or Codex. You describe the edit in the AI client, and the AI makes the changes on the SkyCut timeline, where you can inspect, refine or undo them. AI editing needs Pro. A regular ChatGPT web chat cannot connect to the local MCP server.'],
  ['Do I need a Sky Studio account?','Only for Pro and for cloud generation. SkyCut Pro is tied to a Sky Studio account (one person, up to 2 Macs), and cloud models are paid for with Sky Studio credits. Manual editing on Free needs no account.'],
  ['Does my footage stay on my Mac?','Editing and project files are local. A connected AI client and any cloud generation you ask for receive the content needed for that request.'],
  ['Who makes SkyCut?','Sky Lu, the founder of Sky Studio. SkyCut is part of the Sky Studio product family.'],
];
const terms=[
  'Pro is for one person on up to 2 Macs.',
  'Prices exclude tax; local taxes are added at checkout.',
  'Auto renewal can be cancelled at any time, and Pro stays active through the paid period.',
  'Payments are nonrefundable except where required by law.',
  'Image, video and voice generation use Sky Studio credits purchased separately.',
];

export function renderLlmsFull() {
  const models=cloudModelGroups.map(group=>`- ${compare.models[group.id]}: ${group.models.map(model=>model.title).join(', ')}`).join('\n');
  return `# SkyCut: full fact sheet

> ${summary}

This file is generated from the same content as ${ORIGIN}. Short version: ${ORIGIN}/llms.txt

## Key facts

${bullets(keyFacts)}

## Questions and answers

${questions.map(([q,a])=>`### ${q}\n\n${a}`).join('\n\n')}

## Plans and terms

- Free: ${usd.symbol}0, no time limit.
- Pro monthly: ${usd.symbol}${usd.monthly} per month (${cny.symbol}${cny.monthly} on the Chinese site). No credits included.
- Pro yearly: ${usd.symbol}${usd.yearly} per year (${cny.symbol}${cny.yearly} on the Chinese site). Includes 1,000 Sky Studio credits for each paid year.
${bullets(terms)}

## Free and Pro, feature by feature

${featureGroups.map(group=>`### ${compare.groups[group.id]}\n\n${table(group.rows)}`).join('\n\n')}

### ${compare.charactersTitle}

${table(characterRows)}

### ${compare.localTitle}

Local processing uses no Sky Studio credits. Calling these tools through AI requires Pro. The built-in voices cover ${localVoiceLanguages.map(key=>compare.languages[key]).join(', ')}.

${table(localModelRows)}

### ${compare.cloudTitle}

Cloud models use Sky Studio credits. On Pro the AI calls them for you; video upscaling can also be used directly in the app on Free. The catalog changes, and the app shows the current list.

${models}

## Getting started

${english.docsSteps.map(([title,body],i)=>`${i+1}. ${title}: ${body}`).join('\n')}

${english.docsClients}: ${english.docsClientsBody}

## Privacy

${english.privacySections.map(([title,body])=>`- ${title}: ${body}`).join('\n')}

## Links

${bullets([...pages(),...localized(),...family])}
`;
}
