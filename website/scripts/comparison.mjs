// 将共享的功能与授权表渲成同一张原生 table 模型名称不在四份翻译里重复维护
import {escape as e} from './html.mjs';
import {icon} from '../src/icons.js';
import {featureGroups,localModelRows} from '../content/feature-matrix.js';
import {cloudModelGroups,localVoiceLanguages,soundEffectPresets} from '../content/ai-models.js';

function access(key,p) {
  const c=p.compare,a=c.access;
  const available=!['unavailable','watermarked','none'].includes(key);
  const symbolLabel=key==='watermarked'?a.watermarked:key==='none'?a.none:available?a.included:a.unavailable;
  const labels={included:[],ai:[a.ai],watermarked:[a.watermarked],clean:[a.clean],none:[a.none],unavailable:[a.unavailable],
    localUI:[a.inApp,a.noCredits],localBoth:[a.both,a.noCredits],localAI:[a.ai,a.noCredits],cloudAI:[a.ai,a.usesCredits],cloudUI:[a.inApp,a.usesCredits],cloudBoth:[a.both,a.usesCredits],annualCredits:[p.yearlyCredits]};
  return `<td data-access="${key}"><div class="comparison-access ${available?'is-included':'is-unavailable'}"><span role="img" aria-label="${e(symbolLabel)}">${icon(available?'check':'close')}</span>${labels[key].map(label=>`<span>${e(label)}</span>`).join('')}</div></td>`;
}
function row(id,label,details,free,pro,p,extra='') {
  return `<tr data-feature="${id}"><th scope="row"><span class="comparison-label">${e(label)}</span>${details?`<p>${e(details)}</p>`:''}${extra}</th>${access(free,p)}${access(pro,p)}</tr>`;
}
const list=(items,className)=>`<ul class="${className}">${items.map(item=>`<li>${e(item)}</li>`).join('')}</ul>`;
const groupTitle=(id,title,note='')=>`<tr class="comparison-group" id="comparison-${id}"><th colspan="3" scope="colgroup"><span>${e(title)}</span>${note?`<p>${e(note)}</p>`:''}</th></tr>`;
export function comparison(p) {
  const c=p.compare;
  const features=featureGroups.map(group=>`<tbody class="${group.id==='pro'?'comparison-advantages':''}">${groupTitle(group.id,c.groups[group.id])}${group.rows.map(item=>row(item.id,...c.features[item.id],item.free,item.pro,p)).join('')}</tbody>`).join('');
  const local=localModelRows.map(item=>{
    const extra=item.id==='kokoro'?list(localVoiceLanguages.map(key=>c.languages[key]),'comparison-tags'):
      item.id==='synth'?list(soundEffectPresets,'comparison-tags'):'';
    return row(item.id,...c.features[item.id],item.free,item.pro,p,extra);
  }).join('');
  const cloud=cloudModelGroups.map(group=>row(`model-${group.id}`,c.models[group.id],'',group.id==='upscale'?'cloudUI':'unavailable',group.id==='upscale'?'cloudBoth':'cloudAI',p,list(group.models.map(model=>model.title),'comparison-model-list'))).join('');
  return `<div class="pricing-comparison" aria-labelledby="comparison-title"><h3 id="comparison-title">${e(c.title)}</h3><p class="comparison-intro">${e(c.intro)}</p>
    <table><caption class="visually-hidden">${e(c.title)}</caption><colgroup><col class="comparison-feature-column"><col><col></colgroup>
      <thead><tr><th scope="col">${e(c.feature)}</th><th scope="col">${e(p.free)}</th><th scope="col">${e(p.pro)}</th></tr></thead>
      ${features}<tbody>${groupTitle('local',c.localTitle,c.localNote)}${local}</tbody><tbody>${groupTitle('cloud',c.cloudTitle,c.cloudNote)}${cloud}</tbody>
    </table><p class="comparison-catalog-note">${e(c.catalogNote)}</p></div>`;
}
