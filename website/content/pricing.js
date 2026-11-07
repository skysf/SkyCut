// 方案中的真实标价供页面与 JSON-LD 共用；不参与结账或按所在地换汇。
const usd = {currency:'USD', symbol:'$', monthly:19, yearly:149};
const cny = {currency:'CNY', symbol:'¥', monthly:129, yearly:999};
export const prices = language => language === 'zh' ? cny : usd;

// 只算展示用的年付折合与节省金额 JSON-LD 仍用上面的真实标价
export function annualBreakdown({monthly,yearly}) {
  return {perMonth:(yearly/12).toFixed(2),saving:Number((monthly*12-yearly).toFixed(2)).toString()};
}
