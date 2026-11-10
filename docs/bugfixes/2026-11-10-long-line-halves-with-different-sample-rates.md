# 2026-11-10 一句太长拆成两批，一半 Gemini 读、一半 Eleven 读，接不起来

声音 PR 3–5 合并后的深度审查（只读）发现的，没有等用户撞上。

## 症状

一句超过一批上限的旁白（900 个字符的英文句子；AI 写的 320 字一整段的中文）拆成两批读。其中一批在服务器上换了备用
（`fallback_used: true`，默认的 Gemini 碰上一次 429 / 400 / 500 就会），两批都做完、都扣了积分，任务却以
`failure_stage: local_split` 失败：「Sky Studio changed the audio format between parts of a line; all complete batches were kept.」
每次 `resume` 都一样。

## 根因

`SkyStudioVoiceRender.append` 把一句的几片采样直接拼在一起，发现两片采样率不一样就抛错、不重采样。
而两个读稿模型的格式本来就不一样：Gemini 回 24 kHz 单声道 WAV，Eleven v4 回 44.1 kHz 的 MP3
（Sky Studio 的 `docs/agents/skycut-api.md`、`api/_utils/voice/providers.ts`），Gemini 的自动备用正是 Eleven。

声音 PR 4 让这条路撞得上：几批**同时**交（`SkyStudioVoiceBatchQueue`），`switchToFallback` 只改得到还没交出去的批 ——
装着长句一半的那批换了备用时，另一半所在的那批已经在 Gemini 上跑了。反过来（后一半那批换备用）也一样。

为什么守卫没抓到：`ConcurrencyChecks.longLineChecks` 的两半用的是同一个假的 44.1 kHz WAV；假协议不管哪个模型读都回同一份文件。

## 修复

- 新的 `SkyStudioVoiceLineAudio`（一句的几片接成一条）：采样率不一样就都换到**高的那个**再接（`AVAudioConverter`，拉式喂、
  最高质量），不丢任何一片的高频；出来的帧数正好是「原来的时长 × 新采样率」，所以词的时间（秒）不用动。
  这一片在整句里从第几秒开始按接上之前的时长算（原来按这一片自己的采样率除，两片不一样时就错了）。
- `SkyStudioVoiceRender` 不再自己存采样和采样率，交给它；换采样率在 `MediaReadQueue.voice` 上算。
- `SkyStudioVoiceCloudBatches.switchToFallback` 补一句注释：已经抄好请求、还没 POST 的那一批够不着，不碍事。

两半是两个模型读的、听起来可能不一样，这件事早就有地方说（`line_models`、`voice.note` 的 `mixedModelsNote`），这次不动。

## 验证

- `scripts/check-voice-recovery.sh` 的 `PaidAudioChecks`：
  - `resampleChecks`：24 kHz 里 1.000 秒处的一下「嗒」换到 44.1 kHz 还在 1.000 秒（±1 ms）、帧数正好 88,200；440 Hz 的音还是 440 Hz；
    24 k / 44.1 k / 24 k 三片接出来 3 秒、每片从上一片结束的地方开始。
  - `mixedRateChecks` 两种先后（后一半换备用、前一半换备用）：假协议给 Gemini 的那批回 24 kHz（`lowRate`），任务 `done`、
    一段 12 秒、文件是 44.1 kHz、后半的第一个词在 6 秒前后开口、`line_models` 记着换过备用。
- 反向验证（2026-11-10）：采样率不一样照旧抛错 → 9 条红（两个场景都是 `failed` / `local_split`、就是那句话）；
  不换采样率直接拼 → 4 条红（时长 17.0 秒 / 9.3 秒、文件 24 kHz）。恢复后全绿。
- 没验到的：真的 Gemini WAV 接真的 Eleven MP3 的接缝听感（两个声音本来就不一样），列在人工回归里。

## 教训 / 防回归

- **「两半一定一样」是假协议替生产代码做的假设**：假服务对每个模型都回同一份文件，于是「格式不一样」这条分支从没被走过，
  里面写的是抛错。假协议现在按模型回不一样的格式。
- **改并发（PR 4）会让以前串行时撞不上的组合变成常态**：一批一批交时，换备用之后的批都跟着换，两半总是同一个模型。
  改成同时交之后，要把「前后两批不是同一个模型」的每个后果过一遍。
- **付过钱的东西，格式不合就转，不报错**：本地能补救的不要变成用户的死路。写进
  [Sky Studio 的任务](../architecture/sky-studio-jobs.md)第五节「本机切句」。
