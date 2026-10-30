# Sky Studio 的任务：生成、upscale、克隆走 Sky Studio

> 2026-10-28 引入（[收费方案](../plans/2026-10-27-paid-plans-and-sky-studio-key.md)第 6 刀）。改 `Sources/SrtFlow/SkyStudio/` 里的
> `SkyStudioAPI`（`/models` 之后的那几个接口）、`SkyStudioJob`、`SkyStudioModels`、`SkyStudioJobRun`，或者往 upscale / 生成 / 配旁白里接 Sky Studio 之前必读。
> 接口合同在 **Sky Studio 仓库**（本机 `SkyStudio_APP_Master/cursor-skystudios-app-cinematic`）的 `docs/agents/skycut-api.md`，
> 2026-10-28 上线；2026-10-30 多模型 / 多参考合同在 Sky Studio PR #228、main `bfc5860e` 更新并上线。Key、`/me`、授权见 [Sky Studio 账号](sky-studio-account.md)。

## 一、规矩

| 决定 | 口径 |
| --- | --- |
| 谁碰地址 | **只有 `SkyStudioAPI`**（和 `/me` 同一处：认证头、版本号、机器号、错误怎么分）。上传的签名地址、成品地址是服务器给的，**不带 Key**：认证头只在 `request()` 里写一次（`checks/sky-studio-wiring.sh` 第 7 条） |
| 能用什么 | 模型、给人看的价、参数的取值、上限全从 `GET /models`（`SkyStudioCatalog`）读，**SkyCut 不写死**。id 是 Sky Studio 自己的名字（`topaz-starlight`、`bytedance-upscaler-pro`、`seedream5-flash`、`minimax-h3`、`lyria-3-pro`、`eleven-v4`、`sonilo-sfx`、`zonos2`），不是 fal 的端点号；一个模型做两种事就列两次（`minimax-h3` 的文生视频、图生视频） |
| 扣多少 | **一律问 `POST /quote`**（和 `/jobs` 扣钱同一个计价函数：宽于 16:9 按高一档、4K 封顶、按 0.1 秒计都在服务器上）。面板、AI 的确认码显示这个数，交任务时把它当 `max_credits`：服务器算出来更贵回 `price_changed`、一分不扣 |
| 交任务 | `POST /jobs`，每件活一个 `idempotency_key`（`SkyStudioJobRequest` 建的时候生成）。**同时开着的满了**（`too_many_jobs`，每个账号最多 `max_running_jobs` 个，现在 3）：本机等 15 秒、用**同一个 key** 再交，服务器回原来那个任务、不再扣钱。交的时候断网也用同一个 key 再交两次。**交的请求不跟着取消**（发出去一半被掐断，服务器那边可能已经扣钱建了任务）：回来后先把任务号报告给调用方，再检查取消并按这个任务号停（不能先抛错丢掉 ID）。这一个请求等 120 秒（`submitTimeout`，别的 20 秒）：Sky Studio 在本机 vercel dev 上量到图片、音乐的提交等到做完才回（55 秒、40 秒），线上还没量过 |
| 等 | 没有长轮询：照 `poll_after_seconds` 再问，夹在 2–60 秒（没说按 15 秒）。**问的时候断网不算失败**（活在服务器上照做），连着 10 次问不到才算。最多等 5 小时（服务器自己会收掉没人管的：upscale 245 分钟、别的 35 分钟，失败并退钱） |
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
| `SkyStudioGenerateTool.swift` / `SkyStudioGenerationRun.swift` / `SkyStudioGenerationActivity.swift` / `SkyStudioGenerationFrame.swift` | generate_media：工具（挑模型、问价、把关、回任务号）、任务（传首帧、交、等、下载）、状态行订阅的那张表、图生视频的首帧（宽高比、传哪个文件） |

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
  服务端自己探真实素材并在扣费前核对 `max_credits`；上传一次，替换模型复用同一批 URL。成品下载到「生成」文件夹，作品库也永久保留。
- **真人参考拒绝后的替换**：默认 `auto_fallback=true`，用户已经授权这次生成时，Seedance 的结构化 `REAL_PERSON_REFERENCE` 拒绝且 `refunded=true` / `charged=false`
  才自动换一次兼容的 H3 或 Omni。只认机器字段，不从英文句子猜；普通安全拒绝不触发。退款晚到只 GET 原 job_id（最多 8 次、间隔 15 秒），
  `get_job phase=waiting_for_refund`；仍不确定就保留原任务号 / 幂等 key 和本机账，不再生成。替换必须保留全部参考与时长，报价不高于原来已批准的上限；
  更贵要重新问，不能因失败绕过消费确认。原单明确退款后才退本机原预留、记新单；生成、upscale、配音都不再把一个无退款字段的失败句子当成已退。
- **清单**（2026-10-30）：`generate_media`、`upscale_clip` 都属于 `skystudio` 提供方，但不再按 Key 隐藏；工具及总说明末尾的「Paid」一行始终存在。
  Key、套餐、积分都在执行时核对；不能要求客户端在会话中添加 Key 后重新发现工具。`SkyStudioAccount.hasKey` 仍同步小文件供旧 helper 使用；
  新清单给旧 helper 不携带过滤条件，新 helper 读取旧清单也不隐藏。旧 fal Key、模型、设置、网络路径已删除。

## 五、还没做的（第 6 刀后面几个 PR）

云端配音（6c，2026-10-29）由 `SkyStudioVoiceoverRun` 执行；本机 Kokoro / macOS 仍走原来的同步路径。

- **先回任务号**：Key 静默读取、模型、全部报价、音频处理都在任务里；调用方只用 `get_job` 等，不重复 `add_voiceover`。普通旁白不可用或整批超每日额度时退本机并报告原因；克隆报错，不改用别人的声音、不问付费确认码。
- **整批预留、逐批结算**：先从 `/models` 读模型与 cap，全部报价后一次预留总额（`SkyStudioVoiceBudget`）；每批复用 `SkyStudioJobRun`、同一幂等 key 重试。未提交的退回，取消 / 失败明确没花钱的退回且只退一次；提交结果未知的保留账，报告 `credits_unknown`、`submission_keys` 和已知服务器任务号，不自动重生成。
- **旁白词时间**：`SpeechWordTimes` 拼接所有字符 chunk，时间都是全局秒数，跨 chunk 的词继续拼；坏的后半段不能只丢掉后半段。转成字幕时按实际解码时长夹住尾端，开始已超时长的词丢掉，20ms 最短词不能突破音频尾巴。
- **克隆合批**：`SkyStudioVoicePlan` 读取 `limits.max_characters_by_language`、按接口语言名选 cap；计数用 Unicode code points（`unicodeScalars.count`），保持完整字形，包含句间换行。短句装同一批、长句拆片记原句索引，不按每句收一次钱。参考段截成 16k 单声道 WAV，只上传一次。
- **本机切句**：多句一批前先确认 macOS 26 转写模型已安装，否则收费前失败。拿到成品后复用系统转写和 `SubtitleCueWords` 字符对齐，每句必须覆盖足够原文；只在识别到的词之间找安静切口，不按字数猜时间。切不准保留完整批次文件并报错，禁止再次收费生成来掩盖失败。
- **落地**：各句都经 `AIAudioFileWriter.writeVoiceover` 写到配音目录；最后核对原工程和 generation，一次 `AIUndoGrouping.step` 同时入轨 / 字幕、记本轮改动、未保存工程落盘。工程已换 / 关闭只留文件，不改别的工程。`get_job` 报批次、阶段、服务器任务号、文件和已收积分；状态行与生成共用 `SkyStudioMediaStatus`。

尚未实施：
- SkyCut 退出了，任务在服务器上照样做完：重开之后按记下的任务号取回。
- 第 7 刀已删除旧 fal 路径；`CloudMedia/` 保留阶段、状态行、传输和每日账，历史工程的 `costUSD` 用 `USDollarText` 显示，不改工程字段或身份键。

## 六、守卫

- `scripts/check-sky-studio.sh` 第 7 组（`checks/SkyStudio/JobChecks.swift`、`JobRunChecks.swift`）：`/models` 照合同的样例读（认不出的 kind 留着、没有 id 的跳过、上限和取值）；`/quote` 去掉 inputs / max_credits / idempotency_key、读回 credits / typical_seconds / plan、没有 credits 不算回答；`/jobs` 带上 inputs / max_credits / idempotency_key、这一个请求等 120 秒、202 读成排队中；做完的状态和成品（null 的宽高是不知道、克隆的过期时间、旁白的字符时间原样）、没做成的两种写法、认不出的状态；任务号只当一节路径；取消的两种结果；`/uploads` 之后 PUT 只带服务器给的头、不带 Key、文件原样、进度只升不降到 1；下载成品不带 Key、下到一半不留半个文件。`SkyStudioJobRun`：一路做完（每一份都报、照服务器说的间隔问、夹到 2 秒）、满了等 15 秒用同一个 key 再交、交的时候断网再交（一共三次）、问的时候断网几次不算 / 连着 10 次才算、没做成 / 做完没成品 / 认不出的状态 / 余额不够（服务器的话原样）、停的三种（排队中退钱、开始了取消不了、取消没送到）且后两种把任务号交出去接着查、服务器那边已经取消、等太久；接着查到底（问到 done / failed 就停、不下载不取消、照服务器说的间隔、断网几次照问、连着 10 次问不到就算了）。全程走假协议，不碰真的网络。
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
- 免费端到端：`scripts/gui-smoke/sky-studio/run.sh`，再用 `SRTFLOW_FFMPEG=<ffmpeg> python3 scripts/gui-smoke/sky-studio/voice.py`。独立 `.skystudiosmoke` App、回环假服务和假 Key，真实 MCP / 本机合成 / 转写 / 文件 / 入轨 / 字幕 / 撤销。`run.sh stop` 只清理这个测试身份；不使用生产 Key。假 Key 钩子同时要求测试 bundle 和回环地址，Beta / 正式包不认。
- [ ] 真实 Key：普通旁白跨多个 chunk、字幕尾端不超音频；两句克隆只付一批并切成两段，听接缝无截字；一步撤销音频字幕一起消失。
- [ ] 有窗口 / 后台工程：状态行显示积分、阶段与停止；取消 queued 只退一次，409 已开始继续查到结局；切 / 关工程不落到另一工程。
- [ ] 每日额度为 0：普通配音退本机说明原因，克隆收费前失败；恢复原设置。

## 八、多模型 / 多参考验证

- `ModelPolicyChecks`：目录顺序不改变用户偏好；模型专属默认值 / 画幅；完整参考限制；不丢输入 / 不裁短；通用安全拒绝、未知退款均不能替换。
- `JobRunChecks`：退款晚到只查原单，断网不产生新单。`SpendChecks`：替换不超过原批准价，退款只记一次，零每日额度但原已确认的单仍可按原上限替换。
- 免费真实 App / MCP：`scripts/gui-smoke/sky-studio/run.sh` 后运行 `SRTFLOW_FFMPEG=<ffmpeg> python3 scripts/gui-smoke/sky-studio/media.py`。
  假 Key / 回环服务 / 独立 bundle：查询目录、亚洲 / 默认图片模型、图片视频音频的有序上传、尾帧、提交时 / 查询时拒绝与退款晚到、替换价上限、未知结果不重交。
- [ ] 正式 Key 人工抽查：`get_status models=true model=minimax-h3` 报出当前限制；普通 / 最高质量 / 点名模型按要求选中；真实多参考文件在消费前给出正确报价。
- [ ] Seedance 真人拒绝时原单先退再替换；看 `fallback_attempts`、`submission_keys` 和 Sky Studio 明细，确认没有重复扣费。

## 九、工具栏任务浮层（2026-10-30 用户选定）

- 编辑器右上角只有一个 `CloudTasksButton`：「生成任务 N」加云图标，点击打开锚定浮层。任务不再逐行占据预览；AI 的停止 / 撤销这一轮横幅仍按工程独立。
- 清单仍全 App 共用，每个工程窗口都能查看；`CloudTasksActivity` 只订阅生成 / 配音与 upscale 活动及它们的状态。列表、阶段与模型变化不驱动整个编辑器，只有汇总变化发布给入口；关闭浮层不取消任务。
- 浮层显示任务名、模型、当前阶段、预计积分。标题汇总只加进行中的报价，未知报价写待确认，失败 / 已完成不算预计消费。上传 / 下载显示真实字节比例，处理只显示已用时间，计时仅在打开浮层时运行。
- 取消只在准备 / 上传 / 排队时出现；等待退款可停止等待。upscale 直接 `job.cancel()`，不得先从清单删除：排队到处理之间的 409 和未知取消结果必须看得见。已处理的任务不承诺能退钱。
- 素材生成 / 配音成功、明确未扣费的取消结束后移除；失败或未知扣费把说明放在 `SkyStudioMediaStatus.issue`，保留到用户关闭提示。关闭只移除提示，不重交、不改账；upscale 做完仍有 Compare / Dismiss。
- 浮层自己注入 `.appLanguage()`，三种界面语言都要核对；`CloudPhaseText` 和检查器继续共用文字规则。`CloudTaskSummary` 的纯值检查覆盖汇总与取消阶段，接线守卫禁止任务横幅回来。

人工回归（免费假服务可覆盖，生产 Key 不必为 UI 验证花积分）：

`SRTFLOW_SMOKE_LANGUAGE=zh-Hans scripts/gui-smoke/sky-studio/run.sh` 后运行 `python3 scripts/gui-smoke/sky-studio/tasks.py`，摆出 4 项排队与 640 积分；用真实窗口验证以下各项。回环服务的 `cancel_already_started` 控制可复现取消竞态，结束用 `run.sh stop` 清理测试身份。

- [ ] 四项排队的报价 240 / 112 / 112 / 176：入口为 4，标题合计 640；预览区没有四条任务横幅；AI 撤销横幅仍可见。
- [ ] 关闭 / 重开浮层不影响任务；取消一项，计数与总价更新；最后一项结束后入口收起。
- [ ] 超过五项在浮层内滚动，最小 900pt 窗口仍能打开；长名字截中间，完整内容可即时查看，英 / 中 / 西文没有重叠。
- [ ] 失败 / 未知扣费保留警示、可关闭；取消竞态仍能读到说明；处理中没有假百分比或无效取消承诺。
