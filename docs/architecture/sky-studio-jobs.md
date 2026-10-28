# Sky Studio 的任务：生成、upscale、克隆走 Sky Studio

> 2026-10-28 引入（[收费方案](../plans/2026-10-27-paid-plans-and-sky-studio-key.md)第 6 刀）。改 `Sources/SrtFlow/SkyStudio/` 里的
> `SkyStudioAPI`（`/models` 之后的那几个接口）、`SkyStudioJob`、`SkyStudioModels`、`SkyStudioJobRun`，或者往 upscale / 生成 / 配旁白里接 Sky Studio 之前必读。
> 接口合同在 **Sky Studio 仓库**（本机 `SkyStudio_APP_Master/cursor-skystudios-app-cinematic`）的 `docs/agents/skycut-api.md`，
> 2026-10-28 上线、**从 Sky Studio main 的 5c8d6a0d 起冻结**（那边要改先发消息、带 commit）。Key、`/me`、授权见 [Sky Studio 账号](sky-studio-account.md)。

## 一、规矩

| 决定 | 口径 |
| --- | --- |
| 谁碰地址 | **只有 `SkyStudioAPI`**（和 `/me` 同一处：认证头、版本号、机器号、错误怎么分）。上传的签名地址、成品地址是服务器给的，**不带 Key**：认证头只在 `request()` 里写一次（`checks/sky-studio-wiring.sh` 第 7 条） |
| 能用什么 | 模型、给人看的价、参数的取值、上限全从 `GET /models`（`SkyStudioCatalog`）读，**SkyCut 不写死**。id 是 Sky Studio 自己的名字（`topaz-starlight`、`bytedance-upscaler-pro`、`seedream5-flash`、`minimax-h3`、`lyria-3-pro`、`eleven-v4`、`sonilo-sfx`、`zonos2`），不是 fal 的端点号；一个模型做两种事就列两次（`minimax-h3` 的文生视频、图生视频） |
| 扣多少 | **一律问 `POST /quote`**（和 `/jobs` 扣钱同一个计价函数：宽于 16:9 按高一档、4K 封顶、按 0.1 秒计都在服务器上）。面板、AI 的确认码显示这个数，交任务时把它当 `max_credits`：服务器算出来更贵回 `price_changed`、一分不扣 |
| 交任务 | `POST /jobs`，每件活一个 `idempotency_key`（`SkyStudioJobRequest` 建的时候生成）。**同时开着的满了**（`too_many_jobs`，每个账号最多 `max_running_jobs` 个，现在 3）：本机等 15 秒、用**同一个 key** 再交，服务器回原来那个任务、不再扣钱。交的时候断网也用同一个 key 再交两次。**交的请求不跟着取消**（发出去一半被掐断，服务器那边可能已经扣钱建了任务）：回来之后用户要停再按任务号停。这一个请求等 120 秒（`submitTimeout`，别的 20 秒）：Sky Studio 在本机 vercel dev 上量到图片、音乐的提交等到做完才回（55 秒、40 秒），线上还没量过 |
| 等 | 没有长轮询：照 `poll_after_seconds` 再问，夹在 2–60 秒（没说按 15 秒）。**问的时候断网不算失败**（活在服务器上照做），连着 10 次问不到才算。最多等 5 小时（服务器自己会收掉没人管的：upscale 245 分钟、别的 35 分钟，失败并退钱） |
| 停 | Task 被取消 = 用户要停：**只有排着队的能取消**（`POST /jobs/{id}/cancel`，退钱）；已经开始的回 `not_cancellable`，照实说「已经开始了、取消不了、积分花了、成品照样会进用户的 Sky Studio 作品库」；取消请求没送到就说不准。取消在不继承取消的 Task 里发（`SkyStudioJobError.Stop`） |
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
| `SkyStudioAPI.swift` | 请求：`/models`、`/quote`、`/uploads` + PUT、`/jobs`、`/jobs/{id}`、`/jobs/{id}/cancel`、下载成品（传文件借 fal 那边的 `FalTransferDelegate`：流着发 / 收、字节进度；第 7 刀删 fal 时改名留下） |
| `SkyStudioJob.swift` | 纯值：请求体（`/quote` 的那一份去掉 inputs、max_credits、idempotency_key）、报价、任务的状态、成品、取消的结果 |
| `SkyStudioModels.swift` | 纯值：`/models` 读成 `SkyStudioCatalog`（按 kind 找、上限、参数的取值） |
| `SkyStudioJobRun.swift` | 交一件活、等它做完：满了等着再交、照 `poll_after_seconds` 问、断网几次不算、停的规矩；`SkyStudioJobError` |
| `SkyStudioJobAccess.swift` | 交活之前要的两样：Key（`SkyStudioJobKey`：`.prompting` 只给用户点了按钮起的、`.silent` 别的都用）、`/models` 记一份（`SkyStudioCatalogCache`） |
| `SkyStudioSpend.swift` | 积分的每日上限和按天的账（`SkyStudioSpendStore`）、积分怎么写（`SkyStudioCredits`） |
| `SkyStudioJobGate.swift` | AI 起的活花积分之前那一关（额度内记账、超了回确认码） |

## 四、谁在用

- **upscale**（6a-2，2026-10-28）：面板和 `upscale_clip`，规矩见 [视频 upscale](video-upscale.md)。模型从 `/models`（`SkyStudioCatalogCache`：这一次运行里 10 分钟内不再问，换了 Key 作废）；
  价问 `/quote`；`params.source` 照送上去的那个文件探；Key 面板起的可以弹授权框、别的不弹（`SkyStudioJobKey`）。
- **积分的每日上限**（`SkyStudioSpendStore`，默认 1,000 积分 ≈ 原来 fal 那一档的 10 美元，设置 → Sky Studio 里改）：AI 起的过 `SkyStudioJobGate`
  （额度内直接记账、超了回确认码，和删文件、fal 花钱同一套 `AIConfirmations`）；面板起的面板本身就是确认（超了只标红不拦）；做完按实收改账，没花出去的退回。
  账按本地时区的自然日，规矩和 fal 那本同一份（`FalSpendLedger` / `FalSpendPolicy`，第 7 刀删 fal 时改名留下）。
- **清单**：`upscale_clip` 属于 `skystudio` 提供方，存了 Sky Studio 的 Key 才列（`SkyStudioAccount.hasKey` 一变就同步那个小文件）；总说明末尾的「Paid」那一行配了哪家列哪家。

## 五、还没做的（第 6 刀后面几个 PR）

- **生成改走 Sky Studio**（6b）：`generate_media` 的图片、文生 / 图生视频、音乐、音效。
- **配旁白和克隆**（6c）：Eleven v4 的字符级时间拼成词；克隆一次送多句（不超过各语言的字数上限）、拿回来在本机按句切开。
- SkyCut 退出了，任务在服务器上照样做完：重开之后按记下的任务号取回。
- 第 7 刀删掉 fal 那条路。

## 六、守卫

- `scripts/check-sky-studio.sh` 第 7 组（`checks/SkyStudio/JobChecks.swift`、`JobRunChecks.swift`）：`/models` 照合同的样例读（认不出的 kind 留着、没有 id 的跳过、上限和取值）；`/quote` 去掉 inputs / max_credits / idempotency_key、读回 credits / typical_seconds / plan、没有 credits 不算回答；`/jobs` 带上 inputs / max_credits / idempotency_key、这一个请求等 120 秒、202 读成排队中；做完的状态和成品（null 的宽高是不知道、克隆的过期时间、旁白的字符时间原样）、没做成的两种写法、认不出的状态；任务号只当一节路径；取消的两种结果；`/uploads` 之后 PUT 只带服务器给的头、不带 Key、文件原样、进度只升不降到 1；下载成品不带 Key、下到一半不留半个文件。`SkyStudioJobRun`：一路做完（每一份都报、照服务器说的间隔问、夹到 2 秒）、满了等 15 秒用同一个 key 再交、交的时候断网再交（一共三次）、问的时候断网几次不算 / 连着 10 次才算、没做成 / 做完没成品 / 认不出的状态 / 余额不够（服务器的话原样）、停的三种（排队中退钱、开始了取消不了、取消没送到）、服务器那边已经取消、等太久。全程走假协议，不碰真的网络。
- `scripts/check-sky-studio.sh` 第 8 组（`SpendChecks.swift`）：积分的每日上限默认 1,000、额度内不问 / 超了问、记账退回按那一天、上限夹住取整、存下来读回来一样。
- `checks/sky-studio-wiring.sh` 第 6、7 条：交任务 / 取消只经 `SkyStudioJobRun`；认证头只在 `SkyStudioAPI.request()` 里写一次。第 8 条（upscale）：把关在建任务之前、
  积分的账只在 `SkyStudioJobGate` 和 `UpscaleJob` 里动、只有面板起的任务可能弹钥匙串授权框、清单跟着 Sky Studio 的 Key 走。
