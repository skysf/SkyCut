# 收费：体验版、导出水印、MCP 门槛，生成改用 Sky Studio 的 key

> 2026-10-26 / 27 和用户讨论拍的板。前四刀已合进 main（#254–#257，水印默认关）；第 5 刀拆成两步照 Sky Studio 定稿的接口做：5a（账号，只读不拦，#261）、
> 5b（照开关拦，#263）都合进去了，5b 合进去时先关着，**2026-10-28 接口上线、用户给自己开了正式版、测试版对着真服务器回归之后打开**
> （`SkyCutGates.enforcedByDefault = true`）；第 6、7 刀照 Sky Studio main 5c8d6a0d 冻结的合同做。做到哪以合进 main 的 PR 和之后的实施报告为准。接口合同在 Sky Studio 仓库的 `docs/agents/skycut-api.md`。
> 真 Codex 连 SkyCut 的冒烟见 [报告](../reports/2026-10-26-codex-client-smoke.md)。

## 背景

- 有一个 B 端客户想买 SkyCut、先要一个体验版；他用 Codex。
- 用户的判断：能选的剪辑软件太多，SkyCut 值钱的是 **MCP**（让 Claude / Codex 剪片）和**通过 MCP 直接调 Sky Studio 生成图片和视频**。
- 现状：仓库公开、AGPL（为了 GitHub 的免费 CI）；没有任何授权或限制；生成走用户自己填的 fal Key（[fal.ai 生成](../architecture/fal-generation.md)）；
  发布用的是自签名证书（[签名与系统权限](../architecture/code-signing-and-permissions.md)），外面的人第一次打开会被系统拦下。
- Sky Studio（skystudioai.com）和 SkyCut 是同一个人的产品：它的 Supabase 已经被四个 App 共用（Linguist 花的就是同一个积分钱包），
  网关（api.skystudioai.com）已经有 `sk-` 开头的 API key（`api_keys` 表、建 / 列 / 作废、限频）。

## 拍过的板

| # | 问题 | 定了什么 | 为什么 |
| --- | --- | --- | --- |
| 1 | 卖什么 | **软件授权和 Sky Studio 的积分都卖**（用户定） | 积分在服务器上，改代码也拿不走；授权是对软件本身的付费 |
| 2 | B 端怎么收 | **学电商 ERP**：席位（一把 key 一个）+ 积分 + 开通服务（配好品牌的剪辑风格、字幕样式，教怎么让 AI 剪）+ 年付。前两三个客户单独报价、后台手动开通，自助购买以后再做（用户：可以学 ERP） | B 端比的是剪辑师的工资和出片速度，还要合同、发票、培训，不该按 C 端几百块一年的订阅收。**不按导出次数收**：SkyCut 在本机跑，数导出要每次上报、也容易造假 |
| 3 | 仓库公开还是私有 | **现在公开；以后转私有，什么时候转用户定** | 公开仓库的 CI 免费：2026-09-26 到 10-18 跑了 500 次、约 1 万分钟 macOS，私有要 600–700 美元。仓库公开时 App 里的任何限制都只拦得住老实人（自己编一份就能去掉）；转私有只保护之后的代码，已经发出去的 AGPL 版本收不回 |
| 4 | 体验版限什么 | **不限分辨率；没付费的导出带水印；MCP 是付费的核心，体验期能用**（用户定） | 只限 480p 拦不住（用户：现在 AI upscale 能直接从 480p 拉到 1080p 以上），用户的客户也不在乎 4K。体验版要让人看清成片好坏、试到 AI 剪片，又不能直接拿去交付 |
| 5 | 规则写在哪 | **服务器下发一组开关**（`mcp`：能不能用 MCP；`watermark`：导出加不加水印），SkyCut 只照着做，不写死天数和规则（用户：选再灵活的那种） | 给某个客户「能用 MCP 但还带水印」这种组合、改主意，都不用发新版。附赠积分先不做：Sky Studio 新账号本来就送 30 积分 |
| 6 | 体验多久 | **默认 7 天**，从这个账号第一次用 SkyCut 查授权算起；后台能改默认，**改默认不影响已经开始体验的人**；能单独给某个账号改（用户定） | 开始时把天数记下来，改默认就不会把别人正在跑的体验缩短 |
| 7 | 怎么认人 | **不在 App 里做登录**：用户在 Sky Studio 建一把 `sk-` key，粘进 SkyCut 设置；**一把 key 同时管授权和积分**。以后做浏览器里点「同意」的一键连接（用户：key 像 fal 那样比较省力） | SkyCut 为 fal Key 做的那一套（钥匙串、设置里一行、清单按提供方列不列、花钱的闸、进度）几乎照用；登录界面、token 刷新、Google 回调全省了 |
| 8 | 接口放哪 | **放在 Sky Studio 网站那个仓库**（`api/skycut/v1/`：`me`、`models`、`uploads`、`jobs`、取消），复用网站现有的生成、扣积分、失败退款；**不在网关里再接一遍各家模型**。Sky Studio 那边用户另开窗口做，这边只给指令 | 同一家模型两份接入、两份价格、两份退款迟早对不上；网关走另一本账，SkyCut 花的积分不会出现在 Sky Studio 的积分明细里 |
| 9 | 自带 fal Key 那条路 | **不留**：Sky Studio 那边接好之后从 SkyCut 删掉。upscale、克隆声音（Zonos2）在 Sky Studio 加；**upscale 只用两个模型**（用户 10-27 定，先前记的「Seedance pro」就是字节这一档）：Topaz `topaz/upscale/video/generative`（Starlight Precise 2.6、放大 1–4 倍、出 H.264）和字节 `fal-ai/bytedance-upscaler/upscale/video`（pro 档、aigc 预设、high 保真度、帧率和原片一样），就是 SkyCut 现在模型表里的 `topaz-generative`、`bytedance-pro` | 它直接跟自己的积分生意抢客人，又是第二套要维护的代码（`Sources/SrtFlow/Fal/` 18 个文件、模型表、价格、接口定义快照） |
| 10 | Sky Studio 要不要做成 MCP | **以后做**一个网上的 MCP，建在 v1 接口上，给 ChatGPT 聊天窗口、Claude 网页版这类只能连网上 MCP 的；**SkyCut 里剪片照旧走 SkyCut 的 `generate_media`** | 走 SkyCut：成品直接落进工程文件夹、AI 接着 `add_clips`；upscale 和克隆要处理本机素材，网上的 MCP 碰不到；花钱的闸、进度、按工程排队都在 SkyCut；同一个对话里两个都能生成视频的工具会让 AI 犯迷糊 |
| 11 | 水印长什么样 | **Sky Studio 的 logo**（`SKY_STUDIO_LOGO/SVG/SkyStudio_logo_vector_transparent.svg`，白字透明底，加一点阴影），**同一时刻只在一处，在四个角和正中之间随机跳**，四角大、正中小（用户定）；每 4 秒换一次、不连续两次落在同一处，四角宽约画面短边的 25%、正中约 15%，不透明度 70%（我提、用户：可以）。**只加在导出的成片上** | 要显眼、随机跳不好裁掉。黑字那个在暗画面上看不见，黑底那个自带底色 |
| 12 | 先支持哪些 AI 客户端 | **先保证 Claude 和 Codex**；Kimi、GLM、WorkBuddy 以后（用户定） | 这个客户用 Codex；SkyCut 的 MCP 是标准协议，GLM 的 Coding Plan 本来就接进 Claude Code 用，Kimi Code、腾讯 WorkBuddy 也认 MCP，难的是每家读说明的规矩和模型剪得好不好 |
| 13 | 客户的电脑 | Apple 芯片；**要求升到 SkyCut 要求的系统**（转写、按文字剪、生成字幕要 macOS 26）（用户定） | |
| 14 | Apple 开发者账号和公证 | **客户确定买了再办**（99 美元 / 年）（用户定） | 在那之前，客户第一次打开要去「系统设置 → 隐私与安全性 → 仍要打开」。换签名会让已装的人系统授权重给一次，越早换代价越小 |
| 15 | 团队 | **第一版只做个人账号**（用户：目前一个人用） | 团队席位、团队钱包以后再做；Sky Studio 已经有团队和团队积分 |
| 16 | upscale 一次最长多少 | **和 Sky Studio 网页一样：30 秒**（服务器收 30.5 秒以内的），**两头的余料算在里面**：超了先少留余料，选中的那段本身就超过 30 秒，告诉用户一次最多 30 秒、先切开。上限由服务器在 `/models` 里报，SkyCut 不写死（我提、用户 10-27：可以） | 规则只留一份，以后要放宽只改服务器、SkyCut 不用发版。网页定 30 秒，是因为字节 pro 每秒视频要约一分钟（30 秒 4K 近两小时）。现在走 fal 时 Topaz 能送 300 秒、字节不限 |
| 17 | upscale 帧率上限 | **30 fps**（29.97 算在内），60 fps 的源直接说不支持（我提、用户 10-27：可以） | 要 upscale 的多半是 AI 生成的低清片段（24 / 30 fps）；fal 处理 60 fps 要两倍的钱和时间；和 Sky Studio 网页同一条规矩。现在走 fal 时帧率不限 |
| 18 | 先做 B 端还是 C 端 | **先做 B 端**：客户在网站上建 key、粘进 SkyCut，用户在后台手动开通正式版。**C 端先只放「联系开通」**：设置里、导出面板、AI 没开通时的提示都写同一个邮箱 support@skystudioai.com（写上账号邮箱），**不开网页**（用户 10-27 先定开网页、当天改成软件里写邮箱）；浏览器里一键连接、网站上付款以后再做（用户 10-27 定） | 前几个客户都是单独谈、手动开；付款页要先定 C 端卖什么、多少钱。写邮箱不用等 Sky Studio 做页面、不会 404，AI 没开通时也能把邮箱原样转告用户；以后做付款页再让 `/me` 给网址 |
| 19 | 导出面板的「去除水印」 | 要加水印时导出面板显示一行「导出的视频会带 Sky Studio 水印」和开通写哪个邮箱，**不拦着导出**；付的是开通正式版，不按次去水印（用户提、我补细节，10-27） | 先带水印导出看看效果也行；按次去水印要每次上报（第 2 条） |
| 20 | 体验按什么记 | **每台 Mac 一次、每个账号一次**（Sky Studio 那边和用户 10-27 定）：SkyCut 发硬件 UUID 的哈希（`X-SkyCut-Machine`，原始编号不出本机）；这台 Mac 用过了 `/me` 回 `free` + `trial_unavailable: machine_used`，SkyCut 要说清楚；开始了的体验换 Mac 照样有效 | 不然换个账号就能一直体验 |

## 两边怎么分

**Sky Studio（用户另开窗口做，这个仓库不写）**：一把 key 认人；`skycut_settings`（默认体验天数、三种状态的默认开关、最低版本）和
`skycut_entitlements`（每个账号：体验从哪天开始、记下的天数、体验到哪天、付费到哪天、单独设的开关）两张表；后台改这些的页面；`api/skycut/v1/` 的几个接口：

| 接口 | 做什么 |
| --- | --- |
| `GET /me` | 是谁、余额、`plan`（`free` / `trial` / `pro`）、体验从哪天到哪天、没给体验的原因、`features: {mcp, watermark}`、这份回答能用到哪天（`valid_until`）、最低版本、同时最多几个任务、充值地址。账号第一次来（这台 Mac 也没体验过时）就开始体验 |
| `GET /models` | SkyCut 能请求的模型、积分价和上限（`limits`：最长几秒、最高帧率、输出最多多少像素、上传多大；第 16、17 条）。id 用 Sky Studio 自己的名字，不是 fal 的端点号 |
| `POST /quote` | 只报价、不扣钱，**每种都能报**：和 `/jobs` 扣钱用同一个计价函数（upscale 宽于 16:9 按高一档收、4K 像素数封顶、按 0.1 秒计），SkyCut 不另抄一份计价规矩；SkyCut 面板和 AI 确认里显示这个数，提交时当 `max_credits` |
| `POST /uploads` | 给一个上传地址（R2 预签名，复用网站现有的上传凭证） |
| `POST /jobs` | 提交生成，立刻回任务号；按估价先冻结积分、失败只退一次；带 `max_credits`（用户同意过的上限），服务器算出来更贵就拒 |
| `GET /jobs/{id}` | 阶段、排队位置、已用时间、典型时长、结果地址、实际扣了多少；**立刻回、不等**，带 `poll_after_seconds`（照这个间隔再问） |
| `POST /jobs/{id}/cancel` | **只能取消还在排队的**、退款；开始了的回 `not_cancellable`、不退 |

出错一律带 `code`：`invalid_key`、`upgrade_required`（版本太老）、`insufficient_credits`（带余额和充值地址）、`price_changed`、`invalid_request`、`rate_limited`（模型那边限流）、
`not_cancellable`、`too_many_jobs`（同时最多 3 个任务）、`not_found`、`provider_error`。**接口最后以 Sky Studio 仓库里的接口文档为准**，SkyCut 照那份做。
upscale 那一份复用 Sky Studio 网站 10-27 上线的视频 upscale（Sky Studio 仓库的 #223）：规则只有它的 `shared/videoUpscale.ts` 一份，两档叫 `topaz-starlight` /
`bytedance-upscaler-pro`，档位 1080p / 2K / 4K 按输出的短边（和 SkyCut 的 `FalUpscaleTarget` 一个口径）。

**SkyCut（这个仓库）**：

1. **key 和授权**（5a 已做，[Sky Studio 账号](../architecture/sky-studio-account.md)）：key 存钥匙串（身份类的名字照旧用 SrtFlow 前缀，见 [产品名与代码名](../architecture/product-name.md)），
   设置里单独一节「Sky Studio」；启动时、回到 SkyCut 时、每小时看一眼，到时候了才问 `/me`；连不上服务器时照上一次的回答用到 `valid_until`
   （服务器定：现在是 72 小时和体验 / 正式到期取早的，不是原来写的 7 天），过了就当免费版。
2. **`watermark` 开关**（5b 已做，2026-10-28 打开）：每条导出管线最后叠一层水印，只有一处共用的叠加（剪辑导出、AI 的 `export_video` 都经过它）；预览、AI 用 `look` 看时间线、
   生成和 upscale 的成品都不加；导出的结果里告诉 AI 带了水印、为什么。压缩、烧录字幕这两个只处理用户自己文件的工具不加。
3. **`mcp` 开关**（5b 已做，2026-10-28 打开）：挡在 App 收到工具调用的地方，**不放在 `skycut-mcp` 小程序里**（谁都能自己写一个小程序去连 App）。工具清单照常列出来，调用时回
   「这台 SkyCut 还没开通 AI 剪辑」和下一步怎么做；`get_status` 报现在是免费 / 体验还剩几天 / 正式。
4. **生成改走 Sky Studio**：`generate_media`、`upscale_clip`、配旁白的克隆换成调 `api/skycut/v1`；钱从美元换成积分：**每日上限默认 1,000 积分**
   （Sky Studio 一个积分标价 1 美分，等于现在 fal 那一档默认的 10 美元），超了照旧要确认码；模型和价格从 `/models` 来，不写死。
   本机的分工不变：upscale 先裁片段（前后各多留 1 秒）、去掉声音再上传，拿回成品自己把原片的声音封回去；克隆从素材里截一段人声当样本。
   upscale 的档位、上限同样从 `/models` 来：Sky Studio 只接第 9 条那两档，`FalUpscaleModels` 里另外四档（Topaz precision、FLUX 两档、字节 standard）跟着 fal 那条路删掉；
   上限照第 16、17 条，面板和 `upscale_clip` 在提交之前就说清楚（超长先少留余料、选中的本身超了说先切开、超 30 fps 说不支持）；要扣多少问 `/quote`，提交时把它当 `max_credits`。
   fal 那两处默认值（Topaz 的 `H264_output` 默认出 HEVC、字节的 `target_fps` 默认插帧成 30 fps，`checks/Fal/schemas/` 里查得到）Sky Studio #223 已经在服务器上显式传了，
   字节的帧率取自上传的那个文件。SkyCut 现在等 25 分钟就替 fal 取消（`FalUpscaleTier.maxSeconds`），字节 pro 30 秒 4K 要近两小时：改成按服务器给的典型时长等；
   SkyCut 退出了，任务在服务器上照样做完，重开之后按记下的任务号取回（成品永久在用户的作品库里，见下一节）。
5. **删掉 fal 那条路**。

## Sky Studio 定稿之后（2026-10-27，Sky Studio 仓库 `feat/skycut-api` 的 08bd908a）

接口还没上线（后端在做），先照文档写。和这份方案上面写的不一样、SkyCut 要跟着改的（第 6 刀，除了注明 5a 的）：

- 每个请求带 `X-SkyCut-Machine`（硬件 UUID 加 SkyCut 的盐做 SHA-256），`/me` 缺它回 400；`/me` 新字段 `trial_started_at`、`trial_unavailable`、`valid_until`、`max_running_jobs`（5a 已做）。
- 没有长轮询：`GET /jobs/{id}` 立刻回、带 `poll_after_seconds`，照这个间隔再问。
- 只能取消还在排队（queued）的任务；开始了的回 `not_cancellable`、不退款 —— 停止 / `cancel_job` 要照实说「已经开始了，取消不了，积分已经花了，成品照样会进作品库」。
- 成品不再 24 小时过期：upscale、图片、视频、音乐、旁白、音效都**长期存进用户的作品库**（用户自己删），`result.url` 是永久地址、另带 `generation_id`；
  只有克隆声音不进作品库，留 60 天（带 `expires_at`）。作品库里的 upscale 是 SkyCut 上传的那段（无声、两头各多 1 秒）的放大版。SkyCut 照旧下到本机、自己封回原声。
- 每个账号同时最多 3 个任务（queued + running，`/me` 的 `max_running_jobs`），第 4 个回 `too_many_jobs`（带 `limit`、`running`）：SkyCut 在本机排着、一个做完再提交下一个。
  不按每分钟次数限流；`rate_limited` 只表示模型那边限流。
- free 也能花积分生成，plan 只管 MCP 和水印；只扣个人钱包（团队成员也一样）；正式版由后台手动开通，没有付款流程。
- `/quote` 每种都能报价：估价、确认码一律用它，不再用本机的单价表。
- upscale 的 `params.source` 要取自**导出后的那个片段文件**（宽、高、秒数、帧率），不用时间线上的数；服务器重读文件，差太多回 `price_changed`。
- 模型 id 用 Sky Studio 的：`seedream5-flash`、`minimax-h3`（文生视频、图生视频两个 kind 都用它）、`lyria-3-pro`、`topaz-starlight`、`bytedance-upscaler-pro`、
  `eleven-v4`、`sonilo-sfx`、`zonos2`。MiniMax H3 的分辨率只有 `480p` / `768p`（小写，没有 1080p），时长 5–15 秒。
- 每种用哪些字段见文档的「Per kind」：旁白、克隆、音效的文字都放 `prompt`，克隆的声音样本放 `inputs.reference_audio_url`（走 `/uploads`，不收 data URI）。
- `phase` 只有 `queued` / `processing` / `saving`（下载是 SkyCut 自己的阶段）。
- `/uploads` 的 `purpose`：`video`（mp4 / mov，≤ 200 MB）、`image`（jpeg / png / webp，≤ 30 MB）、`audio`（wav / mp3，≤ 15 MB），60 天后自动删。
- fal 实测账单带来的（所有价格都从 `/models` 和 `/quote` 拿，不写死；定价依据在 Sky Studio 仓库 `docs/credits/skycut-audio-unit-economics-2026-10-27.md`）：
  - **克隆**：fal 每次请求至少按 1 分钟收，所以每次 2.5 积分、不管长短。**不要一句一句送**：一次送多句，不超过各语言的字数上限（Unicode 字符数：英 800、
    西 / 法 / 德 / 意 / 葡 650、日 280、中 220、韩 320），拿回 WAV 在本机按句切开（3 分钟的解说一句一句送约 90 积分，整段送约 12.5）；超了回 `invalid_request`
    （`field: "prompt"`，带 `limit`）。闲置后第一次可能排队 2–4 分钟（冷启动），之后约 20 秒；输出单声道 44.1 kHz 16 位 WAV。
    这改了 SkyCut 现在「一句一句送 fal」的做法：按句切开要知道每句在哪，第 6 刀定怎么切（用 SkyCut 自己的转写和静音检测）。
  - **音效**：0.45 积分 / 秒，每次至少按 3 秒收。
  - **旁白**：每 1000 字符 20 积分，每次至少 1 积分。`words` 是 Eleven 的 timestamps 原样：分块给出 `characters` 和每个字符的开始、结束时间（**字符级，不是词级**），
    要自己拼成词。输出 MP3 44.1 kHz 128 kbps。
- 没变的：`Bearer sk-…` 认证、`X-SkyCut-Version`、错误格式、不需要 CORS、upscale 的上限（30.5 秒、30 fps、4K 像素、200 MB）。
- 「联系开通」那一页和 `/me` 的 `upgrade_url`：**不要了**（第 18 条，用户 10-27 改成软件里写邮箱 support@skystudioai.com）。

## 分刀（每刀一个 PR）

1. 这份方案 + 真 Codex 的冒烟报告。
2. 修：工具会悄悄丢掉不认识的参数（冒烟里 Codex 给 `set_text` 传了 `end`，被忽略了）。
3. 修：「连接」AI 客户端时留的配置备份，权限比原文件宽。
4. **水印**：做出来、接进所有导出入口，**开关先默认关**（授权接上之前什么导出都不加），留一个只给测试用的打开办法；先渲一张样片给用户看，再定数字。
5. key + `/me` + 两个开关接上，拆成两步：**5a** Sky Studio 账号（key、`/me`、此刻的授权、设置里一节，只读不拦，照定稿的文档做、本机假服务器测）；
   **5b** 照两个开关拦（MCP 的门、导出水印、导出面板写开通的邮箱、结果里告诉 AI）。本来打算挂着等接口上线再合；2026-10-28 用户定绿了的 PR 直接合，
   所以 5b 合进去时先关着（`SkyCutGates.enforcedByDefault = false`，测试开关 `skystudio.testGates` 只能打开）：开早了之后打的包里谁都问不到授权，
   用户自己的 AI 剪辑也被挡住。**2026-10-28 Sky Studio 的接口上线、用户给自己开了正式版、测试版 0.18.49 对着真服务器走完回归，单独一个 PR 打开。**
6. 生成、upscale、克隆改走 Sky Studio（2026-10-28 接口上线、合同冻结在 Sky Studio main 5c8d6a0d）。拆四个 PR：**6a-1** 任务的接口（`/models`、`/quote`、`/uploads`、`/jobs`、轮询、取消、下载，`SkyStudioJobRun`；假服务器测，见 [Sky Studio 的任务](../architecture/sky-studio-jobs.md)；#267 已合）、**6a-2** upscale 换过去（加积分的每日上限、清单按 Sky Studio 的 Key 列；#268 已合，2026-10-28 真积分测过）、**6b** `generate_media`（图、视频、音乐、音效走 Sky Studio，`model` / `options` 两个参数删掉，fal 的生成那一套删掉、只留配旁白用的）、**6c** 配旁白和克隆。
7. 删掉 fal 那条路（第 6 刀上线之后）。

## 我定的细节（用户没反对；要改再改）

- 一把 key 算一个席位；建 key 时起个名字（比如「剪辑部 1 号机」），SkyCut 不上报电脑名（电脑名里常带人的真名）。
- 服务器能告诉老版本 SkyCut「请更新」（`upgrade_required`），以后改接口不怕老版本突然坏掉。
- 水印的位置序列每次导出按一个种子定：同一次导出里能复现，不同的导出不一样。
- 没开通 MCP 时工具清单照常列（AI 知道有这些工具，才能告诉用户去开通）。

## 还没定、以后再说

- Sky Studio 的网上 MCP（第 10 条）；团队席位、团队钱包；附赠积分；浏览器里一键连接；Apple 公证；Kimi / GLM / WorkBuddy。
- Claude 桌面版的「连接」还没在真机上跑过（它开着时要重启才认新配置），之后补。
- Codex 每次工具调用要带整份工具清单（约 2.7 万输入 token，见冒烟报告），免费版撑不完一次完整剪辑；以后可以给 Codex 精简清单（它的配置能只开一部分工具）。
