# 2026-11-10 转写不了的 Mac 上，合成一批的 eleven-v4 旁白拿不到可用的字的时间就卡死

声音 PR 3–5 合并后的深度审查（只读）发现的，没有等用户撞上。

## 症状

这台 Mac 转写不了这种语言（macOS 15，或者系统不支持的语言），用预设声音配带字幕的旁白：SkyCut 整段改点名 `eleven-v4`
（它报每个字的时间）、几句合成一批。批做完、扣了积分，可 Eleven 这次的 `words` 用不了，任务以 `failure_stage: local_split`
失败：「This Mac cannot transcribe … speech」。`resume` 多少次都一样 —— 这台 Mac 就是转写不了。

## 根因

`SkyStudioVoiceRender.analyze` 里，一批几句（`splits`）而模型报的词是空的，就去转写；转写的语言问不到（这台 Mac 转写不了，
正是因此才换的 eleven-v4），抛错、包成 `.localSplit`。同样的情况只有一句的批会按字数估（`SpeechWordEstimate`），合批的没有兜底。

`SpeechWordTimes.timedWords` 在这几种时候交回空的：报的字母数不在稿子的 70–130% 之间、有一块时间倒退、`words` 是 `null`。
另外一种同样卡死：词不是空的，可对不回原文（`SkyStudioVoiceSplit.slices` 拒绝）。

声音 PR 5 让它每批最多装 800 字；之前这条路一句一单。两个 PR 都没碰过真的 Eleven `timestamps`。
为什么守卫没抓到：没有一个场景是「转写不了的夹具 + 合成一批 + Eleven 的 `words` 用不了」，假协议的字符时间永远整整齐齐。

## 修复

- 新的 `SkyStudioVoiceSplitEstimate`（纯值）：没有词可对时按字数估句界。整批当一句估（`SpeechWordEstimate`：开口和收尾按响度，
  中间按份数摊），每句头尾的时刻是估的句界；切口不直接落在那里，在它前后一小段（相邻两句里短的那句的四成，0.3–1.5 秒）里找
  **最长的安静窗**、切在正中（两句之间的换行通常是这一段里最长的停顿），一点安静都没有才切在估的位置；一刀比一刀晚、每句至少 50 毫秒。
- `SkyStudioVoiceRender.analyze`：计划里定的是「这台 Mac 转写不了」（`plan.reading.transcribes == false`）而一批有几句时，
  不去转写；模型报的词切不开（没有、用不了、对不回原文）就用上面的估法，不抛错。**转写得了的 Mac 上规矩不变**：切不准照旧
  保留整批、报错、能恢复（那里重试有意义）。
- 估的要说出来：这一批的分析记 `estimatedSplit`；`get_job` 和结果带 `estimated_split_line_indices`，`voice.note` 说这几句的句界是
  按字数估的、可能差一点、叫用户听一下头尾，`next_step` 叫 AI 先转告。这几句没有词，字幕时间照样按字数估（`subtitle_timing: estimated`）。

## 验证

- `scripts/check-sky-studio.sh` 的 `VoiceSplitChecks.estimatedSplitChecks`（100 Hz 的假声音）：估的句界附近有停顿就切在停顿正中
  （估在 3 秒、停顿在 3.3–3.7 秒 → 3.5 秒）、有逗号的短停顿时挑长的那个、很远的停顿不认、没有停顿切在估的位置、一长一短跟着字数走、
  四句一刀比一刀晚、只有标点的一句也有一段、短到分不出来就拒绝。
- `scripts/check-voice-recovery.sh` 的 `PaidAudioChecks.noWordTimesChecks`（真 App 对象，`transcribes = false`）：假协议的
  eleven-v4 回 `words: null`、回对不回原文的字（`brokenWords`）两种，都是一次付费请求、`done`、三段加起来 6 秒、
  `subtitle_timing: estimated`、`estimated_split_line_indices: [0, 1, 2]`、`voice.note` 和 `next_step` 叫 AI 转告、没有转写过。
- 反向验证（2026-11-10）：不估（`estimatesSplit` 恒为 false）→ 两个场景各 5 条红（`failed` / `local_split`：一个是
  「This Mac cannot transcribe English speech」，一个是「could not align…」）。恢复后全绿。
- 没验到的：真的 Eleven `timestamps` 长什么样、什么时候用不了；估出来的句界在真人声上准不准。列在人工回归里。

## 教训 / 防回归

- **「报错、让它恢复」只在重试可能成功时才是办法**：这条路的前提（这台 Mac 转写不了）不会变，报错等于把付过钱的声音扔了。
  写兜底之前先问：同样的输入再来一次，结果会不一样吗？
- **同一种情况的两条路要一起看**：一句的批有「按字数估」，几句的批没有，因为它们在两个分支里。
- **降级了要说出来**：估的句界可能把一句的尾音带进下一句，结果里列出是哪几句、叫用户听。
- 规矩写进 [Sky Studio 的任务](../architecture/sky-studio-jobs.md)第五节「本机切句」。
