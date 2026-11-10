# 声音库：克隆的参考录音和声音库的工具（变声做到时补进来）

> 2026-11-10 起生效（SkyCut 声音 PR 2 `feat/voice-reference-sample`）。方案：[SkyCut 声音方案](../plans/2026-11-09-voice-features.md)
> 第六节、9.1 第 3 条；拍板在仓库外的 `SkyVoiceForClone/决定汇总-2026-11-09.md` 第三节第 3 条、第七节第 2 条；服务器那边怎么查录音见
> Sky Studio 那份方案（在 Sky Studio 仓库）3.3、3.4。这里只放长期约束。
> 声音库的两个 AI 工具（`list_voices` / `manage_voices`）和用声音库的声音配旁白是声音 PR 6（2026-11-10），在第八节；全部权限下的长期授权（PR 7）、
> 新建声音的界面（PR 8）、变声（`change_voice`，PR 9）做到时补进这份文档。
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
  授权的令牌绑做好的那段 WAV 的内容哈希（第八节）。设置里的新建声音对话框（声音 PR 8）照同一条路。用声音库的声音读稿（`voice=voice_…`）不再传参考，
  参考从声音库拿。

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

## 八、声音库的工具（`list_voices` / `manage_voices`，声音 PR 6）

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
   换任何一样另发一张。`consent: true` 只在这个文件、点过头之后造（`checks/sky-studio-wiring.sh` 第 11 节）。录音的语言这一刀要 AI 给（本机检测随界面那一刀接）。
4. **设计**（`SkyStudioVoiceDesignTool`）：先 `/quote`（`voice_design`、`model: auto`，描述的语言决定 MiniMax / Qwen3，SkyCut 不挑），再问一次性费用
   （`SkyStudioJobGate.voiceOneTime`：先判每日硬预算，问句「约多少（最多多少）」），点过头记账、起任务（`SkyStudioVoiceLibraryJob`：`get_job` 报新声音、
   1 小时的 `sample_url`、实收；账按服务器的结算证据改，没花出去的退回）。价格一律从报价来，名片和说明书不写数。
5. **建 MiniMax 版**（配旁白碰上 `default_needs_one_time`，`SkyStudioVoiceOneTimeStep`）：问、`skip_one_time` 照不花钱的那个读、点头起 `voice_enroll` 任务、
   做完再调一次 `add_voiceover`（见 [AI 接口](ai-control-mcp.md)第 40 条）。旁白中途某一批的备用要先建（任务结束码 `fallback_needs_one_time`，
   `SkyStudioVoiceFallbackFee`）：get_job 带问句、价和令牌，`resume` + 令牌建、做完 `resume` + `generate_missing=true`，`resume` + `skip_one_time=true`
   照原来的模型重试（[Sky Studio 的任务](sky-studio-jobs.md)第五节）。
6. **删除**：请求批准模式问一句（问句写名字；正在删的声音 GET 不到，写 id）、全部权限直接删；存储一时不可用（503 `voice_library_unavailable` +
   `reason: storage_unavailable`）再发一次，还不行就说「已经看不见了，再调一次 delete 接着删」。
7. **两种权限模式**：这一刀授权和一次性费用**两种模式都问**（方案 4.5 末条：没有有效的长期授权就照请求批准模式问；长期授权和打开全部权限时的价目说明是声音 PR 7），
   删除按模式；每日硬预算两种模式都拦。问用户只经 `SkyStudioJobGate`（不另开确认入口，扫描钉着）。
8. **声音库用不了**（503 `voice_library_unavailable`，`reason: not_configured`：Sky Studio 的私有声音桶没配）：`list_voices` 照回预设、`mine` 写一句；
   `manage_voices` 各个动作、`add_voiceover voice=voice_…` 都报「暂时用不了、一分没花、稍后再试、预设照常」，**不退本机**（`SkyStudioVoiceLibraryErrors`）。

| 检查 | 守什么 |
| --- | --- |
| `scripts/check-sky-studio.sh` 的 `VoiceLibraryToolChecks`（纯值 + 真走 `SkyStudioJobGate`） | 预设名单（默认的标出来、没有名单的语言照英文并说明、性别按语言）；授权的令牌换路径 / 大小 / 修改时间 / 内容 / 起止 / 语言 / 名字 / 版本 / 账户都另发一张，一次性费用换价 / 语言 / 声音 / 模型、设计换描述 / 试读句 / 价都另发，全都以 `skystudio:` 开头；授权两种模式都问、同一件事回同一张、只收一次；一次性费用超了每日额度不发码不记账、问的时候不记账、点过头按报价记账；删除请求批准问、全部权限不问；`voice_library_unavailable` 两种 reason 分开说、`voice_limit` / `reference_exists` / `too_little_speech` 的话 |
| `scripts/check-mcp.sh` 的 `SkyStudioVoiceChecks` / `GuidePilotChecks` | 两个工具的参数名、动作词表就是 App 分派的五样、只读 / 写 / 会删；名片必含、说明书必含（分节照 4.10、设计一节不写价）、地图的 Voices 一行和 Paid 一行；名片 ≤ 450、按性质的固定说法、新工具没有迁移前的原文 |
| `scripts/check-voice-recovery.sh` 的 `LibraryChecks`（真 App 对象 + 假协议 `VoiceLibraryHTTP`） | 列出（声音库用不了照回预设、只要预设不问声音库）；建声音没点头什么都不传、点过头传 `voice_reference` 一次、`POST /voices` 带授权和版本 / 私有上传名 / 用了哪一段 / 稳定的 key，换一段的令牌不认；删除请求批准问了才发、全部权限直接发、存储失败再发一次；设计没点头不起任务不记账、点过头 `max_credits` 是报价、get_job 报新声音和样音、账按实收；用声音库的声音配旁白：要建 MiniMax 版先问（一批都不交）、`skip_one_time` 每批 `voice_clone` 带同一个 plan、点头起 `voice_enroll`、声音库用不了报错不退本机 |
| `scripts/check-voice-recovery.sh` 的 `FallbackFeeChecks`（真 App 对象） | 旁白中途备用要先花一次性费用：get_job 带价（结束码带的、声音照恢复记录）和令牌、两条路都写在 next_step、恢复记录记下这一笔；普通 resume 不建、这一笔留着且 get_job 再问一遍（同一张令牌）；`skip_one_time` 不建、照原来的选择重报价、全部落地；别的令牌再问（同一张）；那张令牌按报价记账、`voice_enroll` 带模型 / 声音 / 语言 / max_credits，之后 `generate_missing` 读完 |
| `checks/sky-studio-wiring.sh` 第 11 节（扫描） | `consent: true` 只在建声音的工具里、过了授权之后造；长期授权这一刀没人用；`/voices` 的路径只在 `SkyStudioVoiceAPI`；源码和测试数据里没有 MiniMax voice_id 的样子；声音库的工具问用户只经 `SkyStudioJobGate`；声音库的声音不退本机 |

人工回归（真 Key、要花积分的先请用户批准预算）：

- [ ] 请求批准模式：用一段录音建声音，问句是 Sky Studio 那句授权（照会话语言转述）、点头后建成；换一段录音另问；删声音问一句、删了 `list_voices` 里没了。
- [ ] 全部权限模式：删声音不问、结果说删了；建声音、设计这一版照样问（长期授权是声音 PR 7）。
- [ ] 设计一个英文描述的声音（Qwen3，便宜的那个）：报价、点头、`get_job` 给样音链接、听一遍；再用它读一句中文、一句英文。
- [ ] 用自己的声音读一段英文：第一次问要不要建 MiniMax 版；不建（`skip_one_time`）照 IndexTTS2 读完；建了之后再调一次照默认读。
- [ ] 旁白中途某一批的备用要先建 MiniMax 版（服务器回 `fallback_needs_one_time`；真遇上时）：get_job 问价、`resume` + 令牌建、再 `generate_missing` 读完；
      另一次照 `skip_one_time` 用原来的模型重试。
- [ ] Sky Studio 没配声音桶时（或断网）：`list_voices` 照回预设，用 `voice_…` 配旁白报错、没换成本机的声音。
