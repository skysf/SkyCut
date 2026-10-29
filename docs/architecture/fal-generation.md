# fal.ai 生成：Key、每日上限、模型表、generate_media、配旁白的 fal 那一档

> 2026-10-29：生成、upscale、旁白与克隆都已迁到 Sky Studio；本文的 fal HTTP / Key / 语音接线是历史，不能作为新实现依据。当前合同见 [Sky Studio 的任务](sky-studio-jobs.md)。仍共用的阶段、传输与账由第 7 刀改名保留，旧 fal 设置随后删除。

> 2026-09-29 引入（MCP 方案第 6 块，[第 14–19、36、42、52、57、58 条](../plans/2026-09-27-mcp.md)）。改 `Sources/SrtFlow/Fal/`、
> `AIFalVoice` / `AIFalVoices`、`generate_media` 的说明和参数、设置里的 fal 一节、`MCPProviders`（清单按 Key 列不列）、
> `add_voiceover` 的 fal 档之前必读。相关：[AI 接口（MCP）](ai-control-mcp.md)（第四节第 39、40 条）、[阻塞的媒体读取](blocking-media-reads.md)、
> [本地化](localization.md)。
>
> **2026-10-28 起（[收费方案](../plans/2026-10-27-paid-plans-and-sky-studio-key.md)第 6 刀）`generate_media` 和 `upscale_clip` 都改走 Sky Studio、花积分**，
> 规矩在 [Sky Studio 的任务](sky-studio-jobs.md)；fal 只剩配旁白的那一档（第九节）和设置里的 fal 一节（只列旁白、克隆的模型）。下面讲生成的第五节第 8 条、
> 第七、八节和第十三节里 fal 的那部分是历史，第 7 刀删 fal 时一起删。

## 一、落点

| 决定 | 口径 |
| --- | --- |
| 谁能用 | 用户在设置 → AI 里填**自己的** fal.ai Key（第 14 条）；不填就没有这一块，配旁白照旧走本机 / macOS。2026-10-28 起 fal 的 Key 只管配旁白：`generate_media` 跟着 Sky Studio 的 Key 列（第 36 条） |
| 调用方式 | `URLSession` 直接调 fal 的队列 HTTP 接口，不引 SDK（第 14 条）。`FalClient` 是**唯一**碰 fal 地址的地方 |
| Key | 能添加、能删除，存系统钥匙串，先只管一把（第 17 条）。见第六节 |
| 花钱 | **只设每天的上限，默认 10 美元，用户能改；不设单次上限；额度内不问，超了先问；没登记单价的模型每次都先问**（第 18 条）。按登记的单价估，不是 fal 的账单。见第五节 |
| 模型 | 每种事一个预设，用户能改成自己的端点号和单价（第 19 条）；对话里点名别的端点也能用（价格不明，每次问）。**2026-09-29 用户定：视频只用 `minimax/h3-max/` 这个系列；音乐、音效也加上；预设只用当前最新的模型，太老的不要**（第 57 条）。见第二节 |
| 生成是任务 | 回任务号，AI 用 `get_job` 等，停止 / `cancel_job` 能取消（第 5 条）；成品放用户的 `SrtFlow/生成`（点名的文件夹 → 工程的家 → 下载；撞名加编号）。**不改工程**：放上时间线是 `add_clips` 的事。2026-10-28 起这几条照旧，活送 Sky Studio（`SkyStudioGenerateTool` / `SkyStudioGenerationRun`） |
| 配旁白 | 三档谁可用就用谁：**fal > 本机 Kokoro > macOS**（第 42 条）。配旁白是同步工具，**不许停下来问用户**：额度不够就退到下一档并在结果里说为什么（第 58 条）。克隆（第 52 条）只有 fal 能做，用不了就报错、不退档 |

## 二、预设怎么选、怎么更新

**选法**：fal 有公开的目录接口（`https://api.fal.ai/v1/models`，不用 Key），带每个模型的类别和上架日期。2026-09-29 那天按日期排、每类取
最新的、单价固定或能估、接口能拿到我们要的东西的那一个；用户点名的例外（视频）单列。列表和挑的理由：

| 种类 | 端点 | 上架 | 单价（页面上「Your request will cost …」） | 为什么是它 |
| --- | --- | --- | --- | --- |
| 图片 | `bytedance/seedream/v5/flash/text-to-image` | 2026-09-23 | $0.027 / 张 | 图片类里最新；单价固定。GPT Image 2.5（09-08）按 token 计价、随质量差二三十倍，估不准；Nano Banana 2 是 02-26 的，太老 |
| 文生视频 | `minimax/h3-max/text-to-video` | 2026-08-23 | 按分辨率每秒：480p $0.05、768p $0.08、1080p $0.16 | **用户点名**：`minimax/h3-max/` 系列。带同步的声音（环境声、拟音、配乐）；5–15 秒 |
| 图生视频 | `minimax/h3-max/image-to-video` | 2026-08-23 | 同上 | 同上；画幅跟着那张首帧图 |
| 旁白 | `elevenlabs/tts/eleven-v4` | 2026-09-28 | $0.08 / 千字符 | 旁白类里最新（Gemini 3.8 Flash TTS 09-25 不报词时间）；能报每个词的时间（配字幕要）；音色名 fal 在字段例子里列全了 |
| 克隆 | `fal-ai/zonos2` | 2026-06-16 | $0.01 / 成品分钟 | 一步就能按参考音频克隆的里最新的（MiniMax 的克隆是 2025-05 的、两步、一次 $1.5，太老） |
| 音乐 | `elevenlabs/music/v2.5` | 2026-09-14 | $0.6 / 成品分钟，不满一分钟按一分钟 | 有 `force_instrumental`（视频配乐几乎都要纯音乐）和 `music_length_ms`（时长可控）。Lyria 3.5（09-19）没有这两个开关；MiniMax Music 3（08-13）歌词必填、没有纯音乐开关 |
| 音效 | `sonilo/v1.1/text-to-sound-effects` | 2026-07-20 | $0.0018 / 成品秒 | 专做音效的里最新，时长可控（0.5–180 秒） |

**H3 Max 的价格**：页面上现在写的是上线促销价（一半，2026-09-30 结束）；登记的是**正式价**（`FalModels.h3MaxTierPrices`），估价宁多勿少。

**更新的做法**（别靠记忆，fal 的目录天天在变）：`scripts/fal-models/refresh.sh`（要联网，不在 `check-all` 里）——
无参数：重下每个登记端点的接口定义快照（`checks/Fal/schemas/`），说哪些变了；`--newest [N]`：按上架日期列各类最新的；`--prices`：抄每个登记端点页面上的
价格那一句，和 `FalModels.swift` 里登记的对一遍。换预设 = 改 `FalModels.known` + `FalDialect.byEndpoint`（请求怎么写）+ 重下快照 + 改上面这张表的日期和单价；
`scripts/check-fal.sh` 会把「登记表、写法表、快照三样对不上」逮住。

## 三、请求怎么写（`FalInputs`）

- 每个登记端点各有一种写法（`FalDialect`）。字段名、取值范围、必填项**是从 fal 公开的接口定义读的**
  （`https://fal.ai/api/openapi/queue/openapi.json?endpoint_id=…`），定义的快照放在 `checks/Fal/schemas/`，
  自检把造出来的请求体逐条**对着快照验**（必填、取值、范围、多余字段）—— 请求体写错是第一次拿真 Key 才会露馅的那类错，这里没有 Key 就能红。
- 踩到的两处：`prompt_expansion_mode` 在 H3 Max 的定义里是**必填**（虽然有默认值）；文生视频有 `aspect_ratio`、图生视频**没有**（画幅跟着首帧图，多发会被拒）。
- 时长按模型认的范围夹（H3 Max 5–15 秒、音乐 3–600 秒、音效 0.5–180 秒），估价用夹过的数；分辨率认 `480p` / `768p` / `1080p`（默认 768p，AI 做草稿用 480p）。
- 画幅：图和文生视频默认跟画布（`FalInputs.nearestAspect`）；Seedream 的常见画幅有现成的名字（`landscape_16_9` …），别的按宽高写（约 250 万像素、16 的倍数）。
- 本地图片（图生视频的首帧）编成 **base64 data URI** 直接放进请求（fal 各个模型页都写「文件字段收网址或 data URI」）；太大（>6 MB）或 fal 不认的格式先用 ImageIO
  缩到长边 2048、存 JPEG（`FalPayloads`；2026-10-28 起图生视频走 Sky Studio，首帧 `/uploads` 上去，缩图挪进 `SkyStudioGenerationFrame`，`FalPayloads` 删了）。
  克隆的参考音频同理（16 kHz 单声道 WAV）。
- `options`：AI 直接传给模型的其余字段，盖在 SrtFlow 填的上面。**没登记的端点只写最基本的字段**（`prompt` / `text`、`image_url`），其余全靠 `options` ——
  它点名了这个模型，就该知道它的参数。

## 四、队列接口（`FalClient`）

- `POST https://queue.fal.run/<端点号>` 提交 → 回 `request_id` 和 `status_url` / `response_url` / `cancel_url`，**照它给的地址用，不自己拼**
  （没给才按端点号推）→ 轮询状态（`IN_QUEUE` / `IN_PROGRESS` / `COMPLETED`；完成了却带 `error` 就是做失败了）→ 取结果；取消 = 对 `cancel_url` 发 `PUT`。
  认证头 `Authorization: Key <密钥>`。前几次问得勤（1 秒），之后每 2–4 秒。
- **取消必须在不继承取消的 Task 里发**（`cancelDetached`）：调用者的 Task 已经被取消时，URLSession 的 async 接口一看见取消就不发请求，直接 `await cancel` 的话 fal
  那边其实没被取消。这是写自检时用假协议逮到的（撤掉那一行，「fal 被要求取消了」一条得 0 不是 1）。
- 每种失败换成一句给 AI 看的话（`FalError.message`）：401 = Key 不对、403/402 = 余额用完或账号被锁（指去 fal 的账单页）、422 = 请求不合格（带上是哪个字段）、
  429、5xx、完成了但做失败、超时（替 fal 也取消）、网络。Key 相关的话都写「去设置 → AI」。
- 一次生成最多等多久：图 / 音效 / 旁白 5 分钟、音乐 15 分钟、视频 25 分钟（`FalModel.Kind.maxSeconds`），超了替 fal 取消。
- 下载：先下到临时文件再挪过去，下到一半断了不留半个文件；空文件、HTTP 错误都报错；**不把 Key 发给文件那台主机**。
- 自检 / 冒烟用 `SRTFLOW_FAL_QUEUE_BASE` 把队列地址指到本机的假 fal，**只认回环地址**（Key 不会因此发到别处）。

## 五、花钱（`FalSpendPolicy` / `FalSpendLedger`；2026-10-28 起只剩配旁白用）

1. **估算** = 登记的单价 × 用量（`FalModel.estimate`：图按张、视频按秒（分辨率分档）、旁白按千字符、音乐按成品分钟向上取整、音效按秒）。
   没登记单价（用户填了自己的端点又没填价、或 AI 点名的端点）估不出来 = nil。
2. **判断**：`今天已花 + 这次估算 ≤ 上限` 就直接做；超了、或估不出来，先问。上限 0 = 什么要钱的都问。差不到一美元的千分之一不算超。
3. **问 = 聊天里的确认码**（2026-10-17 起，[AI 多开方案](../plans/2026-10-17-multi-project-ai-editing.md) 板 9、J 节；**不弹模态框**，方案第 9、10 条）：
   **起任务之前**、在工具调用里就判断 —— 要问就当场回 `needs_confirmation` + `confirm_token`（删文件那一套 `AIConfirmations`：三十分钟、一次有效、
   同一件事等答复时回同一张、拒绝说原因），**什么任务都不起、不记账、不发请求**；AI 在聊天里把问题转述给用户，用户点头后带着令牌、同样的参数再调一次，
   才记账、起任务。令牌绑着这一次的估价和那几个记号（模型 / 档位、时长、清晰度…：`FalGenerationRun.summary`、`UpscaleJob.summary`），换一样不认。
   不答应就不再调，什么都没发生。
   以前是任务跑起来之后在**顶上的提示条**上问（两个按钮，问之前把剪辑页和 SrtFlow 摆到前面，问题不管这一轮什么状态都摆着）：
   AI 多开以后后台工程没有窗口、用户多半没在看 SrtFlow，提示条上的问题没人看见，任务就一直等。`AISession` 的 ask / question 一起撤掉了。
4. **决定和记账在同一步里做完**（中间没有 await）：同时起的几个任务不会各自以为还在额度内。记的是估算，按**本地自然日**、存 UserDefaults（`FalSpendLedger`，只留 40 天）。
5. **没做出来的退回，做出来了的不退**：失败 / 取消 / 超时退回估算；已经拿到结果、后面下载出了问题不退（fal 已经收了钱）。
6. **配旁白不问**：同步工具，客户端一分钟左右就超时。`FalSpendPolicy.allowsWithoutAsking`：额度不够 / 价格不明 / Key 读不出来 → 退到下一档声音，
   结果里 `voice.note` 写「fal.ai 的声音没用：会让今天超过 $X 的上限」并说去设置里改。
7. 每日上限、今天花了多少、每种事的模型都在设置 → AI 的 fal 一节（`FalSettingsRow`），`get_status` 的 `generation` 也报给 AI。

- **AI 起的 fal 任务（`generate_media`）的把关**原来只在 `FalJobGate.decide` 一处（额度内直接记账；超了 / 价格不明回确认码、收下令牌才记账；
  决定和记账同一步），任务只拿记好的那一笔。2026-10-28 起 `generate_media`、`upscale_clip` 都走 Sky Studio、花积分，把关在 `SkyStudioJobGate`
  （同一套确认码，[Sky Studio 的任务](sky-studio-jobs.md)），`FalJobGate` 跟着生成一起删了；fal 的钱只剩配旁白记（上面第 6 条），`checks/fal-wiring.sh` 第 4 条钉着。

## 六、Key 与钥匙串（`FalKeyStore` / `FalKeyCache`）

- 2026-10-27 起钥匙串的读写（下面的两档读法、缓存）抽成 `KeychainSecret` / `KeychainSecretCache`（`Sources/SrtFlow/KeychainSecret.swift`），
  和 Sky Studio 的 Key 共用一份（[Sky Studio 账号](sky-studio-account.md)）；`FalKeyStore` 只管 fal 这一条叫什么、粘进来的话怎么整理，`FalKeyCache.shared` 就是一个 `KeychainSecretCache`。
- 一条通用密码项：服务名 = bundle id + `.fal`（测试版是另一个 bundle id，另一条），账号 `api-key`。粘进来的先整理：去掉 `Key ` 前缀、引号、首尾空白 / 换行；
  中间有空白或太短就不收。
- **2026-09-29 本机探针量出来的行为**：只查属性（有没有存过）不弹授权框；读密钥本身时，只有创建这一项的那个签名能免弹窗读。App 是 ad-hoc 签名，
  **每出一个新版本签名就变了，第一次读会弹 macOS 的「要使用钥匙串里的机密信息」框**，点「始终允许」之后这一版不再弹。
  **2026-10-03 起发布版和测试版改用固定的自签名证书签**（[签名与系统权限](code-signing-and-permissions.md)）：探针量过，同一把证书签的下一个构建
  读前一个构建建的项不弹框，所以换签之后每台机器再点一次「始终允许」，之后升级不再弹。没有签名身份退回 ad-hoc 的构建照旧每版弹一次。
- 所以读分两档：`.silent`（`kSecUseAuthenticationUIFail`：要弹框就直接回「需要授权」）和 `.interactive`（弹框、等用户点）。**别改成 `LAContext.interactionNotAllowed`**：
  探针里它拦不住老式（文件）钥匙串的授权框，进程卡在框上等人点。任务里先试 `.silent`，需要授权时先在提示条上说一句「macOS 马上会问，请点始终允许」，
  再在后台线程上弹（不占主线程）；读到之后记在内存里（`FalKeyCache`），**一次运行最多弹一次**。
- 不用 data-protection 钥匙串：它要 entitlement，ad-hoc 签名的 App 用不了。
- 用户在设置里存 / 删 Key 时不读回来（读就可能弹框）：直接把刚存的记进 `FalKeyCache`。
- ~~取舍待用户拍板：Developer ID 签名才稳定~~ → 2026-10-03 用固定的自签名证书解决了（不花钱，见上一条）。访问控制不放宽，照旧按第 17 条存钥匙串、默认访问控制。

## 七、清单跟着 Key 走（`MCPProviders`）

- 2026-10-02 起 fal 的工具有两个：`generate_media` 和 `upscale_clip`。**2026-10-28 起两个都属于 Sky Studio 提供方**（`skystudio`：存了 Sky Studio 的 Key 才列，
  收费方案第 6 刀），fal 的 Key 不再多列工具（只管配旁白，`add_voiceover` 一直列着）；总说明的「Paid」那一行只在存了 Sky Studio 的 Key 时有。
  下面说的「列不列」照旧，那个小文件里两家的名字都写（`FalSettingsStore.syncProviders`，Sky Studio 的 Key 变了也叫它）。
- 工具清单由小程序（`skycut-mcp`）当场回（Claude 一启动就要，不能为此拉起 App），而 Key 在 App 的钥匙串里，所以 App 在 Key 添加 / 删除时、以及每次启动时，
  写一个**只有提供方名字**的小文件 `mcp-providers.json`（`{"providers":["fal"]}`，和 socket 同目录、按 bundle id 分开），小程序每回一次清单 / 握手都重读它。
  文件里没有 Key、没有别的机密；读得宽（不在 / 坏了 / 有不认识的名字都当没有）。
- 没配：`generate_media` 不列出来、总说明里也不提它（`MCPInstructions.text(providers:)`）。配了：列出来、总说明的目录末尾多一行（只指路：
  生成什么、要花钱）；花钱怎么问、每日上限、先告诉用户估价写在 `generate_media` 自己的说明里 —— AI 调它之前一定读得到，而总说明在
  Claude Code 里只读前 2,048 字（[AI 接口（MCP）](ai-control-mcp.md) 第一节第 6 条）。
- 清单会变，所以：握手声明 `tools.listChanged = true`，小程序每 2 秒看一眼那个文件，变了就给**握过手的老一代客户端**发 `notifications/tools/list_changed`；
  新一代（2026-07-28）没有会话，靠清单的缓存时间 —— `tools/list` 的 `ttlMs` 从一小时降到一分钟（`MCPServerCore.toolListTTLms`）。
- 说明总长度的上限量的是**每个提供方都配好**时的全清单：原来 72,000 字符（2026-09-29 配齐时 70,377；没配 fal 时 67,208；`generate_media` 整条 3,169、说明 1,685），
  到 2026-10-02 只剩 53 字：`generate_media` 的说明写上 `get_job` 的进度字段就到了 72,085，用户定抬到 **80,000**（约 2.2 万 token；`ProtocolChecks`），
  也给下一个 PR 的 `upscale_clip` 腾地方。以后再加工具还是先把别处写短。

## 八、generate_media（2026-09-29 起送 fal，**2026-10-28 起送 Sky Studio**）

> 2026-10-28 起（收费方案第 6 刀 6b）：模型由 Sky Studio 按种类定（`/models`：图 Seedream 5 Flash、视频 MiniMax H3（只有 480p / 768p）、音乐 Lyria 3 Pro
> （60–180 秒或让模型定、可以带歌词）、音效 Sonilo），价问 `/quote`、花积分，`model` / `options` 两个参数没有了；图生视频的首帧 `/uploads` 上去。
> 结果里报 `credits` / `credits_charged` / `skystudio_job_id`，成品也长期留在用户的作品库里。参数换成 Sky Studio 的写法在 `SkyStudioGeneration`（纯值），
> 工具 `SkyStudioGenerateTool`、任务 `SkyStudioGenerationRun`，规矩见 [Sky Studio 的任务](sky-studio-jobs.md)。下面是 fal 时代的做法（`FalGenerateTool` /
> `FalGenerationRun`，已删），留作对照。

- 参数：`kind`（image / image_to_video / text_to_video / music / sound_effect）、`prompt`，其余按种类：`image`（图生视频的首帧文件，点名文件夹以外的先问一次用户，
  同读别处的文件：图会发给 fal）、`duration`、`resolution`、`aspect_ratio`、`instrumental`、`name`、`model`、`options`。旁白不走它（`add_voiceover`）。
- 立刻回任务号，带 `estimated_cost_usd`、今天已花、每日上限、`next_step`（告诉用户估价、用 `get_job` 等、做完用 `add_clips` 放上去；音乐音效放 `new_audio`）；
  跑着的 `get_job` 带阶段（`phase` / `queue_position` / `transfer_percent` / `phase_seconds` / `typical_seconds`，第十三节）；
  完成的 `get_job` 带 `file`、`cost_usd`、宽高 / 时长（fal 报了的话）。H3 Max 的视频自带声音（环境声、拟音、配乐），**随片段一起播、不另开音频轨**（冒烟实测：放上时间线只有 V1 一个片段）——再配音乐 / 旁白时要压低或静音这个片段的音量（结果的 `note` 告诉 AI）。
- 成品文件是 SrtFlow 自己做的：登记进「AI 可以读」的地方（`AIReadGrants`，不在点名文件夹 / 工程的家里时），AI 接着 `add_clips` 不会再被问。
- 不改工程、不进撤销分组、不算这一轮的改动（`checks/fal-wiring.sh` 钉着路由）。

## 九、配旁白的 fal 档（`AIFalVoice` / `AIFalVoices` / `AIVoiceChoice`）

- 能用 fal 的条件（`AIFalVoice.offer`）：有 Key、这一批字不会让今天超过上限、Key 读得出来。三样有一样不行就退档（并说为什么，没接 fal 时什么都不说）。
- 挑音色：没点名按文字的语言取温和的角色的音色；点名角色换成对应的 ElevenLabs 预制音色（`AIFalVoices.byRole`，和 `AIVoiceRole.all` 一一对上，自检对账）；
  点名 ElevenLabs 的音色（`Rachel`、`Brian`…，大小写不敏感）照用；点名 Kokoro 的音色或这台 Mac 的声音仍照点名。名字撞了（Daniel 两边都有）fal 可用时按 fal。
- Eleven v4 没有语速参数：`speed` 被忽略，结果里说一句。
- 读一句：提交 → 下载到临时文件 → 解码成单声道 → **经 `AIAudioFileWriter.writeVoiceover` 落盘**（音量和文件格式只有一处说了算，和另外两种声音同一份，
  `scripts/check-mcp.sh` 那条扫描钉着）→ 记账。
- **词时间**：要字幕时请求 `timestamps`；fal 没写元素的形状，认三种常见写法（`{word|text, start, end}` 的对象、`[text, start, end]`、ElevenLabs 的按字符对齐）；
  换成字幕认的词（`AIFalVoices.timedWords`：英文词带前导空格、中日韩不加空格、时间夹进音频长度）；**词的字数和原文对不上（差三成以上）就不要** ——
  没有词时间字幕只是没有，不会错位；结果里 `subtitles.note` 告诉 AI 改用 `generate_subtitles`。
- 克隆（`clone_from`）：一段素材里有人声的地方（`clone_start` / `clone_seconds`，5–30 秒）→ 16 kHz 单声道 WAV → data URI → Zonos2。整段几乎没声音就说清楚。
  素材在点名文件夹以外要先问用户（声音会发给 fal）。用不了 fal 就报错，不退档（别的声音克隆不了）。

## 十、已知不足（真 Key 第一次要对的）

自动检查没有 Key、也不该花用户的钱，下面这些**没有对真的 fal 验过**，第一次用真 Key 时逐条看：

1. Eleven v4 的 `timestamps` 元素长什么样（接口定义里元素是空的）：读不出来就没有词时间，字幕退回没有；
2. 每个登记端点的实际产出（我们只对着接口定义验了请求体和样例输出的形状）；
3. 中文旁白用哪个音色好听：角色表是按 ElevenLabs 的音色描述配的，没有听过；
4. Zonos2 读中文的效果、参考音频 16 kHz 够不够；
5. H3 Max 促销价 2026-09-30 结束后的正式价（登记的是正式价，估价偏高不偏低）；
6. 估算不是账单：估价用登记的单价，fal 改价或换计费方式（比如 GPT Image 2.5 按 token）会偏。

## 十一、回归与人工清单

- `scripts/check-fal.sh`（`check-all` 第 2 组，不碰网络、不碰钥匙串）：模型表与估价、花钱把关、按天记账、**每个端点的请求体对着接口定义快照验**、样例输出与词时间、
  `FalClient` 走全流程（假 URLSession：提交 / 三次轮询 / 取结果、照 fal 给的地址、每种失败换的话、Task 取消和超时都替 fal 取消、下载收尾、没 Key 时一个请求也不发）、Key 的整理；
  （视频 upscale 那一组 2026-10-28 删了：upscale 走 Sky Studio，自检在 `scripts/check-upscale.sh` 和 `scripts/check-sky-studio.sh`。）
  **反向验证**做过：漏发必填的 `prompt_expansion_mode`、时长不夹、分辨率不规整、多发字段、上限刚好算超、取消不走 detached、Bearer 头、不用 fal 给的地址、
  音乐不满一分钟不向上取整、登记表对不上写法表、视频换成别的系列，各红。
- `scripts/check-mcp.sh` 的 `ProviderChecks`（清单按 Key 列不列：真起小程序，老一代收 `list_changed`、新一代不收；小文件的读写）和 `FalVoiceChecks`（挑音色、词时间、WAV）。
  反向验证：目录不按提供方过滤、握手不认会话、缓存时间不降、不发通知、总说明不分、小文件每次都写，各红。
- `checks/fal-wiring.sh`（扫描守卫，`check-all` 第 1 组）：fal 的文件里没有模态框、HTTP 只经 `FalClient`、Key 只经 `FalKeyCache`、把关 → 收令牌 → 发确认码的顺序、
  记账恰好两处、两个工具都在建任务之前过关、任务用记好的那一笔、没拿到结果才退账、不在提示条上问（`AISession` 没有 ask）、停止按工程取消任务、
  配旁白里没有 `.ask(`、清单跟着 Key 走、路由不进撤销分组。每条都反向验证过（2026-10-17 确认码那几条：把关挪到建任务之后、AISession 加回 ask、
  收令牌之后不记账、任务不用记好的那一笔、停止不取消任务，各红）。`scripts/check-mcp.sh` 的扫描：会回 `needs_confirmation` 的只有三处（删文件、读别处的文件、fal 花钱）。
- `scripts/check-fal-keychain.sh`（**本机手动**，不在 `check-all` 里：要一个能用的用户钥匙串）：存 → 有 → 读到 → 换 → 删；改 `FalKeyStore` 之后跑。
- `scripts/fal-models/refresh.sh`（要联网，手动）：见第二节。
- **人工回归**（发版前、拿真 Key）：
  1. 设置 → AI 里填 Key、保存：出现「密钥已存入钥匙串」，AI 客户端的工具清单里多了 `generate_media`（老一代客户端马上多、新一代一分钟内）；删除后没了；
  2. 让 AI 生成一张图、一段 5 秒 480p 的视频、一段音乐、一个音效：任务号 → `get_job` 出 `file`；放上时间线能播；视频带着声音；今天已花的数变了；
  3. 把每日上限改成 0.01 再让 AI 生成：AI 在聊天里问你（不是弹框、不是提示条），说出估价和上限；说不要，什么都没做、没花钱；说可以，它带码再调才做；
  4. 后台工程（`set_view background` 之后开的）上让 AI 生成超额度的：同样在聊天里问；
  5. 让 AI 配旁白：用 fal 的声音（结果里 `voice.name` 是音色名）；要字幕的话有字幕（或结果里有说明）；上限改成 0.01 后自动退到下一档、结果里说为什么；
  6. 用 `clone_from` 指一段自己的录音：出来的旁白像那个人；
  7. 装新版本后第一次生成：提示条先说「macOS 马上会问」，点「始终允许」后继续，之后不再弹；
  8. 点名一个没登记的端点（`model`）：先在聊天里问（价格不明），每次都问。

## 十二、视频 upscale（2026-10-02 起送 fal，**2026-10-28 起送 Sky Studio**）

fal 那一层（六个档位、四个端点的请求体和快照、`FalUpscalePricing` 估价、`FalClient.upload`、账单明细 `FalBilling`）2026-10-28 随
[收费方案](../plans/2026-10-27-paid-plans-and-sky-studio-key.md)第 6 刀删了：upscale 改走 Sky Studio，只剩 `topaz-starlight` 和 `bytedance-upscaler-pro` 两档、
模型和上限从 `/models` 读、价问 `/quote`、花用户的 Sky Studio 积分。现在的规矩在 [视频 upscale](video-upscale.md) 和 [Sky Studio 的任务](sky-studio-jobs.md)。
fal 时代量出来的计费规律和画质印象留在 [smoke test 实测](../reports/2026-10-02-upscale-smoke-test.md)（Sky Studio 定价时也参考了它）。

## 十三、进度：AI 从 `get_job` 看、用户从编辑器顶上的状态行看（2026-10-02 起）

> 用户 2026-10-02 定：送 fal 的活（upscale、`generate_media`）在上传和生成中都要看得见进度。改 `FalJobPhase.swift`、`FalTransfer.swift`、
> `FalStatusRows.swift`、`AIJobs.liveDetail` 之前必读。

| 决定 | 口径 |
| --- | --- |
| 阶段是一份（`FalJobPhase`，纯值） | 六步：`preparing`（裁一段 / 把关花钱、取 Key）→ `uploading`（带字节比例）→ `queued`（带排队位置）→ `processing` → `downloading`（带字节比例）→ `finishing`（封回原声、落盘）。upscale 六步都走；`generate_media` 只有图生视频有上传（2026-10-28 起首帧 `/uploads` 上去；fal 时代图是内嵌的）。`FalJobProgress` 再记这一阶段从什么时候起（换比例不重记、换阶段才重记）和这一档通常要几秒 |
| **fal 处理中没有百分比** | 队列接口只给 `IN_QUEUE`（带 `queue_position`）和 `IN_PROGRESS`，日志里的步数各模型格式不一，**不能当百分比**。能给的就是阶段、排队位置、这一阶段已用的秒数、这一档的典型时长 —— 「处理中 48 秒，这档通常约 1 分钟」，**不画假进度条** |
| 典型时长 | upscale 的照 Sky Studio `/quote` 报的 `typical_seconds`（2026-10-28 起；fal 时代每档写死一个实测数），面板上的「about N min」和进度里的「usually about N min」都从它算（`FalJobProgress.minutes`，不满一分钟算一分钟）；`generate_media` 2026-10-28 起也照 `/quote` 的 `typical_seconds`，没报时按种类（`SkyStudioGeneration.typicalSeconds`：图 15 s、音效 10 s、音乐 60 s、视频 180 s，和工具说明里写的一致） |
| 上传 / 下载的字节进度 | `FalTransfer`：上传 `uploadTask(with:fromFile:)` + `didSendBodyData`，下载 `downloadTask` + `didWriteData`（`didFinishDownloadingTo` 那一拍当场把系统的临时文件挪到成品旁边的 `.part` 文件，回调一返回系统就删它）；按 1% 一格、没变不报；服务器没说总长就不报比例；**成功时 `FalClient` 一定补报 1**，失败 / 拒绝不报 1。`URLSession` 只许出现在 `FalClient.swift` 和 `FalTransfer.swift`（`checks/fal-wiring.sh`） |
| 给 AI 的 | `AIJobs.Job.liveDetail`：跑着的任务可以给一份明细，`get_job` 只在 running 时并进去。fal 的两种任务给 `FalJobProgress.json`：`phase`、`queue_position`（排队时）、`transfer_percent`（上传 / 下载时，整数）、`phase_seconds`、`typical_seconds`（知道时）。工具说明里写明这几个字段，AI 看了「排队第 3 位」「这档通常 2 分钟」就不会每 30 秒问一次只会说「还在跑」 |
| 给用户的 | 编辑器顶上的状态行 `FalStatusRows`：挂在「AI 正在剪辑」那条横幅底下（mockup「Status row while upscaling」说的「复用编辑器那条状态行」），每个 upscale 任务（`UpscaleActivity.jobs`）和生成任务（`SkyStudioGenerationActivity.runs`，2026-10-28 起）一行：做什么、四个阶段的小标（过了的打勾、当前的带百分比 / 已用时间 / 「通常约几分钟」、没到的灰着）、积分、停止；upscale 做完那一行 Compare… / Dismiss。生成任务做完 / 失败 / 取消就从行上消失（结局 AI 会告诉用户）。检查器那一节同一份文字（`FalPhaseText`）。只订阅两个小对象、不读工程；**没有任务时什么都不画、不醒**（性能场景里计数为零，所以它能挂在横幅底下而不动基线） |
| 不改的 | `generate_media` 的结果和落点、upscale 做完先弹对比窗口的流程、钱怎么问、Key 怎么读 —— 这一节只加进度 |

回归：`scripts/check-fal.sh` 第八组（阶段、进度账、get_job 的字段、典型时长折成的分钟数、同一阶段同一比例只报一次）和第五 / 七组
（下载 / 上传的比例只升不降、成功最后是 1、失败不报 1、不留 `.part`）；`scripts/check-upscale.sh` 第五组（流水线的阶段按顺序、上传 / 下载报到 100%）；
`checks/fal-wiring.sh` 第 2、8 条（传输只经 FalTransfer、上传 fromFile、liveDetail 接到 get_job、横幅底下挂着状态行）和 `checks/sky-studio-wiring.sh` 第 9 条
（生成任务登记进 SkyStudioGenerationActivity、状态行订阅它、get_job 有阶段和 skystudio_job_id）。
人工：存着 Sky Studio 的 Key 做一次 upscale（2026-10-28 起走 Sky Studio），状态行上「Uploading 35%」真的在走、排队位置变、处理那一格每秒走、下载百分比、做完 Compare…；
AI 用 `generate_media` 做一段视频时 `get_job` 的 `phase` 从 queued 到 processing 到 downloading，状态行同步。

