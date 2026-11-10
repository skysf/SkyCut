# 2026-11-10 云端配音的字幕显示的是这台 Mac 听成的字，不是稿子

## 症状

用 Sky Studio 的声音配旁白、要字幕（`add_voiceover subtitles=true`），而读的模型不报每个字的时间（克隆读稿的 IndexTTS2 / MiniMax / HeyGen，
声音 PR 3 起的 Gemini 预设）时，字幕的字是这台 Mac 把成品转写一遍**听出来的字**，不是 AI 写的稿子：

- 稿子写「SkyCut 每天做 20 条视频」，字幕可能是「Sky cut 每天做二十条视频」；
- 英文的数字、品牌名、生僻词被识别器换成它听成的写法，大小写、标点也跟着识别器走。

声音本身是对的，只有字幕的字不对。2026-10-29（`977d041`，克隆和云端旁白接进 Sky Studio）起就这样；那时只有多句克隆走转写，
声音 PR 3（2026-11-10）把 Gemini 预设的字幕也交给转写之后，普通旁白也会碰上。

## 根因

`SkyStudioVoiceRender.analyze` 在模型没报字的时间时把整批转写一遍，转写出来的 `[TimedWord]` 有两个用处：

1. 找句界（`SkyStudioVoiceSplit.slices`）—— 这一步用 `SubtitleCueWords.realigned` 把识别出来的词对回原文，只取切口的时间，是对的；
2. 当这一句的字幕的词 —— `finish` 把落在这一句时间里的识别词**原样**交给 `SpeechWordTimes.timedWords`，那个函数只核对字母数
   差不多（70%–130%），不换字，于是 `AIVoiceoverSubtitles.add` → `SubtitleSegmenter` 拼出来的字幕就是识别器的写法。

`SpeechWordTimes.timedWords` 原本是给 Eleven 的字符时间用的（那些字就是原文的字，原样用没问题），转写的词借了同一条路，
「字对不对」这件事没人管。检查里的假转写就是把原文按空格切开，听成的字和原文一模一样，所以一直绿。

## 修复

声音 PR 5（`feat/voiceover-subtitle-timing`，SkyCut 声音方案第七节「本机转写，再按原文对齐」）：

- 新的 `SpeechWordTokens`：原文按字幕那一套的写法切成词（中日韩一个字一个词、别的按空白分、标点贴前一个词、原文词前的空白留一个空格）；
- 新的 `SpeechWordAlignment.aligned`：识别出来的词（或 Eleven 报的字）按 `SubtitleCueWords` 对到原文上，**词用原文的、时间用对上的字的**；
  一个识别词盖住几个原文词时按份数分它的时间，没对上的原文词夹在两边对上的词中间分空当；对上的字不到原文字母数字的 65% 就算对不上；
- 对不上（或这一句有一片没拿到词）：这一句按字数估（`SpeechWordEstimate`），结果里标 `estimated`，整段不失败（声音是好的）；
- `SkyStudioVoiceRender.finish` 所有要字幕的句子都走这一步（在 `MediaReadQueue.voice` 上做，逐字的最长公共子序列不占主线程）。

## 验证

- `scripts/check-voice-recovery.sh`（真 App 对象）`TimingChecks.swift`：假转写把「SkyCut」听成「Sky cut」、「20」听成「twenty」，
  入轨后的字幕里是「SkyCut」「20」，没有「Sky cut」「twenty」。**反向验证**：`finish` 换回用识别出来的词（对上了也交 `heard`）→ 这一条红。
- `scripts/check-sky-studio.sh` 的 `VoiceTimingChecks`：对齐的纯值（听成两个词的「SkyCut」拿两段时间、没对上的「20」分空当、
  简体的转写对繁体的稿子显示繁体、对不上的回 nil、时间不倒退）。
- 反向验证的完整记录在声音 PR 5 的说明里（13 处单独弄坏、各自变红、恢复后工作区和提交一致）。

## 教训 / 防回归

- **给字幕的词，字从稿子来，时间从别处来**。转写、语音服务报的词都只是「时间的来源」；凡是要把它们变成字幕，先对到原文上。
  长期约束写进 [Sky Studio 的任务](../architecture/sky-studio-jobs.md) 第五节「字幕时间」。
- 假转写要会「听错」：`VoiceRecoveryFixture.mishear` 把指定的词换成别的写法，`garbleAt` 让某一批整个听成别的话 ——
  只会照抄原文的假转写测不出「字对不对」。
