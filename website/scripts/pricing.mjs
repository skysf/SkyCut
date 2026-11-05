// 首页价格区只展示方案与外链；登录和付款均由 Sky Studio 处理。
import {escape as e} from './html.mjs';
import {icon} from '../src/icons.js';
import {DOWNLOAD_URL,PRO_PURCHASE_URL} from './site-config.mjs';

const features = items => `<ul class="pricing-features">${items.map(item=>`<li>${icon('check')}<span>${e(item)}</span></li>`).join('')}</ul>`;

function billing(p, yearly) {
  const label = yearly ? p.yearlyLabel : p.monthlyLabel;
  return `<div class="pricing-billing ${yearly ? 'pricing-yearly' : ''}">
    <h4>${e(label)}</h4>
    <p class="pricing-price"><strong>${p.symbol}${yearly ? p.yearly : p.monthly}</strong><span>${e(yearly ? p.year : p.month)}</span></p>
    <p class="pricing-credits">${e(yearly ? p.yearlyCredits : p.monthlyCredits)}</p>
  </div>`;
}

export function pricing(c) {
  const p = c.pricing;
  return `<section class="pricing container section" id="pricing" aria-labelledby="pricing-title">
    <div class="section-heading"><div><h2 id="pricing-title">${e(p.title)}</h2><p>${e(p.intro)}</p></div><p class="pricing-trial">${icon('ai')}${e(p.trial)}</p></div>
    <div class="pricing-grid">
      <article class="pricing-card pricing-free" aria-labelledby="pricing-free-title">
        <div class="pricing-plan-heading"><h3 id="pricing-free-title">${e(p.free)}</h3><p class="pricing-free-price">${e(p.freePrice)}</p></div>
        ${features(p.freeFeatures)}
        <a class="button button-outline" href="${DOWNLOAD_URL}">${e(c.download)}${icon('arrow')}</a>
      </article>
      <article class="pricing-card pricing-pro" aria-labelledby="pricing-pro-title">
        <div class="pricing-plan-heading"><h3 id="pricing-pro-title">${e(p.pro)}</h3><p>${e(p.proIntro)}</p></div>
        ${features(p.proFeatures)}
        <div class="pricing-billing-grid">${billing(p,false)}${billing(p,true)}</div>
        <div class="pricing-purchase"><a class="button" href="${PRO_PURCHASE_URL}" target="_blank" rel="noopener noreferrer">${e(p.buy)}${icon('arrow')}</a><p>${e(p.login)}</p></div>
        ${p.wechat ? `<p class="pricing-wechat">${e(p.wechat)}</p>` : ''}
      </article>
    </div>
    <div class="pricing-terms"><div><p class="pricing-devices">${e(p.devices)}</p><p>${e(p.clients)}</p><p>${e(p.credits)}</p></div><div><p>${e(p.tax)}</p><p>${e(p.cancel)}</p><p>${e(p.refund)}</p></div></div>
  </section>`;
}
