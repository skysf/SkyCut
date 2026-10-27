# 导出水印

> 2026-10-27 引入（[收费方案](../plans/2026-10-27-paid-plans-and-sky-studio-key.md)第 4 刀）。改 `Sources/SrtFlow/Watermark/`、导出图里水印的落点、
> `WatermarkPolicy`、`Resources/watermark-logo.svg` 之前必读。为什么要水印、长什么样是用户拍的板（方案第 4、5、11 条）；这里记已经生效的约束。

## 一、规矩

| 决定 | 口径 |
| --- | --- |
| 加在哪 | **只加在剪辑导出的成片上**：`VideoEditExporter.export`（界面上的导出、AI 的 `export_video` 都走它）。预览、AI 用 `look` 看时间线、生成和 upscale 的成品、压缩 / 烧录字幕（处理用户自己的文件）、录屏都不加 |
| 谁说了算 | **只有 `WatermarkPolicy.mark()`**，`VideoEditExporter` 开始导出时问一次。`VideoEditExportGraph.plan()` 的 `watermark` 参数**没有默认值**：新加的调用方必须自己说加不加（自检一律传 nil），不会因为漏传悄悄不加 |
| 现在 | **默认不加**（授权还没接上）。测试时打开：`defaults write com.srtflow.SrtFlow.beta export.testWatermark -bool true`（正式版把 `.beta` 去掉），关掉写 `false`。收费方案第 5 刀换成服务器下发的 `watermark` 开关 |
| 落点 | **字幕烧完之后、缩到导出分辨率之前**：压在所有画面之上（调色、盖一块、形状、文字、字幕都在它下面），和别的东西一样按工程尺寸叠完、最后整幅等比缩小（[导出设置](export-settings.md)第一节） |
| 样子 | Sky Studio 的 logo（`Resources/watermark-logo.svg`，用户给的白字透明底那一版）；一圈软阴影（往右下偏 logo 宽的 1.2%、模糊半径 4%、黑 55%），亮画面上也看得清；字和阴影整体不透明度 70% |
| 怎么跳 | 同一时刻只在一处；**每 4 秒换一处**，在四个角和正中之间随机挑、**不连续两次落在同一处**；种子每次导出随机、一次导出里固定（`SeededRandom`：同一个种子同一张表） |
| 多大、放哪 | 四角的 logo 宽 = 画面短边的 **25%**、正中 = **15%**；四角离两边各短边的 **4%**，正中居中。按工程画布算（竖屏、横屏都按短边） |
| 滤镜图 | **整段成片只加两个 overlay**（四角用的大图、正中用的小图；表里没用到的那张不叠）。位置和开关是随时间分段的常数，写成平衡的 `if(lt(t,…))` 树、相邻同值的段先并起来：一小时 900 段也只有十来层。**不许一段挂一个 overlay**（一小时就是 900 层滤镜）。段左闭右开 `[起点, 下一段起点)`，同 `OverlayExportFile.enableWindow` |
| logo 怎么读 | 只认绝对坐标的 M / L / Z（这份 logo 就是这样矢量化出来的）。有别的命令、没有路径、墨迹是空的都回 nil —— 换 logo 时自检先红，不会画出缺笔画的图。路径是矢量，每次按那一处的宽现画，不存位图 |

## 二、授权接上时（收费方案第 5 刀）要改的

- `WatermarkPolicy.mark()` 改问服务器下发的 `watermark` 开关：`SkyStudioAccount.shared.license`（存下来的 `/me` 用到 `valid_until`，服务器定，现在 72 小时；
  [Sky Studio 账号](sky-studio-account.md)，第 5 刀第一步已做），测试开关去掉或只留给测试版。
- **logo 读不出来要拦住导出**。现在读不出来是悄悄不加 —— 只有测试才加，这样没关系；水印成了必须的之后，删掉包里的 logo 就能免水印，不行。
- 导出的结果里告诉 AI 带了水印、为什么（AI 用 `look` 看成片会看到它）。

## 三、已知能绕过去的（不防）

- 录屏录预览窗口；把成片拿到别的软件里把角上的 logo 裁掉 / 糊掉 —— 所以要随机跳、正中也有。
- 仓库公开期间自己编一份去掉判断（收费方案第 3 条）。真正收得住的是服务器那一侧（积分、授权）。

## 四、守卫

- `scripts/check-export-watermark.sh`（`check-all.sh` 第 5 组，要 ffmpeg）：
  - 纯值（`checks/Watermark/PureChecks.swift`）：logo 的墨迹尺寸和原点、几种坏 SVG 回 nil、分词；PNG 的尺寸 = 墨迹 + 阴影那一圈、最实的一点 alpha ≈ 178（70%）、是白字、有黑阴影、角落透明；
    一小时的表 900 段、不连续同一处、首尾相接、五处都用到且大致一样多、同种子同表、换种子换表、短的成片；1080p / 竖屏的大小和位置；分段表达式逐 0.25 秒求值和表一致、
    4 秒那一刻已经是第二段、900 段的树不超过 11 层。
  - 真导出（`checks/Watermark/ExportChecks.swift`，调真实的 `VideoEditExportGraph.plan()`，开着和不开各导一遍逐像素比）：每一段改动的外接框落在表上那一处的整张图里、
    范围差不多是整个 logo；第 95 帧（3.958 秒）还是第一段、第 96 帧（4.000 秒）已经是第二段；盖满画面的实心形状上面照样有；不加水印时参数里没有水印的图、
    加的时候用到几种进几张；1280 × 720 导 480p 之后还在那一角。
- `checks/export-watermark-wiring.sh`（扫描，`check-all.sh` 第 1 组）：`Sources` 里只有 `VideoEditExporter` 调 `VideoEditExportGraph.plan(` 和 `WatermarkPolicy.mark()`，
  而且把问到的水印传进去；导出图里叠水印正好一处、在烧字幕之后、缩小之前。

## 五、人工回归（发版前）

- [ ] 测试版打开测试开关，导一条 1080p 横屏、一条 9:16 竖屏：logo 在四角和正中跳、每 4 秒换、不连续两次同一处；亮的、暗的画面上都看得清；字幕、文字、形状都在它下面。
- [ ] 关掉开关再导：没有水印。
- [ ] AI 的 `export_video` 导出来和面板导的一样（同一个开关）。
