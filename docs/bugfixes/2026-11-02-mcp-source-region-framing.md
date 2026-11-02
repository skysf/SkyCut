# 2026-11-02 MCP 不能直接取录屏中的小矩形

## 症状

放大网页提示词、模型选择区或角色卡时，AI 需要反算 crop、scale、x、y。四边裁切各限 45%，
很小或靠边的控件无法完整、干净地展示；调用方需要堆黑色形状遮掉区域外的内容。

## 根因

`AIFrameFit.fill` 已有正确的「源窗映到画布」几何，但 MCP 只收四边裁切和手动变换。
fill 能借摆放把多余画面挤到画布外，contain 的留空处则无法遮掉未裁净的源内容。
`ClipCrop` 的 initializer 和 decoder 都夹到 45%，即便只在内存放宽也会在保存重开时变坏。
旧的空裁切容差又固定为 0.05%，会吞掉高分辨率素材上的一至数个源像素。

真实渲染回归还发现，YUV 4:2:0 在奇数源像素边界直接裁时，色度的采样起点与原生预览不同，局部放大后色边明显偏移。

## 修复

- `AIFramingRequest` 收完整的 region，源旋转摆正后的左上坐标 0–1；默认 fit，支持居中 fill；冲突参数直接拒绝。
- `AIRegionFraming` 把像素边界与能力校验集中一处，复用 `AIFrameFit.fillWindow` / `mapping`，沿用单项及批量编辑事务。
- `ClipCrop(keeping:)` 承载有效精确矩形，传统 crop initializer 和 MCP crop 参数范围不变；有效四边数值原样解码。
  检查器单边编辑保留另外三边，工程 v33 拦住会夹坏新区域的旧版。
  精确边界不再按 0.05% 判空；旧工程当年忽略的微小裁切按版本迁移成无裁切，升级不改旧成片。
- 导出 crop 使用 exact=1，奇数边界先转 RGBA 再裁；预览继续用已有 AVFoundation 裁切，不增加合成器、素材或遮挡形状。
- 结果给 requested_region、实际 region、visible_region、source_display_size 和最终 transform；get_timeline 同源复查。

## 验证

检查入口：`scripts/check-region-framing.sh`、`scripts/check-mcp.sh`、`scripts/check-project-file.sh`、`scripts/check-guards.sh`。
渲染检查在完整 App 对象上调用生产的编辑、look、AVFoundation 预览、导出 plan() 与 ffmpeg；覆盖横竖素材、
90/180/270 度旋转、跨宽高比、4% × 6% 四角、奇数像素、强色度棋盘、撤销 / 重做及批量失败不落半份修改。
坐标尺在测试侧独立算期望像素，不从被测的裁切 / placement 回推期望。

本次结果（隔离测试工程，真实媒体和渲染，未安装用户 App）：

- check-region-framing：223 条断言通过，24 个取景场景各实际调用 look / 预览 / 导出；另有强色度奇数裁切比对。
  保留验收图在 `/private/tmp/skycut-region-evidence/`，逐项测量在其中的 measurements.json；人工看过横屏、竖屏、旋转和小边角的 look 图。
- check-mcp：2,913 项通过，含 8K 一像素与非零精度反馈；check-project-file：1,312 项通过，含微小裁切与旧工程迁移。
- 既有 check-preview-composition：315 项通过；check-export-frame-rate：73 项通过。
- 反向验证：将 region 降回传统 45% 裁切，独立源坐标断言红 10 条（整组红 15 条）；
  撤掉解码精确值保留，存盘往返断言红 1 条；撤掉奇数边界裁前转 RGBA，强色度断言红 1 条，平均 RGB 差回到 0.0866。
  每组都在 finally 中逐字节恢复源码并核对 SHA-256，再重跑正向检查转绿。
- 另两组精度反向验证：恢复旧空裁切容差，一像素取景断言红 1 条；将裁切结果退回三位小数，反馈非零断言红 1 条。
- 全仓 check-guards、文件体积、文档索引和 diff 空白检查通过。

测试素材明确标注 BT.709 色彩信息，避免把未标记色彩的解码差异算成取景误差；单独的强色度回归不依赖坐标尺。
使用注册表中的后台测试工程、生产预览 builder 显式取帧，不额外运行无窗口播放器；参考图复制成普通像素，
避免长期持有解码缓冲。早期验收曾超时，按失败处理，没有将它计为通过；最终渲染验收独立于其它媒体检查运行。
真实网页小字 / 检查器手势的发版前清单保留在架构文档，尚未声称完成实机手动验收。

## 教训 / 防回归

取景接口应直接表达调用方的源矩形，再复用既有几何；不能把参数上限的缺口转嫁成遮挡图层。
扩大已有数值范围也是格式语义变更，必须同时看 decoder、检查器、版本闸门和两条渲染管线。
几何位置和高频色度插值分别测量，真实旋转素材必须断言存在方向矩阵，不能只拿长得像竖屏的文件代替。
长期合同和发版前实机清单在 [预览自由变换](../architecture/preview-free-transform.md)「MCP 的源矩形取景」。
