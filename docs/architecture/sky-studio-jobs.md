# Sky Studio 的任务：生成、upscale、克隆走 Sky Studio

> 2026-10-28 引入（[收费方案](../plans/2026-10-27-paid-plans-and-sky-studio-key.md)第 6 刀）。改 `Sources/SrtFlow/SkyStudio/` 里的
> `SkyStudioAPI`（`/models` 之后的那几个接口）、`SkyStudioJob`、`SkyStudioModels`、`SkyStudioJobRun`，或者往 upscale / 生成 / 配旁白里接 Sky Studio 之前必读。
> 接口合同在 **Sky Studio 仓库**（本机 `SkyStudio_APP_Master/cursor-skystudios-app-cinematic`）的 `docs/agents/skycut-api.md`，
> 2026-10-28 上线；2026-10-30 多模型 / 多参考合同在 Sky Studio PR #228、main `bfc5860e` 更新并上线；
> 2026-10-31 七模型 / 结算政策已随 PR #229 的 exact main `3df55d654628bb4f199f9914f9fa996046e3f291` 通过受控生产发布；正式域名已指向该构建。生产原始 `/models` 在 18:30:42 +08:00 核验为 HTTP 200、27 条及全部七个新 ID，根与 27/27 模型的 `billing_policy.version` 均为 `2026-10-31`。发布与客户端验证证据见 [本次案例](../bugfixes/2026-10-31-sky-studio-model-expansion.md)。Key、`/me`、授权见 [Sky Studio 账号](sky-studio-account.md)。

## 一、规矩

官方原创短片的附加合同见 [官方原创短片](official-film.md)。普通请求保持本页规则；带 `film` 的报价还必须携带实际 inputs，提交携带不透明 pin 和两侧接缝审查。

| 决定 | 口径 |
| --- | --- |
| 谁碰地址 | **只有 `SkyStudioAPI`**（和 `/me` 同一处：认证头、版本号、机器号、错误怎么分）。上传的签名地址、成品地址是服务器给的，**不带 Key**：认证头只在 `request()` 里写一次（`checks/sky-studio-wiring.sh` 第 7 条） |
| 能用什么 | 模型、给人看的价、参数的取值、上限从 `GET /models`（`SkyStudioCatalog`）读；原生角色另读 `/characters/capabilities`，**SkyCut 不写死**。id 是 Sky Studio 自己的名字（`topaz-starlight`、`bytedance-upscaler-pro`、`seedream5-flash`、`minimax-h3`、`lyria-3-pro`、`eleven-v4`、`sonilo-sfx`、`zonos2`），不是 fal 的端点号；一个模型做两种事就列两次（`minimax-h3` 的文生视频、图生视频） |
| 扣多少 | **一律问 `POST /quote`**（和 `/jobs` 扣钱同一个计价函数：宽于 16:9 按高一档、4K 封顶、按 0.1 秒计都在服务器上）。面板、AI 的确认码显示这个数，交任务时把它当 `max_credits`：服务器算出来更贵回 `price_changed`、一分不扣 |
| 交任务 | `POST /jobs`，每件活一个 `idempotency_key`（`SkyStudioJobRequest` 建的时候生成）。**同时开着的满了**（`too_many_jobs`，每个账号最多 `max_running_jobs` 个，现在 3）：本机等 15 秒、用**同一个 key** 再交，服务器回原来那个任务、不再扣钱。**交的时候断网、超时或回答损坏不自动再 POST**：保留同一 key；有任务号只查原单，没有任务号保留待核查。**交的请求不跟着取消**（发出去一半被掐断，服务器那边可能已经扣钱建了任务）：回来后先把任务号报告给调用方，再检查取消并按这个任务号停（不能先抛错丢掉 ID）。这一个请求等 120 秒（`submitTimeout`，别的 20 秒）：Sky Studio 在本机 vercel dev 上量到图片、音乐的提交等到做完才回（55 秒、40 秒），线上还没量过 |
| 等 | 没有长轮询：照 `poll_after_seconds` 再问，夹在 2–60 秒（没说按 15 秒）。**问的时候断网不算失败**（活在服务器上照做），连着 10 次问不到才算。最多等 5 小时（未知供应商结果由服务端继续核查，经过多久都不证明失败或退款） |
| 停 | Task 被取消 = 用户要停：**只有排着队的能取消**（`POST /jobs/{id}/cancel`，退钱）；已经开始的回 `not_cancellable`，照实说「已经开始了、取消不了、积分花了、成品照样会进用户的 Sky Studio 作品库」；取消请求没送到就说不准。取消在不继承取消的 Task 里发（`SkyStudioJobError.Stop`）。**取消不了、说不准的那单接着在后台查到 done / failed**（`SkyStudioJobRun.followToEnd`，不继承取消的后台任务里、照 `poll_after_seconds`、不下载不换源；连着 10 次问不到、等满 5 小时就算了）：Sky Studio 在有人查的时候才去服务商那里取成品、存进作品库、把这一单从「同时开着的」里拿掉，没人查要等它的兜底几个小时、还一直占着 3 个名额中的一个（2026-10-28 真积分测试撞上的，[案例](../bugfixes/2026-10-28-uncancellable-upscale-left-unfinished.md)）。SkyCut 退出前还没查完的单只能靠 Sky Studio 的兜底 |
| 成品 | upscale、图片、视频、音乐、旁白、音效都**永久存进用户的作品库**（只有用户自己删），`result.url` 是永久地址、另带 `generation_id`；克隆的声音不进作品库，留 60 天（`expires_at`）。SkyCut 照旧下到本机。宽高、时长、帧率服务器没记的是 null（MiniMax H3 的视频不记像素和帧率）：从文件读，**别当 0** |
| 阶段 | 服务器的 `phase` 只有 `queued` / `processing` / `saving`（存进作品库）；裁 / 上传 / 下载 / 封声是 SkyCut 自己的阶段。没有百分比，照旧是阶段 + 排队位置 + 已用时间 + 典型时长（`typical_seconds`，从 `/quote` 和任务的回答来），不画假进度条 |
| 话 | 服务器的 `message`（英文、写给人看）原样给 AI；SkyCut 自己说的（停了、没连上、等太久）在 `SkyStudioJobError.message`。界面上的话在各自的调用方按语言换 |
| 只经一处 | `SkyStudioAPI` 的 `submit` / `cancel` 只许 `SkyStudioJobRun` 调（满了等着再交、停的规矩只在那一处；`checks/sky-studio-wiring.sh` 第 6 条） |

## 二、Sky Studio 那边实测的细节（2026-10-28 真服务器跑过 8 种活）

- `/uploads`：PUT 时**原样带上回答里 `headers` 的每一项**，少带或改了签名对不上。PUT 成功后 `file_url` 马上能读。`purpose`：`video`（mp4 / mov，≤ 200 MB）、`image`（jpeg / png / webp，≤ 30 MB）、`audio`（wav / mp3，≤ 15 MB），60 天后自动删。
- upscale：`params.source` 用**导出那个文件**探出来的宽、高、时长（两位小数）、fps，不用时间线上的数；服务器会自己再读一遍上传的文件，差太多回 `price_changed`。832×480、1.0 秒、24 fps 的片子 `/quote` 18、`/jobs` 扣 18。
- 图生视频：`params.aspect_ratio` 必须带（挑 `/models` 里离首帧最近的），不带在扣钱之前就 400；视频的形状跟着首帧走。
- 克隆（zonos2）：冷启动常在队列里等 3.5–4 分钟（queued、queue_position 0、phase_seconds 一直涨），所以 typical_seconds 是 240；连着发几个，后面的通常秒出。
- 第 4 个同时开着的任务回 429，error 里带 `limit: 3`、`running: 3`；同一个 idempotency_key 再交回同一个 job_id、不再扣钱。
- 旁白回 MP3，`words` 是字符级的时间（Eleven v4 的 timestamps 原样）；音效回 WAV，不满 3 秒按 3 秒收钱。

## 三、文件

| 文件 | 管什么 |
| --- | --- |
| `SkyStudioAPI.swift` | 请求：`/models`、`/quote`、`/uploads` + PUT、`/jobs`、`/jobs/{id}`、`/jobs/{id}/cancel`、下载成品（传文件经 `CloudTransferDelegate`：流着发 / 收、字节进度） |
| `SkyStudioJob.swift` | 纯值：请求体（`/quote` 的那一份去掉 inputs、max_credits、idempotency_key）、报价、任务的状态、成品、取消的结果 |
| `SkyStudioModels.swift` | 纯值：`/models` 读成 `SkyStudioCatalog`（按 kind 找、上限、参数的取值） |
| `SkyStudioJobRun.swift` | 交一件活、等它做完：满了等着再交、照 `poll_after_seconds` 问、断网几次不算、停的规矩；`SkyStudioJobError` |
| `SkyStudioJobAccess.swift` | 交活之前要的两样：Key（`SkyStudioJobKey`：`.prompting` 只给用户点了按钮起的、`.silent` 别的都用）、`/models` 记一份（`SkyStudioCatalogCache`） |
| `SkyStudioSpend.swift` | 积分的每日上限和按天的账（`SkyStudioSpendStore`）、积分怎么写（`SkyStudioCredits`） |
| `SkyStudioJobGate.swift` | AI 起的活花积分之前那一关（额度内记账、超了回确认码） |
| `SkyStudioApproval.swift` | 确认码对应的完整请求身份、输入文件身份；摘要只用于显示 |
| `SkyStudioHeldCredits.swift` | 一单活记在本机积分账上的那一笔：没花出去退回（只退一次）、做完按实收换；upscale 和生成共用 |
| `SkyStudioSubmission.swift` | 交上了没有、任务号是多少（分清「没交上就停了」和「交上之后停不下来」，get_job 报 `skystudio_job_id`）；upscale 和生成共用 |
| `SkyStudioGeneration.swift` | 纯值：generate_media 的参数换成 Sky Studio 的 kind / prompt / params（默认值、取整、用不上的说一句）、确认码的记号、离谁最近的画幅、成品的扩展名 |
| `SkyStudioImageOperation.swift` / `SkyStudioImageResult.swift` | 图片操作的离散移动 / 单图 / 倍率合同；下载后按实际字节确认格式并纠正扩展名，不重编码 |
| `SkyStudioGenerateTool.swift` / `SkyStudioGenerationRun.swift` / `SkyStudioGenerationActivity.swift` / `SkyStudioGenerationFrame.swift` | generate_media：工具（挑模型、问价、把关、回任务号）、任务（传首帧、交、等、下载）、状态行订阅的那张表、图生视频的首帧（宽高比、传哪个文件） |

### 模型目录的缓存与换账户

`SkyStudioCatalogCache.cachedCatalog` 只读十分钟内、时间未倒退的热目录，不发 HTTP；
新制作 render 要求先显式取得公开目录，已有制作计划的读取和原样保存不依赖联网。
换 Key 的 `forget` 推进 invalidation epoch；旧异步加载既不能迟到回填 stored，也不能在 defer 清掉后继 loading。
旧调用者可收到它自己那次结果，但共享缓存只认当前 epoch。回归及反向证据见
[换 Key 后旧目录回填](../bugfixes/2026-11-04-catalog-cache-key-change.md)。

## 四、谁在用

- **upscale**（6a-2，2026-10-28）：面板和 `upscale_clip`，规矩见 [视频 upscale](video-upscale.md)。模型从 `/models`（`SkyStudioCatalogCache`：这一次运行里 10 分钟内不再问，换了 Key 作废）；
  价问 `/quote`；`params.source` 照送上去的那个文件探；Key 面板起的可以弹授权框、别的不弹（`SkyStudioJobKey`）。
- **积分的每日上限**（`SkyStudioSpendStore`，默认 1,000 积分 ≈ 原来 fal 那一档的 10 美元，设置 → Sky Studio 里改）：AI 起的过 `SkyStudioJobGate`
  （额度内直接记账、超了回确认码，和删文件、fal 花钱同一套 `AIConfirmations`）；面板起的面板本身就是确认（超了只标红不拦）；做完按实收改账，没花出去的退回。
  账按本地时区的自然日，`DailySpendLedger` / `DailySpendPolicy` 是共用纯值，序列化格式保持不变。
  **确认码绑完整请求**（2026-10-29，`SkyStudioApproval`）：kind、model、prompt、全部参数 / 输入、精确报价，加首帧或原片的文件身份和落点；
  生成还绑文件夹 / 名字，upscale 还绑源范围 / 被替换的段 / 工程。显示摘要只给人看，不能拿它当 action；提交的随机 key 不参与。
  同一件事重问回同一码，换 kind / 提示词 / 参数 / 输入 / 价格就另发，串码不消费、不记账。
- **生成**（6b，2026-10-30 更新）：`generate_media` 收可选 `model`，不再取目录第一条；能力、默认时长 / 分辨率 / 画幅只读 `/models`，价格只问 `/quote`。
  图片亚洲人物、地点或文化主体优先 Seedream 5 Flash；非亚洲、混合、不明确优先 Nano 2。按主体判断，不按提示词语言；AI 用 `image_context` 表达判断。
  普通视频依次 H3、Omni 1.1 Flash、Veo Fast、Seedance 2.0；明确不计成本 / 时间追求最高质量才 `quality=highest`，优先 Seedance 2.5、其次 Veo Pro。
  点名模型优先；默认只从完整兼容输入的候选里挑。没有兼容模型就报告，不能丢引用、裁短时长来凑。
  `get_status models=true` 是只读目录（可 `model=<id>` 过滤），回所有默认值和输入限制，不生成、不记账。
- **参考素材**：`image` + 可选 `last_image` 是首尾帧；`reference_images` / `reference_videos` / `reference_audio` 是有序多模态引用，不能和首尾帧混用。
  图片生成也能收多张参考图。所有路径先过同一份 `confirmReading`，再测量、按目录检查数量 / 字节 / 长度 / 组合限制；图片转码走 `MediaReadQueue.analysis`。
  例：H3 多模态最多 9 图 / 3 视频 / 3 音频，但总数最多 12，音频不能独用；首尾帧只有 2 图。H3 多模态支持 2K / 4K，首尾帧不支持。
  限制只从服务端读，不能抄一份常量冒充模型能力。报价带实际图片数量、参考视频总秒数；有序上传后经 `inputs.references` 原样发；审批身份绑所有本机文件与顺序。
  服务端自己探真实素材并在扣费前核对 `max_credits`；输入不改写、不缩小；原始字节按目录约束上传。成品下载到「生成」文件夹，作品库也永久保留。
- **不自动替换**（2026-10-31 用户要求，覆盖 10-30 的自动切模型策略）：任何模型失败、拒绝或状态未知都不自动重生成、切模型或重放收费 POST。
  `auto_fallback=true` 明确拒绝，false 只为旧客户端兼容。用户另行批准的新生成使用新 key / 新预算。`get_job` 在本机任务结束后也只 GET 原服务器任务，更新 billing 与原结果地址。
- **清单**（2026-10-30）：`generate_media`、`upscale_clip` 都属于 `skystudio` 提供方，但不再按 Key 隐藏；工具及总说明末尾的「Paid」一行始终存在。
  Key、套餐、积分都在执行时核对；不能要求客户端在会话中添加 Key 后重新发现工具。`SkyStudioAccount.hasKey` 仍同步小文件供旧 helper 使用；
  新清单给旧 helper 不携带过滤条件，新 helper 读取旧清单也不隐藏。旧 fal Key、模型、设置、网络路径已删除。

## 五、云端旁白与失败恢复

云端配音（6c，2026-10-29）由 `SkyStudioVoiceoverRun` 执行；本机 Kokoro / macOS 仍走原来的同步路径。

- **先回任务号**：Key 静默读取、模型、全部报价、音频处理都在任务里；调用方只用 `get_job` 等，不重复原始 `add_voiceover`。普通旁白服务不可用时可退本机；每日硬预算不足暂停，不换声音。克隆不退档、不问越额确认码。
- **整批预留、逐批结算**：先从 `/models` 读模型与 cap，全部报价后一次预留总额（`SkyStudioVoiceBudget`）；每批复用 `SkyStudioJobRun`、同一幂等 key 重试。未提交的退回，取消 / 失败明确没花钱的退回且只退一次；提交结果未知的保留账，报告 `credits_unknown`、`submission_keys` 和已知服务器任务号，不自动重生成。
- **旁白词时间**：`SpeechWordTimes` 拼接所有字符 chunk，时间都是全局秒数，跨 chunk 的词继续拼；坏的后半段不能只丢掉后半段。转成字幕时按实际解码时长夹住尾端，开始已超时长的词丢掉，20ms 最短词不能突破音频尾巴。
- **克隆合批**：`SkyStudioVoicePlan` 读取 `limits.max_characters_by_language`、按接口语言名选 cap；计数用 Unicode code points（`unicodeScalars.count`），保持完整字形，包含句间换行。短句装同一批、长句拆片记原句索引，不按每句收一次钱。参考段截成 16k 单声道 WAV，只上传一次。
- **本机切句**：多句一批前先确认 macOS 26 转写模型已安装，否则收费前失败。拿到成品后复用系统转写和 `SubtitleCueWords` 字符对齐，每句必须覆盖足够原文；只在识别到的词之间找安静切口，不按字数猜时间。切不准保留完整批次文件并报错，禁止再次收费生成来掩盖失败。
- **落地**：各句都经 `AIAudioFileWriter.writeVoiceover` 写到配音目录；最后核对原工程和 generation，一次 `AIUndoGrouping.step` 同时入轨 / 字幕、记本轮改动、未保存工程落盘。工程已换 / 关闭只留文件，不改别的工程。`get_job` 报批次、阶段、服务器任务号、文件和已收积分；状态行与生成共用 `SkyStudioMediaStatus`。

**2026-11-01：后续本地失败不否定已成功的生成。**

- `SkyStudioVoiceCheckpoint` 将原始输入、原工程、原播放头、每批原文 / 原句索引、请求 key、服务器任务号、成品地址与元数据、完整原音频、本地切点 / 词时间、已完成成句文件和入轨回执记在配音目录的 `Voiceover-<UUID>.recovery/voiceover-recovery.json`。目录 700、记录 600；串行原子写，IO 经 `MediaReadQueue.voice`。原始批次不再由临时目录 defer 删除。
- POST 前先持久化 `submitted`；云端成功先持久化原结果，再下载，再做本地分析；成句完成即保存进度。长句跨批时保留原音频与分析，恢复按批次原序重建未完成句；已完成句子不重复写文件。付费生成不在分句 / 字幕重试路径上。
- `failure_stage` 区分 `cloud_generation`、`local_split`、`subtitle_alignment`，另有 `download`、`file_write`、`checkpoint`、`insertion`。要求字幕但没有可信词时间时明确留待恢复，不能把“音频成功但无字幕”当整项成功。
- MCP 继续用 `add_voiceover` 和 `get_job`，不增加平行任务系统。`add_voiceover {resume: <recovery_file>}` 默认仅处理已有音频或 GET 已知原单，不重新报价、上传或 POST 生成；完整原音频在本机时连 Key 都不读。`generate_missing:true` 才会为明确未生成的批次报价 / 预留 / 提交。两种调用都回新 `job_id`，用 `get_job` 等；同一恢复文件并发请求复用正在跑的任务。
- “未生成”只能是从未提交，或失败 / 取消有明确无扣费、全退证据且没有成品。未知结果有原单号只复用 `SkyStudioJobRun.resume` GET 原单；无原单号保留原 key 待核查，显式补生成也不重放它。成功后下载 / 本地处理失败不能退款、不能退回 missing。
- 结果给出 `recovery_state`、`completed_line_indices`、`pending_recovery_line_indices`、`not_generated_line_indices` / `not_generated_batch_indices`、`unknown_batch_indices`、每批 `parts`（原文与 `line_index`）、原音频 / 成句文件、原单身份与可执行 `recovery.arguments`。列表中的索引从 0 起；顶层历史 `batch_index` 仍从 1 起。可恢复的未完成任务仍以 `failed` / `cancelled` 结束，通过 `recovery_state` 与方法继续，不能再次提交原稿。
- 入轨仍复用 `AIVoiceoverTool.plan/apply`、`AIVoiceoverSubtitles`。提交前先写稳定的片段 UUID；提交完成记回执。重复恢复不再插入，用户之后撤销也不自动补回；工程已存在那组 UUID、但最终回执没写成时认已有插入，不再生字幕。只存在部分 UUID 时拒绝自动补插，交还现有内容让调用方检查。
- 恢复记录与音频是用户输出，持续保留；记录不是整份工程备份。已保存工程可在重开后按原路径核对恢复；未保存工程只能认原运行代号。收到结果前就退出且没有服务器任务号的未知提交不能凭 key 自动查单（服务端没有该端点）。

仍未实施：
- App 启动时自动枚举 / 接管全部历史云任务（旁白现可显式传恢复文件取回已记下的原单）。
- 第 7 刀已删除旧 fal 路径；`CloudMedia/` 保留阶段、状态行、传输和每日账，历史工程的 `costUSD` 用 `USDollarText` 显示，不改工程字段或身份键。

## 六、守卫

- `scripts/check-sky-studio.sh` 第 7 组（`checks/SkyStudio/JobChecks.swift`、`JobRunChecks.swift`）：`/models` 照合同的样例读（认不出的 kind 留着、没有 id 的跳过、上限和取值）；`/quote` 去掉 inputs / max_credits / idempotency_key、读回 credits / typical_seconds / plan、没有 credits 不算回答；`/jobs` 带上 inputs / max_credits / idempotency_key、这一个请求等 120 秒、202 读成排队中；做完的状态和成品（null 的宽高是不知道、克隆的过期时间、旁白的字符时间原样）、没做成的两种写法、认不出的状态；任务号只当一节路径；取消的两种结果；`/uploads` 之后 PUT 只带服务器给的头、不带 Key、文件原样、进度只升不降到 1；下载成品不带 Key、下到一半不留半个文件。`SkyStudioJobRun`：一路做完（每一份都报、照服务器说的间隔问、夹到 2 秒）、满了等 15 秒用同一个 key 再交、提交断网只 POST 一次并保留原 key、问的时候断网几次不算 / 连着 10 次才算、没做成 / 做完没成品 / 认不出的状态 / 余额不够（服务器的话原样）、停的三种（排队中退钱、开始了取消不了、取消没送到）且后两种把任务号交出去接着查、服务器那边已经取消、等太久；接着查到底（问到 done / failed 就停、不下载不取消、照服务器说的间隔、断网几次照问、连着 10 次问不到就算了）。全程走假协议，不碰真的网络。
- `scripts/check-sky-studio.sh` 第 8 组（`SpendChecks.swift`）：积分的每日上限默认 1,000、额度内不问 / 超了问、记账退回按那一天、上限夹住取整、存下来读回来一样。
- `scripts/check-sky-studio.sh` 第 9 组（`GenerationChecks.swift`）：generate_media 的词表和 `SkyStudioGeneration` 对账、每种的默认值（画幅跟画布 / 首帧、
  视频 5 秒 768p、音效 5 秒 wav、音乐纯音乐不给时长）、秒数取整、用不上的参数说一句不送、请求体（首帧放 `inputs.image_url`、`/jobs` 才带 `max_credits`）、
  确认码的记号、离谁最近的画幅、成品的扩展名。
- `checks/sky-studio-wiring.sh` 第 6、7 条：交任务 / 取消只经 `SkyStudioJobRun`；认证头只在 `SkyStudioAPI.request()` 里写一次。第 8 条（upscale）：把关在建任务之前、
  积分的账只在 `SkyStudioJobGate` 和 `SkyStudioHeldCredits` 里动、只有面板起的任务可能弹钥匙串授权框、清单跟着 Sky Studio 的 Key 走。第 9 条（生成）：把关在建任务之前、
  任务用记好的那一笔、Key 不弹框、清单属于 skystudio、路由只起任务不包撤销分组、get_job 有阶段和 `skystudio_job_id`、状态行订阅生成任务、能取消、不弹模态框。


## 七、配音验证与人工回归

- `scripts/check-sky-studio.sh` 的 `VoiceChecks`：动态上限、code points、合批 / 长句拆片、所有 chunk 的全局词时间、实际时长、切句拒绝不可靠转写、整批配额与未知账；`JobRunChecks` 覆盖 POST 返回瞬间取消仍先报告 ID。
- `scripts/check-mcp.sh` 的 `SkyStudioVoiceChecks`：选声与本机退档、预制音色 / 角色、词时间各种合同格式、WAV 字节逐个对账。
- `scripts/check-voice-recovery.sh`（`check-all` 第 1 组）：链接真实 App 目标文件，只注入假 HTTP 与转写结果；模拟第二批云端成功后真实 `SkyStudioVoiceSplit` 拒绝空词表，验证原音频 / 映射保留、本地恢复零新增生成、只补第三批、最终 6 段 / 6 字幕、重复恢复及回执写失败窗口不重复、一步撤销 / 重做。另测云端部分失败 / 退款、跨批长句字幕对齐失败、未知提交拒绝重放。`VoiceRecoveryChecks` 在 `check-sky-studio` 中真写读恢复记录，验证原单恢复只 GET。
- 免费端到端：`scripts/gui-smoke/sky-studio/run.sh`，再用 `SRTFLOW_FFMPEG=<ffmpeg> python3 scripts/gui-smoke/sky-studio/voice.py`。独立 `.skystudiosmoke` App、回环假服务和假 Key，真实 MCP / 本机合成 / 转写 / 文件 / 入轨 / 字幕 / 撤销。`run.sh stop` 只清理这个测试身份；不使用生产 Key。假 Key 钩子同时要求测试 bundle 和回环地址，Beta / 正式包不认。
- [ ] 真实 Key：普通旁白跨多个 chunk、字幕尾端不超音频；两句克隆只付一批并切成两段，听接缝无截字；一步撤销音频字幕一起消失。
- [ ] 有窗口 / 后台工程：状态行显示积分、阶段与停止；取消 queued 只退一次，409 已开始继续查到结局；切 / 关工程不落到另一工程。
- [ ] 每日额度为 0：新配音收费前暂停；本地已有音频的恢复不受付费额度影响；恢复原设置。
- [ ] 真服务的多批克隆失败后，保持原恢复文件，用本地恢复确认句界听感；重开原已保存工程后仍能恢复，用户原有音频 / 字幕和声音不受影响。真实提供方生成质量与 ASR 识别率不由假夹具替代。

## 八、多模型 / 多参考验证

- `ModelPolicyChecks`：目录顺序不改变用户偏好；模型专属默认值 / 画幅；完整参考限制；不丢输入 / 不裁短；通用安全拒绝、未知退款均不能替换。
- `JobRunChecks`：退款晚到只查原单，断网不重放收费 POST。`SpendChecks` 保留历史预算上限回归；生产路径不再自动申请替换预算。
- 免费真实 App / MCP：`scripts/gui-smoke/sky-studio/run.sh` 后运行 `SRTFLOW_FFMPEG=<ffmpeg> python3 scripts/gui-smoke/sky-studio/media.py`。
  假 Key / 回环服务 / 独立 bundle：查询目录、亚洲 / 默认图片模型、图片视频音频的有序上传、尾帧、提交时 / 查询时拒绝只查原单、退款晚到、未知结果不重交。
- [ ] 正式 Key 人工抽查：`get_status models=true model=minimax-h3` 报出当前限制；普通 / 最高质量 / 点名模型按要求选中；真实多参考文件在消费前给出正确报价。
- [ ] Seedance 真人拒绝后只查原单；核对 `submission_keys`、`billing` 和 Sky Studio 明细，确认没有替换或重复扣费。

## 九、工具栏任务浮层（2026-10-31 轻盈卡片定稿）

- 右上角入口明确写「全部生成任务 N · 本工程 M」，各窗口共享总量，M 只算所在窗口那一次工程的进行中任务。失败 / 未知扣费另标需处理；完成的 upscale 保留比较入口，但不加入进行中数量或预计积分。
- 浮层从上到下为全局汇总、当前工程卡片、其他工程卡片。当前工程始终展开，没有任务也写明；其他工程默认折叠，按工程代号记住展开状态。标题保留数量和异常提醒，进度变化不重排工程。
- 每项前用 `CloudTaskMediaKind` 的视频 / 音频 / 图片图标区分，不能按翻译后的 `kindLabel` 或文件名猜。阶段与积分常驻，详情展开才看完整说明、关闭问题提示或比较 upscale 成片。**浮层暂不放取消按钮**（2026-10-31 用户定）；停止 / `cancel_job` 的现有任务取消和退款规矩照旧。
- 起任务时用 `CloudTaskOwner` 固定工程代号、原身份 token、短 id 与名字快照。生成、配音、AI / 面板 upscale 全部必须提供；`CloudTaskGrouping` 只按代号分组。换窗口、同一工程对象换内容、保存时改名字都不能把旧任务认到新工程上。
- 开着的工程显示实时名字；关闭后的任务留名字快照及异常，不能消失或挪到主窗口名下。后台工程的「打开此工程」与已有窗口的「切换到此工程」都复用 `OpenProjects.focus`，按钮动作时现核对原工程代号；已关 / 已换内容的工程没有打开按钮。注册表窗口状态要可观察，打开 / 收到后台后的标记立即更新。
- `CloudTasksActivity` 只订阅生成 / 配音与 upscale 的活动及状态。列表 / 阶段 / 模型不驱动整个编辑器，只有分组汇总变化发布给入口；每行自己订阅任务，时钟只在打开浮层的行或详情内运行。
- 未知报价写待确认，已失败 / 已完成不算预计积分。上传 / 下载显示真实字节比例，处理只显示已用时间，不能造百分比。关闭浮层不取消，关闭异常提示只移除提示，不重交或改账。
- MCP 的 `get_status.cloud_tasks` 从 `CloudTaskStatusSnapshot` 现读，再经 `CloudTaskReport` 报同一份分组和计数：任务名、媒体类型、模型、报价、阶段、排队位置、实际传输比例、阶段秒数、问题及可用的真实 `job_id` / `skystudio_job_id`。原工程 token、是否仍开着、窗口位置一起报；面板任务没有 AI 任务号时不伪造，不能拿界面 UUID 调 `get_job`。
- `projects[*].cloud_task_summary` / `cloud_task_ids` 对应各工程自己的那次打开。查询不提交任务、不取消、不打开工程、不改会话归属；AI 可直接把这些进展转述给用户。
- 浮层自己注入 `.appLanguage()`，英 / 中 / 西文都要核对。`CloudPhaseText` 继续与检查器共用；`scripts/check-cloud-media.sh` 验分组 / 报价 / MCP 详情，`checks/cloud-task-projects.sh` 验生产接线，禁止任务横幅回来。
- 卡片边框与当前工程的顶部强调线分别叠放，强调线只贴顶，不与填满卡片的边框共用默认布局容器；装饰层不接鼠标。

人工回归（独立假服务，不花生产积分）：

- [ ] 两个可见工程及一个后台工程各起视频 / 图片 / 音频任务：总数相同，本工程数量不同；当前卡片展开，其他默认折叠，媒体图标正确。
- [ ] 没有任务的窗口打开浮层：明确写当前工程暂无任务；失败 / 未知扣费保持原工程归属，折叠标题仍有提醒。
- [ ] 展开后台工程点打开：真实工程窗口出现、预览重建；已有窗口点切换：该窗口前置。关 / 换过原工程后按钮不误开新工程。
- [ ] 展开 / 折叠、看详情、关 / 重开浮层不影响云端请求与积分；浮层没有取消按钮，原停止 / `cancel_job` 仍按真实任务号工作。
- [ ] `get_status` 的工程、总量、分组、类型、阶段、报价与界面相符，后台任务可查询；按详情里的真实 `job_id` 调 `get_job` 能继续等，面板任务不伪造 AI id。
- [ ] 失败只退出进行中总数，异常提示保留到关闭；完成 upscale 的比较 / 关闭仍可用。
- [ ] 超过五项在浮层内滚动，900pt 窗口仍能打开；长名字中间截断并可查看全文，英 / 中 / 西文无重叠；当前卡片强调线只贴顶部，详情按钮可点。

## 十、七个新增模型与结算证据（2026-10-31）

- Wan 三个公开 ID 分别为 `wan-3.0-text-to-video`、`wan-3.0-image-to-video`、`wan-3.0-reference-to-video`，不改变普通视频的默认优先级。
  首尾帧用 `image` / `last_image`；参考模型用 `multimodal` 与有序参考数组，也能用 `document` 或 `web_url`。音频 / 文档 / 页面可单独参考。
  分辨率、智能时长（`duration=null` / `auto`）、种子、思考 / 扩写 / 安全开关以及文件、像素、时长、组合限制只读目录，报价用实际测得的视频参考总时长。
- `kind=lipsync`：HeyGen Speed / Precision 收本机 `video` + `audio`，按 `inputs.*.upload_purpose` 上传；七个附加参数全部开放，动态时长默认 false 必须显式发送。
  目录没有公布的数值上限是 null，不自行猜一个时长差容差；建议两份素材长度接近，不裁短、不垫长。
  MiniMax H3 Max 收 `image` + `audio`，分辨率大小写按目录规整；不误收 HeyGen 的时段 / 动态时长等参数。
- `kind=image operation=remove_background`：只收一张图片，无 prompt / 分辨率 / 画幅 / 参考数量参数。使用目录的十进制字节上限，PNG 原字节保存；不转 JPEG、不铺白底。
  透明图片入轨复用已有 `StillImageClipFactory` 的透明视频 / 遮罩；没有第二套图片合成实现。
- `/models` 的 operation、input_mode、参数说明、outputs、notes、billing_policy 以及根政策完整透传给 MCP；不能只保留旧的几个字段。模型格式由实际 ImageIO / 媒体探测识别，全部文件先授权、测量、验证，再报价 / 预留。
- 本机可选 `idempotency_key` 绑定全部 MCP 参数和原工程，同 key 的并发准备请求拒绝、已经返回过的请求复用原本机 job_id，不再报价、上传、记账或 POST。
  没提供时仅在起操作时生成一次并返回；AI 必须用 get_job 等。服务端仍负责每账号幂等；App 重启后不承诺恢复本机去重表。
  **当前 API 没有按幂等 key 的只读查单端点**：提交应答完全丢失且无 job_id 时，只保留 key / 预算待服务端核查，不自动 POST 寻找它。
  `GET /jobs/{id}` 的回答必须包含同一个任务号；在 API 边界拒绝错号，再允许进度、账务、下载或回执更新。
  官方镜头的持久回执与重启恢复另见 [官方原创短片](official-film.md)，不能把普通内存去重表当作持久恢复。
- `billing` 是唯一结算证据：只用最终净 `credits_charged` 调整本机账；reserved / pending_review / refund_pending 保持预留并报待核查。
  旧 error.refunded 与 cancelled 应答不能覆盖 billing，退回未用预留不代表整单免费。生成成功后下载、保存、入轨失败不退款。
  `get_job` 即使本机已失败，仍可 GET 原单更新账务 / remote_result；反复查询不会再次退款。需要恢复文件时使用原结果地址，不重生成。
- 返回实际 content_type / 宽高 / duration / fps、seed、计费时长与透明标记；计费时长不作为时间线时长。可选 SRT 失败只报 caption_issue，不否定已保存的视频。
  macOS 无法原生打开部分 HeyGen WebM：保留 `original_file` 原字节，借既有 `FFmpegProcess` 生成 H.264/AAC `file` 编辑副本，并明确标记 file_content_type / import_note。
  副本按其本身探测的几何入轨，原 WebM、原结果地址和实际远端元数据继续可恢复；本机转码失败也不退款。

验证入口：`scripts/check-sky-studio.sh` 的 `ModelExpansionChecks` 从本次后端目录快照读七条完整记录，检查参数 / 限制 / 结算 / 幂等。
实际 App：先 `scripts/gui-smoke/sky-studio/run.sh`，再 `SRTFLOW_FFMPEG=<ffmpeg> python3 scripts/gui-smoke/sky-studio/model_expansion.py`。
此流程只用假 Key、回环服务、合成素材和独立 bundle，覆盖模型发现、七种请求、上传用途、重复不记账、WebM 副本、透明 PNG、SRT、入轨与导出、下载失败不退款和原单结算刷新。
付费提供方的输出质量、长时长 / 大文件边界、Wan 智能时长与高分辨率仍需另行授权的真服务抽查，不能把免费夹具冒烟称为付费联调通过。


## 十一、草稿审批与硬预算（2026-11-01，取代旧越额询问规则）

AI 权限与设置确认合同见 [统一设置](workbench-and-settings.md#ai-操作权限与草稿2026-11-01)。`SkyStudioJobGate` 先检查每日硬预算，再检查草稿越档审批；全部权限和旧确认码均不能让日预算超额。`reserveReplacement` 同样遵守预算。配音超预算现在暂停并提示设置，不再悄悄退到本机音色；手动 upscale 按钮与任务开跑时都核对硬预算。余额不足保留服务器 `balance/needed/recharge_url` 并给出充值入口。未知结果只查原单；本次不改变服务端退款政策。

## 十二、图片目录、换机位与图片放大（2026-11-07 客户端合同）

本节对应 Sky Studio `feat/skycut-image-model-catalog` 的最终 image catalog 合同（Commit 2），角色操作另见第十三节。
客户端完成不代表服务器已上线；生产启用和 App 发版另行安排。回归 fixture `models-image-2026-11-07.json`
从该服务端实现的 `buildSkycutModelCatalog()` 导出九条 image 记录（服务端 `af648a67`），不是在线生产目录的证明。

- 普通图片生成可点名 `nano2-lite`、`nano-banana-pro`、`gpt-image-2`、`seedream5-pro`，以及原来的 `seedream5-flash` / `nano2`。
  不发送内部 `pro` 或已停售的名字。未点名模型仍按原 `SkyStudioModelPolicy.ordered` 的 Seedream Flash / Nano 2 顺序，
  不把新模型插进默认优先级。所有画幅、档位、参考 MIME / 数量 / 字节限制只从目录读：Nano 2 目录已去掉 `1:4` / `1:8`，
  Lite 的这两项仍可用。`credits_with_references_by_resolution` 只展示；实际价格只问 `/quote`，不乘参考图片数量。
- `generate_media kind=image operation=camera_angle`：换机位、换角度，匹配目录中的 `qwen-angles`。
  用 `camera_angle:{rotate,tilt,zoom}`，缺的轴为 0；rotate 收 `-180,-135,-90,-45,0,45,90,135,180`，
  tilt 收 `-45,0,45`，zoom 收 `-1,0,1,2`。全零、非离散值先在客户端拒绝；还要核对所选模型公布的轴取值。
  只收一张 `image` 或一项 `reference_images`，不收 prompt；画幅和 `1K` / `2K` 档位仍读目录。
  `/quote` 与 `/jobs` 都显式带顶层 operation 和完整 camera_angle，不发普通生成的 reference count 提示；不在客户端组供应商提示词。
  ±135° 的多步执行和全部价格由服务器决定，客户端不拆单、不计算、不重试付费调用。
- `generate_media kind=image operation=upscale`：放大一张图片，匹配 `image-upscale`；
  `upscale_factor=x2|x3|x4`，默认 x2，只发这一项 params。不收 prompt / aspect_ratio / resolution；也不收 film。
  单图与读取授权走同一条参考路径；`upscale_clip` 继续只管视频片段，图片不走其换源或视频导出路径。
  服务器可能为输出像素上限下调有效倍率；结果按实际返回的宽高报告，不能用请求倍率推算尺寸。
- 两种新操作均不收 film，先于官方短片分派拒绝。报价只使用原 `/quote`；消费仍经 `SkyStudioJobGate`，
  确认身份通过 `SkyStudioApproval` 绑定 operation、全部角度 / 倍率、模型、精确积分、输入文件身份和输出落点。
  参数、文件、模型或报价变了，旧确认码不消费也不记账；每日硬预算照旧先于令牌和全部权限。
- 任务继续走 `SkyStudioGenerationRun` / `SkyStudioJobRun`，复用任务号、稳定 key、`get_job` 和原单 GET 恢复；
  generation / delivery / billing 分开读。中间步骤成功后失败可能仍有供应商成本，只认 billing 的最终净扣费，不能报整单退款。
  图片放大 inline 结果未持久保存时保留待核查，不重新收费生成。
- 下载初始名字读 `result.content_type`，最终经 ImageIO 读取实际图片格式再定扩展名；JPEG 用 `.jpg`，PNG 用 `.png`，
  原字节不重编码。`file_content_type` 报本机实际格式，远端 `content_type` / `remote_result` 原样保留。
  无法确认图片格式时保留已下载文件并报本地交付失败，不退款、不自动重生成。案例见 [图片扩展名](../bugfixes/2026-11-07-generated-image-extension-from-bytes.md)。

验证：`scripts/check-sky-studio.sh` 的 ImageOperation / ImageApproval / ImageResult 组覆盖实际目录、全部离散角度、
两种请求的精确 HTTP body、校验、报价 / 文件身份、硬预算、错误码、部分扣费与只 GET 原单，以及真 JPEG / PNG 下载落盘。
`scripts/check-mcp.sh` 核对 schema、嵌套参数名与前 512 字用法；扫描守卫确认生产下载之后真的调用格式收口。

上线后另行授权的人工回归：各一张真实换机位 / 放大结果核对画面、±135° 的账单和实际尺寸，
Lite JPEG 能正常预览 / 入轨；服务器保存失败时只核查原单及 billing。免费假服务通过不等于真实提供方输出质量或生产联调通过。


## 十三、Sky Studio 角色 A/B（2026-11-07）

客户端依据同日最终角色合同 Commit 3 / 4；服务器 PR #242（角色 A `eab6b978`，B 定稿 `b4e7a376`；开 PR 前复读时 head `1b90c1c8` 仅补测试 / 文档，接口未变）的上线、客户端 CI 和 App 发版分别验收，不能把假服务通过称为生产可用。

- `list_characters` 是账户的免费只读分页，limit 1–100（默认 50）、UUID cursor、ready（默认）/ draft / generating / failed / all；`get_character` 现读详情、可用视图与不透明 revision。安全 DTO 原样保留，不自行算 revision。
- `generate_media` 的 `character_id` / 可选 `character_roles` 是服务器引用，不进入本机路径表，也不下载再上传。普通图片与视频支持；媒体专用操作 / 音乐 / 音效不收。显式视图不得重复、缺失或静默丢弃；省略时由 `/quote` 在剩余组合容量里决定。
- 本机参考数量与角色数量分账：`params.reference_image_count` 只报本机图；`character_usage.roles` 是实际角色视图，usage 的 count 是合并后的图片数。最终 mode 和 revision 从报价取，提交发选择、`character_revision`、精确 `max_credits` 与稳定 key。无显式帧的多模态模型可用全部可用视图；frames 只让服务器提供一张 front，不能把 side/back 自动变成尾帧。
- 确认身份包含角色、视图、revision、mode、全部本机参考与精确价格；角色的项目批准也绑定完整身份，不复用别的角色 / 旧 revision 的宽泛模型批准。换图后重新报价；旧确认不能消费或预留。每日硬预算仍先于确认和全部权限。
- Key / 账户变化清角色缓存、待确认收费身份和官方准备 / 报价；缓存 epoch 阻止旧 Key 的晚到请求回填。任务收费 POST 前重新核对 Key 和 epoch。持久原单证据不删除，换账号不能拿它重新生成。
- `character_not_ready` 等原单，`character_changed` / `price_changed` 现读并重报价，`not_found` 重新列当前账户；`character_checkpoint_failed` 保留原 job_id/key 和明确的零预留 / 未提交证据，只查原单。`get_job.character_usage` 报实际角色与视图，billing 单独处理；角色不授权自动付费替换或模型 fallback。
- 官方短片准备从本账号 DTO 取实际角色资产声明，加入公开 render / reference sources；报价仍由服务器解析 ownership、真正选图并绑定 pin。原本机输入只收 uploads，公开邻镜声明可以含角色资产 URL，但单有 URL 不代表获准使用；新 quote 的 usage 与准备声明不一致就拒绝，要求重做制作图和两侧审查。客户端不下载这些图。

验证：`scripts/check-sky-studio.sh` 的 Character / CharacterApproval 组覆盖精确请求体、只读报价、分页与 Key 变化、迟到缓存、组合上限、实际模式、revision 和确认闸、各错误码；生产接线由 `checks/sky-studio-wiring.sh` 与完整 App 编译核对。

发版前真服务回归：各一张角色图片、H3 多模态视频和 frames 视频，核对实际视图 / 价格 / billing；换图后旧码拒绝、重新报价；官方短片核对真实角色声明、pin 和左右接缝。免费假服务不证明提供方的人物一致性。


### 角色库写入 B 与恢复

- 三个 MCP 工具最终为 `list_characters`、`get_character`、`manage_characters`；前两个只读，list 的 `capabilities=true` 额外返回独立原生角色目录。写工具按 action=create / import / update / replace_view / headshot / delete 分派，不新增同用途的平行工具。三个说明全文均放在前 512 字内；清单上限 **110,000** 是用户 **2026-11-07** 批准。
- 能力、默认模型 / 档位、按文字 / 照片计价的格子和免费写入费均读 `/characters/capabilities`。不把原生模型混入普通 `/models`、不把 `character-import` 内部标记当成新模型。头像默认使用角色里仍受支持的档位；旧值不支持时按当前能力默认值回退。
- 文字 / 单照片创建走原生 `/characters/create`，先 `/quote`，只发送 `params.resolution`；21:9 源图和 1:1 头像的固定形状只展示，不回传 aspect_ratio。原生提示词限能力给出的 UTF-16 单位（当前 25,000），不复用普通图片的 4,000 code-point 门槛。创建先用服务器共享的本地化未命名名称，改名另外 PATCH。
- 照片 / 视图统一用真实 ImageIO 元数据测量，JPEG / PNG / WebP、静帧、≤30 MiB；照片还限 64,000,000 像素。不会把 BMP 当作可接受原生角色格式，也不转码缩图以绕过限制。测图由 `SkyStudioReferenceImage` 与普通本机参考共用；上传前后核对已批准文件身份。
- 导入要求能力表中的 front / side / back，headshot 可选；先问免费 import quote，上传 purpose=character_role，再用 file_url 的路径生成 assetKey / publicUrl / mimeType / sizeBytes，只 POST `/characters/import`。每张上传描述立即存回执，不用任意外部 URL 冒充库资产。
- 免费 PATCH 名字 / 声音描述、PUT 某个视图、DELETE 都发送最新 `character_revision`。重做头像先现读详情 / front、再报价，提交 `/characters/{id}/headshot` 只发模型、resolution、报价 revision、上限和 key，无调用方 prompt / media。角色换图 / 头像完成 / 删除会清此角色相关的待确认 / 官方报价，不误清其他任务的批准。
- **权限**：付费原生创建 / 头像复用 `SkyStudioJobGate` 的报价、规格确认和每日硬预算；全部权限或旧令牌不越硬预算。免费导入 / 改资料 / 换图直接写库，外部本机文件仍走原有读取授权。删除复用 `AIFileTools` 的确认入口：请求批准先问，全部权限直接执行并通知。服务器删除不伪称进本机废纸篓，也不称可用时间线 undo 恢复；进行中删除由服务端保护，不能退款已成功的源图。
- **持久回执**：创建 / 导入 / 头像 / 换图调用前必须选稳定 idempotency_key；本机 job_id 是账户 + key 的摘要，跨 App 重启不变。`Application Support/<原 bundle id>/CharacterReceipts/` 目录 700、文件 600，存原账户、操作、key、确认身份摘要、固定请求 / 已上传描述、原 job_id / character_id 和独立状态；API Key 不落盘。与官方回执共用 `SkyStudioReceiptFile` 的锁、原子写与 fsync，正式 / Beta 按原 bundle id 隔离。
- 先找持久原单，再读当前文件 / 角色 / 目录、报价或预留。重复 key 只能取原操作，不因源图被删或角色后来被换 / 删除而新建。`get_job` 找到持久角色 id 后只读原服务器 job；`manage_characters {action,resume:job_id}` 可显式继续原单轮询，不重报价格、不上传、不重新预留。跨重启的本机预算不重复扣退，无法证明旧聚合账结算时报告 `local_budget_reconciliation=pending`；服务器 billing 仍单独展示实际净额。
- **恢复合同与原规则的差异**：服务端没有按 idempotency_key 只读找单的端点。付费丢答且未拿到 job_id 保留原 key 待核查，继续遵守不重放付费 POST 的原规则。唯一新增例外是用户显式恢复**免费导入**：保存的同一 import body / key 可再送 `/characters/import` 取回已持久角色，绝不重传图或请求供应商；只读 get_job 不做这个 POST。换图丢答只 GET 当前角色，把 current_character、原 revision 与上传描述交给调用方核对，不自动重 PUT。原生角色任务不支持服务器取消，停止只是停本机等待 / 交后台查原单；带角色的普通 generate_media 仍沿用普通任务的排队取消规矩。
- `get_job` 分开显示 `generation_status`（源图）、`character_status`（角色整理）和 `billing`，另报 character_id / operation / 实际 character_usage。源图 succeeded 且角色 finalizing / failed 时保留源地址和实收，提示只查原单重试整理（服务端至少 60 秒间隔），不能说退款、重生成源图或再建一个角色。ready 只返回可复用角色 id / DTO，不自动将四视图放进时间线。

验证：CharacterNativeChecks 真跑生产 `SkyStudioCharacterWorkflow` / API，逐字段比对六动作、照片 / role 上传、报价零写入、动态能力、UTF-16 长度、禁止字段与免费请求；CharacterRecoveryChecks 真写读私有回执、新实例只 GET 旧单、删除原本机照片后恢复、错误响应保留原任务号、未知免费导入的显式同 key 恢复、角色整理失败仍保留实收、免费换图只读恢复和禁止 `/cancel`。CharacterApprovalChecks 核对精确身份、预算、Key 变化与相关角色批准失效。隔离源码反向验证：角色 A 撤掉 revision 身份 / 提交和 epoch 写回保护，实际 8 项断言红；角色 B 撤掉头像提交 revision、放开未知收费重交与已提交回执覆盖，实际 3 项断言红。生产源码均恢复后正向检查通过。全清单连 tools envelope 实测 **106,166 / 110,000 UTF-16 单位**，总说明 **2,012 / 2,048**。

上线后仍须真服务核对：文字 / 照片创建的四视图质量、头像一致性、同 key 丢答恢复与账单、进行中删除保护、免费导入 / 换图 / 改名、原生任务整理失败只恢复原单。未连接生产或使用真实 Key，本轮通过不代表服务端 PR 已部署。
