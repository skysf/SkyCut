# 2026-11-05 官网 404 被标成英文首页的副本

## 症状

补齐官网 SEO 时发现：生成的 `404.html` canonical 和 OG URL 都指向 `/en/`，
沿用首页摘要，也没有不收录标记。确认页同样没有明确的 noindex。

## 根因

旧模板把 `error` 的路由片段设成空字符串，再直接拼成语言首页 URL；所有页面又共用
同一份首页 description，没有区分内容页与工具状态页的索引口径。

## 修复

`scripts/site-config.mjs` 明确 404 的独立地址，`seo.mjs` 按路由生成元数据：
404 canonical 为 `https://skycut.app/404.html`；确认与 404 为 `noindex,follow`，
排除在 sitemap 之外。404 不生成指向首页的语言 alternate 或软件实体 JSON-LD。
可索引的首页、文档、隐私保持独立摘要与四语言互链。

## 验证

- `tests/seo.test.mjs` 检查 404 的 canonical / noindex，以及 sitemap 排除状态页。
- 反向验证：临时把 404 URL 换回语言首页，运行 404 回归守卫，退出 1，明确报
  canonical 不是 `/404.html`；恢复修复后 8 项 SEO 单项检查转绿。
- 完整 40 项网站测试与本地构建通过，`npm run check:seo` 从实际 `dist` 验证 16 个
  语言页面、根目录副本、404、sitemap、robots、结构化数据和四张 PNG。
- 这是元数据修复，不代表本地模板检查已经验证正式域名的 HTTP 404 响应。

## 教训 / 防回归

错误页的“回到首页”链接和页面本身的 canonical 是两件事，不能因为有返回入口就把
错误页标成首页。状态页要能被抓取到 noindex，但不进入 sitemap。长期口径见
[SkyCut 官网](../architecture/skycut-website.md) 的 SEO 与创始人身份一节。
