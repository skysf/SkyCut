# 2026-11-10 克隆的参考录音被降到 16 kHz、默认只截 10 秒

## 症状

- `add_voiceover clone_from` 的参考录音一律截成 **16 kHz** 单声道 WAV，默认 **10 秒**、夹在 5–30 秒。2026-11-08 的 zonos2 实测
  （仓库外 `SkyVoiceForClone/zonos2-test-2026-11-08/README.md`）：同一段 0–10 秒的中文参考，16 kHz 版读出 44.4 秒、后半段跑稿（zh-A），
  44.1 kHz 版 18.1 秒、正常（zh-B）。之后各轮盲测（IndexTTS2、MiniMax、HeyGen）的参考都是 44.1 kHz 单声道 16-bit。
- 报错说「至少 5 秒」（"for at least 5 seconds"），实际 3 秒就收。
- 新的克隆模型（MiniMax）要**至少 10 秒有效人声**：默认的 10 秒窗口只要中间有停顿就不够；用户给一段几分钟的录音，也只用得上前 10 秒。

## 根因

1. 参考段复用了字幕生成的 `AudioWindowReader`：它输出 16 kHz / 16-bit / 单声道，是给 SpeechAnalyzer 的格式，不是给克隆模型的。
   「能读出 PCM」就顺手拿来用，没人问过克隆模型要什么采样率。
2. 默认 10 秒、最长 30 秒是 zonos2 时代随手定的，没有依据；决定（第三节第 3 条）改成 10 秒有效人声到 3 分钟、超过自动挑一段。
3. 门限（`samples.count >= 16000 × 3`）和报错里的数字（5 秒）各写各的，后来改了一边。
4. `AudioWindowReader.extract` 是「async 函数里跑 `copyNextSampleBuffer` 循环」的唯一例外，理由只对字幕生成成立（严格一个窗口一个窗口读）；
   克隆参考借用它，就越出了那个理由（[阻塞的媒体读取](../architecture/blocking-media-reads.md)「例外」）。

## 修复

- 新的纯值 `VoiceReferenceWindow`：20 ms 一格的响度 → 有效人声（≥ −45 dBFS，同 `AIVoiceLevel.activeFloor`；同一天审查后改成单独写死的合同常量 0.0056、服务器放宽到 0.0055，见 [门限借了配音响度的常量](2026-11-10-voice-reference-floor-borrowed-from-voice-level.md)）、10 秒下限、3 分钟上限，
  超过 3 分钟挑有效人声最多的一段（切在 ≥ 0.2 秒的停顿里、离两头 40 ms；一样多比前 15 秒）。下限和报错里的数字都从 `minimumVoicedFrames` 来。
- 新的 `VoiceReferenceReader`：AVAssetReader 直接出 44.1 kHz，立体声取平均，按 PTS 落格；阻塞读取只在 `MediaReadQueue.analysis` 上，取消只置标记。
- `VoiceReferenceSample.prepare`：先整段量响度、挑段，再只截那一段写成 **44.1 kHz 单声道 16-bit WAV**，写好的采样再数一遍有效人声；
  上传用途改成 `voice_reference`（`uploadPurpose`）。不再用 `AudioWindowReader`。
- `AIVoiceoverInput.cloneSource`：去掉「默认 10、夹在 5–30」；给了 `clone_seconds` 就是那一段（不到 10 秒当场拒），不给就到结尾、自动挑。
- 用了哪一段写进恢复记录的声音说明，落地时随 `voice.note` 报给 AI（`SkyStudioVoiceCloudBatches` / `SkyStudioVoiceoverRun`）。
- 长期约束（规格、两边一致的有效人声口径、挑段规则、谁在用）写进 [声音库](../architecture/voice-library.md)。

## 验证

- `scripts/check-mcp.sh` 的 `VoiceReferenceChecks`（纯值、和穷举对账）与 `VoiceReferenceFileChecks`（现写素材真走 `prepare`、把 WAV 按字节读回来）；
  `scripts/check-voice-recovery.sh` 用真 App 对象验克隆的上传：一次、`voice_reference`、12 秒 44.1 kHz 单声道 16-bit，结果说用了哪一段。
- 反向验证：采样率改回 16 kHz、下限改回 3 秒、用途改回 `audio`，对应的守卫都变红；恢复后转绿（明细见 [声音库](../architecture/voice-library.md) 第六节和 PR 正文）。

## 教训 / 防回归

- **给模型的音频格式按那个模型定**，别顺手复用给另一个系统（转写）的读取器；复用之前先问「它的输出规格是为谁定的」。
- 门限和报错里的数字只许一处定义，报错从常量算。
- 两边都要检查的量（这里是有效人声），定义要写到格子、门限、尾巴怎么算，并且两边对一遍；写在 [声音库](../architecture/voice-library.md) 第二节。
- 「async 里读」的例外只对写明理由的那一处成立；新的读取一律交给 `MediaReadQueue`。
