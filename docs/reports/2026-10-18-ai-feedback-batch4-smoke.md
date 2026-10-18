# 2026-10-18 第四批 AI 反馈的测试版冒烟（0.18.46，扮成 AI 客户端）

对应案例：[listen cuts=true 说「可以不改」，cut_speech 却说同一刀切在字上](../bugfixes/2026-10-18-cut-check-disagrees-with-cut-speech.md)（#246）、
[字幕自动折行把中文的词拆在两行](../bugfixes/2026-10-18-subtitle-wrap-splits-chinese-words.md)（#248）。main a8b0e19 出测试版 0.18.46 装上
（版本、arm64、`codesign --verify --deep --strict`、证书 leaf 76d27565… 和仓库钉着的一致、小程序能答 initialize 且不拉起 App），用
`scripts/gui-smoke/mcp-client/client.py` 那一套驱动它的小程序（本地拷了一份、加了「从上一步结果里取值、`${名字}` 引用」，整轮在同一个会话里跑完），
**全程后台模式**（`set_view background`，一个工程窗口都没开）。素材是测试员的 L16 测试工程，用 `scripts/gui-smoke/in-process/copy-project.sh`
连素材拷到 scratchpad（4 段、29.125 秒、6 句中文字幕、圆体 72 号粗体）。

## 折行（#248）

`get_subtitles` 的框、`look` 看时间线（预览那份合成）、`export_video` 原尺寸真导出后 `look` 看成片，三处一样：

| 宽度 | 句子 | 折成 |
| --- | --- | --- |
| 默认 0.92 | 包括 Google 的 Nano Banana、OpenAI 的 GPT Image 以及字节跳动的 Seedream | 包括 Google 的 Nano Banana、/ OpenAI 的 GPT Image 以及字节跳动的 Seedream |
| 默认 0.92 | 其余五句 | 各一行 |
| 0.6 | 在这一节中 我们会带你设置 SkyStudio 账号 | 在这一节中 / 我们会带你设置 SkyStudio 账号 |
| 0.6 | 包括 Google 的 … Seedream | 包括 Google 的 Nano Banana、/ OpenAI 的 GPT Image / 以及字节跳动的 Seedream |
| 0.6 | 工作区里有三个标签页 图像、视频和音乐 | 工作区里有三个标签页 / 图像、视频和音乐 |
| 0.6 | 视频标签页也提供了 多个目前最强的视频模型！ | 视频标签页也提供了 / 多个目前最强的视频模型！ |
| 0.6 | 在音乐标签页中 可以生成最长 5分钟的「音乐」吗？ | 在音乐标签页中 / 可以生成最长 5分钟的「音乐」吗？ |

- `get_subtitles` 的 `lines`：默认 1 / 1 / 2 / 1 / 1 / 1，max_width 0.6 时 2 / 1 / 3 / 2 / 2 / 2；`box_note` 是新文案（「between Chinese or Japanese words,
  never inside one」）。
- 成片（1920×1080、24 fps）抽的五帧和预览那五帧行一模一样。Vision 认出的第一句两行：预览 x 0.40–0.59 / 0.23–0.76，成片 0.40–0.59 / 0.24–0.77。
- 修之前同一个工程在 max_width 0.6 下是「工作区里有三个标签 / 页 图像…」「视频标签页也提供了 多 / 个…」「…GPT Image 以 / 及…」。

## 剪辑点检查（#246）

拷出来的素材换了路径，转写缓存按路径认、没有现成的，先 `transcribe` 四段（6 秒，en_US），再 `listen cuts=true`：

| 剪辑点 | 结论 | 切到的词 | 建议 | 声音（复算的电平） |
| --- | --- | --- | --- | --- |
| 第 3 段出点 77.417 | on_speech（修之前：quiet_spot + 77.717） | available. | 77.75（停顿 77.60–77.88） | 77.415 那一格 −48 dB 的低谷，之后 −37.6 dB 尾音，77.60 起才静 |
| 第 3 段入点 71.458 | on_speech | image. | 71.709（第一轮）/ 71.75（完整转写） | 71.425–71.471 还有 −36.7 dB（上一句的尾音），71.61 起才静 |
| 第 4 段入点 91.417 | on_speech | —（这一段的转写从 90.917 起，没认出「model.」） | 91.667 | 91.394–91.440 −34.8 dB（「model.」的尾音），91.58 起才静 |
| 其余四处 | in_pause | | | |

- 照建议 `edit_clip source_out=77.75 ripple=true`，再查：第 3 段出点 in_pause。
- 测试员只提了 77.417，其实这三刀都把上一句的尾音带进了下一段（snap=false 剪的）；现在检查和 cut_speech 一样都报出来。
- **cut_speech 对照**：新工程放整段素材、整个文件转写，`cut_speech keep 71.458–77.417` → `moved` 71.458 → 71.75（「moved into the pause 71.61–71.89 s」）、
  77.417 → 77.75（「…77.60–77.88 s」）；剪完 `listen cuts=true` 两头 in_pause。
- **同一份数据同一个答案**：用完整的转写再放一段 71.458–77.417 查，检查建议入点 71.75、出点 77.75，原因文字和 cut_speech 的 `moved` 一字不差。
  第一轮入点建议 71.709 差一帧，是因为那时只转写了四段（转写窗口从 70.958 起、切进「image.」半个词，词的时间不一样）—— 同一个停顿里，不是两个工具判法不同。

## 没验到 / 留给人工

- 预览窗口本身没开（后台模式）；`look` 看的是预览那份合成，人工回归清单里「长句的折行点」那条照旧要在窗口里看一眼。
- 测试版跑完还开着（小程序 `open -g` 拉起的，工程都已 `close_project`）。

## 冒烟工具的坑

- 结果里取到的段 id 恰好是 8 位纯数字（「52028358」），本地加的「整串是 `${名字}` 就按 JSON 解析」把它变成了数字，`transcribe` / `cut_speech` 报参数错；
  改成只有带小数点的才当数字。
