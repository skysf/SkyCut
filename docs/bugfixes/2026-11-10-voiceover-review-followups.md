# 2026-11-10 声音 PR 3–5 审查的几处小问题：get_job 看不到换声音的原因、批次上限按整稿的语言、点名模型不说换了声音

和同一次审查的三个大问题（[繁体稿切不开](2026-11-10-traditional-chinese-batch-split-fails.md)、
[两半采样率不一样](2026-11-10-long-line-halves-with-different-sample-rates.md)、
[拿不到字的时间卡死](2026-11-10-packed-batch-without-word-times-stuck.md)）一起修的；这几处不丢钱，只是说错或说漏。

## 症状

1. **重新报价时写的 `voice.note`，运行中和失败后的 `get_job` 都看不到。** 装不上这台 Mac 的转写模型时，任务里按「转写不了」
   再报一次价：Charon 换成了 eleven-v4、预留从 7.5 变成 16 积分。之后任务因为别的原因失败，`get_job` 只给出新的 `voice_plan`，
   没有解释；AI 上次告诉用户的还是「Gemini Charon」。（PR #361 的正文说看得到。）
2. **英文为主、夹一行 350 字中文的稿子在 `/quote` 被拒**，报错里写的是 `params.batches[1]`，AI 对不上是第几句。
3. **Gemini 的预设点名 `model=eleven-v4`**：服务器用这个预设的 Eleven 替身读，`voice.name` 还是 `gemini:Charon`，也没有
   「声音会不一样」的提示。

## 根因

1. 那句话只存在 `input.choice.note` 里，只有落地的结果（`AIVoiceoverTool.apply`）才把它写进 `voice`；`SkyStudioVoiceoverRun.detail()`
   和恢复记录的 `detail` 都没有 `voice` 这个键。
2. 分批的上限按**整稿**的主要语言定（`voiceCharacterLimit(kind:language:)`），服务器却按**每一批自己**的主要语言卡
   （Sky Studio `api/_utils/voice/quote.ts` 的 `checkTextLimits`）。
3. 「声音不一样」那句只在为了字幕时间整段换模型（`switchedForTiming`）时才加；用户自己点名的那条路没有。

## 修复

1. `SkyStudioVoiceoverRun.detail()` 带 `voice`（名字、质量、`note`）：运行中、没做成之后都有；落地的结果里有它自己的一份、盖过这一份。
   重新报价那句话挪到预留之前记（新的预留留不下时 AI 也看得到为什么贵了）。
2. 每句按它自己的字定上限（`SkyStudioModel.characterLimit(text:)`）：取这段字里**出现了的**每种文字的上限里最小的那个
   （汉字 `zh`、假名 `ja`、谚文 `ko`，别的字 = 表里其余的键）。服务器哪种语言算主要是按语速估的，SkyCut 不抄那套算法 ——
   取最小的一定不超过它卡的数。`SkyStudioVoiceBatch.make` 收「这一句的上限」，一批的上限是它装着的几句里最小的。
   代价：英文稿里带几个汉字的那一行按 300 分（原来 800），多分几批，不多花钱。
3. 服务器选的声音（`voice_plan.selection.voice`）和点的不是同一个时，`voice.note` 说实际是谁读的、听起来不一样、叫 AI 转告。
   `voice.name` 照旧是点的那个预设（和整段换模型那条路一样，恢复记录也按它记）。

审查里另一条（`resume` 的拒绝文字没提 `confirm_token`）声音 PR 6（#362）已经改了，合并时取了它的那一份。

## 验证

- `scripts/check-voice-recovery.sh` 的 `PaidAudioChecks.voiceNoteChecks`：装不上模型、重新报价之后云端失败 → 失败的 `get_job` 的
  `voice.note` 说了为什么换成 eleven-v4；同样的任务卡在排队时读运行中的 `get_job` 也有；点名 eleven-v4 时回任务号的 `voice.note`
  说了替身是谁（假协议现在照服务器的样子把选择里的声音换成替身）。
- `scripts/check-sky-studio.sh` 的 `VoiceSplitChecks.batchLimitChecks`：对着目录快照，各种文字的上限；英文稿夹 350 字中文，
  每一批都放得进它自己那几种文字的上限、那一行在句末分成两片、一个字不丢；纯英文照旧 800 一批。
- 反向验证（2026-11-10）：`detail()` 不带 `voice` → 2 条红；不加点名模型那句 → 1 条红；上限按整稿的语言 → 2 条红（一批 635 字）。恢复后全绿。

## 教训 / 防回归

- **PR 正文里写「看得到」的，要有一条检查去看**：这句话是推出来的，不是量出来的。
- **客户端替服务器预先分批时，分的规矩要按服务器检查的那个单位**（每一批），不是按整段。抄不了它的算法就取保守的那个。
- 规矩在 [Sky Studio 的任务](../architecture/sky-studio-jobs.md)第五节（合批、先报价再回任务号）。
