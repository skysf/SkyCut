# 2026-10-31 七个 Sky Studio 模型与原单结算

## 症状

后端新增 Wan 三款、HeyGen 两款、H3 Max 换口型和 Ideogram 去背景，MCP 仍只认旧生成种类，强制 prompt，丢掉目录的操作 / 输出 / 结算说明。
WebM 被当 MP4，字幕与透明标记没有返回路径；旧实现还会在丢失提交响应时重放 POST、在真人参考拒绝后自动换模型。

## 根因

生成请求只覆盖旧模型的字段，目录投影不完整，限制只读旧的 references/modes 层级，上传用途固定按媒体类型猜。
账务没有解析新的 billing；任务 failed、取消应答与供应商实际结算被混在一起。文件扩展名也没有 WebM，且 macOS AVFoundation 实测无法打开 HeyGen 的该种容器。

## 修复

- 保留完整目录和计费政策；扩展 generate_media 的 lipsync、image/remove_background、Wan 控制与文档 / 页面引用；输入先授权，再按目录检查数量、实际格式、字节、尺寸与时长，价只问 /quote。
- 按目录发专用上传 purpose，HeyGen 七个附加参数全部透传、dynamic duration 默认 false；H3 Max 的实际音频时长进入报价。
- 同一 idempotency_key 只起一个本机任务；并发准备也占位。删除自动换模型实现，提交响应未知不重放收费 POST。get_job 刷新原服务器任务与账务，不创建替代任务。
- 最终净扣费 / 全退 / 待核查只认 billing；生成成功后下载、保存、导入失败不退款。保留原结果地址、job id 和 key。
- 保存实际输出元数据与可选 SRT。透明 PNG 原字节保存并复用现有透明素材管线。WebM 原字节保留，macOS 不支持时用现有 FFmpegProcess 做本机 H.264/AAC 编辑副本，明确返回两份路径及用途。
- 免费冒烟服务器增加素材准备后，启动顺序必须等回环服务 ready 再开测试 App，否则首次 /me 会失败并触发授权查询退避。

## 验证

- 后端发布：构建 success 最初没有接管正式域名。用户授权后，后端窗口完成 [受控发布 41192353608](https://github.com/skysf/skystudio-aigc-app/actions/runs/41192353608)，只推广既有 exact main `3df55d654628bb4f199f9914f9fa996046e3f291`。exact-main / merged-PR / exact-head CI、推广前复核、Promote、canonical verify 全部 success，生产 provider-free Cinematic smoke 为 2 passed（12.3s）。六个策略域名逐一 inspect，均指向 `dpl_3NhsabhkCg7By6mNxeNwKj3JJVaA` / production / READY；发布开关最终恢复 false 并读回确认。
- 后端窗口使用本机既有认证只读核验正式 `/models`（2026-10-31 18:30:42 +08:00）：HTTP 200、27 条、全部七个新 ID；根与 27/27 模型的 `billing_policy.version` 都是 `2026-10-31`，cache BYPASS，`x-vercel-id=sfo1::iad1::pwg4k-1793442641091-fab5aa13578f`。该证据已由用户回传，本窗口未重复读取凭证或发起生产生成。API base 仍为 `https://skystudioai.com/api/skycut/v1`。
- `scripts/check-sky-studio.sh`：新增后端目录快照、七模型参数 / 限制 / billing / 幂等回归。反向验证临时恢复错误的动态时长默认值和 WebM 扩展名，要求两条守卫明确变红后自动恢复。
- 真实 App / MCP 免费验证入口：`scripts/gui-smoke/sky-studio/model_expansion.py`，独立假 Key / 回环服务 / 合成素材，覆盖发现、参数、专用上传、同 key 不重扣、WebM / PNG / SRT 入轨与导出，以及下载失败不退款和原单刷新结算。
- Sky Studio **795 项**、MCP **2,685 项**、upscale **123 项**通过；完整 App 编译通过。七模型免费真实 App / MCP 已通过发现、参数、上传用途、同 key 去重、WebM 编辑副本、PNG 字节透明度保留、SRT 入轨与导出、交付失败不退款和原单结算刷新。
- `scripts/check-guards.sh` 全部扫描守卫通过，包含 MCP 扫描、生产接线、文档索引和文件长度限制。
- 全量入口首跑发现 upscale 旧取消夹具没有 billing 证据；按新合同补齐原单查询，单项 123 项复跑通过。最终 `scripts/check-all.sh` 完整跑到结束：**76 组通过、0 失败**。
- 反向验证明确出现 **2 项失败**（动态时长默认值、WebM 扩展名），随后恢复修复。没有提交付费生成或替换用户正在使用的 App。

## 教训 / 防回归

模型接入必须贯通目录、参数、限制、上传、交付和结算。媒体能被 ffmpeg 探测不等于原生预览能播放；取消应答和本机失败也都不等于退款。
长期合同、无任务号时的恢复限制和验证入口见 [Sky Studio 的任务](../architecture/sky-studio-jobs.md)第十节。
