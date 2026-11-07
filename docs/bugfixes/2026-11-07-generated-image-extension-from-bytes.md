# 2026-11-07 生成图片只信元数据，JPEG 可能落成 PNG

## 症状

接入 Lite 图片模型时核对落盘：假服务返回真实 JPEG，结果 MIME 缺失或与字节不一致、URL 没有可靠后缀时，
旧路径会按图片种类兜底保存为 `.png`。MIME 正确报 image/jpeg 的原路径已经能存 `.jpg`；问题是没有核对实际字节。
这是本机合成夹具复现，不代表已经在尚未上线的服务端新模型上进行了真实付费测试。

## 根因

`SkyStudioGeneration.fileExtension` 只在下载前按 result.content_type → URL → kind 选名字。
`SkyStudioGenerationRun` 下载后直接报告成功，没有确认实际图片格式，媒体类型元数据不可靠时扩展名就跟着错。

## 修复

下载初始命名仍用原 MIME 逻辑。图片完成下载后在 analysis 队列用 `SkyStudioImageResult.format` 调 ImageIO 读真实类型；
经同一份 finalize 在已有避重名 / 任务占位规则下纠正扩展名，不重编码，不覆盖用户文件。
`file_content_type` 单独报实际本机类型，服务器 result 元数据原样保留。无法确认时保留文件并报交付失败，仍按原单 billing 结算。

## 验证

`ImageResultChecks` 用原生编码器生成真 JPEG / PNG，经假 HTTP 和生产下载器落盘；覆盖正确 MIME、错误 MIME、无可靠 MIME / 后缀，
逐字节断言保存内容不变，确认 JPEG 为 `.jpg`、PNG 为 `.png`。非图片字节明确失败并保留文件。
扫描守卫另钉生产生成任务在下载之后调用同一份格式识别与 finalize。

反向验证：临时撤掉顶层 operation 编码，并让最终后缀退回下载时选中的名字，
`scripts/check-sky-studio.sh` 以非零退出，30 项变红（含两项真 JPEG 落成 PNG、精确 HTTP body 和审批串码）；
`checks/sky-studio-wiring.sh` 同样非零。两份生产文件随后逐字恢复，Sky Studio 完整检查 5,743 项通过。
完整 App 的 `swift build --arch arm64` 通过；`check-local sky-studio mcp` 中扫描和 Sky Studio 通过，
MCP 的目录长度 / 说明问题修正后，`check-local mcp` 再跑全部扫描及 3,238 项 MCP 检查通过。
schema、前 512 字用途、英文说明、每工具 2,048 与整份清单 100,000 字符上限均由实际小程序清单验证。

## 教训 / 防回归

内容类型和 URL 能帮助选择初始名字，最终文件格式应核对实际字节；扩展名纠正不需要重新编码，更不需要再次收费生成。
长期合同见 [Sky Studio 的任务](../architecture/sky-studio-jobs.md)第十二节；回归随 `scripts/check-sky-studio.sh` 和 MCP 检查运行。
