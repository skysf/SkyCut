// Navigation and footer labels for the two guide-only languages. Their guide pages
// reuse a site language's pages for everything else (zh-hant → /zh/, ja → /en/),
// so only the words a reader sees around the article are translated here.
import chinese from './zh.js';
import english from './en.js';
const shells={
  'zh-hant':{...chinese,lang:'zh-hant',name:'繁體中文',
    nav:['功能','文件'],download:'下載 Mac 版',menu:'選單',close:'關閉',skip:'跳到內文',home:'首頁',back:'返回 SkyCut',
    pricing:{...chinese.pricing,title:'價格'},privacy:'隱私',support:'聯絡',footer:'你來導演 AI 來剪輯',
    seo:{...chinese.seo,founderLabel:'創辦人 Sky Lu',familyLabel:'Sky Studio 產品家族',imageAlt:'Sky Lu 創立的 Mac AI 影片剪輯軟體 SkyCut 屬於 Sky Studio 產品家族'}},
  ja:{...english,lang:'ja',name:'日本語',
    nav:['機能','ドキュメント'],download:'Mac 版をダウンロード',menu:'メニュー',close:'閉じる',skip:'本文へ移動',home:'ホーム',back:'SkyCut に戻る',
    pricing:{...english.pricing,title:'料金'},privacy:'プライバシー',support:'お問い合わせ',footer:'あなたが監督 AI が編集',
    seo:{...english.seo,founderLabel:'創業者 Sky Lu',familyLabel:'Sky Studio ファミリーの製品',imageAlt:'Sky Lu による Mac 向け AI 動画編集ソフト SkyCut Sky Studio ファミリーの製品'}},
};
// The copy object the page shell needs for any language a guide can be written in.
export async function shellCopy(language) {
  return shells[language]||(await import(`./${language}.js`)).default;
}
