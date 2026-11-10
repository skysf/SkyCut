# 声音库：克隆的参考录音（声音库本身和变声做到时补进来）

> 2026-11-10 起生效（SkyCut 声音 PR 2 `feat/voice-reference-sample`）。方案和拍板在仓库外：`SkyVoiceForClone/plan-drafts/SkyCut-声音方案.md`
> 第六节、9.1 第 3 条，`SkyVoiceForClone/决定汇总-2026-11-09.md` 第三节第 3 条、第七节第 2 条；服务器那边怎么查录音见
> `SkyVoiceForClone/plan-drafts/Sky-Studio-声音方案.md` 3.3、3.4。这里只放长期约束。
> 声音库（`list_voices` / `manage_voices`，声音 PR 6）、新建声音的界面（PR 8）、变声（`change_voice`，PR 9）做到时补进这份文档。
> 相关：[Sky Studio 的任务](sky-studio-jobs.md) 第五节（云端旁白 / 克隆）、[阻塞的媒体读取](blocking-media-reads.md)、[写代码的规范](coding-standards.md)。
> 案例：[克隆的参考录音被降到 16 kHz、默认只截 10 秒](../bugfixes/2026-11-10-voice-reference-16khz-short-sample.md)。

## 一、参考录音的规格（和 Sky Studio 3.4 同一个口径）

| 项 | 规矩 | 为什么 |
| --- | --- | --- |
| 格式 | **44.1 kHz 单声道 16-bit PCM WAV**（`VoiceReferenceSample.wavData`，44 字节的头） | 同一段 10 秒中文参考：16 kHz 版 zonos2 读出 44 秒、后半段跑稿，44.1 kHz 版正常（`zonos2-test-2026-11-08` zh-A / zh-B）；之后各轮实测都用这个规格 |
| 最短 | 至少 **10 秒有效人声**（第二节） | MiniMax 克隆的硬要求（`round5-2026-11-09` B 节「接口文档的参考要求」） |
| 最长 | 3 分钟；超过就挑一段（第三节），终点在 3:00 前后 1 秒内，整段**不到 181 秒** | 决定第三节第 3 条；服务器只守上限 180 秒、容差 1 秒 |
| 上传 | `/uploads` 的 purpose **`voice_reference`**、`audio/wav`（`VoiceReferenceSample.uploadPurpose` / `contentType`，只在这里写） | 决定第七节第 2 条：上限 35 MB（十进制）；3 分钟单声道约 16 MB |
| 存几段 | 每个声音按语言各存一段（声音库，PR 6） | 决定第三节第 3、7 条 |

不做：判断有没有背景音乐、是不是一个人在说（本机没有可靠的办法），只在界面和说明书里写提示（方案第六节）。

## 二、有效人声怎么数（SkyCut 和服务器必须一样）

- 要上传的 16-bit 采样按服务器解码的方式换回 Float（÷ 32768），从文件开头起 **20 ms 一格**（44.1 kHz 是 882 个采样），
  一格的均方根 **≥ −45 dBFS**（`AIVoiceLevel.activeFloor` = 0.0056，配音音量数「说话部分」的同一个门限）就算有声；
  **有效人声 = 有声的整格数 × 20 ms**，不满一格的尾巴不算。
- 规则只在 `VoiceReferenceWindow` 一处（`Meter` 量响度、`voicedFrames` 数格、`minimumVoicedFrames` = 500）。挑段时按它数，
  写好的采样再按它数一遍（`VoiceReferenceSample.voicedSeconds(of:)`）：不到 10 秒不写文件、不上传，报错说还差几秒，
  结构化的 `reason` 是 `too_little_speech`，和服务器的同名。
- 服务器的兜底（Sky Studio 3.4 第 4 条「按 −45 dBFS 门限数有能量的帧」）要用同一个格子和门限，或者比它宽；
  比 SkyCut 严，就会出现 SkyCut 收了、服务器拒（`too_little_speech`）的情况。

## 三、挑哪一段（`VoiceReferenceWindow.choose`，纯值）

1. 不到 3 分钟（≤ 180 秒）用整段，`autoSelected` = false。
2. 超过 3 分钟：
   - **起点**：这段声音的开头，或一个停顿之后的开口前 40 ms（开口 = 停顿后第一个有声的格）；
   - **终点**：落在 3:00 前后 1 秒内的停顿里、离停顿两头至少 40 ms（取最早够得着的那个格子边）；或者就是这段声音的尽头（够得着的话，用真实时长）；
   - **停顿** = 连续 ≥ 0.2 秒（10 格）都低于门限，开头、结尾的静音也算；更短的小停顿不切（`round5-2026-11-09` B 节「切口修正」：60 ms 的短静音切出过半个词）。
3. **打分**：有效人声多的赢；一样多比前 15 秒谁更密（IndexTTS2 上游只用参考的前 15 秒）；再一样取早的、短的。
4. 哪个起点都找不到自然的终点（一直有声、没有 0.2 秒的停顿）才退一步：终点放在 3:00 前后 1 秒里最安静的格子边上（两边两格加起来最轻，一样轻取早的）。
5. 结果说清用了哪一段：`VoiceReferenceSample.Sample` 带原文件里的起止秒、有效人声、`autoSelected`，`summary(name:)` 是写给 AI / 用户的那一句
   （「Voice sample: 1:12–4:12 of talk.mov, 2 min 41 s of clear speech, picked automatically …」）；以后 `POST /voices` 的 `source` 带起止秒和 `auto_selected`（PR 6）。

和方案的一处不同：方案写「每 0.5 秒滑一次」，实现直接枚举全部合格的起点（开头和每个停顿后的开口）——那种滑法挑得到的起点都在里面，结果只会更好；
每个起点二分找终点，几小时的文件也只是「停顿数 × log」。

## 四、读和写（`VoiceReferenceReader` / `VoiceReferenceSample`）

- AVAssetReader 直接按 44.1 kHz 输出 Float；立体声取左右平均，多于两声道先让 AVFoundation 按立体声布局混下来（同 `AIListenAudioWindow`）。
- 按 PTS 落到采样格上：第 n 个采样就是 `from + n / 44100` 秒，缺的补零、重叠的丢掉——AAC 的编码延迟、包边界都不挪时间，挑段算的时间和截出来的采样对得上。
- **两遍**：先把给的那一段整个读一遍、只留 20 ms 的响度（几小时的视频也只占几 MB），挑完再只截那一段写 WAV；
  44.1 kHz 16-bit 单声道的源一个采样都不变（量化是 ×32768 四舍五入，和解码时的 ÷32768 互逆）。
- 阻塞的读取只在 `MediaReadQueue.analysis` 上跑；reader 的 `cancelReading` 只在读取体自己的 defer 里，外面的取消只置停止标记
  （[阻塞的媒体读取](blocking-media-reads.md)「读取中的取消与释放」）。字幕生成的 `AudioWindowReader`（16 kHz、async 里读的那个例外）不许再拿来做参考录音。
- 文件写在调用方给的文件夹里，名字 `reference.wav`；被拒、被取消都不留文件。

## 五、谁在用

- **现在**：`add_voiceover` 的 `clone_from`（`SkyStudioVoiceCloudBatches.uploadReferenceIfNeeded`，只做一次、只传一次）。给了 `clone_seconds` 就是那一段
  （不到 10 秒当场拒，`AIVoiceoverInput.cloneSource`），不给就从 `clone_start` 到结尾、超过 3 分钟自动挑；用了哪一段写进恢复记录的声音说明，
  落地时随 `voice.note` 报给 AI（恢复也带着）。
  **这条旧路在过渡期哪个服务器都走不通**：现在线上的 Sky Studio 不认 `voice_reference` 这个用途；新的声音服务（Sky Studio 声音 PR）的 `voice_clone`
  不再收 `inputs.reference_audio_url`。声音 PR 6 用 `manage_voices create` 取代它并删掉 `clone_from`（决定第七节第 8 条；过渡期不能克隆，用户已接受，决定第十二节）。
  MCP 清单里 `clone_seconds` 的说明（5–30、默认 10）是旧的，留到声音 PR 3 / 6 和清单一起改（这一刀不碰清单）。
- **以后**：`manage_voices create` / `add_reference`、设置里的新建声音对话框（声音 PR 6、8）都只调 `VoiceReferenceSample.prepare`。

## 六、回归

| 检查 | 守什么 |
| --- | --- |
| `scripts/check-mcp.sh` 的 `VoiceReferenceChecks`（纯值） | 10 秒下限、3 分钟上限、门限就是 `AIVoiceLevel.activeFloor`；整段、人声多的那段、一样多比前 15 秒、再比早；切口只在 ≥ 0.2 秒的停顿里且离两头 40 ms、尽头能当终点、一直有声时退到最安静的格子边；和照规矩直写的穷举对 16 组随机样本（含只有小停顿的）；分块量的响度 = 一口气量的；WAV 头、量化往返、写给 AI 的那一句、上传用途 |
| `scripts/check-mcp.sh` 的 `VoiceReferenceFileChecks`（真读真写） | 现写素材走生产的 `prepare`、把写出来的 WAV 按字节读回来：44.1 kHz 16-bit 的源逐采样不变；48 kHz 立体声 4 分钟挑在说话密的 3 分钟、开口前起、到尽头、不到 181 秒、左右取平均；点名的一段原样截；AAC 的时间对得上；只有 8 秒人声的拒、说还差 2 秒、不留文件；取消不留文件 |
| `scripts/check-voice-recovery.sh`（真 App 对象） | 克隆的参考只上传一次、用途 `voice_reference`、传上去的是整段 12 秒的 44.1 kHz 单声道 16-bit；恢复记录和最终结果说用了哪一段；`clone_seconds` 不到 10 秒当场拒、不给就到结尾、不再夹在 30 秒 |

反向验证（2026-11-10）：

1. `VoiceReferenceReader.sampleRate` 改回 16 kHz → `VoiceReferenceChecks` 的采样率 / WAV 头、`VoiceReferenceFileChecks` 的逐采样往返、`check-voice-recovery` 的上传头全红。
2. `minimumVoicedFrames` 改回 3 秒（150 格）→ 10 秒下限、9.98 秒不够、8 秒人声被拒三条红。
3. 上传用途改回 `audio` → `VoiceReferenceChecks` 的用途和 `check-voice-recovery` 的上传断言红。
4. 终点不再要求离停顿两头 40 ms、或停顿下限改成 0.18 秒 → 穷举对账和「小停顿不切」红。

恢复后全绿（详细输出记在 PR 正文）。

## 七、人工回归（真 Key；声音库上线、新建声音的界面做好之后）

- [ ] 新建声音：录 10 秒（刚够）、录 45 秒、选一个 3 分 30 秒的文件：说出用了哪一段，试听那一段（方案 9.3，声音 PR 8）。
- [ ] SkyCut 算出刚好 10 秒多一点有效人声的样本，服务器不回 `too_little_speech`（两边口径一致）。
- [ ] 一段 3 分钟以上、背景有一点噪声（比 −45 dBFS 响）的录音：噪声也会被当成「有声」，挑段只按响度——确认界面的提示（一个人说、没有背景音乐）写到了。
