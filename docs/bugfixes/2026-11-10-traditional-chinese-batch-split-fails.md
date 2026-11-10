# 2026-11-10 繁体中文的旁白合成一批之后切不开，付过钱的声音卡死

声音 PR 3–5 合并后的深度审查（只读）发现的，没有等用户撞上。

## 症状

macOS 26 上，用 Sky Studio 的声音读两句以上的**繁体中文**旁白：报价、扣积分、下载都成功，然后任务以
`failure_stage: local_split` 失败（「SkyCut could not align the cloned speech with the lines…」）。照提示 `resume`：重新转写、
同样失败；`generate_missing` 又没有东西可补。声音文件在恢复目录里，可永远进不了时间线。

## 根因

两处，都在「稿子是繁体」这条没人走过的路上：

1. **切句对字没有折叠繁简。** 一批几句要靠这台 Mac 的转写找句界（`SkyStudioVoiceSplit.slices`）：识别出来的字按最长公共子序列
   对回原文，每句对上的字不到 65% 就整批拒绝。`SubtitleCueWords.realigned` / `matchingCharacterCount` 有 `foldsChineseScript`
   这个开关，声音 PR 5 新写的逐句对齐（`SpeechWordAlignment`）开了，切句这一关没开 —— 而切句在前面，根本走不到对齐。
   转写写成简体时，繁体稿里和简体写法一样的字只有一半上下（审查量的五句：48% / 67% / 74% / 48% / 70%）。
2. **转写用的语言丢了字形。** `AIVoiceoverInput.read` 用 `AIVoiceChoice.baseLanguage` 把 `zh-Hant` 收成 `zh`（目录的上限、
   预设的语言都按 ISO 639-1，这没错），可同一个 `zh` 又拿去问 `SpeechTranscriber.supportedLocale(equivalentTo:)`：
   `zh` → zh_CN，`zh-Hant` → zh_TW（本机探针）。繁体稿于是交给了简体模型，正好踩中第 1 条。

为什么之前没事：声音 PR 5 之前普通旁白一句一单，不走切句；PR 5 让旁白默认合批（`SkyStudioVoiceReading`）。
为什么守卫没抓到：`checks/VoiceRecovery/Fixture.swift` 的假转写原样照抄这一批的字，永远和稿子一模一样；
没有一个场景是「转写写出来的字形和稿子不一样」。

## 修复

- `SkyStudioVoiceSplit.slices`：`realigned` 和 `matchingCharacterCount` 都带 `foldsChineseScript: true`（和 `SpeechWordAlignment`
  同一个口径；只折叠比较用的键，位置和字幕的字照旧是稿子的）。
- `AITextLanguage.speechLanguage(_:texts:)`：这台 Mac 转写用哪种语言 —— 中文按字形分（繁→简会改的字比简→繁会改的多就是
  `zh-Hant`），别的语言原样。不问 `NLLanguageRecognizer`：两种写法一样的短句（「你好」）它判成繁体。
  `AIVoiceoverInput.speechLanguage` 现算（恢复出来的输入也有稿子，不用往恢复记录里加字段）。
- 问转写的两处都用它：报价之前（`SkyStudioVoiceoverStart.quoteAndStart`）、恢复时（`SkyStudioVoiceRender.analyze`）。
  `language`（`zh`）照旧管目录上限、预设、语言名。

## 验证

- `scripts/check-sky-studio.sh` 的 `VoiceSplitChecks`：三句繁体、简体的词（先断言每句相同的字确实不到 65%）切成三句，
  反过来（简体稿、繁体的词）也切得开，不相干的话照旧拒绝；`speechLanguage` 的六种输入。
- `scripts/check-voice-recovery.sh` 的 `PaidAudioChecks.traditionalChecks`（真 App 对象）：假转写写成简体（`simplifies`），
  一次付费请求、三段、字幕是稿子的繁体字；问转写时带的语言是 `zh-Hant`，起任务时和 `resume` 时都是。
- 反向验证（2026-11-10，合并 #362 之后的代码上）：去掉两处 `foldsChineseScript` → 纯值 1 条红（`Problem()`）、真 App 4 条红
  （`failed` / `local_split`，就是审查说的那句）；两处问转写改回 `input.language` → 2 条红（`["zh"]`、`["zh", "zh"]`）。恢复后全绿。
- 没验到的：真的 zh_TW 模型转写真的繁体配音（要真积分和真模型），列在 [Sky Studio 的任务](../architecture/sky-studio-jobs.md)第七节的人工回归里。

## 教训 / 防回归

- **同一个口径的两处，一处开了开关、另一处没开**：「对上的字不到 65% 算对不上」在切句和对齐各有一份，新写的那份带了折叠，
  老的没跟上。带默认值的参数（`foldsChineseScript: Bool = false`）漏写编译器不吭声 —— 加这种开关时把所有调用点过一遍。
- **假转写不能原样照抄稿子**：识别器写出来的字和稿子不一样才是常态（繁简、数字、品牌名）。夹具现在有 `simplifies`、
  `mishear`、`garbleAt` 三种「不一样」。
- **语言标签收窄之前先看谁还要用原来的那一截**：`zh` 对目录够了，对选转写模型不够。规矩写进
  [Sky Studio 的任务](../architecture/sky-studio-jobs.md)第五节「本机切句」。
