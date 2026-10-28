# 2026-10-28 Upscale 面板上 Sky Studio 不肯报价的那一行只写「—」，不说为什么

## 症状

upscale 改走 Sky Studio（#268）之后，面板上每一行的积分是问 `/quote` 来的。有几种情况 Sky Studio 不肯报价：
- 超过这一档的最大倍数：Topaz Starlight 最多放大 4 倍，360p 要升 4K 就超了；
- 源已经不比目标小。

这时那一行只有一个灰色的「—」，开始键灰着，面板上找不到原因。用户只会以为这一档坏了。合进 main 之后、发版之前，我对着服务器的代码复查时发现的，还没有用户撞上。

## 根因

`/models` 只报一次最长几秒、最高几帧、上传多大这几个上限，**不报每一档的最大倍数**。最大倍数和「不比源大」都是服务器在 `/quote` 里判的（Sky Studio 仓库 `api/_utils/skycut/catalog.ts`：`over_max_factor`、`not_above_source`），回 `invalid_request`，`message` 是写给人看的一句话。

`UpscaleOffers` 把它记成 `.failed(message)`，面板的价格那一格却只画「—」：写面板时以为报价失败只会是断网这种临时的事，原话就没往界面上放。

## 修复

`Sources/SrtFlow/Upscale/UpscalePanel.swift` 的 `tierRow`：这一行本地没有挡（`refusal` 为空）、报价失败了，就在模型名底下用橙色写出 Sky Studio 的原话，代替那一句介绍。服务器的 `message` 是英文、写给人看的，同 [Sky Studio 账号](../architecture/sky-studio-account.md)「报错的话」一行，原样显示。开始键照旧灰着（没有报价就不能开始）。

## 验证

- 构建通过；界面这一处自动化够不着（SwiftUI 的一行字）。按仓库规矩写进 [视频 upscale](../architecture/video-upscale.md) 第四节的人工回归第 2 条：「Sky Studio 不肯报价的那一行写出它的原话」。
- 真服务器上用 360p 的片子要 Topaz 4K 复核一次：「Topaz Starlight upscales at most 4x; pick a lower target.」（这句照 `catalog.ts` 的 `over_max_factor`）。等测试版装上新包时一起看。

## 教训 / 防回归

- 服务器说「不行」的那一句话本身就是要给用户看的东西。报价、校验这类会因为**内容**失败的请求，失败的原因要写到界面上，不能只画一个占位符。价格那一格照旧是「—」，原因写在模型名底下；断网这种临时失败也照样写（「Could not reach Sky Studio: …」），用户才知道该重开面板，而不是去换一档。
- 规则在服务器上、`/models` 不报的那几条（最大倍数），SkyCut 不要自己再抄一份：照它的话说就行。
