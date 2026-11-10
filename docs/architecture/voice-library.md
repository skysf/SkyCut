# 声音库：克隆的参考录音、声音库的工具和界面（变声做到时补进来）

> 2026-11-10 起生效（SkyCut 声音 PR 2 `feat/voice-reference-sample`）。方案：[SkyCut 声音方案](../plans/2026-11-09-voice-features.md)
> 第六节、9.1 第 3 条；拍板在仓库外的 `SkyVoiceForClone/决定汇总-2026-11-09.md` 第三节第 3 条、第七节第 2 条；服务器那边怎么查录音见
> Sky Studio 那份方案（在 Sky Studio 仓库）3.3、3.4。这里只放长期约束。
> 声音库的两个 AI 工具（`list_voices` / `manage_voices`）和用声音库的声音配旁白是声音 PR 6（2026-11-10），全部权限下的长期授权是声音 PR 7
> （2026-11-10），都在第八节；设置里的声音库、声音选择器、新建 / 设计声音的对话框是声音 PR 8（2026-11-10），在第九节；变声（`change_voice`，PR 9）
> 做到时补进这份文档。
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
  一格的**均方根 ≥ 0.0056**（均方 ≥ 3.136e-5，约 −45.04 dBFS，不是精确的 −45 dBFS）就算有声；
  **有效人声 = 有声的整格数 × 20 ms**，不满一格的尾巴不算。
- **门限是和 Sky Studio 的跨仓库合同**：SkyCut 0.0056，服务器的 `too_little_speech` 兜底故意放宽到 **0.0055**（同一个 20 ms 的格子、
  只数满格），吃掉两边浮点和取整的差别，保证服务器只会比 SkyCut 宽、不会更严。SkyCut 这边是单独写死的常量
  `VoiceReferenceWindow.speechRMSFloor`，不借配音响度的 `AIVoiceLevel.activeFloor`——调配音的门限不许把合同带着变
  （扫描守卫 `checks/MCP/voice-reference-wiring.sh`；案例：[门限借了配音响度的常量](../bugfixes/2026-11-10-voice-reference-floor-borrowed-from-voice-level.md)）。
- 规则只在 `VoiceReferenceWindow` 一处（`Meter` 量响度、`voicedFrames` 数格、`minimumVoicedFrames` = 500）。挑段时按它数，
  写好的 16-bit 采样再按它数一遍（`VoiceReferenceSample.voicedSeconds(of:)`；浮点源刚过门限的格子量化之后可能就不够了，以后者为准）：
  不到 10 秒不写文件、不上传，报错说还差几秒，`AIToolError` 带着结构化的 `reason: too_little_speech`（和服务器同名）、`voiced_seconds`、`missing_seconds`。
- 重采样过来的素材（48 kHz、16 kHz、AAC）**正好 10.0 秒**的会被拒：重采样器在结尾少吐约 1 ms，第 500 格不满、不算。服务器数的就是上传的文件，
  结果一样，不算破坏合同；录音要留余量，别卡着 10 秒。

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
   时间都向下取整到秒：180.5 秒的样本写成 3:00、3 min 0 s，不会在「最长 3 分钟」旁边显示 3:01。

和方案的一处不同：方案写「每 0.5 秒滑一次」，实现直接枚举全部合格的起点（开头和每个停顿后的开口）——那种滑法挑得到的起点都在里面，结果只会更好；
每个起点二分找终点，几小时的文件也只是「停顿数 × log」。

## 四、读和写（`VoiceReferenceReader` / `VoiceReferenceSample`）

- AVAssetReader 直接按 44.1 kHz 输出 Float；立体声取左右平均，多于两声道先让 AVFoundation 按立体声布局混下来（同 `AIListenAudioWindow`）。
- 按 PTS 落到采样格上：第 n 个采样就是 `from + n / 44100` 秒，缺的补零、重叠的丢掉——AAC 的编码延迟、包边界都不挪时间，挑段算的时间和截出来的采样对得上。
- **两遍**：先把给的那一段整个读一遍、只留 20 ms 的响度（几小时的视频也只占几 MB），挑完再只截那一段写 WAV；
  44.1 kHz 16-bit 单声道的源一个采样都不变（量化是 ×32768 四舍五入，和解码时的 ÷32768 互逆）。
- 量化（`VoiceReferenceSample.quantize`）先排除坏采样再转整数：浮点源里的 NaN、±Inf 记成 0，特别大的数先在浮点上夹到满幅；
  直接 `Int(_:)` 会让整个 App 崩掉（[坏采样让 App 崩掉](../bugfixes/2026-11-10-voice-reference-nan-sample-crash.md)）。
- 阻塞的读取只在 `MediaReadQueue.analysis` 上跑；reader 的 `cancelReading` 只在读取体自己的 defer 里，外面的取消只置停止标记
  （[阻塞的媒体读取](blocking-media-reads.md)「读取中的取消与释放」）。字幕生成的 `AudioWindowReader`（16 kHz、async 里读的那个例外）不许再拿来做参考录音。
- 文件写在调用方给的文件夹里，名字 `reference.wav`；被拒、被取消都不留文件（读完到写之间再看一次取消，晚到的取消也不写）。

## 五、谁在用

- **现在没有生产入口**：`add_voiceover` 的 `clone_from`（参考录音随读稿现做现传一次）**2026-11-10 在声音 PR 3 里去掉了**（决定第七节第 8 条；
  方案原排在 PR 6，PR 3 改写读稿的流程（先整段报价再回任务号）和恢复记录（version 2）时一起去掉，免得把一条哪个服务器都走不通的旧路搬进新流程：
  线上的 Sky Studio 不认 `voice_reference` 这个用途，新的声音服务的 `voice_clone` 不再收 `inputs.reference_audio_url`）。带 `clone_from` / `clone_start` /
  `clone_seconds` 就是说明上没有的参数名，整个调用不做。过渡期不能克隆，用户已接受（决定第十二节）。同一天 PR #350 加的「报价之前做好参考录音、
  人声不够当场拒并把 `reason` / `voiced_seconds` / `missing_seconds` 带进 get_job」那一段随之删了；`AIToolError.details` 进 get_job 的那一手留着，声音 PR 6 用。
  `VoiceReferenceSample.prepare` 这段时间只有自检在调（第六节）。
- **`manage_voices create` / `add_reference`（声音 PR 6）**：只调 `VoiceReferenceSample.prepare`，在问授权之前就做好（人声不够当场拒、什么都不传）；
  授权的令牌绑做好的那段 WAV 的内容哈希（第八节）。用声音库的声音读稿（`voice=voice_…`）不再传参考，参考从声音库拿。
- **设置里的新建声音对话框（声音 PR 8，第九节）**：选的文件、现录的那个文件都只过 `VoiceReferenceSample.prepare` 这一遍（`NewVoiceModel`），
  没有第二份「够不够格」的算法；界面上「用了哪一段、有效人声多少」就是它回的 `Sample`。

## 六、回归

| 检查 | 守什么 |
| --- | --- |
| `scripts/check-mcp.sh` 的 `VoiceReferenceChecks`（纯值） | 门限是 0.0056（0.0056 和精确的 −45 dBFS 算有声，再小一点和服务器的 0.0055 不算）、10 秒下限、3 分钟上限（正好 3 分钟、结尾有停顿还是整段）；整段、人声多的那段、一样多比前 15 秒、再比早；切口只在 ≥ 0.2 秒的停顿里且离两头 40 ms、尽头能当终点、一直有声时退到最安静的格子边；和照规矩直写的穷举对 16 组随机样本（含只有小停顿的）；分块量的响度 = 一口气量的；WAV 头、量化往返、NaN / ±Inf 记 0 且特别大的夹住、写给 AI 的那一句（时间向下取整）、上传用途 |
| `scripts/check-mcp.sh` 的 `VoiceReferenceFileChecks`（真读真写） | 现写素材走生产的 `prepare`、把写出来的 WAV 按字节读回来：44.1 kHz 16-bit 的源逐采样不变；48 kHz 立体声 4 分钟挑在说话密的 3 分钟、开口前 40 ms 起、停在最后一个字后 40 ms（和读到尽头人声一样多，取短的）、不到 181 秒、左右取平均；点名的一段原样截、采样数正好；AAC 的时间对得上；只有 8 秒人声的拒、说还差 2 秒、不留文件；取消不留文件；照审查的 `borderline.wav` 现写的贴边样本（9.9 秒 + 5 格 ±184）正好 10.0 秒、收；浮点刚过门限、量化后不够的 10 格按写出去的数（9.9 秒、拒）；带 NaN / ±Inf / 1e20 的浮点素材不崩、那几处写成 0 / 0 / 0 / 满幅 |
| `checks/MCP/voice-reference-wiring.sh`（扫描，`check-mcp` 和 `check-guards` 都跑） | 门限是写死的 `speechRMSFloor = 0.0056`，`VoiceReferenceWindow` 的代码里不碰 `AIVoiceLevel` |
| ~~`scripts/check-voice-recovery.sh`（真 App 对象）~~ | 2026-11-10（声音 PR 3）去掉 `clone_from` 时这几条一起删了：读稿不再上传参考、不再在任务里做参考录音。上传用途、WAV 规格、人声不够的原因仍由上面三项钉着；声音库建声音的真 App 检查在声音 PR 6 加回来了（第八节） |

反向验证（2026-11-10，每一处临时改回去、跑、再恢复）。PR #346：

| 临时改成 | 红了什么 |
| --- | --- |
| `VoiceReferenceReader.sampleRate` = 16 kHz | `check-mcp` 12 条：采样率、有效人声的换算、整段 12 秒、WAV 头、逐采样往返、48 kHz 立体声、点名的一段、AAC 的长度和时间；`check-voice-recovery`：传上去的不是 44.1 kHz |
| `minimumVoicedFrames` = 150（3 秒） | 10 秒的常量、9.98 秒不够、8 秒人声被拒且不留文件 |
| `uploadPurpose` = `audio` | 上传用途那一条；`check-voice-recovery`：上传不是 `voice_reference` |
| `pauseFrames` = 9（0.18 秒也算停顿） | 停顿的定义、「小停顿不能切」（终点挪到 180.84 秒）、穷举对账的 3 组只有小停顿的样本 |
| `cloneSource` 换回「默认 10、夹在 5–30」 | `check-voice-recovery` 3 条：5 秒不拒、不给时成了 10 秒、45 秒被夹到 30 |
| 去掉落地前从恢复记录同步声音说明的那一行 | 一次就做完的克隆，结果不说用了哪一段（恢复出来的那次照样有：说明从记录里读） |

审查之后的修正 PR：

| 临时改成 | 红了什么 |
| --- | --- |
| `quantize` 换回 `Int16(clamping: Int(…))` | `check-mcp` 当场崩（Double value cannot be converted to Int…，SIGTRAP，退出码 133） |
| `speechRMSFloor` = 0.0056234（精确的 −45 dBFS） | 扫描守卫先红；摘掉扫描再跑，运行时三条红：常量、边界两格、贴边样本（只剩 9.9 秒、被拒） |
| `speechRMSFloor` = `AIVoiceLevel.activeFloor`（数值一样） | 只有扫描守卫红；摘掉扫描，运行时 4371 项全过 —— 比数值查不出耦合，所以要那条扫描 |
| 写出去的采样不再数一遍（用挑段时的数） | 浮点刚过门限的样本没被拒；带坏采样的那份算成 14.98 秒 |
| 3 分钟的边界 `>` 改成 `>=` | 正好 3 分钟、结尾有停顿的那份变成挑段（179.54 秒） |
| 去掉报价之前做参考录音那一步 | `check-voice-recovery` 3 条：6 秒的素材没在报价之前拒、发了 POST、写了恢复记录 |
| `fail()` 不把结构化的原因带进 get_job | `check-voice-recovery`：6 秒素材的 get_job 里没有 `reason` / `missing_seconds` |

全部恢复后转绿。读完到写之间再看一次取消（第 6 条）没有确定的触发办法，没做反向验证。
两张表里牵涉 `check-voice-recovery` 的几行是当时的记录；那几条检查在声音 PR 3 随 `clone_from` 一起删了。

## 七、人工回归（真 Key；声音库上线、新建声音的界面做好之后）

- [ ] 新建声音：录 10 秒（刚够）、录 45 秒、选一个 3 分 30 秒的文件：说出用了哪一段，试听那一段（方案 9.3，声音 PR 8）。
- [ ] SkyCut 算出刚好 10 秒多一点有效人声的样本，服务器不回 `too_little_speech`（两边口径一致）。
- [ ] 一段 3 分钟以上、背景有一点噪声（比 −45 dBFS 响）的录音：噪声也会被当成「有声」，挑段只按响度——确认界面的提示（一个人说、没有背景音乐）写到了。

## 八、声音库的工具（`list_voices` / `manage_voices`，声音 PR 6）和全部权限下的长期授权（声音 PR 7）

> 方案 4.5、4.6、9.1 第 8、9、12 项；AI 那一面的规矩在 [AI 接口](ai-control-mcp.md)第四节第 58 条（第 6 条：两种权限模式），用声音库的声音配旁白在
> 第 40 条和 [Sky Studio 的任务](sky-studio-jobs.md)第五节。接口合同在 Sky Studio 仓库 `docs/agents/skycut-api.md`「Voice library」。

1. **读和写分开**（同角色 A/B 的先例）：`list_voices` 只读免费，`manage_voices` 写（服务器上的事，**不登记时间线撤销**；删了就是没了，结果说清楚）。
   路由里 `list_voices` 不排队、`manage_voices` 排队但不摆剪辑页、不算这一轮；两个都不碰工程（不收 `project`）。
2. **列出来的**（`SkyStudioVoiceListing`）：预设一种语言一份（`listed` 的、按打分高到低、默认的标出来，性别和说明按这种语言报：同一个预设中英文可能是两个人），
   没有自己名单的语言照 `other_languages`（英文那份）并写 `list_language`；我的声音只有 `SkyStudioVoice.json` 那几样，**没有任何服务商 id**。
3. **用录音建声音 / 加一种语言**（`SkyStudioVoiceRecordingTool`）：参数核对 → 点名文件夹以外的先过 `AIWorkspace.confirmReading` → 本机做参考录音（第一到四节）→
   **问授权**（`SkyStudioJobGate.voiceConsent`，问句带 `/models` 的 `voice_consent.per_recording` 英文原文和版本，AI 照会话语言转述）→ 点过头才传
   `voice_reference`、`POST /voices`（`consent: true` + 版本、`source` 写用了哪一段、`idempotency_key` 从令牌绑的身份算）或 `POST /voices/{id}/references`。
   令牌绑**完整身份**（`SkyStudioVoiceApproval.Recording`）：文件路径、大小、修改时间、做好的那段 WAV 的 SHA-256、用的那一段、语言、名字 / 声音、版本，外加账户戳；
   换任何一样另发一张。全部权限 + 有效的长期授权不问，带 `consent: "standing_grant"`（第 7 条）。**加一种语言**（`add_reference`）读到 Key 先 `GET /voices/{id}`：
   已经有这种语言就当场说（`SkyStudioVoiceLibraryErrors.referenceExists`，和服务器的 409 同一句）、什么都不问不传；问句写声音的**名字**，令牌照旧绑 id
   （[案例](../bugfixes/2026-11-10-add-reference-asks-before-reading-the-voice.md)）。AI 这一路的 `consent: true` 和 `"standing_grant"` 只在这个文件、
   `voiceConsent` 放行之后造（`checks/sky-studio-wiring/voice-library.sh`；`consent: true` 另一处是对话框里用户自己勾了那一句之后，第九节）。
   录音的语言 AI 这一路要它给；界面上的对话框用本机检测预选（第九节第 4 条）。身份和「传、建 / 加」那一步在 `SkyStudioVoiceRecordingSubmission`，两个入口共用。
4. **设计**（`SkyStudioVoiceDesignTool`）：先 `/quote`（`voice_design`、`model: auto`，描述的语言决定 MiniMax / Qwen3，SkyCut 不挑），再问一次性费用
   （`SkyStudioJobGate.voiceOneTime`：先判每日硬预算，问句「约多少（最多多少）」），点过头记账、起任务（`SkyStudioVoiceLibraryJob`：`get_job` 报新声音、
   1 小时的 `sample_url`、实收；账按服务器的结算证据改，没花出去的退回）。价格一律从报价来，名片和说明书不写数。
5. **建 MiniMax 版**（配旁白碰上 `default_needs_one_time`，`SkyStudioVoiceOneTimeStep`）：问、`skip_one_time` 照不花钱的那个读、点头起 `voice_enroll` 任务、
   做完再调一次 `add_voiceover`（见 [AI 接口](ai-control-mcp.md)第 40 条）；全部权限 + 长期授权不问、直接起（第 7 条）。旁白中途某一批的备用要先建（任务结束码 `fallback_needs_one_time`，
   `SkyStudioVoiceFallbackFee`）：get_job 带问句、价和令牌，`resume` + 令牌建、做完 `resume` + `generate_missing=true`，`resume` + `skip_one_time=true`
   照原来的模型重试（[Sky Studio 的任务](sky-studio-jobs.md)第五节）；全部权限 + 长期授权直接建（get_job 带 `enroll_job_id`）。
6. **删除**：请求批准模式问一句（问句写名字；正在删的声音 GET 不到，写 id）、全部权限直接删；存储一时不可用（503 `voice_library_unavailable` +
   `reason: storage_unavailable`）再发一次，还不行就说「已经看不见了，再调一次 delete 接着删」。
7. **两种权限模式**（声音 PR 7 起，方案 4.5）：照 `SkyStudioVoiceStanding.voiceAsk`（`SkyStudioJobGate.VoiceAsk` 三种）——
   - 请求批准模式（`.ask`）：授权、一次性费用、删除都问；
   - 全部权限 + 这个账号有有效的长期授权（`GET /voices/consent-grant` 说 `active`，`.standing`）：**不问**。建声音带 `consent: "standing_grant"`，设计、
     建 MiniMax 版（配旁白开头和旁白中途的那一笔）直接做，删声音直接删；结果带 `full_access`（做了什么、最多花多少，AI 照转告），工程的提示条也说一句；
   - 全部权限、还没有有效的长期授权（读不到、没记过、别的 Mac 关了全部权限撤了、文案升了版本，`.once`）：用录音建声音、设计、建 MiniMax 版**第一次照请求批准
     模式问一次**，问句后面接打开全部权限时那段说明（`SkyStudioVoiceStandingNotice.missingText`：价目、额度、长期授权那句），令牌另绑那一版（请求批准模式发的码
     答不了它）；点过头先记长期授权（`POST`，记不上不挡这一次），这一段录音照问过的带 `consent: true`；以后不再问。删声音不花钱、不要授权，照全部权限直接删；
   - 带 `standing_grant` 被 Sky Studio 拒（`no_standing_grant` / `consent_outdated`：GET 之后刚被撤）：照 `.once` 问一次。
   每日硬预算两种模式都拦（一次性费用先判预算）。问用户只经 `SkyStudioJobGate`（不另开确认入口，扫描钉着）。
8. **声音库用不了**（503 `voice_library_unavailable`，`reason: not_configured`：Sky Studio 的私有声音桶没配）：`list_voices` 照回预设、`mine` 写一句；
   `manage_voices` 各个动作、`add_voiceover voice=voice_…` 都报「暂时用不了、一分没花、稍后再试、预设照常」，**不退本机**（`SkyStudioVoiceLibraryErrors`）。
9. **长期授权怎么记、怎么撤**（`SkyStudioVoiceStanding`，方案 5.6；`/voices/consent-grant` 只经它，扫描钉着）：
   - 设置里选「全部权限」先弹说明（`FullAccessConsentSheet`：不再先问的几件事、一次性费用价目从 `/models` 的 `minimax-voice-design` / `qwen3-voice-design` /
     `minimax-voice-clone` 读 —— 按次收的写「约 `typical_credits`」，按字数收的（`price.per == "1000_characters"`，Sky Studio #247 起的 Qwen3 设计）写
     「描述加试读句每开始 1,000 字 `credits`」，读不到写「以报价为准」；实际多少照旧只问 `/quote` —— 每日额度、打开即确认的那句 —— SkyCut 认识的版本显示译文，不认识的显示服务器的英文原文），
     按「同意并打开」才写 Store、`POST` 用户看到的那一版；「取消」什么都不改；每次切到全部权限都弹。记不上（没 Key、没连上、Sky Studio 不收）照样打开，设置里写一行
     「还没记上，第一次会问一次」。切回请求批准立刻写 Store、`DELETE`。
   - `set_settings ai_access_mode=full_access`：照旧永远先回确认码（`AISettingsApproval`），问句后面接 `SkyStudioVoiceStandingNotice.turnOnText`，令牌另绑
     那一句的版本；点过头写 Store、`POST`，结果报 `voice_standing_consent`（`recorded` / `not_recorded` + 原因）；关掉 `DELETE`、报 `revoked`。
   - **升级前就开着全部权限**：新版第一次读到 Key（启动时静默读到、或存下新 Key）时 `migrateIfNeeded` 替用户记上、不问（用户 2026-11-09 定）；这台 Mac 上只做一次
     （`SrtFlow.skystudio.voiceStandingConsentMigrated.v1`），开着的是请求批准就记成做过、什么都不发；已经有有效的不再记；记不上下次读到 Key 再试。
   - 换了 Key：设置里那一行的状态清掉（账号不同，Sky Studio 那边各记各的）。

| 检查 | 守什么 |
| --- | --- |
| `scripts/check-sky-studio.sh` 的 `VoiceLibraryToolChecks`（纯值 + 真走 `SkyStudioJobGate`） | 预设名单（默认的标出来、没有名单的语言照英文并说明、性别按语言）；授权的令牌换路径 / 大小 / 修改时间 / 内容 / 起止 / 语言 / 名字 / 版本 / 账户都另发一张，一次性费用换价 / 语言 / 声音 / 模型、设计换描述 / 试读句 / 价都另发，全都以 `skystudio:` 开头；授权 `.ask` / `.once` 都问、同一件事回同一张、只收一次，`.once` 的问句带说明、请求批准模式的码答不了它，`.standing` 不问；一次性费用三种都先判每日额度（超了不发码不记账）、问的时候不记账、点过头按报价记账，`.standing` 不问直接按报价记账；删除请求批准问、全部权限不问；`voice_library_unavailable` 两种 reason 分开说、`voice_limit` / `reference_exists` / `too_little_speech` 的话 |
| `scripts/check-mcp.sh` 的 `SkyStudioVoiceChecks` / `GuidePilotChecks` | 两个工具的参数名、动作词表就是 App 分派的五样、只读 / 写 / 会删；名片必含、说明书必含（分节照 4.10、设计一节不写价）、地图的 Voices 一行和 Paid 一行；名片 ≤ 450、按性质的固定说法、新工具没有迁移前的原文 |
| `scripts/check-voice-recovery.sh` 的 `LibraryChecks`（真 App 对象 + 假协议 `VoiceLibraryHTTP`） | 列出（声音库用不了照回预设、只要预设不问声音库）；建声音没点头什么都不传、点过头传 `voice_reference` 一次、`POST /voices` 带授权和版本 / 私有上传名 / 用了哪一段 / 稳定的 key，换一段的令牌不认；删除请求批准问了才发、全部权限直接发、存储失败再发一次；设计没点头不起任务不记账、点过头 `max_credits` 是报价、get_job 报新声音和样音、账按实收；用声音库的声音配旁白：要建 MiniMax 版先问（一批都不交）、`skip_one_time` 每批 `voice_clone` 带同一个 plan、点头起 `voice_enroll`、声音库用不了报错不退本机 |
| `scripts/check-voice-recovery.sh` 的 `FallbackFeeChecks`（真 App 对象） | 旁白中途备用要先花一次性费用：get_job 带价（结束码带的、声音照恢复记录）和令牌、两条路都写在 next_step、恢复记录记下这一笔；普通 resume 不建、这一笔留着且 get_job 再问一遍（同一张令牌）；`skip_one_time` 不建、照原来的选择重报价、全部落地；别的令牌再问（同一张）；那张令牌按报价记账、`voice_enroll` 带模型 / 声音 / 语言 / max_credits，之后 `generate_missing` 读完 |
| `scripts/check-sky-studio.sh` 的 `VoiceStandingNoticeChecks` / `AccessChecks`（纯值） | 说明的价目照目录快照读（751.4 / 22.5 / 377.6，没有 typical 用 credits、少了的模型那一行不写）、额度、授权那句和 Sky Studio 导出的 v1 一字不差、读不到 `/models` 的退路；给 AI 的两段英文；`set_settings` 打开全部权限的问句带说明、令牌绑那一句的版本（新版本另问）、关掉的问句不带 |
| `scripts/check-voice-recovery.sh` 的 `StandingChecks`（真 App 对象 + 假协议） | 全部权限 + 长期授权：建声音不问、带 `standing_grant`、结果和提示条说一句，设计直接起任务，每日额度照拦，配旁白建 MiniMax 版直接起（`skip_one_time` 照收），旁白中途那一笔直接建（`enroll_job_id`）再 `generate_missing` 读完；没有长期授权：问一次（这段录音那句 + 说明）、点过头先 `POST` 问句里那一版再带 `consent: true` 建、之后不再问；Sky Studio 拒 `standing_grant` 时问一次；`set_settings` 打开问句带价目和那句、点过头记、关掉撤、记不上照样打开并报 `not_recorded`；升级补记：请求批准什么都不发、记不上下次再试、记上了只做一次、已经有有效的不再记 |
| `checks/sky-studio-wiring/voice-library.sh`（`checks/sky-studio-wiring.sh` 第 11 节 source 进来，扫描） | `consent: true` 和 `standing_grant` 只在建声音的工具里、过了 `voiceConsent` 之后造，`standing_grant` 只在 `.standing` 时用；`/voices/consent-grant` 只经 `SkyStudioVoiceStanding`；改权限模式的文件和告诉长期授权的文件对得上、设置里只有「同意并打开」写全部权限、读到 / 存下 Key 时都补记；`/voices` 的路径只在 `SkyStudioVoiceAPI`；没有 MiniMax voice_id 的样子；声音库的工具和长期授权问用户只经 `SkyStudioJobGate`；声音库的声音不退本机 |

人工回归（真 Key、要花积分的先请用户批准预算）：

- [ ] 请求批准模式：用一段录音建声音，问句是 Sky Studio 那句授权（照会话语言转述）、点头后建成；换一段录音另问；删声音问一句、删了 `list_voices` 里没了。
- [ ] 设置里切到全部权限：弹说明，价目对得上 `/models`（中 / 英 / 西三种界面、默认窗口大小下无截字）；取消就不改；同意之后 AI 用录音建声音、设计、建 MiniMax 版、
      删声音都不问、做完说清楚花了多少，提示条也说一句。
- [ ] AI 用 `set_settings` 切全部权限：问句里带同一段说明；同意之后记上授权（`voice_standing_consent: recorded`）；切回请求批准撤掉。
- [ ] 换一个 Sky Studio 账号：全部权限下第一次用录音建声音会问一次（问句带说明），之后不问。
- [ ] 升级前就开着全部权限：装上新版、第一次连上 Sky Studio 就记上长期授权，用录音建声音不问。
- [ ] 设计一个英文描述的声音（Qwen3，便宜的那个）：报价、点头、`get_job` 给样音链接、听一遍；再用它读一句中文、一句英文。
- [ ] 用自己的声音读一段英文：第一次问要不要建 MiniMax 版；不建（`skip_one_time`）照 IndexTTS2 读完；建了之后再调一次照默认读。
- [ ] 旁白中途某一批的备用要先建 MiniMax 版（服务器回 `fallback_needs_one_time`；真遇上时）：get_job 问价、`resume` + 令牌建、再 `generate_missing` 读完；
      另一次照 `skip_one_time` 用原来的模型重试。
- [ ] Sky Studio 没配声音桶时（或断网）：`list_voices` 照回预设，用 `voice_…` 配旁白报错、没换成本机的声音。

## 九、声音库的界面（设置里的一节、声音选择器、新建 / 设计声音，声音 PR 8）

> 方案 5.1–5.4、5.7、9.1 第 13 项、9.3「界面」。文件在 `Sources/SrtFlow/VoiceLibrary/`。相关：[顶部工作台与统一设置](workbench-and-settings.md)（「剪辑与声音」那一类）、
> [本地化](localization.md)、[预览性能 ratchet](preview-perf-ratchet.md)、[即时提示](instant-tooltips.md)、[签名与系统权限](code-signing-and-permissions.md)（麦克风）。

1. **界面和 AI 的工具是同一条路，不另写一份逻辑**（扫描守卫钉着）：
   - 建声音 / 加一种语言的录音：参考录音只经 `VoiceReferenceSample.prepare`，交只经 `SkyStudioVoiceRecordingSubmission`（身份、`voice_reference` 上传、
     `POST /voices` / `…/references`、用了哪一段、从身份算的 idempotency_key）。同一段录音、同一个名字和语言，对话框和 `manage_voices` 发的是同一个 key。
   - 删除只经 `SkyStudioVoiceDeletion`（存储一时不可用再发一次只有这一份）；设计只经 `SkyStudioVoiceDesignOrder`（核对、起 `SkyStudioVoiceLibraryJob`）。
   - 服务器的错误是哪一种只在 `SkyStudioVoiceLibraryErrors.kind` 分一次：给 AI 的英文（`message`）和界面上照语言写的那一句（`VoiceLibraryText.message`）都从它来；
     界面上的话不许出现「去调某个 AI 工具」。
   - 「声音库变了」（`SkyStudioVoiceLibraryChange`：建、加录音、改名、删、设计好了，AI 做的也算）一声，开着的那一节自己再取一遍。
2. **授权是对话框里的一勾**（方案 5.3：这是用户自己在操作，不是 AI 在问，两种权限模式都有）。**只有勾上了才造 `consent: true`**（带 `/models` 那一句的版本）：
   `NewVoiceGate` 没勾就不让按，`NewVoiceModel.submit` 里 `guard agreed` 之后才造（两道，守卫钉着后一道）。勾的那句是 `voice_consent.per_recording` 的本地化版本：
   **认得的版本（`voice-consent-v1`）显示译文，服务器换了新版本而表里还没有译文时显示服务器的英文原文**——用户同意的必须是交上去的那个版本说的话；
   加一版译文 = `VoiceLibraryText.knownConsentVersion` 和三张表一起改。开了全部权限、`GET /voices/consent-grant` 说这个账号有有效的长期授权时默认勾上（用户动过就不替他改；
   交的仍是这一次的 `consent: true`，长期授权那一种是声音 PR 7 的事）。
3. **声音库的几种样子**（`VoiceLibraryStore.Phase`）：没有 Key →「接上 Sky Studio 才能用」+ 去「设置 → Sky Studio」的按钮；钥匙串要授权 → 同一个按钮（去那一页点「允许…」）；
   `voice_library_unavailable` →「声音库暂时用不了，稍后再试」，新建、设计灰着（列表是空的，改名 / 删除无从点起），**预设照样能浏览、试听**；别的毛病 → 那一句 +「重试」。
   Key 只静默读（打开设置不弹钥匙串框，`.prompting` 仍只有面板起的 upscale 任务用）。
4. **录音的语言**先替用户选好、可改（`VoiceSampleLanguage`）：macOS 26 上用生成字幕那套两段式检测——候选和裁决 2026-11-10 从 `TranscriptHarvester` 原样挪进了
   `SpokenLanguageProbe`，两边共用（只在已装的语言里裁决、不为它下载模型，探针是参考录音的前 20 秒）。检测不出来、一个模型都没装、macOS 15：**那一行空着、要用户选，不许猜**
   （语言记错了，服务器选模型跟着错）。用户选过就不再替他改；加录音时检测出这个声音已有的语言也不替他选。能选的是一份常用语言的名单（检测出名单外的照样能用）。
5. **现在录**（`VoiceSampleRecorder`）：第一次按「录」才请求麦克风授权（和录屏同一个请求口 `ScreenRecordingPermissions.requestMicrophoneAccess`）；被拒了说去
   「系统设置 > 隐私与安全性 > 麦克风」打开、给一个打开系统设置的链接。录成和参考录音同一个规格的 WAV（44.1 kHz 单声道 16-bit），到 3 分钟自己停；录下来的文件
   和选的文件一样过 `prepare`。一秒十次的电平只叫醒录音那一小块视图。麦克风的用途说明（`InfoPlist.strings` 三种语言 + `packaging/Info.plist`）写了「录屏的解说」和「新建声音时的样本」两样。
6. **「新建」为什么还灰着**一次只说最要紧的一样（`NewVoiceGate`，纯值）：声音库用不了 → 满了（每个账号 50 个；服务器另外卡 `voice_limit`）→ 没起名字 → 还没有能用的录音
   （人声不够的那一句由 `prepare` 给：有多少秒、至少要 10 秒）→ 没选语言 → 这种语言已经有录音了（加录音时；已有的语言本来就不列）→ 没勾授权。加录音不问名字、不数上限。
   费用一行写明新建免费、MiniMax 版第一次用到再说（方案 5.3）。
7. **设计声音**（`DesignVoiceModel` / `DesignVoiceSheet`）：填好描述和名字、停 0.6 秒才问 `/quote`（免费、不建任务）；显示「将用 MiniMax / Qwen3 设计 · 约 X 积分（最多 Y）」
   （大概和最多一样时只写一个数）；按钮「设计（最多 Y 积分）」**按下就是确认**（和 upscale 面板同一个口径，不走确认码）：照报价先过每日硬预算
   （`SkyStudioJobGate.reserveWithoutAsking`，超了那一行标红、按钮灰着）、记账、起任务。**报价对的是哪一份就交哪一份**：改了任何一个字，手里的报价作废、重新问。
   设计是任务：关掉对话框不取消，云端任务浮层里看得见（挂在菜单作用的那个工程名下），做完自己出现在声音库那一节；没做成那一节说一句（任务自己的原话，不另编「没扣钱」）。
   价只从报价来，界面和表里不写数。
8. **声音选择器**（`VoicePickerView`，共用组件，变声面板也用它）：一排语言（中文 / English / 其他语言）+ 三组（我的声音、设计的声音、预设排最后）。列什么在
   `VoicePickerRows`（纯值）：预设只列这种语言 `listed` 的、和 `list_voices` 同一个顺序；性别、说明、样音取**这一排的语言**的那一套；说明按界面语言挑（中文界面 `zh`，
   英文、西语界面 `en`）；「其他语言」照 `other_languages`；默认哪一排：中文界面中文，其余 English。给了 `selection` 能点选，不给只浏览。
9. **试听**只经 `VoiceAudition`：一个播放器、同一时间只放一个、面板关掉就停。预设的样音是公开地址；我的声音的试听是 1 小时的临时链接，
   **只留在内存里、不存盘**，还剩不到一分钟就重取那一个声音（`VoiceLibraryStore.previewURL`）。
10. **删除**先确认一句「删除『X』？」，不另加说明（决定第三节第 7 条）；删了立刻从列表消失。改名是一张小 sheet。这些都不碰时间线、不登记撤销。
11. **界面的规矩**：每张 sheet 各套 `.appLanguage()`；确认框的标题和按钮走 `L10n`；新文案三张表都有；每个视图 body 第一行计数；提示用 `instantHelp`；
    声音库的视图不读工程、不订阅播放器的时钟（只订阅 `VoiceLibraryStore` / `VoiceAudition` / 各自的小模型）；录音语言那一行的键是「Recording language」
    （`"Language"` 在表里是「界面语言」，一个键一个含义）。新加的界面文件都在 400 行以内。

| 检查 | 守什么 |
| --- | --- |
| `scripts/check-sky-studio.sh` 的 `VoiceLibraryUIChecks`（纯值，47 条） | 选择器三组的顺序、预设名单和 `list_voices` 同序、按这一排的语言取性别 / 样音、说明按界面语言挑、「其他语言」照英文、默认标出来、默认哪一排、我的声音试听哪种语言；`NewVoiceGate` 的顺序、50 个上限、加录音不问名字；错误分成哪一种、给 AI 的英文没变 |
| `scripts/check-voice-recovery.sh` 的 `LibraryUIChecks`（真 App 对象 + 假协议 `VoiceLibraryHTTP`） | Store：取到了 / 用不了（预设还在、什么都不发）/ 没有 Key / 要授权；改名；删除再发一次、立刻消失；临时链接没过期不重取、快过期只重取那一个；「声音库变了」自己再取。新建：**没勾授权什么都不传**、勾了传一次 `voice_reference`、`POST /voices` 带 `consent: true` + 版本 / 用了哪一段 / key，和 `manage_voices` 同一个 key；人声不够当场说、不碰网络；语言照检测预选、用户选过不改、检测不出来留空；加录音不列已有的语言；那一勾的默认。设计：填够才问价、改字作废报价、按下去记账并起 `voice_design`（`max_credits` 是报价）、做完进列表、超了每日额度不记账不起任务、太长不问价。录音机：电平换算、规格、3 分钟、被拒不录。话：授权那句的两种版本、语言名照界面语言、界面不叫人去调 AI 工具 |
| `checks/sky-studio-wiring.sh` 第 11、12 节（第 12 节拆在 `checks/sky-studio-wiring/voice-library-ui.sh`） | `consent: true` 只在两处造且各在问到之后；建 / 加 / 删的请求只从 `SkyStudioVoiceRecordingSubmission.swift` 发；设计只经 `SkyStudioVoiceDesignOrder`、先过每日硬预算再起任务；界面不用确认码、不弹钥匙串框、不直接动账；视图不读工程 / 时钟；拆出去的那一节在总闸之前装进来 |
| `checks/project-file-wiring.sh` | 语言检测搬家之后守卫跟着走：候选去重 / 排序 / 不许单候选捷径钉在 `SpokenLanguageProbe`，生成字幕和参考录音都只走它 |
| `scripts/check-localization-coverage.sh`、`checks/presented-views-app-language.sh`、`checks/preview-perf-wiring.sh`、`checks/instant-tooltip-wiring.sh`、`checks/source-file-size.sh` | 三张表、sheet 的语言、body 计数、提示、行数（方案 9.1 第 13 项，各自已有） |
| `scripts/render-voice-library.sh <输出目录>`（要图形会话，**不在 check-all 里**） | 不判对错，只出图：生产的视图 + 假 Sky Studio，英 / 中 / 西各一套 PNG（设置那一节的三种样子、浏览预设、新建声音空着 / 填好、加录音、设计带报价），发版前和改这些视图之后看排版 |

反向验证（2026-11-10，每一处临时改坏、跑、看红、再恢复）：

| 临时改成 | 红了什么 |
| --- | --- |
| `NewVoiceGate` 不看那一勾、`submit` 里去掉 `guard agreed` | `check-voice-recovery` 4 条（缺的不是授权了、没勾也传了、传了两次、同一个 key 出现三次）；只去掉 `guard agreed`：扫描守卫红 |
| 试听的临时链接永不重取 | 「快过期的重取那一个」 |
| 声音库用不了当成普通失败 | 「用不了是单独一种样子」 |
| 设计按 0 积分过每日额度 | 「按报价记账」「超了额度不记账不起任务」 |
| 改字不作废手里的报价 | 「改了字报价作废」「交的就是报价的那一份」 |
| 检测盖掉用户选的语言 | 「用户选过不改」（连带等样本超时） |
| 录音上限改成 10 分钟、麦克风被拒照录 | 录音机 2 条 |
| 选择器把预设排第一、说明一律 `en`；上限改 100；存储失败不单独分 | `check-sky-studio` 15 条（顺序 / 名单 / 默认 / 中文说明 / 上限 / 存储失败，连带旧的「再调一次 delete」那条） |
| 删除不再发一次（`SkyStudioVoiceDeletion`） | `check-voice-recovery`：旧的 AI 删除那条先抛错（界面和 AI 共用这一份） |
| 另一个文件里造 `consent: true`；Store 直接调 `deleteVoice`；对话框自己 `createVoice`；设计先起任务后过额度；视图里读 `OpenProjects`；界面里用 `AIConfirmations`；拆出去的那一节挪到总闸后面 | `checks/sky-studio-wiring.sh` 各红一条 |
| `SpokenLanguageProbe` 里已装语言不排序 / 加单候选捷径；生成字幕不把元数据交给候选 | `checks/project-file-wiring.sh` 各红一条 |
| sheet 去掉 `.appLanguage()`；一个 body 去掉计数；西语表删一条；`instantHelp` 换成 `.help` | 各自的守卫红 |

全部恢复后转绿。

人工回归（自动化够不着的；真 Key 的几条要花积分，先请用户批准预算）：

- [ ] **第一次按「录」**：系统弹麦克风授权框，文案是新的那一句（提到录声音样本）；点允许后直接开始录，电平条跟着声音动、时间在走；录到 3 分钟自己停。
- [ ] **拒绝麦克风之后**：那一块写「去系统设置 > 隐私与安全性 > 麦克风打开」，链接能打开那一页；打开之后回来再按「录」能录（不用重开 SkyCut；要重开的话把文案改掉）。
- [ ] **装下一个版本之后**（固定签名）：麦克风不用再授权（[签名与系统权限](code-signing-and-permissions.md)）。
- [ ] 新建声音：录 10 秒出头（刚够）、录 45 秒、选一个 3 分 30 秒的文件：「用的」那一行说出用了哪一段（自动挑的写明）、▶ 放的就是那一段；录 5 秒：说还差多少、「新建」灰着。
- [ ] 语言：中文录音自动选中文、英文选英文（macOS 26、两种模型都装了）；一段这台 Mac 没装模型的语言：那一行空着、要手选；手选之后换一个文件不被改回去。
- [ ] 不勾授权建不了；勾上、新建之后声音出现在列表里，▶ 能听到自己的录音；给它加一段另一种语言的录音，列表里多一种语言。
- [ ] 改名、删除（确认一句、删了立刻消失）；同时让 AI 用 `manage_voices` 建 / 删一个：设置开着时列表自己跟着变。
- [ ] 设计：英文描述（Qwen3，便宜的那个）报价 → 按下 → 对话框收起、设置里「正在设计…」、云端任务浮层里有这一条 → 做完出现在列表、▶ 能听样音；
      每日额度调到比报价低：那一行标红、按钮灰着。中文描述看到的是 MiniMax 和「约 X（最多 Y）」（只看报价，不必真设计）。
- [ ] 浏览预设：中文 / English / 其他语言三排，逐个 ▶ 能听、同一时间只响一个、关掉面板就停；Charon 标着「默认」。
- [ ] 没有 Key：那一节写「接上 Sky Studio」，按钮跳到 Sky Studio 那一类；钥匙串要授权时同样。Sky Studio 没配声音桶时：写「暂时用不了」，新建 / 设计灰着，预设照样能听。
- [ ] 英 / 中 / 西三种界面（系统语言设成英文再切）：设置那一节、选择器、三个对话框、删除确认框无截字、无漏翻；900 pt 高的窗口里对话框完整（方案 9.3）。

