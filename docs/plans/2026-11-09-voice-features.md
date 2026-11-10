# SkyCut 声音方案（草稿）

> **2026-11-10 用户批准施工；Sky Studio 那份方案（`Sky-Studio-声音方案.md`）在 Sky Studio 仓库。** 按第十节的 PR 1 → 9 做，做到哪看合进 main 的 PR 和 [声音库](../architecture/voice-library.md)。
> 本方案 2026-11-10 放进 `docs/plans/`、在 AGENTS.md 补了索引，正文保持批准时的原样（下面「只是方案，不写代码」「批准之后放进 docs/plans/」这几句是批准前写的）。文中的 `SkyCut-MCP按需说明方案.md` 就是本仓库的 [MCP 按需说明](2026-11-09-mcp-guide.md)；`决定汇总-2026-11-09.md`、`plan-contract.md` 和各轮实测的文件夹（`round5-2026-11-09/` 等）在仓库外的 `SkyVoiceForClone/` 文件夹里。
>
> 2026-11-09 · 给用户审 · **只是方案，不写代码**（写代码要等用户明确说「写」）。
> 唯一依据：同一文件夹的 `决定汇总-2026-11-09.md`（下文简称「决定」），含第七、八节（2026-11-09 晚看过两份草稿后补拍的板）。两份方案的共同约定见 `plan-contract.md`（下文简称「约定」，第二节照写）。
> **接口名字已对齐 Sky Studio 方案**（`Sky-Studio-声音方案.md` 2026-11-09 22:39 版文末的「名字对照」表）：任务种类、模型 id、字段名、路径都用那张表里的。第三节末尾「SkyCut 需要 Sky Studio 提供的东西」已和那份（同一版）逐项核对，没对上的列在第十三节。
> MCP 工具照 `SkyCut-MCP按需说明方案.md` 的新规矩写（名片常驻 + 说明书 `skycut_guide` 按需读），那件事先做（决定第七节第 3 条）。MCP 工具名是 SkyCut 自己的，审的时候可以改。
> 批准之后这份放进 SkyCut 的 `docs/plans/`、在 AGENTS.md 补索引（这次不做）。

---

## 〇、先说结论

1. **配旁白改成「自动选模型」**。SkyCut 不再自己挑模型（现在是取 `/models` 里那一类的第一个）。普通旁白 kind `voice`、克隆读稿 kind `voice_clone`，`model` 写 `auto` 或点名的 id。整段先 `POST /quote`（带 `params.batches`），服务器回 `voice_plan`（选了哪个模型、`rule`、`reason`、各语言的 `share`、`cross_language`、`warnings`），SkyCut 原样告诉 AI 和用户；每批 `/jobs` 带 `model: "auto"` + `params.plan`，保证整段一个模型。
2. **声音的名字**：声音库的 `voice_…`、预设的 `gemini:<名字>` / `eleven:<名字>`；照旧认 8 个角色（对应关系从 `/models` 的 `voice_roles` 读）和本机 Kokoro / macOS 的名字。MiniMax 的 voice_id 永远不进 SkyCut。不点名默认 `gemini:Charon`。
3. **MCP**：新增 `list_voices`（只读）、`manage_voices`（声音库）、`change_voice`（变声）；`add_voiceover` 加 `model`、`skip_one_time`，去掉 `clone_from` 那三个参数（决定第七节第 8 条）。四个工具都按「名片 ≤ 450 字 + `skycut_guide` 主题」写，**不抬清单上限**（决定第七节第 3 条）。
4. **两种权限模式分开**（决定第七节第 1 条）：**请求批准**模式下，一次性费用、用录音建声音的授权、删声音都先问（界面是对话框，AI 走确认码）；**全部权限**模式下什么都不问，代价是在**打开全部权限的那一刻**弹一次说明：列出一次性费用价目（设计一个声音约 750 积分、给声音建 MiniMax 版约 375 积分，数从 `/models` 的 `price` 读），并记一次「以后用来克隆的录音我都有权使用」的长期授权（`POST /voices/consent-grant`，之后建声音带 `consent: "standing_grant"`）；之后 AI 直接做、做完通知。每日硬预算两种模式都照样拦。
5. **MiniMax 版第一次用到时再建**（决定第七节第 7 条、第八节第 5 条）：请求批准模式问一次，不建就这一单用报价里不花一次性费用的那个（英文是 IndexTTS2，其他语言是 HeyGen Turbo）；全部权限直接建（kind `voice_enroll`）、事后通知。新建声音（`POST /voices`，只存录音）不花钱。
6. **界面**：「设置 → 剪辑与声音」里加「声音库」一节；一个共用的声音选择器（按语言、能试听）；新建声音对话框（录音或选文件，10 秒到 3 分钟，同一个框里勾授权、看费用）；设计声音对话框；片段右键「换成我的声音…」；「设置 → 连接 AI」打开全部权限时的那张说明。
7. **参考录音**：去掉「默认 10 秒、最多 30 秒、降到 16 kHz」；至少 10 秒有效人声、最长 3 分钟、44.1 kHz 单声道 16-bit WAV（各轮实测用的就是这个规格）；超过 3 分钟本机挑最好的连续 3 分钟并说用了哪一段；上传用途 `voice_reference`，上限 35 MB（决定第七节第 2 条）。
8. **字幕时间**：Eleven v4 用它给的字符时间；别的模型在本机转写对齐；本机转写不了的语言又要字幕：预设声音整段点名 `eleven-v4`，克隆 / 设计的声音按字数估算并说明是估的（决定第七节第 5 条）。
9. **变声**：kind `voice_convert`，单声道上传（`voice_convert_source`，≤ 35 MB），每段最长 5 分钟（决定第八节第 8 条）；服务器回 `voice_url` + `background_url`，SkyCut 放两条新音频轨、原声静音、一步撤销。
10. **并发**：声音类任务单独一个池，每账号 8 个（决定第八节第 3 条；`/me` 的 `max_running_audio_jobs`），图片、视频仍 3 个。SkyCut 按池开槽；普通旁白和克隆一样按约 60 秒合批（用户定，8.1），一段旁白的几批同时交（现在是串着交）。
11. **拆 9 个 SkyCut PR**：Sky Studio 先上线（zonos2 在同一个 PR 里直接下线，决定第八节第 9 条）；说明书方案先做，声音的 PR 3 起排在它的试点 PR 之后。
12. **需要用户拍板**：现在没有了。上一版的 8 条、后来冒出的「升级前就开着全部权限怎么补」（直接当作已授权）、第十三节第 1、2 条都已定，写进了正文（第十二节）。
13. **和 Sky Studio 方案逐项核对**（第十三节）：第三节的 15 条需求，13 条给了、1 条只给了一半、1 条没给；连同读那份时发现的做法差异，一共 11 处没对上，其中 2 处你已定（普通旁白也合批；不建 MiniMax 版时英文用 IndexTTS2、其他语言用 HeyGen Turbo），已改进正文；其余 9 处里，4 处已照建议改进本方案正文，5 处由 Sky Studio 那份补。

---

## 一、范围

| 这一轮做（SkyCut） | 不做 |
|---|---|
| MCP：配旁白选声音 / 模型、跨语言提示、一次性费用和授权（分两种权限模式）、声音库增删查、声音设计、视频变声 | Sky Studio 网页上的入口（决定第一节） |
| 界面：声音库、选择器、新建 / 设计声音、片段右键变声、打开全部权限时的说明 | 两个人的对话（Gemini 双说话人，决定第二节：第二批） |
| 参考录音去掉旧限制、超 3 分钟自动挑一段 | Gemini 的「复刻声音」、ElevenLabs 直连、zonos2（决定第一节） |
| 字幕时间：本机对齐 / 点名 `eleven-v4` / 估算 | 选模型、换备用、积分、对账、声音库存储（都在 Sky Studio 方案） |
| 并发：按池开槽、几批同时交 | 价格写进 SkyCut（价格只在 `/models`、`/quote`，决定第一节） |

前提：Sky Studio 那边的声音接口先上线（约定第 7 条：接口的主人是 Sky Studio）。SkyCut 的界面和 AI 都只是这个共用声音服务的一个客户端：选模型、换备用、按语言存参考都放在服务器，以后 Workspace、Cinematic 直接用同一套（决定第一节）。

---

## 二、两份方案共同遵守的约定（照写）

下面 7 条是 `plan-contract.md` 的原文，每条后面写 SkyCut 这边怎么落地。

> 1. **选模型的规则放在 Sky Studio 服务器上**。以后 Workspace、Cinematic 也要用，所以「按读出来的时长算语言占比、≥ 80% 用那种语言的默认、不到 80% 整段一个模型、混合用中文参考、出错换备用」都在服务器的共用声音服务里做。SkyCut 发请求时 `model` 写 `auto`（或者用户 / AI 明确点名的模型），带上文字和要用的声音。`/quote` 和 `/jobs` 的回答里都带：实际选了哪个模型、各语言占比、为什么、是不是跨语言（要不要提示「效果不如同语言」）。

→ SkyCut：删掉本机挑模型那一行；`add_voiceover` 加 `model`；结果和 `get_job` 报 `voice_plan`（4.2、4.4）。一段旁白分几批时，各批带 `params.plan` 沿用整段的选择（8.4）。

> 2. **一次性费用和授权**：新建 MiniMax 声音、声音设计这类一次性费用，先在 `/quote` 里单独列出来；SkyCut 负责问用户（界面上是对话框，AI 那一路走现有的确认码 `AIConfirmations`）。服务器要求请求里带 `max_credits`；用录音新建声音时还要带 `consent: true`，并把同意记录（谁、什么时候、哪段录音）存下来。

→ SkyCut：`/quote` 的 `one_time[]` 不为空时，请求批准模式下问（对话框 / 确认码），建声音带 `consent: true`；全部权限模式按决定第七节第 1 条不问，靠打开全部权限时那一次说明和长期授权，建声音带 `consent: "standing_grant"`（4.5、5.6）。一次性费用和授权都进 `SkyStudioJobGate`，不新开第五个确认入口。

> 3. **声音的身份**：SkyCut 和 AI 只看到 Sky Studio 自己的声音 id（比如 `voice_…` 这种我们自己发的 id）和预设声音的名字（比如 `gemini:Charon`）。**任何服务商的 id（MiniMax 的 voice_id）都不出服务器**。

→ SkyCut：DTO 里没有服务商 id 的字段（声音的 `languages[].minimax` 只是布尔值）；扫描守卫禁止源码和测试数据里出现 MiniMax voice_id 的样子（9.1 第 12 项）。

> 4. **视频变声的结果**：服务器只负责 SAM 分离 + Chatterbox HD 变声，并把变声后的人声在结尾补静音补齐到原长，然后**分别返回两个文件**：变声后的人声、分离出来的背景。**混音在 SkyCut 里做**：两段各放一条新音频轨（互相链接），原片的声音静音不删，一步撤销回去。这样服务器不用做混音，用户还能单独调背景音量；以后网页要用，再在服务器加一步混音。

→ SkyCut：`change_voice` 和右键面板的落地规则见 4.8。

> 5. **字幕时间**：Eleven v4 返回字符时间，其他模型不返回。SkyCut 知道自己的本机转写支持哪些语言，所以由 **SkyCut 决定**：这一段的语言本机转写不了、又要字幕时，就明确点名 `eleven-v4` 来读；Eleven 也不支持就按字数估算并提示。服务器不管这件事，只照点名的模型读。

→ SkyCut：第七节。克隆 / 设计的声音不换 Eleven、按字数估（决定第七节第 5 条）。

> 6. **合批和并发**：SkyCut 沿用现在的做法，把多句合成几批、每批一个任务。每个账号同时最多 3 个任务的上限要不要放宽、怎么放宽，由 Sky Studio 那份给建议；SkyCut 那份按「上限可能是 3，也可能放宽」两种情况都写清楚怎么排。

→ SkyCut：第八节。已定声音池 8 个（决定第八节第 3 条）；服务器还没给 `max_running_audio_jobs` 时按共用的 3 个排，两种都写了。

> 7. **接口名字**：新的任务种类、模型 id、字段名由 Sky Studio 那份定（它是接口的主人）。SkyCut 那份先用描述性的名字写（比如「克隆读稿任务」），标注「以 Sky Studio 方案为准」，等两份都写完由我来对齐。

→ SkyCut：已照 Sky Studio 方案的「名字对照」表换完。

---

## 三、现在的代码，和要改成什么

读的是 SkyCut main（`7a9d8c9`）。

| 现在（文件） | 和决定的差别 | 改成 |
|---|---|---|
| `SkyStudio/SkyStudioVoiceoverRun.swift` `prepareNew`：`catalog.models(kind:).first` 挑模型 | 本机挑模型 | 送 `model: "auto"` / 点名的 id，读 `/quote` 的 `voice_plan` |
| `SkyStudio/SkyStudioVoices.swift`：8 个角色 → ElevenLabs 预制名（Jessica、Sarah、Eric…），默认 Rachel；本机抄一份 Eleven 名单 | 决定第四节：角色改指 Gemini，默认 Charon；SkyCut 不写死 | 删掉这张表和名单；预设读 `/models` 的 `voice_presets`，角色读 `voice_roles` |
| `AIVoiceChoice.Engine.skyStudio(voice:)`：只有一个名字 | 分不出预设和声音库 | 分「预设」「声音库」两种，带上点名的模型 |
| `AIVoiceoverInput.cloneSource`：`clone_seconds` 默认 10、夹在 5–30 | 决定第三节第 3 条、第七节第 8 条 | 去掉；克隆一律先进声音库 |
| `VoiceReferenceSample.swift`：截成 16 kHz 单声道 WAV，≥ 3 秒就收（报错却说 5 秒） | 去掉降采样；最短 10 秒有效人声；最长 3 分钟 | 44.1 kHz 单声道 16-bit、10 秒–3 分钟、自动挑一段（第六节）；上传用途 `voice_reference` |
| `SkyStudioVoiceCloudBatches`：参考放 `inputs.reference_audio_url`，每次现传 | `voice_clone` 不再收参考，参考从声音库拿 | 只送 `params.voice: "voice_…"` |
| `SkyStudioVoiceoverRun.process`：各批**一批一批串着交** | 决定第三节第 9 条：要合批或同时提交 | 按池领槽、同时交（第八节） |
| `SkyStudioVoicePlan` / `SkyStudioVoiceBatch`：普通旁白一句一单，克隆按 `/models` 的字数上限合批 | 用户定：普通旁白也合批（8.1） | 普通旁白也合批（合批不再只给克隆），上限改读 `limits.max_characters_by_language`；批只在两句之间分，一句超长先在句末标点分；本机切不开的语言不合批（第七节）；`eleven-v4` 读的按字符时间切（`SkyStudioVoiceSplit` 加这一种）；报价改成整段一次（`params.batches`） |
| `SkyStudioVoiceAudio.splitLocale`：转写模型没装就在收费前报错、不下载 | 新增的语言多了（日、韩…），每次报错不实用 | 收费之前**明着**下载（状态行写「准备本机转写」，和生成字幕同一个 `ensureModel`）；macOS 15 / 不支持的语言走第七节 |
| `AIVoiceoverTool.result`：Sky Studio 没给 `words` 的句子就没有字幕 | 决定第三节第 6 条、第七节第 5 条 | 本机对齐 / 点名 `eleven-v4` / 估算，结果带 `subtitle_timing` |
| `SkyStudioVoiceCheckpoint` `version = 1`（读的时候只认 1） | 要记 `voice_plan.selection`、每批实际用的 `model` 和 `fallback_used` | 升到 version 2；不再认 version 1（只有用户本人在用：升级前把没做完的配音做完或放弃） |
| `sky-studio-jobs.md` 第五节「先回任务号：Key、模型、全部报价都在任务里」 | 一次性费用要在花钱之前问 | 整段一次 `POST /quote`（带 `params.batches`）挪到回任务号之前；任务里只剩预留、交、等、切、落地 |
| `SkyStudioJobGate`：硬预算 + 请求批准模式下的规格偏离 | 一次性费用、授权、删声音要按两种模式分开 | 加这三样（4.5）；全部权限下靠开启时记的授权 |
| `AIAccessSettingsSection` / `AISettingsApproval`：切到全部权限没有任何说明 | 决定第七节第 1 条 | 打开全部权限时弹说明、`POST /voices/consent-grant` 记长期授权；关掉时 `DELETE`（5.6） |
| `MCPMediaTools` 的 `add_voiceover` 说明 1,069 字（全清单最长的一条），写着 Rachel / Brian、Kokoro 下载、`clone_from` | 过时；清单只剩 3,694 字余量 | 改成名片 + 说明书主题（4.10） |

### SkyCut 需要 Sky Studio 接口提供的东西（名字已对齐；逐项核对的结果见第十三节）

| 需要 | 为什么 |
|---|---|
| `/models` 的 `voice_presets`：每个预设按语言分开的 `listed` / `gender` / `rating` / `description`（`zh`、`en` 两种界面文字）/ `sample_url`，`default`、`other_languages`、`fallback`（Eleven 备用） | 选择器和 `list_voices` 按语言显示（决定第四节）；西语界面用 `en` 的说明 |
| `/models` 的 `voice_roles`：8 个角色 → 预设 id | SkyCut 不再写死角色表（4.3） |
| `/models` 里 `minimax-voice-clone`、`minimax-voice-design`、`qwen3-voice-design` 的 `price`（`typical_credits`） | 打开全部权限时的说明要列价目（5.6），SkyCut 不写死 |
| 声音库：`GET/POST /voices`、`GET/PATCH/DELETE /voices/{id}`、`POST /voices/{id}/references`；`consent: true`；只回 `voice_…`；声音的 `languages[]` 带 `minimax`（布尔）和试听用的临时链接 | 4.6 |
| 授权两种来源：建声音、加参考时 `consent: true`（可带 `consent_statement_version`）或 `consent: "standing_grant"`；长期授权 `GET/POST/DELETE /voices/consent-grant`；两句文案的当前版本和英文原文在 `/models` 的 `voice_consent`（`per_recording`、`standing`） | 决定第七节第 1 条；SkyCut 要知道这个账号记没记过长期授权、是哪一版，全部权限下才能不问（4.5、5.6、第十二节） |
| `POST /quote` 收 `params.batches`，回 `voice_plan`、`batches`、`one_time`、`credits`（作 `max_credits`）/ `credits_expected` / `settlement` | 一次性费用要先问；各批不能各选各的（8.4）；界面写「约 X（最多 Y）」 |
| 每批 `/jobs` 收 `model: "auto"` + `params.plan`；某批换了备用后，后面各批带 `voice_plan.fallback.selection` | 决定第三节第 1 条、第七节第 6 条 |
| `model: "auto"` 时报价前就知道怎么分批：这个 kind 下各模型的 `limits.max_characters_by_language` 一样，或者给一份 kind 级的 | 分批在报价之前（8.1） |
| 任务结果的 `model`（实际跑的）、`fallback_used`、`voice_plan`；Eleven 的 `words` 原样 | 结果要说清楚用了哪个模型（决定第三节第 1 条）；字幕时间 |
| 一次性费用的错误：409 `one_time_required`（点名的模型）、任务结束码 `fallback_needs_one_time`（带 `one_time`、`refunded`）；`voice_plan.rule: default_needs_one_time` | 4.5 |
| `eleven-v4` 支持哪些语言（`/models` 里能读到） | 「Eleven 也不支持就估算」要先知道（第七节） |
| `voice_convert`：`inputs.source_audio_url`、`params.target_voice`、`params.source.seconds`；结果 `voice_url` + `background_url`；`limits.max_source_seconds`（5 分钟） | 4.8 |
| 上传用途 `voice_reference`、`voice_convert_source`，上限 35 MB，收单声道 WAV | 决定第七节第 2 条、第八节第 8 条 |
| `/me` 的 `max_running_audio_jobs`；429 `too_many_jobs` 带 `pool` | 第八节 |
| 每账号最多 50 个声音（409 `voice_limit`）、`reference_exists`、`minimax_voice_exists`、`invalid_request` 的 `too_long` / `too_little_speech` / `unsupported_language` / `consent_required` / `no_standing_grant` / `consent_outdated` / `upload_too_large`；删除时存储暂时不可用回 503、再发一次 DELETE 接着删；私有声音桶没配时回 503 `voice_library_unavailable`（预设旁白照常） | 界面和 AI 要说人话（4.6、5.1） |

---

## 四、MCP 工具

### 4.1 一览

| 工具 | 新 / 改 | 只读 | 做什么 | 花钱 / 要问（请求批准模式；全部权限都不问） | 撤销 |
|---|---|---|---|---|---|
| `add_voiceover` | 改 | 否 | 读稿：预设、声音库、角色、本机声音 | 收费；要建 MiniMax 版时问一次 | 落地那一下一步（不变） |
| `list_voices` | 新 | 是 | 我的声音 + 某种语言的预设名单 | 免费 | — |
| `manage_voices` | 新 | 否 | `create` / `add_reference` / `design` / `rename` / `delete` | 用录音建声音问授权；设计问一次性费用；删除问一句 | 服务器上的事，不进时间线撤销 |
| `change_voice` | 新 | 否 | 把一段的人声换成某个声音（长任务） | 收费；不是一次性费用，不问 | 落地那一下一步 |
| `skycut_guide` | 说明书方案新加 | 是 | 四个声音工具各一个同名主题 | 免费 | — |
| `get_job` / `cancel_job` / `get_status` | 不变 | — | 等、停、看；变声和设计在 `cloud_tasks` 里算音频任务 | — | — |

每日硬预算两种模式都拦，超了当场 `daily_budget_exceeded`、不发越额码（现有规矩）。

为什么是三个新工具：AI 接口第一节第 5 条「只读的和写的不放进同一个工具、不许有两个长得像的」；照角色 A/B 的先例（`list_characters` 只读、`manage_characters` 一个写工具按 `action` 分）。变声改时间线、是长任务，和 `upscale_clip` 同一类，单独一个；它不能并进 `add_voiceover`（输入是一段现成的声音，不是文字），也不能并进 `generate_media`（那个不改工程）。

### 4.2 `add_voiceover` 改什么

| 参数 | 现在 | 改成 |
|---|---|---|
| `voice` | 角色 / Rachel 这类 Eleven 预制名 / Kokoro / Mac 的名字 | 认 `voice_…`、`gemini:<名字>`（也认不带前缀的预设名）、`eleven:<名字>`、角色、Kokoro / Mac 的名字（4.3）；**不带前缀的 Eleven 旧名（Rachel 这类）不再收**，要用 Eleven 就写 `eleven:<名字>`（决定第十二节） |
| `model` | 没有 | 新：`auto`（默认）；预设可点名 `gemini-3.8-flash-tts` / `eleven-v4`，声音库的声音可点名 `index-tts-2` / `minimax-speech-2.8-hd` / `heygen-voice-turbo`；只对云端声音有用 |
| `skip_one_time` | 没有 | 新：请求批准模式下用户不肯花一次性费用时带 `true`：新的一单照报价里不花一次性费用的那个读（`voice_plan.selection`：英文是 IndexTTS2，其他语言是 HeyGen Turbo）；和 `resume` 一起用时，没做成的批用原来的模型重试 |
| `confirm_token` | 没有 | 新：请求批准模式下一次性费用的确认码 |
| `clone_from` / `clone_start` / `clone_seconds` | 有 | 去掉（决定第七节第 8 条）；带了就当说明上没有的参数名，整个调用不做（现有的参数核对，报错指向说明书），不另做指路 |
| `lines`、`speed`、`track`、`subtitles`、`max_lines`、`download_voices`、`resume`、`generate_missing` | | 不变 |

一次云端配旁白的流程：

1. 核对参数、认声音（4.3）。本机声音照旧同步读完、直接落地。
2. 云端声音：静默读 Key、读 `/models`（缓存 10 分钟），先分批（8.1），再 **`POST /quote` 一次**：kind `voice` 或 `voice_clone`、`model`、`params.voice`、`params.batches`（每批的文字）；语言提示 `params.language`：拉丁字母的那些句子用 NaturalLanguage（`AITextLanguage`，已经在用）判主要语言，判得出、而且不是英文时才带（`es`、`de`、`fr`…，ISO 639-1），中文、日文、韩文这些服务器自己分得清，英文是服务器的默认，都不带；占比照样由服务器算，提示只给它分不清的拉丁字母短句当依据（Sky Studio 方案 5.2 ①）。回：`credits`（最多，当 `max_credits`）、`credits_expected`（大概）、`settlement`、`batches[]`、`voice_plan`、`one_time[]`。
3. 把关（`SkyStudioJobGate`）：每日硬预算按 `credits` 加一次性费用算；`one_time` 不为空：请求批准模式回 `needs_confirmation`，全部权限模式先交 `voice_enroll`、做完再报一次价（4.5）。
4. 起任务，回 `job_id`，同时回 `voice_plan` 和 `voice.note`；`cross_language` 或 `warnings` 不为空时，`next_step` 要 AI 在用户听之前先转告（4.4）。
5. 任务里：按 `credits` 预留 → 每批 `/jobs` 带 `model: "auto"` + `params.plan`（`voice_plan.selection` 原样）+ 这一批的 `max_credits`，按槽同时交（第八节）→ 下载 → 本机切句 / 对齐（第七节）→ 写文件（照旧只经 `AIAudioFileWriter.writeVoiceover`）→ 一步落地（音频 + 字幕在同一个 `AIUndoGrouping.step`）→ 按 `billing` 实收改本机的账，多的退一次（决定第八节第 4 条）。

整段的 `POST /quote` 挪到回任务号之前的理由：一次性费用要在**花钱之前**问（决定第三节第 4 条）；`generate_media` 本来就是先报价、过关再起任务。只多一个请求（一段旁白一次，不是每批一次），客户端等一分钟绰绰有余。报价时服务器不可用：普通旁白当场退本机（Kokoro > macOS，决定第七节第 4 条；现在是在任务里退，挪到前面）；声音库的声音报错、不退本机（和现在的克隆一样）。付费请求交出去之后就不再退本机（现有规矩「只有付费请求之前可用本机退档」不变）。

结果和 `get_job` 加的字段：`voice_plan`（原样，不含任何服务商 id）；各句不全是同一个模型时，每句的 `model` 和 `fallback_used`；`subtitle_timing`（`provider` / `aligned` / `estimated` / `mixed`）；全部权限下替用户花了的一次性费用 `one_time_spent`；要转告用户的话照旧放 `voice.note`。

### 4.3 认声音

| AI 给的 `voice` | 云端用什么 | 本机退档（没 Key / 报价时服务不可用） |
|---|---|---|
| 没给 | `gemini:Charon`（决定第二节） | 照 `voice_roles` 里指向 Charon 的角色：中文 `zh_male`、英文 `en_male`，用它的 Kokoro / Mac 声音 |
| 8 个角色之一 | 照 `/models` 的 `voice_roles`（决定第四节：活泼女声 → Laomedeia、温暖女声 → Sulafat、男声 → Charon、英式女声 → Erinome、英式男声 → Iapetus，只用于英文）；英式男声碰上不是英文的文字，改用同语言男声角色对应的那个（现在是 Charon），并在 `voice.note` 说一声 | 照旧：角色的 Kokoro 音色 / Mac 声音 |
| `gemini:<名字>`，或不带前缀的预设名 | 照读；它在这种语言里不在名单上（`warnings: not_listed_for_language`，比如中文稿点名 Aoede），照读并在 `voice.note` 里说一声 | 按这个预设在这种语言的 `gender` 挑角色 |
| `eleven:<名字>` | Eleven v4 | 照旧退本机 |
| `voice_…` | 声音库里的声音，规则在服务器 | 不退本机，报错 |
| Kokoro 音色名 / Mac 声音名 | 不走云端 | 照旧 |

- 小程序的角色词表（`MCPVocabulary.voiceRoles`）照旧，检查里核对 `voice_roles` 覆盖全部 8 个角色、指向那种语言里 `listed` 的声音。
- 同一个声音中英文听起来可能是两个人（Gacrux、Kore、Callirrhoe，决定第四节），所以凡是报声音的性别 / 说明，都按这次读的语言报。

### 4.4 选模型和跨语言提示

- 不给 `model` = `auto`。SkyCut 只做三件事：把文字、声音、点名的模型送过去；把 `voice_plan` 原样报出来（`reason` 是英文，给 AI 原样用；界面按 `rule` 本地化）；一段旁白多批时整段一个选择（8.4）。
- 点名的模型和声音配不上（比如 `gemini-3.8-flash-tts` 配 `voice_…`）：服务器在报价时拒，SkyCut 原话转给 AI，一分不花。点名的模型没测过这种语言：照做，`warnings: model_not_tested_for_language` 进 `voice.note`。
- **跨语言**：`cross_language=true` 时，起任务的回答里带 `voice.note`（「这个声音没有日语的录音，用中文录音读日语，效果不如同语言」），`next_step` 要 AI 先转告用户。不发确认码：决定写的是「提示」不是「先问」；要是同时有一次性费用，提示就写进那一个问句里，只问一次。

### 4.5 一次性费用、授权和删除：两种权限模式

| 情况 | 请求批准模式 | 全部权限模式（决定第七节第 1 条） |
|---|---|---|
| 用录音新建声音 / 加一种语言的录音 | `needs_confirmation`：授权问句，每段录音一次；交的时候 `consent: true` + `consent_statement_version` | 不问；`consent: "standing_grant"`（引用开启全部权限时记的长期授权）；结果写用了哪段录音、建了什么 |
| 设计声音（`voice_design`） | `needs_confirmation`：写清「约 X 积分（最多 Y）」 | 直接做；结果写花了多少 |
| 默认要的 MiniMax 版没建（`voice_plan.rule: default_needs_one_time`） | 问一次：建（确认码）或不建（`skip_one_time=true`，这一单用报价里不花一次性费用的那个：英文是 IndexTTS2 + 英文参考，其他语言是 HeyGen Turbo + 英文参考）（决定第八节第 5 条；用户定按 Sky Studio 方案 5.2 ④ 的理解） | 先交 `voice_enroll`、再报价、照默认读；事后通知 |
| 点名的模型要 MiniMax 版（409 `one_time_required`） | 同上；不建就换个模型或用 `auto` | 直接建 |
| 某批默认出错、备用要先建 MiniMax 版（任务结束码 `fallback_needs_one_time`） | 这一批停下，任务以可恢复的 `failed` 结束；`next_step`：问用户，`resume` + 确认码 = 建了用备用接着做，`resume` + `skip_one_time=true` = 用默认重试那几批 | 直接建，后面用备用接着做完；事后通知 |
| 设计的默认模型出错（服务器退款，回答带备用报价） | 问要不要用备用模型设计 | 直接用备用 |
| 删声音（`DELETE /voices/{id}`） | 先确认一句（同角色删除，走 `AIFileTools` 的入口） | 直接删、通知（决定第八节第 7 条） |
| 每日硬预算 | 照拦 | 照拦 |

- **确认码只在请求批准模式下出现**（声音这几件事）。令牌绑完整身份：录音的文件身份（路径 + 大小 + 修改时间 + 内容哈希）、用的那一段、语言、名字；一次性费用的 `kind`、`voice`、`language`、精确积分。换了任何一样另发一张。三十分钟、一次有效、同一件事等答复时回同一张（`AIConfirmations` 原规矩）。
- 授权的问句明写「请用户本人确认有权使用这个声音（自己的声音，或已获得声音主人同意）」；文字照 `/models` 的 `voice_consent.per_recording` 那一版译成会话语言，交的时候带它的版本号。
- 全部权限下「事后通知」= 结果里写清做了什么、花了多少（AI 照转告），SkyCut 顶上的提示条也说一句。
- 全部权限下要是这个账号还没有有效的长期授权（`GET /voices/consent-grant` 读不到、或服务器回 `no_standing_grant` / `consent_outdated`：换了账号、文案改了版本、开的时候没登录、别的电脑关了全部权限把它撤了），声音这几件要花一次性费用或要授权的事（用录音建声音、设计、建 MiniMax 版）第一次照请求批准模式问一次；问句里带全部权限的那段说明（价目 + 授权那句），用户同意就补记，以后不再问。删声音不花钱、不要授权，照全部权限直接做。
- 升级前就开着全部权限的不用补问：新版第一次连上 Sky Studio 时直接替用户记上长期授权（`POST /voices/consent-grant`），当作已授权（用户 2026-11-09 定：只有用户本人在用）。
- 点名文件夹以外的文件：照旧先过 `AIWorkspace.confirmReading`（请求批准模式问、记住文件夹；全部权限不问，现有规矩）。
- 一次性费用算进当天的硬预算。注意量级：设计约 750 积分，默认每日 1,000 积分时一天只够一次；MiniMax 版约 375 积分。

### 4.6 声音库：`list_voices` 和 `manage_voices`

`list_voices`（只读、免费、不碰工程）

| 参数 | 说明 |
|---|---|
| `language` | `zh` / `en` / `ja`…；不给 = 中文、英文两份。其他语言照 `other_languages` 回英文名单（决定第四节） |
| `include` | `mine` / `presets` / `all`（默认 `all`） |

回：`mine`（`GET /voices`：`voice_…`、名字、`source` 录音 / 设计、有哪几种语言、每种有没有 MiniMax 版；没有任何服务商 id）；`presets`（`voice_presets` 里这种语言 `listed` 的，按 `rating` 高到低：`gemini:<名字>`、`gender`、`description.en`，`default` 的标出来）。30 个预设一种语言约 3–4 KB，不分页；声音最多 50 个，一页回完。

`manage_voices`（写；服务器上的事，不登记时间线撤销）

| action | 参数 | 接口 | 请求批准模式要问 | 花钱 | 回 |
|---|---|---|---|---|---|
| `create` | `file`、`start` / `end`（可选，源文件秒数）、`language`（可选，自动识别）、`name` | 传 `/uploads` purpose `voice_reference` → `POST /voices`（`name`、`language`、`reference_url`、`source`：文件名 / 起止秒 / `auto_selected`、`consent`：`true` 或 `"standing_grant"`、`idempotency_key`） | 授权（每次） | 免费 | `voice_…`、用了哪一段、有效人声秒数 |
| `add_reference` | `voice`、`file`、`start` / `end`、`language` | `POST /voices/{id}/references` | 授权 | 免费 | 这个声音现在有哪几种语言 |
| `design` | `description`、`name`、`sample_text`（可选） | `/quote` + `/jobs` kind `voice_design`（`prompt` = 描述、`params.name`、`params.sample_text`） | 一次性费用 | 设计费（服务器按描述的语言选 `minimax-voice-design` / `qwen3-voice-design`） | `job_id` → `get_job` → 新声音 + `sample_url` |
| `rename` | `voice`、`name` | `PATCH /voices/{id}` | — | 免费 | |
| `delete` | `voice` | `DELETE /voices/{id}` | 确认一句 | 免费 | 已删除；不说「可以撤销」 |

- 录音的语言：macOS 26 用现成的两段式检测（`SubtitleLanguageDetection`，只在已装的语言里裁决）；检测不出来或 macOS 15，就要 AI 给 `language`、界面上手选。
- 错误照服务器的码说人话：`voice_limit`（每账号最多 50 个）、`reference_exists`（这种语言已经有录音；这一版想换只能删了重建）、`too_little_speech`、`too_long`、`upload_too_large`、`unsupported_language`、`consent_required`；`no_standing_grant` / `consent_outdated` 走 4.5 的「问一次、补记」。
- `voice_library_unavailable`（503，Sky Studio 的私有声音桶没配）：`list_voices` 照回 `presets`，`mine` 写「声音库暂时用不了」；`manage_voices` 的各个动作、`add_voiceover` 用 `voice_…`、`change_voice`（源音频也要传到那个私有桶）都报「声音库暂时用不了，稍后再试」，一分不花、不退本机；用预设配旁白照常。
- 删除就是全删、立刻生效，结果和界面都不另加说明（决定第三节第 7 条、第八节第 7 条）；正在用这个声音的任务不挡删除，由服务器处理。回 503（存储暂时不可用）时再发一次 DELETE。

### 4.7 声音设计

- 描述的语言决定用哪个模型（中文描述 `minimax-voice-design`、英文描述 `qwen3-voice-design`，决定第二节），这件事在服务器；SkyCut 只送描述、名字、可选的试读句。
- 设计出来的声音进声音库，样音就当一段参考录音，之后读什么语言都照「克隆」的规则（决定第二节）。
- 设计是任务：`AIJobs` 加一种「声音设计」，状态行和云端任务浮层沿用现有的。

### 4.8 视频变声 `change_voice`

参数：`clip`（短 id，要有声音）、`voice`（`voice_…` 或预设名）、`language`（可选：这段说的是什么语言，ISO 639-1）、`project`（多工程规矩）。

1. 核对：这一段有声音、没静音，几乎没声音的拒绝；源时长不超过 `/models` 的 `limits.max_source_seconds`（5 分钟，决定第八节第 8 条），超了拒绝、话里建议先 `split_clip`。
2. `POST /quote`（kind `voice_convert`、`params.target_voice`、`params.source.seconds`，照下面「用哪种语言的参考」可能再带 `params.target_language`）→ 把关（每日硬预算；不是一次性费用，两种模式都不问）→ 起任务、回 `job_id`。
3. 任务里：从原素材截这一段的源时间范围，写成**单声道** 16-bit WAV（采样率取原素材的、最高 48 kHz；5 分钟约 27–29 MB，在 35 MB 以内；读取在 `MediaReadQueue` 上），传 `/uploads` purpose `voice_convert_source`，交 `/jobs`（`model: "auto"`、`inputs.source_audio_url`、`params.target_voice`、`params.source`、有的话 `params.target_language`、`max_credits`），等，下载 `voice_url`、`background_url` 两个文件。
4. 落地（一步撤销，任务做完那一刻异步落账，自己包一层 `AIUndoGrouping.step`）：
   - 原片段静音（`isMuted`），不删；
   - 新开两条音频轨，人声、背景各一段，放在原片段同一时间；带上原片段的变速、音量、渐入渐出、音量曲线；
   - 三段互相链接（挪原片段两段新音频跟着走）；
   - 服务器只补短的、长了不裁（`padded_seconds`）；人声比原片段长几毫秒时只在时间线上裁到原长、文件不动（Chatterbox HD 实测会长 5–35 ms，`confirm-round-2026-11-09/README.md`「B. 变声复测」、`round5-2026-11-09/README.md`「混音、补尾和对齐」）。
5. 文件放原素材旁边（同 upscale），撞名加编号：`<原名> - <声音名>.wav`、`<原名> - 背景.wav`。
6. 工程换了 / 关了：只留文件，`get_job` 报路径，不落到别的工程（`CloudTaskOwner`，和旁白一样）。
7. 「按原电平混回背景」= 两段都用原片段的音量、不另加增益；导出时的 −1 dBFS 限幅器兜底（`export-audio-mixdown.md`）。实测两段直接相加，六条都没超过 0 dBFS、整体偏移 0 ms（`round5-2026-11-09/README.md`「A. SAM分离」）。结果里的 `model` 和 `fallback_used` 照报（`chatterbox-hd` 出错时服务器自动换 `chatterbox`）。

**用哪种语言的参考**（`params.target_language`）：先定这段说的是什么语言——AI 给了 `language` 就用它；否则 macOS 26 在这一段上跑生成字幕那套本机检测（`SubtitleLanguageDetection`，只在已装的语言里裁决，收费之前做）；检测不出来或 macOS 15，就算不知道。目标声音有这种语言的参考（声音库的看 `languages[]`，预设看有没有这种语言的样音）才带 `params.target_language`；不知道、或者没有这种参考，就不带，照服务器的默认（中文参考，没有中文就随便一段）。理由：实测都是同语言参考（英文素材配英文参考，`round5` A 节、`confirm-round` B 节），拿中文参考去变英文片段没测过。界面不加选项。

**挑哪个声音**：界面上默认放「我的声音」、预设排最后（5.5）；AI 那一路在说明书 `change_voice` 的主题里写「优先用用户自己的声音（`list_voices` 的 `mine`）；预设当变声目标没验证过（样音只有约 8 秒）」。

### 4.9 撤销分组

| 操作 | 撤销 |
|---|---|
| `add_voiceover` 落地 | 一个 `AIUndoGrouping.step`（音频 + 字幕，现在就是） |
| 中途换了备用的多批旁白 | 仍然是最后一次落地一步 |
| `change_voice`（AI）/ 右键（界面）落地 | 一个 step：静音原片段 + 两条新轨 + 两段新音频 + 链接；界面起的也走同一个包法（异步落账不是用户事件，不包就会和下一步并成一组） |
| `manage_voices`、声音库界面、全部权限的说明 | 不碰时间线，不登记时间线撤销 |

### 4.10 怎么写进清单：名片 + 说明书（不抬上限）

照 `SkyCut-MCP按需说明方案.md`（决定第七节第 3 条），那份先做；声音的工具从第一天起就按它的规矩写。

| 项 | 规矩（以说明书方案为准） | 声音这四个 |
|---|---|---|
| 名片（工具说明） | ≤ 450 字（目标 350：说明书方案 1.6 按这里的样稿重估后从 400 收紧；复杂的工具照样可以写到 450）；按工具性质必写固定说法：`Read-only`、`One undo step`、`Returns job_id; wait with get_job`、`Paid (Sky Studio credits)`、`needs_confirmation`；要先读说明书的，最后一句「Read skycut_guide topic=<工具名> before the first call」 | 见下面四张样稿 |
| 参数说明 | 每条 ≤ 120 字（目标约 80），有范围的写数字 | 例：`start`「Source seconds in file; default: whole file, or the best 3 min if longer」 |
| 单个工具的参数定义 | ≤ 4,500 UTF-8 字节 | `manage_voices` 参数最多（action 枚举 + 9 个字段），估约 2 千字节 |
| 说明书主题 | 每个工具一个同名主题；每次 ≤ 6,000 字（硬限 8,000），长的分节 | `add_voiceover` 分 voices / models_languages / paid_confirmation / subtitles / batches_recovery / examples / pitfalls；`manage_voices` 分 create / design / rename_delete / permission_modes / examples；`list_voices`、`change_voice` 各一节 |
| 说明书地图 | 每个工具都在地图里 | 加一行「Voices: list_voices (presets, my voices), manage_voices (clone, design, delete), add_voiceover (narration), change_voice (re-voice a clip)」；地图的 Paid 一行加 `change_voice`、`manage_voices`（design） |
| 全清单 | 迁移完 ≤ 100,000 | 说明书方案 1.6 按收紧后的目标估：含说明书工具和声音这几个约 9.8 万，离 100,000 还剩约 2 千（声音的 3 个新工具和 `add_voiceover` 的改动约占 3.3 千） |

名片样稿（英文；括号里是 UTF-16 字数，已实测）：

- `add_voiceover`（439）：`Narrate lines on an audio track, optional subtitles; One undo step. Voices: gemini:Name (default gemini:Charon), voice_… (list_voices) or a role. Cloud: Paid (Sky Studio credits), model=auto. Returns job_id; wait with get_job; relay voice.note. Ask mode may return needs_confirmation. The daily credit limit always applies. If it fails: resume=recovery_file, never resend lines. Read skycut_guide topic=add_voiceover before the first call.`
- `list_voices`（276）：`Read-only, free. Voices for add_voiceover and change_voice: mine (the user's recorded and designed voices, voice_… ids) and presets for one language (gemini:Name, gender, description). Pass language: a preset can sound different per language. Default narration: gemini:Charon.`
- `manage_voices`（401）：`Edit the user's Sky Studio voice library (no timeline change, no undo): create from a recording (clone my voice), add another language, design from a description, rename, delete. design: Paid (Sky Studio credits), one-time; Returns job_id; wait with get_job. The daily credit limit always applies. Ask mode returns needs_confirmation first. Read skycut_guide topic=manage_voices before the first call.`
- `change_voice`（337）：`Paid (Sky Studio credits): re-voice one clip with a library or preset voice (dub in my voice). Returns job_id; wait with get_job. Result: new voice + separated background on two new linked audio tracks; original clip muted. One undo step. The daily credit limit always applies. Read skycut_guide topic=change_voice before the first call.`

三张新名片共 1,014 字（上一版 1,197，少 183 字），按这三张算全清单约 9.8 万的结论不变。`list_voices`、`change_voice` 在目标 350 以内；`manage_voices`（401）超目标、在硬限 450 以内——五个动作加上花钱、任务号、每日上限、确认、先读说明书这几句固定说法，压不到 350，属于说明书方案说的「复杂的工具照样可以写到 450」。`manage_voices` 补上了说明书方案 2.2 第 4 条要的两句（`Returns job_id; wait with get_job`、每日上限）。挪进说明书主题的：录音要一个人说、10 秒到 3 分钟、超过 3 分钟自动挑一段、全部权限下不问、变声片段超长先分割——这些不会让 AI 调错或花错钱，SkyCut 和服务器都会挡，报错也会说。

会花错钱、做错事的写在名片和结果里（失败后别重发原稿、跨语言要转告、硬预算），其余进说明书（说明书方案第三节：不能指望 AI 一定读说明书）。`add_voiceover` 现在是全清单最长的说明（1,069 字），按说明书方案在第一批迁移；如果那时第一批还没搬到它，就由声音的 PR 3 按新格式一起写。

---

## 五、界面

### 5.1 入口

| 入口 | 在哪 | 打开什么 |
|---|---|---|
| 「声音库」一节 | 设置 → 剪辑与声音（Kokoro 那一行下面） | 我的声音列表（试听、加另一种语言的录音、改名、删除）+「新建声音…」「设计声音…」「浏览预设声音…」 |
| 片段右键「换成我的声音…」 | 时间线上有声音、没静音的段（视频段、音频段），放在「Upscale…」旁边 | 变声面板 |
| 变声面板里的「新建声音…」 | 还没有自己的声音时 | 新建声音对话框 |
| 权限模式切到「全部权限」 | 设置 → 连接 AI（现有的 `AIAccessSettingsSection`） | 全部权限的说明（5.6） |
| 云端任务浮层 | 工具栏右边（现有） | 变声 / 设计任务的阶段和积分 |

没有 Sky Studio 的 Key：声音库那一节写「接上 Sky Studio 才能用」，按钮去「设置 → Sky Studio」；右键菜单项照样有，面板里说同一句。

Sky Studio 回 `voice_library_unavailable`（服务器那边的声音库暂时用不了）：声音库那一节写「声音库暂时用不了，稍后再试」，新建、设计、加录音、改名、删除都灰着，预设照样能浏览、试听；变声面板说同一句；用预设配旁白不受影响。

### 5.2 声音选择器（共用组件）

- 上面一排语言：中文 / English / 其他语言（照 `other_languages` 用英文名单）。默认：中文界面选中文，英文、西语界面选 English。
- 三组：我的声音、设计的声音、预设声音。预设只列这种语言里 `listed` 的（中文 21 个、英文 27 个），按 `rating` 高到低、同分按名字；每行：名字、`gender`、这种语言的 `description`（中文界面用 `zh`，英文、西语界面用 `en`）、▶ 试听（这种语言的 `sample_url`）；`default` 的 Charon 标「默认」。
- 我的声音试听用 `GET /voices/{id}` 给的临时链接（`languages[].preview_url`，到 `preview_expires_at` 过期），过期就重取，不存链接（决定第八节第 2 条：录音只发临时链接）。
- 一个 `AVPlayer`，同一时间只放一个，关面板就停。不订阅播放器时钟、不读工程；每个视图 body 第一行计数（预览性能 ratchet 第二、十三节）。

### 5.3 新建声音对话框

```
┌ 新建声音 ────────────────────────────────┐
│ 名字   [我的声音                       ] │
│ 录音   (●) 现在录    ( ) 选文件…           │
│        ▮▮▮▮▯▯  00:42   建议 30 秒到 1 分钟 │
│        一个人说、没有背景音乐               │
│ 语言   [中文 ▾]（自动识别，可改）           │
│ 用的   00:00–00:42 · 有效人声 38 秒  ▶     │
│ ☐ 我有权使用这个声音（自己的声音，         │
│    或已获得声音主人的同意）                 │
│ 费用   新建免费                             │
│                       [取消]   [新建]       │
└────────────────────────────────────────┘
```

- 录音：麦克风授权沿用录屏那一套的请求方式（`ScreenRecordingPermissions`）；`InfoPlist.strings` 里的麦克风用途说明加上「录声音样本」（三种语言）；电平条；到 3 分钟自动停。
- 选文件：音频、视频都行；超过 3 分钟本机自动挑一段（第六节），显示「用了 mm:ss–mm:ss」，能试听那一段。
- 有效人声不到 10 秒、或没勾授权：「新建」灰着，下面说差什么。
- 授权这一勾两种权限模式都有：这是用户自己在操作，不是 AI 在问（决定第三节第 4 条）；文字是 `/models` 的 `voice_consent.per_recording` 的本地化版本，交的时候带 `consent: true` 和它的版本号。开了全部权限、这个账号有有效的长期授权时默认勾上。
- 费用一行：新建只存录音、免费。建 MiniMax 版不在这里花，第一次用到时再说（决定第七节第 7 条）。
- 声音到 50 个：「新建」灰着，说上限（`voice_limit`）。
- 给已有的声音加一种语言的录音：同一个框，标题换成「给『X』加一段录音」；这种语言已经有录音的不列出来（`reference_exists`）。

### 5.4 设计声音对话框

- 描述（多行）、名字、可选的试读句；报价后显示「将用 MiniMax / Qwen3 设计，约 X 积分（最多 Y）」（`credits_expected` / `credits`，来自 `/quote`）；按钮「设计（最多 Y 积分）」——按下就是确认。
- 设计是任务：关掉对话框不取消；云端任务浮层能看到；做完进声音库，能试听样音。

### 5.5 右键「换成我的声音…」

- 菜单项只调动作（块不读工程、不做 IO，预览性能 ratchet 第九节），和「Upscale…」一样把面板交给一个 Activity。
- 面板：目标声音（选择器）、这一段多长、「约 X 积分（最多 Y）」、「开始」。目标声音默认放「我的声音」：只有一个就默认它，有几个就默认上次用过的那个；排序是我的声音、设计的声音、预设（预设排最后：样音只有约 8 秒，当变声目标没测过，Sky Studio 方案风险 15）；还没有「我的声音」时默认不选，顶上放「新建声音…」，设计的声音和预设照样能选。超过 5 分钟（`limits.max_source_seconds`）：灰掉、说上限、建议先分割。
- 面板上的报价就是确认（和 upscale 面板同一个口径）；每日硬预算照样拦。
- 做完自动落地（4.8 第 4 步）；提示条说「已换成『X』的声音，原声已静音，⌘Z 撤回」。不往检查器里加行。
- 删声音（声音库那一节）：确认一句「删除『X』？」，不另加说明（决定第三节第 7 条）；删了立刻从列表消失。

### 5.6 打开全部权限时的说明（决定第七节第 1 条）

```
┌ 打开「全部权限」 ────────────────────────────────┐
│ 打开以后，AI 做这些事不再先问你，做完告诉你：         │
│ · 读点名文件夹以外的文件、把文件移到废纸篓             │
│ · 超出默认规格的生成                                 │
│ · 用录音新建声音、建 MiniMax 版、设计声音、删声音        │
│ 一次性费用（以 Sky Studio 报价为准）：                 │
│ · 设计一个声音（中文描述，MiniMax）     约 752 积分      │
│ · 设计一个声音（英文描述，Qwen3）       约 22.5 积分     │
│ · 给声音建 MiniMax 版（每种语言一次）  约 377 积分        │
│ 每日额度照样是硬上限（现在 1,000 积分 / 天）。           │
│ 打开即表示：以后你在 SkyCut 里用来建声音的每一段录音，    │
│ 都是你本人在说，或你已获得说话人的同意。                  │
│                         [取消]   [同意并打开]          │
└────────────────────────────────────────────┘
```

- 挂在现有的权限模式选择上（`AIAccessSettingsSection`）：选「全部权限」先弹这张，按「同意并打开」才真改（`AIAccessStore`）；按「取消」退回原来的模式。每次切到全部权限都弹。
- 价目从 `/models` 里 `minimax-voice-design`、`qwen3-voice-design`、`minimax-voice-clone` 的 `price`（`typical_credits`）读（SkyCut 不写死；读不到就只写「以报价为准」）；每日额度读 `SkyStudioSpendStore`。
- 授权那句是 `/models` 的 `voice_consent.standing` 的本地化版本（英文原文和版本号由服务器给，比如 `voice-standing-consent-v1`）。「同意并打开」时 `POST /voices/consent-grant`（带 `statement_version`），服务器记谁、什么时候、哪一版。没登录、记失败：照样打开，只是声音那几件事第一次还会问（4.5），并在这里写一行「授权还没记上」。
- 升级前就开着全部权限：不弹这张、不问，新版第一次连上 Sky Studio 时直接 `POST /voices/consent-grant`（用户 2026-11-09 定：只有用户本人在用）。
- AI 用 `set_settings ai_access_mode=full_access` 打开：照现有规矩永远先回确认码（`AISettingsApproval`），问句里带同一段说明（价目 + 授权那句）；用户同意后才打开，并 `POST /voices/consent-grant`。
- 切回请求批准模式：照旧什么都先问，并 `DELETE /voices/consent-grant` 撤掉长期授权（Sky Studio 方案 3.5：再打开就再记一条）。同一个账号在别的电脑上还开着全部权限的话，那边下一次会问一次、再记一条（4.5）。
- sheet 自己套 `.appLanguage()`、三种语言都要有译文；body 计数照规矩。

### 5.7 要守的规矩

| 规矩 | 怎么守 |
|---|---|
| 本地化 | 新文案同时进 en / zh-Hans / es 三张表；sheet、popover 自己套 `.appLanguage()`；`scripts/check-localization-coverage.sh` |
| 预览性能 ratchet | 新视图 body 第一行计数（`checks/preview-perf-wiring.sh --fix`）；选择器和对话框不订阅时钟、不读工程；右键菜单项只调动作 |
| 检查器排版 | 这一轮不往检查器加行；以后要加，标题一行、控件一行，不 `.fixedSize()`（`checks/inspector-fits-width.sh`） |
| 产品名 | 看得见的写 SkyCut；新加的 UserDefaults 键（上次用的声音）沿用 SrtFlow 前缀（`checks/product-name.sh`） |
| 单文件行数 | 新功能开新文件（目标 ≤ 400、红线 600）；`VideoEditTimelineClipBlock.swift`（470 行）只加菜单那几行 |
| 多工程 | 任务带 `CloudTaskOwner`，只落回发起的那个工程（`open-projects.md`） |
| AI 那一路不弹框 | 请求批准模式全走确认码；全部权限的说明只在用户自己切模式时弹 |

---

## 六、参考录音：去掉旧限制

| 项 | 现在 | 改成 | 为什么 |
|---|---|---|---|
| 最短 | 3 秒（报错文案说 5 秒） | 10 秒有效人声 | MiniMax 硬要求（决定第三节第 3 条；`round5-2026-11-09/README.md`「接口文档的参考要求」） |
| 默认 / 最长 | 默认 10 秒、最长 30 秒 | 建议 30 秒–1 分钟，最长 3 分钟 | 决定；fal 接受英文 5.59–174.27 秒的参考（`round5` B 节） |
| 采样率 | 16 kHz 单声道 | 44.1 kHz 单声道 16-bit WAV | 10 秒 16 kHz 的中文参考读出 44 秒、后半段跑稿，同一段 44.1 kHz 正常（`zonos2-test-2026-11-08/README.md` zh-A / zh-B）；后面几轮都用这个规格 |
| 超过 3 分钟 | 只截前 N 秒 | 本机挑最好的连续 3 分钟，告诉用户用了哪一段 | 决定第三节第 3 条 |
| 存几段 | 每次现截、只用一次 | 每个声音按语言各存一段（声音库） | 决定第三节第 3、7 条 |
| 上传 | `/uploads` purpose `audio`（15 MiB） | purpose `voice_reference`，35 MB；3 分钟约 16 MB | 决定第七节第 2 条 |

自动挑一段（新的纯值类型，暂名 `VoiceReferenceWindow`）：

1. 解码成单声道，20 ms 一格算响度，−45 dBFS 以下算停顿（和 `AIVoiceLevel` 同一口径）。
2. 候选窗口长 3 分钟（不到 3 分钟就整段），每 0.5 秒滑一次；起点在一个 ≥ 0.2 秒停顿之后的开口处，终点在 3:00 前后 1 秒内的停顿里，离静音边缘至少 40 ms（`round5` B 节「切口修正留档」的做法）。
3. 打分：有效人声秒数最多；一样多时前 15 秒人声更密的优先——IndexTTS2 的上游代码只用参考的前 15 秒（fal 内部是否一样看不到，`round5` B 节「接口文档的参考要求」）；再一样取最早的。
4. 有效人声不到 10 秒：拒绝（界面灰按钮；AI 报错说还差几秒）。服务器另外再查一遍（`too_little_speech`）。
5. 结果说清：「用了 01:12–04:12，有效人声 2 分 41 秒」；`POST /voices` 的 `source` 带起止秒和 `auto_selected`。

不做：自动判断有没有背景音乐、是不是一个人说（本机没有可靠的办法），只在界面上写提示。

---

## 七、字幕时间（决定第三节第 6 条、第七节第 5 条，约定第 5 条）

| 用的模型 | 本机能转写这种语言？ | 字幕时间 | `subtitle_timing` |
|---|---|---|---|
| `eleven-v4` | 不管 | 它给的 `words`（字符时间，现有 `SpeechWordTimes`） | `provider` |
| `gemini-3.8-flash-tts`、`index-tts-2`、`minimax-speech-2.8-hd`、`heygen-voice-turbo` | 能 | 本机转写，再按原文对齐（`SubtitleCueWords`；合批的同时切句） | `aligned` |
| 预设声音（`gemini:<名字>`） | 不能，且要字幕 | 整段改成 `model: "eleven-v4"` + 原来的 `params.voice`（服务器换成这个预设的 Eleven 备用声音），并说一声；一段里不出现两种声音 | `provider` |
| 克隆 / 设计的声音（`voice_…`） | 不能，且要字幕 | 按字数估算并说明是估的（不换 Eleven，换了就不是那个人的声音） | `estimated` |
| 任何 | `eleven-v4` 也不支持这种语言 | 按字数估算 | `estimated` |
| 本机 Kokoro / macOS | — | 现有的词标记，不变 | `provider` |

- 「本机能转写」= macOS 26 及以上、`SpeechTranscriber.supportedLocales` 里有这种语言。模型没装就在收费之前明着下载（状态行显示），下载失败当作「不能转写」。macOS 15 没有 `SpeechTranscriber`，全部当「不能转写」。
- 「整段」：一段旁白里只要有一句要字幕、本机又转写不了，预设声音就整段换 `eleven-v4`。
- 一句对不上（转写和原文对不齐）：这一句改按字数估算并标出来，不让整段失败——声音是好的。合批切句对不上：照现在的规矩保留整批文件、报错、能恢复，**不重新花钱**。
- 估算怎么算（新的纯值类型）：开口和收尾按响度找（`SubtitleSpeechOnset` 那一套）；中间按字数分（中日文一个字一份，拼音文字按字母数，标点给停顿）。结果和 `voice.note` 里写「字幕时间是按字数估的，可能差半秒左右」，AI 照转告。
- 合批（8.1）：普通旁白和克隆一样要靠本机转写切句，所以本机转写不了的语言**不合批**（一句一单），要不要字幕都一样；整段由 `eleven-v4` 读的照样合批，按它给的字符时间切，不用本机转写。

---

## 八、排队与并发

### 8.1 怎么分批（用户 2026-11-09 定：普通旁白也合批，规则和克隆一样）

用户原话：「一句一句不合理、浪费资源、效率低；文案确定的前提下尽可能一次多生成一些，但也不要太长，太长可能出问题。」每单至少收 1 积分（决定第一节），短句一句一单要多花五成到一倍半、任务数也多一个量级（按 Vertex 原价的算例见第十三节第 1 条）；约定第 6 条的原话就是「把多句合成几批、每批一个任务」。

| 情况 | 怎么分批 |
|---|---|
| 本机切得开：macOS 26、这种语言能本机转写（第七节）。普通旁白（`voice`）和克隆 / 设计的声音（`voice_clone`）一样 | 按 `limits.max_characters_by_language` 合批，每批约 60 秒以内；整句往里装，批和批只在两句之间分，**不切在句子中间**；切句和字幕都靠本机转写对齐 |
| 整段由 `eleven-v4` 读（预设声音碰上本机转写不了的语言又要字幕，第七节） | 一样合批；按 Eleven 给的字符时间切句，不用本机转写 |
| 本机切不开：macOS 15，或这种语言本机转写不了（又不是 `eleven-v4` 读） | 一句一单 |
| 一句本身就超过上限 | 先在句末标点（。！？.!?）处分开；一个句子都放不下才在逗号、空格处分；几片记着原句、全齐后拼回一句（现有做法） |

分批在报价之前做（报价要带 `params.batches`），这时模型还没选，所以字数上限取这个 kind 下各模型里最小的那个（Sky Studio 方案 5.3：所有声音模型都是中 300、日 330、韩 300、其余 800，约 60 秒，`eleven-v4` 也是这一组）。

### 8.2 槽

- 新的全 App 一份的 `SkyStudioJobSlots`，两个池，和服务器一样：
  - **声音池**：`voice`、`voice_clone`、`voice_enroll`、`voice_design`、`voice_convert`、`sound_effect`，槽数 = `/me` 的 `max_running_audio_jobs`（决定第八节第 3 条：8）；
  - **共用池**：其余（图片、视频、upscale、对口型、音乐），槽数 = `max_running_jobs`（3；`SkyStudioMe.maxRunningJobs` 已经读进来了）。
  - 读不到 `max_running_audio_jobs`（服务器还没上新池）：声音任务也进共用池，按 3。
- 交之前先在对应的池领槽，结束就还。服务器的 429 `too_many_jobs` 照旧兜底：看 `pool`，等 15 秒、用同一个 idempotency_key 再交（`SkyStudioJobRun` 不变）。网页或别的电脑上开着的任务 SkyCut 看不见，所以兜底必须留着。
- 一段旁白的各批按顺序领槽、同时跑；回来的顺序不管，切句和落地按原来的顺序，全部好了一次落地。状态行写「第几批 / 共几批，几批在跑，几批等空位」，不造百分比。
- 停：排着队的取消退钱，已开始的照现有规矩（只有排队中的能取消）。

### 8.3 两种情况

| | 声音池 8（已定，决定第八节第 3 条） | 服务器还没给 `max_running_audio_jobs`（按共用的 3 个） |
|---|---|---|
| 3 分钟普通旁白（约 50 句，Gemini；合成约 3–4 批） | 一轮全发，等最慢的那一批（每批约 60 秒的音频，耗时待实测，估计几十秒）；参照：60 单同时交 85 秒全部做完（`gemini-voices-2026-11-09/README.md`「并发」） | 分两轮，多等一批的时间 |
| 3 分钟克隆稿（合成 3–4 批） | 一轮全发；主要等一次 IndexTTS2 排队 30–150 秒（`round5` B 节） | 分两轮，多等一次排队 |
| 本机切不开的语言、不要字幕的普通旁白（一句一单，50 句） | 8 单一起跑，约 7 轮；Gemini 一单十几秒，粗估 1.5–2 分钟（待实测） | 约 17 轮，粗估 4–6 分钟 |
| 配音时又起 upscale / 生成 | 不同的池，互不挡 | 排在后面，状态写「等空位」 |
| SkyCut 要改什么 | 不用改：槽数从 `/me` 读 | 不用改 |

现在是一单一单串着交，上面几种都只会更快。积分（按 Vertex 原价）：3 分钟中文旁白 30 句，一句一单 30 积分、合批约 20.5（Sky Studio 6.4）；句子越短省得越多（50 句短句 50 → 约 19），英文长句省一成左右（第十三节第 1 条的表）。

### 8.4 整段一个模型、中途换备用

- 整段 `POST /quote` 时服务器选定模型（`voice_plan.selection`）；每一批 `/jobs` 都带 `model: "auto"` + `params.plan`（原样），各批不各选各的（决定第三节第 1 条「整段只用一个模型，中途不换」）。
- 某一批默认出错、服务器在这一批里自动换了备用（结果 `fallback_used: true`）：已做好的不重做；后面没交的批带 `params.plan` = `voice_plan.fallback.selection`；结果写清哪几句用了哪个模型，并提示「前后可能听得出差别，要统一可以整段重做（先报价）」（决定第七节第 6 条）。
- 备用要先建 MiniMax 版（任务结束码 `fallback_needs_one_time`）：按 4.5 的表，两种模式各走各的。
- 恢复记录（version 2）记下 `voice_plan.selection` 和每批实际用的 `model`、`fallback_used`；恢复永远只 GET 原单、不重新选模型。

---

## 九、测试和守卫

### 9.1 自动检查（反向验证：临时撤掉修复或规则，确认守卫变红再恢复；没红过的不算验证）

| # | 检查 | 改 / 新 | 守什么 | 反向验证 |
|---|---|---|---|---|
| 1 | `scripts/check-sky-studio.sh` 的 `VoiceCatalogChecks` + 目录快照 fixture（从 Sky Studio 导出，同 `models-image-2026-11-07.json` 的做法） | 新 | `voice_presets` 按语言分开（Gacrux 中文男 / 英文女）、`listed` 为假的不进名单、中文 21 / 英文 27、`sample_url`、`default` 是 Charon；`voice_roles` 覆盖 8 个角色、都指向那种语言里 `listed` 的声音（Iapetus 只英文）；DTO 里没有服务商 id | 把 fixture 里 `zh_female_lively` 指向 Despina（藏起来的）→ 红 |
| 2 | `VoicePlanChecks` | 新 | `/quote` 带 `params.batches`、`model: "auto"` / 点名；读回 `voice_plan` 各字段、`credits` / `credits_expected`、`batches`、`one_time`；各批 `/jobs` 带同一个 `params.plan`；`max_credits` 用 `credits`；拉丁字母稿判出西语带 `params.language: "es"`，英文、中文、日文稿不带 | 让第二批不带 `params.plan` → 红；让中文稿也带 `params.language` → 红 |
| 3 | `VoiceReferenceChecks`（纯值 + 真写读 WAV） | 新 | 10 秒下限、3 分钟上限、挑窗口（人声最多、前 15 秒密、切在停顿里）、44.1 kHz 单声道 16-bit 的头、传 `voice_reference` | 采样率改回 16 kHz → 红；下限改回 3 秒 → 红 |
| 4 | `VoiceSlotChecks` | 新 | 两个池（8 / 3）；读不到新字段时都进共用池；任何时候在飞的不超过槽数；乱序回来按原顺序落地；429 看 `pool`、同 key 再交 | 让变声进共用池 → 红 |
| 5 | `VoiceChecks` | 改 | 普通旁白和克隆都按 `limits.max_characters_by_language` 合批、批和批只在两句之间分；一句超过上限先在句末标点分；本机转写不了的语言一句一单，`eleven-v4` 读的照样合、按字符时间切；估算的纯值 | 让普通旁白退回一句一单 → 红；让批在句子中间断开 → 红；让转写不了的语言（不是 `eleven-v4`）也合批 → 红 |
| 6 | `VoiceRecoveryChecks` + `scripts/check-voice-recovery.sh`（真 App 对象） | 改 | 只认 version 2：记 `voice_plan.selection` 和每批 `model`，恢复只 GET 原单；两批同时跑、后交的先回；第二批换了备用、后面的批改 `params.plan`；`fallback_needs_one_time` 后 `resume`；估算的句子；仍是一步撤销 / 重做 | 把恢复路径改成重新报价选模型 → 红 |
| 7 | `VoiceChangeChecks`（真 App 对象，同 check-voice-recovery 的接法） | 新 | 单声道 WAV 上传 `voice_convert_source`、`voice_convert` 请求、两个文件；落地：原段静音、两条新轨、链接、变速 / 音量 / 渐变 / 曲线照抄、长几毫秒裁到原长；超 `limits.max_source_seconds` 收费前拒；AI 给的 `language` 优先于本机检测，知道语言、目标声音又有这种参考时才带 `params.target_language`；一步撤销 / 重做；工程换了只留文件 | 去掉落地那层 `AIUndoGrouping.step` → 红（撤一步回不全）；目标声音没有这种参考也带 `target_language` → 红 |
| 8 | `scripts/check-mcp.sh` 的 `SkyStudioVoiceChecks` | 改 | 4.3 的认声音顺序、`gemini:` 前缀和不带前缀、`eleven:`、本机退档按角色 / 性别、不给声音 = `gemini:Charon`、英式男声读非英文改用 Charon 并说一声；`voice_library_unavailable` 时 `list_voices` 照回预设、`mine` 说暂时用不了，`manage_voices` / `change_voice` / `voice=voice_…` 报同一句、不退本机，预设旁白照常 | 让不给声音时还取温和女声 → 红；让 `list_voices` 碰上 503 整个失败 → 红；让英式男声读中文还送 `gemini:Iapetus` → 红 |
| 9 | `ConfirmationChecks` + `scripts/check-sky-studio.sh` 的 `AccessChecks` | 改 | 请求批准模式：授权 / 一次性费用 / 删除各回确认码，令牌绑完整身份，换一样另发，`skip_one_time` 走不花钱的那个；全部权限：都不问、带 `consent: "standing_grant"`、结果写花了什么；没有有效长期授权（读不到、`no_standing_grant`、`consent_outdated`）时第一次照问，升级前就开着全部权限的直接记上、不问；切全部权限先弹说明、同意才写 Store、`POST /voices/consent-grant`，切回 `DELETE`；`set_settings` 问句带说明 | 把文件指纹从身份里拿掉 → 红；全部权限下让授权照问 → 红 |
| 10 | `CatalogTextChecks` / `ProtocolChecks` / `UsageExampleChecks` + 说明书方案新加的 `GuideChecks` | 改 | 四张名片 ≤ 450、带各自的固定说法、只用英文；参数说明 ≤ 120 且范围写数字；单个工具参数定义 ≤ 4,500 字节；四个主题都在、在地图里、每节 ≤ 6,000、例子过参数核对；全清单 ≤ 上限；`clone_from` 等按说明上没有的参数名拒 | 把 `change_voice` 从地图删掉 → 红；名片里删掉 `One undo step` → 红 |
| 11 | `UndoChecks` | 改 | `change_voice` 落地在一个 step 里；`manage_voices` 不登记撤销 | 让落地分两次 perform 各自登记 → 红 |
| 12 | `checks/sky-studio-wiring.sh` | 加几条扫描 | 源码和 fixture 里没有 MiniMax voice_id 的样子（`Voice` + 一长串十六进制）；`/voices` 请求只经 `SkyStudioAPI`；交任务只经 `SkyStudioJobRun`、领槽只经 `SkyStudioJobSlots`；`consent: true` 只从对话框和确认码来、`"standing_grant"` 只在全部权限且有有效长期授权时用 | 在别处写一行 `consent: true` → 红 |
| 13 | 扫描守卫：`checks/preview-perf-wiring.sh`、`scripts/check-localization-coverage.sh`、`checks/source-file-size.sh`、`checks/product-name.sh`、`checks/docs-index-drift.sh` | 照旧 | 新视图计数、三张表、行数、身份前缀、新文档进索引 | 各自已有 |

推之前跑 `scripts/check-local.sh sky-studio mcp voice-recovery`（全部扫描守卫 + 点名的几项）；完整的 `check-all` 交给 CI。

### 9.2 免费冒烟

扩 `scripts/gui-smoke/sky-studio/voice.py` 和 `permissions.py`：假服务回 `voice_plan`、`one_time`、`default_needs_one_time`、两批同时、中途 `fallback_used`、`fallback_needs_one_time`、变声的两个文件、两个池的 429、`voice_library_unavailable`；两种权限模式各跑一遍；真 MCP、真入轨、真撤销；只用假 Key 和独立的测试 bundle，不碰生产 Key。

### 9.3 人工回归清单（真 Key、要花积分，每次都先请用户批准预算）

试听：
- [ ] 中文克隆（`index-tts-2`）3 句：像不像；接缝有没有吞字。
- [ ] 英文克隆：第一次用到 MiniMax 英文版——请求批准模式问一次（不建就用 IndexTTS2 读完），全部权限直接建、事后说；中英混合（整段一个模型）；日语（`heygen-voice-turbo`，出现跨语言提示）；西语（第一次用到 MiniMax 英文版也会问，不建就用 HeyGen Turbo 读完）。
- [ ] 普通旁白：不点名 = Charon；8 个角色各一句；让 AI 按描述挑一个预设。
- [ ] 设计：英文描述（Qwen3）一次；中文描述（MiniMax，约 750 积分）一次；样音进库，再用它读一句中文、一句英文。
- [ ] 新建声音：录 10 秒（刚够）、录 45 秒、选一个 3 分 30 秒的文件（说出用了哪一段，试听那一段）。

字幕时间：
- [ ] Gemini 中文 / 英文：字幕开头结尾和声音差不超过 0.3 秒。
- [ ] 本机转写不了的语言（照那台 Mac 的支持表挑一种）：预设声音整段换 Eleven 并说一声；克隆的标「估算」。
- [ ] 有 macOS 15 的机器就走一遍。

变声与口型：
- [ ] 三段：纯说话、有配乐、带笑声（同 `round5` A 节的素材）：两条新轨、原声静音、⌘Z 一步回去、⇧⌘Z 再来。
- [ ] 口型：0.5 倍速看嘴型，和原片比；实测整体偏移 0 ms（`round5` A 节），局部差 0.1–0.3 秒以内属转写误差，要看片判断。
- [ ] 背景是单声道：挑一段立体声背景的片子听，确认能接受（决定第三节第 8 条）。
- [ ] 一段接近 5 分钟的片段（测试只做过 5–10 秒）；超过 5 分钟的面板灰掉。
- [ ] 用预设（比如 `gemini:Charon`）当目标变一段：听效果；面板默认是「我的声音」、预设排在最后；效果不行再照 Sky Studio 风险 15 的办法给常用预设各生成一段 30 秒的参考（另批）。
- [ ] 英文片段换成有中、英两段录音的「我的声音」：请求带了 `target_language: "en"`，听像不像；macOS 15 或检测不出来时不带。
- [ ] 挪原片段：两段新音频跟着走（联动开着）。

权限两种模式：
- [ ] 设置里切到全部权限：弹说明，价目对得上 `/models`；取消就不改；同意之后 AI 用录音建声音、设计、建 MiniMax 版、删声音都不问、做完说清楚花了多少。
- [ ] AI 用 `set_settings` 切全部权限：问句里带同一段说明；同意之后记上授权。
- [ ] 换一个 Sky Studio 账号：全部权限下第一次用录音建声音会问一次，之后不问。
- [ ] 升级前就开着全部权限：装上新版、第一次连上 Sky Studio 就记上长期授权，用录音建声音不问。
- [ ] 请求批准模式：授权问一次；换文件、换那一段另问；删声音问一句；界面上不勾授权建不了。

并发与费用：
- [ ] 30 句普通旁白：合成几批（每批约 60 秒以内、不断在句子中间），切开的接缝不吞字、字幕对得上；计时；跑着时起一个 upscale，两边互不挡；取消排着队的，只退一次。
- [ ] 账单「约 X、最多 Y」：做完按实收，多的退一次。
- [ ] 每日额度设成 0：所有声音任务收费前停下；两种模式都一样。

界面：
- [ ] 英 / 中 / 西三种界面：设置那两节、选择器、三个对话框、变声面板、菜单项，无截字、无漏翻。
- [ ] 900 pt 高的窗口里对话框完整。
- [ ] 第一次录音弹麦克风授权；拒绝之后说去系统设置哪里开。

---

## 十、PR 拆法和顺序

**先做的两件事（SkyCut 声音的 PR 不碰它们）**：

- **Sky Studio**：声音库、预设名单、`voice_plan`、几种新任务、上传用途、声音池上线（受控发布），并导出一份目录快照给 SkyCut 当 fixture。zonos2 在同一个 PR 里直接下线、不提最低版本号（决定第八节第 9 条）：从 Sky Studio 上线到装上新版 SkyCut 之间，旧版 SkyCut 的克隆和 Sky Studio 旁白都用不了（Sky Studio 不再收旧版的写法；本机的 Kokoro / macOS 声音照常），不做过渡（只有用户本人在用，决定第十二节，用户已接受）；SkyCut 的 PR 什么时候合、什么时候打包按方便来。
- **MCP 说明书**（`SkyCut-MCP按需说明方案.md`）：声音的 PR 1、2 不碰清单，可以同时做；PR 3 起排在说明书的试点 PR（它的 PR 3）合了之后。

之后 SkyCut 一个 PR 一件事、CI 的 `check-all` 绿了就合（`--merge`，不 squash），下一个从合并后的 main 开；每个 PR 同时更新它碰到的文档。

| # | 分支（英文） | 内容 | 依赖 | 主要检查（9.1） |
|---|---|---|---|---|
| 1 | `feat/voice-catalog-contract` | 纯值 + `SkyStudioAPI`：`voice_presets` / `voice_roles`、`/voices`、`voice_plan`、`one_time`、`voice_enroll` / `voice_design` / `voice_convert` 的 DTO 和请求、两个新上传用途、`max_running_audio_jobs`；fixture；不接任何入口 | Sky Studio 的快照 | 1、2 |
| 2 | `feat/voice-reference-sample` | 参考录音：44.1 kHz、10 秒–3 分钟、自动挑一段（纯值 + 真写读） | 无（可和 1 并行） | 3 |
| 3 | `feat/voiceover-auto-model` | `add_voiceover`：`model`、`gemini:` / `eleven:`、`voice_roles`、默认 Charon、整段 `POST /quote`（`params.batches`）挪到回任务号之前、报 `voice_plan`、跨语言提示、拉丁字母的非英文稿带 `params.language`、恢复记录 v2；名片 + 说明书主题 | 1、说明书 PR 3 | 2、6、8、10 |
| 4 | `feat/voice-job-slots` | `SkyStudioJobSlots` 两个池、各批同时交、整段一个 `params.plan`、中途换备用 | 3 | 4、6 |
| 5 | `feat/voiceover-subtitle-timing` | 单句本机对齐、预设整段点名 `eleven-v4`、克隆估算、转写不了的语言不合批、明着下载转写模型 | 3 | 5、8 |
| 6 | `feat/voice-library-mcp` | `list_voices`、`manage_voices`、`voice=voice_…`、去掉 `clone_from`、`voice_library_unavailable` 的处理、一次性费用 / 授权 / 删声音按两种模式进 `SkyStudioJobGate`（这时全部权限下用录音建声音还会问，见 4.5）；三张名片 + 主题 | 1、2、3 | 9、10、12 |
| 7 | `feat/full-access-voice-consent` | 打开全部权限时的说明（设置 + `set_settings` 问句）、`GET/POST/DELETE /voices/consent-grant`、建声音带 `consent: "standing_grant"`；全部权限下不再问；升级前就开着的直接记上 | 6 | 9、GUI 冒烟 |
| 8 | `feat/voice-library-ui` | 设置那一节、选择器、新建 / 设计对话框、录音、「声音库暂时用不了」的样子、三种语言 | 6 | 13、GUI 冒烟 |
| 9 | `feat/change-voice` | `change_voice`（含可选的 `language`、按语言带 `params.target_language`）、右键面板（默认「我的声音」、预设排最后）、落地、云端任务浮层 | 6、8 | 7、11、12 |

要更新的文档：`sky-studio-jobs.md` 第五节（选模型、两个池、字幕时间、先报价后起任务）、`ai-control-mcp.md` 第四节第 6 条（两种模式下声音这几件事）、第 34、40 条和新加一条「声音库与变声」、`workbench-and-settings.md`「AI 操作权限」（打开全部权限时的说明和长期授权）、新写 `docs/architecture/voice-library.md`（声音库与变声的长期约束、人工回归清单）并在 AGENTS.md 补索引。合进 main 不等于发版；发版另外拍板。

---

## 十一、风险

| # | 风险 | 影响 | 怎么减 |
|---|---|---|---|
| 1 | 说明书方案没先做完 | 声音的 MCP 工具加不进清单（不抬上限） | 只有 PR 1、2（纯值、参考录音，不碰清单）能先做；PR 3 起都排在说明书的试点 PR（它的 PR 3）合了之后，界面的 PR 8、9 依赖 PR 6，也在这之后 |
| 2 | 旧版 SkyCut 在 Sky Studio 上线后克隆和 Sky Studio 旁白都用不了 | 那段时间不能克隆、不能用云端旁白（本机声音照常） | 决定第八节第 9 条、第十二节已接受，不做过渡（只有用户本人在用） |
| 3 | IndexTTS2 排队 30–150 秒、冷启动 | 克隆旁白慢 | 合批 + 同时交；状态写阶段和已等时间 |
| 4 | 合批切句对不上 | 多句克隆 / 普通旁白失败 | 现有恢复：保留整批文件、不重花钱；单句对不上改估算 |
| 5 | 中途换备用 | 一段里两种声音 | 不重做、写清哪几句、提示可整段重做（决定第七节第 6 条） |
| 6 | 全部权限下 AI 不问就花一次性费用 | 一天花掉一大块额度（设计约 750） | 打开时列价目；每日硬预算照拦；结果和提示条写清花了多少 |
| 7 | 长期授权覆盖以后所有录音 | 有人拿别人的声音克隆 | 说明里写明授权的意思、带版本；记录谁、什么时候；请求批准模式照旧每次问 |
| 8 | 两个英式角色的英国口音没验证 | 用户以为是英音 | `gemini-voices-2026-11-09/README.md`「SkyCut角色对应」已标明；说明里不写「英国口音」 |
| 9 | 同一个声音中英文是两个人 | AI 照错的语言说明挑 | `list_voices` 按语言回；结果按这次的语言报 |
| 10 | 变声只测过 5–10 秒 | 接近 5 分钟的质量没把握 | 人工回归加一段接近 5 分钟的 |
| 11 | 背景是单声道 | 立体声背景变窄 | 决定已接受；人工回归听一遍 |
| 12 | macOS 15 没有本机转写 | 克隆和普通旁白都不能合批（单数变多、短句更贵）、字幕靠 Eleven / 估算 | 第七节；结果里说明 |
| 13 | 估算的字幕不准 | 字幕早 / 晚半秒 | 标 `estimated`、告诉用户 |
| 14 | Gemini 2027-01-01 起恢复原价 | 积分已经按原价定（决定第十节第 3 条），到时积分价不变 | SkyCut 不写死价，照 `/quote` |
| 15 | 恢复记录升到 version 2、不认旧版 | 升级前没做完的配音，新版恢复不了 | 只有用户本人在用：升级前把它们做完或放弃（用户 2026-11-09 定：不为旧版做兼容） |
| 16 | 声音到 50 个上限 | 建不了新的 | 界面和 AI 都说清上限，建议删掉不用的 |
| 17 | 预设样音只有约 8 秒，当变声目标没测过（Sky Studio 方案风险 15） | 用预设变出来不像 | 变声面板默认「我的声音」、预设排最后；说明书里写明；人工回归加一条；不行再给常用预设补 30 秒参考（另批） |

---

## 十二、需要用户拍板

上一版的 8 条都已拍板（决定第七节、第八节），已写进正文：清单不抬上限（4.10）、本机两档都留（4.2、4.3）、克隆 / 设计的声音估算字幕（第七节）、中途换备用不重做（8.4）、全部权限不问（4.5、5.6）、MiniMax 版第一次用到再建（4.5）、上传 35 MB 和变声 5 分钟（4.8、第六节）、去掉 `clone_from`（4.2）。

上一版新冒出的那 1 条「已经开着全部权限的用户，升级之后怎么补那一次说明」也定了：不用补问，直接当作已授权，新版第一次连上 Sky Studio 时替用户记上长期授权（用户 2026-11-09 定：只有用户本人在用；4.5、5.6）。换了 Sky Studio 账号、授权文案升了版本、别的电脑关了全部权限把授权撤了，这几种和账户有关，照旧第一次问一次（4.5）。

另外，第十三节第 1、2 条已由你定（2026-11-09），已写进正文。

**现在没有待拍板的。**

---

## 十三、和 Sky Studio 方案没对上的地方

> 对的是 `Sky-Studio-声音方案.md` 2026-11-09 22:39 版（会话 A 按决定第七、八节改完的那一版；它还在定稿的 5.8「Gemini 走哪条路」只动服务商那部分，不影响这里）。只读，没改那份。

**处理状态**：第 1、2 条用户 2026-11-09 已定，已改进正文；第 4、5、8、10 条已照建议改进本方案正文；第 3、6、7、9、11 条由会话 A 在 Sky Studio 那份补。

### 13.1 第三节 15 条需求的核对结果

| 第三节的需要 | Sky Studio 那份 | 结论 |
|---|---|---|
| `voice_presets` 的各字段 | 4.1，结构和字段都对得上 | 给了 |
| `voice_roles` | 4.1（「8 个角色 → 预设 id」）、4.2 的表 | 给了；结构没写，见第 11 条 |
| 一次性费用的价目 | 5.4 末段：三条记录的 `price.typical_credits`，约 377 / 752 / 22.5 | 给了 |
| 声音库接口、DTO | 3.3 | 给了 |
| 授权两种来源、`/voices/consent-grant`、`voice_consent` | 3.3、3.5、4.1 | 给了；`GET` 回的「有效」算不算文案过期，见第 9 条 |
| `/quote` 的 `params.batches` 和回答 | 5.2 ⑥、5.4 | 给了 |
| 每批 `params.plan`、换备用后带 `voice_plan.fallback.selection` | 5.2 ⑥、5.4 | 给了；另写明「带回的已经是备用，出错就不再换」，和 8.4 一致 |
| 报价前分批用的字数上限 | 5.3：每个模型各一份，没有按 kind 的 | 给了一半，见第 7 条 |
| 任务结果 | 5.3 | 给了 |
| 一次性费用的错误、`default_needs_one_time` | 5.2 ④、5.6 | 给了；「不建用什么」两边理解不同，见第 2 条 |
| `eleven-v4` 支持哪些语言 | 没写 | **没给**，见第 3 条 |
| `voice_convert` | 5.3；另有可选的 `params.target_language` | 给了；SkyCut 还没用上 `target_language`，见第 5 条 |
| 上传用途和 35 MB | 3.3：按十进制 35,000,000 字节卡；立体声也收、服务器转单声道 | 给了 |
| `/me` 的 `max_running_audio_jobs`、429 的 `pool` | 第八节；声音池含 `sound_effect`，和 8.2 一致 | 给了 |
| 错误码 | 5.6、3.6 | 给了；另有 `voice_library_unavailable`（503），SkyCut 要补，见第 8 条 |

### 13.2 两边做法不一样的

**1. 普通旁白要不要合批**（已定：合批，用户 2026-11-09）
- SkyCut 这份原来（8.1）：普通旁白一句一单，照约定第 6 条「沿用现在的做法」理解。
- Sky Studio 那份（第八节）：「再加约 60 秒的字数上限，让 SkyCut 合批：一段 3 分钟旁白约 3–4 个任务」，6.4 的算例也是一分钟一单；同一节「依据」里又写了 SkyCut 现在是一句一单。
- 差在哪：每单至少收 1 积分（决定第一节），短句一句一单要多花五成到一倍半。按 Sky Studio 6.1 的原价算实收（Gemini 走 Vertex，约每秒 0.113、每分钟约 6.8 积分；向上取 0.1，每单至少 1；决定第九节、第十节第 3 条）：

  | 稿子 | 一句一单 | 合批（每批约 60 秒以内） |
  |---|---|---|
  | 中文 3 分钟、30 句（Sky Studio 6.4 的算例） | 30 个任务，30 积分 | 4 个任务，约 20.5 积分 |
  | 中文 50 句 × 15 字（约 2.8 分钟） | 50 个任务，50 积分 | 3 个任务，约 19 积分 |
  | 英文 30 句 × 100 字（约 4 分钟） | 30 个任务，30 积分 | 4 个任务，约 27.4 积分 |

  （上一版按 fal 旧价每千字 11.25 算，30 句中文是 30 → 10.2；改按 Vertex 原价后结论不变，只是省得没那么多：中文短句省三到六成，英文长句省一成左右。）

  任务数也差一个量级：一句一单在 8 个的声音池里要排好几轮。
- 合批的代价：Gemini 不给字时间，合批之后要靠本机转写切句（和克隆一样），切不准走现有的恢复（保留整批、不重花钱）；本机转写不了的语言还是一句一单。`eleven-v4` 给字符时间，合批后照它切，不用转写。
- **建议：普通旁白也合批**，规则和克隆一样（8.1 的表合成一行：本机切得开就按上限合，切不开的一句一单；`eleven-v4` 按它的字符时间切）。约定第 6 条的原话本来就是「把多句合成几批」。
- → **用户定：照建议合批**（原话：「一句一句不合理、浪费资源、效率低；文案确定的前提下尽可能一次多生成一些，但也不要太长，太长可能出问题」），每批约 60 秒以内、不切在句子中间。已改：8.1、8.3 的估算、第七节最后一条、9.1 第 5 项；顺带改了第三节那一行、〇第 10 条、9.3、风险第 4、12 条。

**2. 「不建 MiniMax 版就这一单用 IndexTTS2」怎么理解**（已定：照 Sky Studio 的理解，用户 2026-11-09）
- 决定第八节第 5 条原话：「不建就这一单用 IndexTTS2」。SkyCut 这份原来照原话写（〇第 5 条、4.5 的表）。
- Sky Studio 那份（5.2 ④ 的批注）：按英文理解；西、德、法这些「其他语言」默认也是 MiniMax 英文声音，可 IndexTTS2 只会中英（`round5` C 节日语读不出），所以那时用不花钱的备用 HeyGen Turbo + 英文参考；请用户指出理解对不对。
- SkyCut 两种理解下做法一样：照 `/quote` 回的 `voice_plan.selection` 读，不自己挑。
- **建议：照 Sky Studio 的理解**；SkyCut 这份那两处改成「这一单用报价里不花一次性费用的那个（英文是 IndexTTS2，其他语言是 HeyGen Turbo）」。
- → **用户定：照 Sky Studio 的理解**——英文用 IndexTTS2，其他语言用 HeyGen Turbo。已改：〇第 5 条、4.5；顺带改了 4.2 的 `skip_one_time`、9.3 的西语那一条。

**3. `eleven-v4` 支持哪些语言没给**
- SkyCut 这份（第七节）：「Eleven 也不支持这种语言 → 按字数估算」，要在报价前知道。
- Sky Studio 那份：只写了 Eleven 的 `language_code` 用占比最高的语言，没有支持哪些语言的清单；`unsupported_language` 只列在 `invalid_request` 的原因里，没写读稿时会不会回。
- **建议**：`/models` 的 `eleven-v4` 那条记录列出它支持的语言（ISO 639-1）。做不到的话，至少点名 `eleven-v4` 报价时语言不支持就回 `invalid_request`、`reason: "unsupported_language"`，SkyCut 收到就改成按字数估算（不花钱）。

**4. 语言提示 `params.language`**
- SkyCut 这份（4.2 第 2 步）：不带，占比由服务器自己算。
- Sky Studio 那份（5.2 ①、风险 14）：拉丁字母的短句分不清英文还是西语时，用请求里的 `params.language`；没有就当英文。
- **建议：SkyCut 带，但只在有用的时候**：本机用 NaturalLanguage（`AITextLanguage` 已经在用）判拉丁字母的那些句子，判得出、而且不是英文时才带（`es`、`de`、`fr`…）；中文、日文这些服务器自己分得清，不带，免得把中文稿带偏。→ 已改：4.2 第 2 步、9.1 第 2 项、第十节 PR 3。

**5. 变声用哪种语言的参考（`params.target_language`）**
- Sky Studio 那份（5.3）：不带就用目标声音的中文参考，没有中文就随便一段。
- SkyCut 这份：没用这个字段。
- 问题：实测都是同语言参考（英文素材配英文参考，`round5` A 节、`confirm-round` B 节）；英文片段换成「我的声音」时拿中文参考去变，没测过。
- **建议**：SkyCut 知道这段说的是什么语言（macOS 26 用生成字幕那套本机检测，AI 也可以直接给）、目标声音又有这种语言的参考时，带 `params.target_language`；不知道就不带，照服务器的默认。界面先不加选项。→ 已改：4.8（加可选参数 `language` 和「用哪种语言的参考」一段）、9.1 第 7 项、9.3、第十节 PR 9。

**6. 给 SkyCut 的目录快照**
- SkyCut 这份（第十节、9.1 第 1 项）：PR 1 要一份从 Sky Studio 导出的 `/models` 快照当测试数据，照 `models-image-2026-11-07.json` 的做法（从服务器生成目录的函数导出）。
- Sky Studio 那份：9.4 的 10 个 commit 里没有这一步。
- **建议**：放进它的第 2 或第 10 个 commit：导出 `voice_presets`、`voice_roles`、`voice_consent` 和声音模型的记录（`limits`、`price`），作为 SkyCut `checks/SkyStudio/Fixtures/` 里的一份 JSON；以后改目录就重新导出。

### 13.3 小事（不用改设计，说清楚就行）

7. **报价前分批用的字数上限**：Sky Studio 按模型给、没有按 kind 的；那份已补：所有声音模型都是同一组（`eleven-v4` 也是），并写明「同一个 kind 新加的模型不低于这一组」（Sky Studio 方案 5.3）。SkyCut 取同一个 kind 里最小的那个就能分批，不用新字段；8.1 已照改。
8. **`voice_library_unavailable`（503）**：私有桶没配时声音库接口都回它，预设旁白照常。SkyCut 第三节和 4.6 原来没列。→ 已补：第三节错误那一行、4.6、5.1、9.1 第 8 项、9.2、第十节 PR 6 / 8；声音库那一节和 `list_voices` / `manage_voices`（还有用 `voice_…` 读稿、变声）说「声音库暂时用不了」，用预设配旁白照常。
9. **`GET /voices/consent-grant` 的「有效」**：建议它回的「有效」已经把「文案版本过期」算进去，并一起回这条授权的版本和当前版本；SkyCut 就能在设置那一页提示「授权文案更新了，下次会再问一次」。不改也能用：过期时建声音服务器回 `consent_outdated`，SkyCut 照 4.5 问一次。
10. **预设声音当变声目标**：Sky Studio 风险 15：预设样音只有约 8 秒，当变声目标没测过。SkyCut 这份允许选预设（4.8、5.5），没提这个风险。建议：变声面板默认放「我的声音」，预设排在后面；人工回归加一条用预设变声；效果不行再照 Sky Studio 的办法给常用预设各生成一段 30 秒的参考。→ 已改：5.5、4.8「挑哪个声音」、9.3、风险第 17 条、第十节 PR 9。
11. **`voice_roles` 的结构**：Sky Studio 只写了「8 个角色 → 预设 id」。SkyCut 按平的 `{角色: 预设 id}` 读；「英式男声只用于英文」由 SkyCut 处理（文字不是英文时改用 Charon 并说一声，4.3），服务器不用表示。建议 Sky Studio 那份写一句结构，免得两边各猜。→「非英文改用 Charon」已补进 4.3 和 9.1 第 8 项。

---

已按「只有用户本人在用」简化（用户 2026-11-09 定；网站、账户、积分相关的兼容照旧）：删了升级前就开着全部权限的补问（直接当作已授权，4.5、5.6、第十二节）、恢复记录对旧 version 1 的兼容（只认 version 2，第三节、9.1 第 6 项、风险第 15 条）、不带前缀的 Eleven 旧声音名的专门处理和指路（4.3、9.1 第 8 项）、`clone_from` 停用后的专门指路（按说明上没有的参数名拒，4.2、9.1 第 10 项），以及为缩短「旧版 SkyCut 不能克隆、不能用 Sky Studio 旁白」那段时间而先合 PR、上线就打测试版的安排（第十节、风险第 2 条）。
