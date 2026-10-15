# 2026-10-15 工程没记语言的字幕轨，导出的字幕文件名不带语言标签

## 症状

测试版 0.18.30 上扮成 AI 客户端复测 [export_subtitles](../architecture/ai-control-mcp.md)（第四节第 49 条）时撞出来的：

- 用 `edit_subtitles` 手写两句中文译文（track=translation），再 `export_subtitles name=promo format=vtt`：得到 `promo.en.vtt` 和
  `promo.vtt`，后者该是 `promo.zh-Hans.vtt`。
- 用 `add_clips` 导入一个 .srt 当原文轨再导出：得到 `<名字>.srt`，该是 `<名字>.en.srt`；`get_timeline` 里 original 也没有 `language`。
- 不带标签的文件，IINA / VLC 这类播放器当成视频的**默认字幕**，挑语言的菜单里分不清它是哪一种。真实场景就是这样：本机没装
  翻译语言时，AI 会自己翻好再用 `edit_subtitles` 写进去。
- 导出面板「高级」里的「导出字幕文件」同一个缺口（同一个起名函数、同一个来源）。

## 根因

- `AISubtitleFileExport`（AI）和 `SubtitleFilesExport.targets`（面板）只读 `state.subtitleCompanion?.sourceLanguage` /
  `targetLanguage`，交给 SrtFlowCore 的 `SubtitleExportPlanner.fileName`，缺标签就省略。
- 这两个字段只有三条路会写：生成字幕（`replaceSubtitleForGeneration` 记转写用的语言）、翻译（`applyTranslations` 记目标语言）、
  配音字幕（`AIVoiceoverSubtitles`）。手写（`edit_subtitles`、字幕表的 +）、导入（`attachSubtitle`、`add_clips` 的 .srt）的轨什么都
  不记 —— 导入还顺手把整个 companion 清掉（换原文照旧清译文）。
- 2026-10-15 早上写 export_subtitles 时，自检只造了「记了语言」和「都没记」两种输入，没记语言那条的期望写成了 `Talk.vtt` +
  `Talk.translation.vtt` —— 把症状钉成了对的。写期望值之前没问一句「这个字段从哪来、哪几条路不写」。

## 修复

- 新文件 `Sources/SrtFlow/SubtitleFileLanguage.swift`：每条轨的标签依次取 —— **按这条轨现在的文字判**（`AITextLanguage.dominant`，
  和 translate_subtitles 同一个函数）→ 判不出来用工程记的 → 都没有才省略。先按文字、再信记录，和 translate_subtitles 认原文语言
  同一个顺序（AI 可能把整轨改写成别的语言而记的还是旧的，[2026-09-27 案例](2026-09-27-ai-translation-stale-source-language.md)）。
  判出来的只用来起名、不写回工程。按写进文件的那份句子判（`subtitleDocument(for:)`，藏起来的不算）。
- AI（`AISubtitleFileExport`）和导出面板（`SubtitleFilesExport`）都改成从它取；「两条轨标签一样时译文那份用 translation」照旧
  （`AISubtitleFiles.targets`）。
- 面板上语言识别不在 body 里跑（[预览性能 ratchet](../architecture/preview-perf-ratchet.md) 的规矩）：标签放 `@State`，
  `onChange(of: SubtitleFileLanguage.Inputs(exportState), initial: true)`，句子或记录变了才重判。
- 工具说明补一句标签从哪来（`MCPSubtitleExportTools`）；长期约束写在 [AI 接口 §4 第 49 条](../architecture/ai-control-mcp.md) 和
  [导出设置](../architecture/export-settings.md)。

## 验证

- `scripts/check-mcp.sh` 的 `SubtitleFileChecks`：没记语言时英文原文 + 中文译文 → `en` / `zh-Hans`；只有数字判不出来 → 退回记的
  `en` / `ja`；都没有 → 没标签；中文文字 + 记的 `en` → `zh-Hans`（文字先于记录）；从时间线读：藏起来的那句中文不算、原文按剩下的
  英文判，起出来的名字是 `Talk.en.vtt` + `Talk.zh-Hans.vtt`（以前是 `Talk.vtt` + `Talk.translation.vtt`）。
- `checks/MCP/tool-result-wiring.sh`：AI 的工具和导出面板都经 `SubtitleFileLanguage.tags(`、把 `languages.source` / `target` 交给
  起名，不再直接传 companion 记的语言。
- 反向验证（不合并的草稿 PR，CI）：见文末「反向验证」。
- 测试版复测：待 0.18.31 装上后按本案例的症状步骤重走（见文末）。

## 教训 / 防回归

- **自检的输入要覆盖「这个字段没人写」的那一路。** companion 的语言只有生成 / 翻译会写，手写和导入的轨从来没有；写期望值之前
  先问这个值从哪来、哪几条路不写 —— 不然自检把症状钉成了对的。
- **同一个判断别造第二份。** 「这条轨是什么语言」translate_subtitles 已经有一套顺序（文字 → 记录），起名直接用它；界面和 AI 的
  工具从同一份数据起名，就共用一处（`SubtitleFileLanguage`）。
