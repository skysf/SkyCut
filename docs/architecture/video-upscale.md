# 视频 upscale：轨道上的片段送 Sky Studio 放大、比过再换

> 2026-10-02 起，**2026-10-28 起送 Sky Studio**（[收费方案](../plans/2026-10-27-paid-plans-and-sky-studio-key.md)第 6 刀：模型、上限从 `/models` 读，价问 `/quote`，
> 花用户的 Sky Studio 积分；之前送 fal、花用户自己的 fal 账户）。方案和用户拍的板在 [视频 upscale](../plans/2026-10-02-video-upscale.md)，
> fal 时代的实测数字在 [smoke test](../reports/2026-10-02-upscale-smoke-test.md)，Sky Studio 那一层（交任务、等、取消、积分的账）在
> [Sky Studio 的任务](sky-studio-jobs.md)，换源的规则在 [工程文件与素材重链接](video-edit-project-file.md)「四之五」。本文记任务那一层（`Sources/SrtFlow/Upscale/`）的长期约束；
> 改 `UpscaleRange` / `UpscaleTiers` / `UpscaleSourceTrimmer` / `UpscaleAudioMux` / `UpscaleOutputName` / `UpscalePipeline` / `UpscaleJob` / `UpscaleOffers` 之前必读。

## 一、一次 upscale 是什么

用户在检查器或右键菜单里对一段画面点「Upscale…」，面板上选范围、目标分辨率、模型，看到 Sky Studio 报的积分，点「开始」；
App 把原片的那一段裁出来送 Sky Studio，做完**先弹对比窗口**，用户点「替换」才换源（方案第 15 条），文件已经存在原片旁边（Sky Studio 的作品库里也永久留一份：传上去的那段的放大版，无声、两头带余料）。

| 环节 | 谁 | 规矩 |
| --- | --- | --- |
| 模型和上限 | `UpscaleTier`（纯值，`UpscaleTiers.swift`） | 从 Sky Studio 的 `/models` 读（kind = upscale），**不写死**：2026-10-28 是 `topaz-starlight`（1080p / 4K，没有 2K）和 `bytedance-upscaler-pro`（1080p / 2K / 4K），一次最长 30.5 秒（余料算在里面）、最高 30 fps、上传最大 200 MB（收费方案第 16、17 条）。目标按短边（1080 / 1440 / 2160），Sky Studio 叫 1080p / 2K / 4K。送不了的说清楚：这一档没有这个分辨率、帧率超了、选中的那段本身超过一次的上限（先切开）。默认 `topaz-starlight`（几分钟；字节 pro 每秒视频约一分钟） |
| 范围 | `UpscaleRange`（纯值） | 三选一：这一段 / 工程里用这个原片最长的那处（默认）/ 整个文件。前两种两头各留 **1 秒余料**（主轨转场最多借 2 秒，往外拖一点也要有帧），**一次放不下就两头一样少留**（不收进选中的那段），起点往前对到整帧、终点往后对到整帧，夹在文件两头之内。范围盖住的用处（差一帧以内算盖住）就是做完要换的段；盖不住的不换。点开的这一段比别处短时，面板提示「另一处用了更长的范围」、建议直接做那一处（方案第 5 条）。变速的段按**源秒数**算范围和钱 |
| 输入 | `UpscalePipeline.uploadsWholeFile` / `UpscaleSourceTrimmer` | 范围就是整个文件、原片是 mp4、没超过这一档的时长 / 大小上限：原片直接上传。否则裁一份：AVAssetReader → AVAssetWriter，原分辨率、原帧率、H.264、**只有画面**，码率每像素每帧 0.3 bit、6–20 Mbps（30 秒 × 20 Mbps = 75 MB，在 200 MB 以内）。阻塞的读和编只在 `MediaReadQueue.export` 上（[阻塞的媒体读取](blocking-media-reads.md)）；Task 取消时经 `UpscaleCancelFlag` 停下、不留半个文件。裁出来的文件自己的 0 秒 = 原片的范围起点，这个数就是记录里的 `sourceOffset` |
| 送 Sky Studio | `SkyStudioAPI.upload` → `SkyStudioJobRun.run`（`/jobs`）→ `SkyStudioAPI.download` | 送上去之前**探一遍送的那个文件**（宽、高、时长两位小数、帧率）当 `params.source`（服务器会再读一遍，差太多回 `price_changed`）；`/uploads` + PUT（原样带服务器给的头、不带 Key）；交任务时 `max_credits` = 用户同意的报价；照 `poll_after_seconds` 等，最多 5 小时（字节 pro 30 秒 4K 近两小时）；**只有排队中的能取消**（退钱），开始了的取消不了（积分花了，成品照样进作品库）。规矩在 [Sky Studio 的任务](sky-studio-jobs.md) |
| 声音 | `UpscaleAudioMux` | **送上去的就没有声音**（裁出来的只有画面；整个 mp4 直接传的，服务器那边的成品也不可信 —— fal 时代实测只有 FLUX 原样复制，Topaz 裁到画面长度、字节重采样）：用 App 自带的 ffmpeg 把原片 `[sourceOffset, +时长)` 的声音封回去 —— 画面流原样复制（**HEVC 要点名 `hvc1`**，不然 AVFoundation 不认）、声音从原片解码后精确裁、重编 AAC 256k（流复制只能在 AAC 帧边界上切，差 ±20 ms）、`-shortest` 按画面收尾。原片没声音就不封。ffmpeg 不在时文件照落、`audioRestored` 为假 |
| 落盘 | `UpscaleOutputName` | `<原名>_<宽x高>_<模型>.mp4`，宽高是**探测出来的输出尺寸**（服务器按 4K 像素上限封顶，和目标不一定一样）；放原片的文件夹，写不进去退到工程的家、再退到下载；撞名加编号（`ExportFileName.unoccupied`，全 App 一个规矩，不覆盖） |
| 结果 | `UpscaleOutcome` | 文件、探测信息、`ClipUpscaleRecord`（原片、偏移、模型名、原片的探测信息、**实收的积分 `credits`**；fal 时代的记录记着 `costUSD`）、Sky Studio 的任务号、实收的积分、耗时。换源时拼成 `ClipSourceSwap.Replacement` 交给 `VideoEditProject.applyUpscale` |
| 账 | `UpscaleJob` / `SkyStudioSpendStore` | 面板上的报价（`/quote` 的积分）就是用户的确认（方案第 10 条）：开跑先记进积分的账，不再问（超了每日上限只标红不拦）；AI 起的在起任务之前过 `SkyStudioJobGate`（见第五节）。做完按实收（`credits_charged`，服务器按实际的文件算、比报价低就收低的）改账；**没花出去的退回**：没交上（裁、传的时候停了 / 出错）、排队中取消了、Sky Studio 说没做成（它自己退钱）。交上之后停不下来的（已经开始了、取消没送到）照实说积分花了。fal 时代那套「做完几分钟后查账单、回写工程」2026-10-28 删了：实收做完就知道，随换源一起记进记录 |
| Key | `UpscaleJob` / `SkyStudioJobKey` | Sky Studio 的 Key（钥匙串，[Sky Studio 账号](sky-studio-account.md)）：**面板起的可以弹授权框**（用户刚点了按钮，`keyPrompt` 让界面提醒点「始终允许」）；面板取模型和报价、AI 起的任务都不弹（读不到就请用户去设置里点「允许…」） |
| 进度 | `UpscaleJob.state` / `UpscaleActivity.shared` | 阶段（`FalJobPhase`，[fal.ai 生成](fal-generation.md) 第十三节）：裁 → 上传（字节比例，1% 一格）→ 排队（带位置；同时开着的满了在本机等也算排队）→ 处理（这一阶段过了多久 + 这一档通常几分钟，`/quote` 报的 `typical_seconds`；服务器的 saving 也算处理）→ 下载（字节比例）→ 封声落盘。同一阶段同一比例只报一次；换阶段才重记开始时刻（`FalJobProgress`）。界面从 `UpscaleActivity` 读：检查器那一节和编辑器顶上的状态行（`FalStatusRows`）同一份文字；切工程 `cancelAll` |

## 二、硬约束

1. **做完不替换**：对比窗口里用户点了替换才 `applyUpscale`；换的时候重新算一遍工程里用这个原片的段（`clipIDs(usingPicture:)`），范围被盖住的才换。
2. **范围按原片算**：在 upscale 过的段上再做，输入仍是原片（`ClipUpscaleRecord.originalURL`），`sourceOffset` 永远相对原片。
3. **扣多少只问 `/quote`**（宽于 16:9 按高一档、4K 封顶、按 0.1 秒计都在服务器上）：面板上显示的、AI 的确认码绑着的、交任务时的 `max_credits` 是同一个数；SkyCut 不写死价格。
4. **一次只交一个任务**：一段一次；多选第一版不做（方案第 12 条）。同时开着的满了（每个账号 3 个）在本机等着再交。
5. **中间文件只在 `UpscaleJob.workFolder`**（临时目录），每次做完 / 取消 / 失败都删干净；成品只在原片旁边（或退路）。
6. **不弹模态框、不进撤销分组**：任务本身不改工程；换源那一步是一次 `perform`。

## 三、界面（2026-10-02 第四刀，mockup 定的样子）

| 哪里 | 文件 | 规矩 |
| --- | --- | --- |
| 检查器一节 | `VideoEditInspector+Upscale.swift`（检查器的一段 body）+ `Upscale/UpscaleJobStatusView.swift` | 画面段才有，放在头部信息下面、Speed 上面。三个状态：还没做（一句说明 + Upscale…）、做着（`UpscaleJobStatusView` **只订阅那一个任务**：阶段、估价、取消、钥匙串授权的提醒）、做完还没处理（Compare… / Discard）、已换源（档位、日期、扣费、原片在哪、Compare… / Revert to Original）。**不是单独的视图**：预览性能 ratchet 数的是 body 次数，选一段多一个视图就是多一次（CI 2026-10-02 逮到 +1 body、+1 update）；任务的增删由检查器上的 `upscaleActivity` 订阅（很少变）；「Upscale…」不挂提示（提示是一层 NSViewRepresentable，每选一段多一次 update） |
| 右键菜单 | `VideoEditTimelineClipBlock.swift` | 图片段没有；普通块一项 Upscale…；换过源的块三项 Compare with Original… / Revert to Original Clip / Upscale Again…。**块不做 IO**：换回原片找不到文件时用 `project.notice` 说一句，菜单不灰 |
| 块角标 | 同上 | 换过源的块名字旁一枚短边的标（`1080p`），和静音图标同一处，不盖缩略图 |
| 面板 | `Upscale/UpscalePanel.swift` + `UpscalePanelModel.swift` | sheet（套 `.appLanguage()`）。范围三选一（默认：别处用得更长就选最长的那处，否则这一段；有另一处更长就提示）、目标三档（默认按画布短边能到的那档，比画布大提示画布也要改）、六个档位各一行（一句话、大约几分钟、夹过的输出尺寸、估价；超过模型的时长 / 大小上限灰掉）、文件名预览、今天已花 / 上限（超限只标红）、没有 Key 才拦。点开始：`UpscaleJob` 进 `UpscaleActivity` |
| 摆出来 | `Upscale/UpscalePresenter.swift` | 挂在检查器底下的不画东西的小视图，只订阅 `UpscaleActivity.panel` / `.compare`；右键、检查器、做完的任务都往那两个字段里写。`Equatable`（按工程的身份）+ `.equatable()`：检查器每重算一次不重算它 |
| 对比窗口 | `Upscale/UpscaleCompareView.swift` + `UpscaleCompareStage.swift` + `UpscaleComparePlayback.swift` | 做完先弹（已经在看别的就不抢）。两个 AVPlayer 同一个主机时间起步（`setRate(_:time:atHostTime:)`，不读 `currentTime`），原片出声、upscale 文件静音，原片加 `sourceOffset`。分割线（点哪儿到哪儿、能拖、底下有滑杆）/ 并排；缩放 适合 / 100% / 200%（按 upscale 文件的像素，默认 100%：缩到窗口大小看不出差别），滚轮平移。按钮：Replace Clip（`applyUpscale`，工程里用这个原片且范围被盖住的段一起换，一步撤销）/ Keep Original（文件留着）/ Try Another Model…（回面板）；看已换源的段时是 Revert to Original / Close。实际扣费那一行单独订阅任务（账单几分钟后才有） |
| 状态行 | `Fal/FalStatusRows.swift`（`UpscaleStatusRow`） | 编辑器顶上、「AI 正在剪辑」那条横幅底下，每个任务一行（mockup「Status row while upscaling」）：「Upscaling <段> with <档位>」、四个阶段的小标（过了的打勾、当前的带百分比 / 已用时间 / 通常约几分钟）、估价、Stop；做完：「<段> upscaled to 1920×1080 · est. / charged」+ Compare… / Dismiss；失败 / 取消一句 + Dismiss。不选中那一段也看得见（检查器那一节只有选中时才有）。只订阅 `UpscaleActivity`，没任务不画 |
| 切工程 | `VideoEditProjectDocument.closeCurrentDocument` | `UpscaleActivity.cancelAll()`：在飞的作废（排着队的替它向 Sky Studio 取消、退钱；已经开始的取消不了，成品进作品库），做完的文件留在磁盘上 |

还没做的：导出面板的「有几段低于目标分辨率」提示（mockup 第二排）；画布自定义尺寸；多选；
SkyCut 退出了、任务在服务器上照样做完：重开之后按记下的任务号取回（成品在作品库里，用户现在可以去网站上下）。

## 五、AI 的工具 `upscale_clip`（2026-10-02 起）

> 怎么接进 MCP（只在存了 Sky Studio 的 Key 时列、任务号、`get_job` 的阶段、结果字段）在 [AI 接口（MCP）](ai-control-mcp.md) 第四节第 44 条；这里记任务那一层的差别。

| 决定 | 口径 |
| --- | --- |
| 同一份数 | 范围、档位送不送得了、默认目标 / 默认范围 / 默认模型都从 `UpscalePanelModel` 算，和面板一个数；模型照 `/models`、价问 `/quote`（和面板同一个请求）；词认成类型在 `AIUpscaleNames`（纯值，和清单的词表对账：模型名是 Sky Studio 的，目标 AI 叫 1080p / 1440p / 2160p） |
| 花钱 | 面板起的：面板就是确认，直接记报价（`Approval.panel`）。AI 起的：`upscale_clip` 问完 `/quote`、在建任务之前过 `SkyStudioJobGate.decide`：每日积分上限（默认 1,000，设置里改）以内直接记账、超了当场回确认码（AI 在聊天里问用户、带码再调才记账），任务拿到记好的那一笔（`Approval.ai`）。问 Sky Studio 的那一两秒里工程换了就什么都不起 |
| 做完 | **AI 起的直接换源**（用户 2026-10-02 定：不弹对比窗口）：`UpscaleActivity.add(job, opensCompare: false)`，`onFinished` 里 `applyUpscale` 包一层 `AIUndoGrouping.step`、选中换了的段、没存过的工程存一下、结局记给 AI 的任务（`onEnded` 记失败 / 取消），这一行从状态行上拿掉。面板起的照旧先弹对比窗口 |
| 钥匙串授权框 | AI 起的不弹（读不到就回一句「请用户去设置 → Sky Studio 点允许…」）；面板起的可以弹，检查器里提醒一句（用户就在电脑前） |
| 看得见 | 状态行和检查器那一节对 AI 起的任务一视同仁（阶段、积分、Stop）；Stop = 取消 = AI 的任务 cancelled，结局照实说积分花没花 |
| 工程换了 | `projectGeneration` 和做完时的 `documentGeneration` 不一样就不换源，结果里说明；切工程本来就 `cancelAll` |

## 四、回归

- `scripts/check-upscale.sh`（`check-all` 第 2 组，要 ffmpeg 造带声音的素材）：范围（三选一、余料、对齐、夹住、谁被盖住、提示；**一次放不下先少留余料**）、
  Sky Studio 的档位（`/models` 读成 `UpscaleTier`、能升到哪几档、上限、送不送得了）、起名落盘、封回原声的参数（精确裁、画面复制、hvc1）、
  真裁一段（帧数 / 时长 / 尺寸、首帧是原片那一刻、没声音、能取消）、流水线对着假 Sky Studio 走全程
  （裁 → 探 → `/uploads` + PUT（不带 Key）→ `/jobs`（source 照送上去的文件、`max_credits` = 同意的价）→ 排队 / 处理 → 下载 → 封声 → 落盘（记实收的积分）；
  整个 mp4 直接上传、超过这一档的上限还是裁、排队中停下替它取消且不留文件、被拒（价格变了）就没有文件）。
  阶段按顺序、上传 / 下载的比例只升不降且报到 100%、同一阶段同一比例只报一次（2026-10-02 进度那一刀）。
  反向验证：去掉 hvc1 的点名、把 `-ss` 挪到原片的 `-i` 之后、阶段重复报、整文件判定不看时长上限，各红。
- `scripts/check-sky-studio.sh` 第 7、8 组（交任务、等、取消；积分的每日上限）；`scripts/check-project-file.sh` 第 41 组（换源；记录里的积分存得下读得回）。
- `checks/sky-studio-wiring.sh` 第 8 条：AI 起的 upscale 在建任务之前过 `SkyStudioJobGate`、积分的账只在它和 `UpscaleJob` 里动、只有面板起的任务可能弹钥匙串授权框、
  清单跟着 Sky Studio 的 Key 走、不弹对比窗口、阶段交给 AIJobs。`checks/fal-wiring.sh`：upscale 的几个文件不许再碰 fal 的 Key、账和把关。
  `scripts/check-mcp.sh`：`upscale_clip` 的词表和 App 对账、定义、说明说清积分 / 30 秒 / 30 fps / 只有排队中能取消、总说明的「Paid」那一行带着它（`UpscaleToolChecks`）；
  做完换源那一下包在 `AIUndoGrouping.step` 里（异步落账扫描）。
- 界面这一层自动化够不着（真窗口、两个播放器、分割线手感），走人工回归；扫描守卫钉着：sheet 套 `.appLanguage()`、提示走 `.instantHelp`、
  每个视图 body 计数、文案三张表配齐。
- **人工回归**（发版前、存着一把 Sky Studio 的 Key、花真积分）：
  1. 选一段 720p 的画面段：检查器头部下面有「Upscale」一节，一句说明 + Upscale…；音频段、图片段没有这一节；右键菜单有 Upscale…。
  2. 点开面板：先转一下（问 Sky Studio 有哪些模型），然后两行模型、每行的积分随范围 / 目标变（Topaz 选 1440p 那一行灰掉、写没有这一档）；默认范围（工程里另一处用得更长时选最长的那处并有提示）、
     默认目标按画布、文件名预览对；超过 30 秒的段写「先切开」、60 fps 的源写只到 30 fps；没有 Key / 读不到 Key 时写清楚、按钮灰。
  3. 点开始：检查器那一节变成阶段 + 积分 + 取消，编辑器顶上多一行状态（上传的百分比真的在走、排队位置、处理那一格每秒走、下载百分比），
     换选中别的段那一行还在；期间照常剪辑。排队中取消：不扣积分、没有文件；处理中取消：写清楚取消不了、积分花了、成品在作品库里。
  4. 做完弹对比窗口：分割线点哪儿到哪儿、并排、100% / 200% + 滚轮平移、空格播放两边同步、声音是原片的；Keep Original 文件留着、片段不变；
     Try Another Model… 回面板；Replace Clip 之后片段指向新文件、关键帧 / 标记 / 音量曲线位置不变、压在段上的字幕 / 文字 / 音效原地不动
     （联动开着也不动，[案例](../bugfixes/2026-10-15-linkage-follows-source-shift-after-swap.md)）、块名字旁有「1080p」、⌘Z 一步撤回。
  5. 换过源的片段：检查器显示模型 / 日期 / 积分 / 原片（fal 时代换的显示美元），Compare… 看原片 vs 现在，Revert to Original 换回；把原片挪到别的文件夹再换回也行；
     原片删了提示找不到。
  6. 积分：对比窗口 / 检查器 / 状态行的积分是 Sky Studio 实收的；设置 → Sky Studio 的「今天已花」跟着变；网站的积分明细里多一行「SkyCut · …」，作品库里多一条放大的片段。
  6b. 把窗口缩到最小宽度再起一个 upscale：状态行上的小标（Preparing / Uploading / In queue / Processing / Downloading）都在一行上、不折行，左边那句话截掉中间。
  7. 切工程：做到一半的任务取消，不弹对比窗口。
  8. AI：让 Claude Code 对一段 720p 的画面段调 `upscale_clip`（额度内）：回任务号和积分、状态行多一行、`get_job` 的 phase 从 uploading 走到 finishing；
     做完片段已换成新文件、块名字旁有「1080p」、⌘Z 一步撤回、右键能 Compare / Revert；把每日积分上限调到比报价小再调一次：AI 在聊天里问你（回的是确认码，
     没起任务）；说不要就什么都没发生、没扣积分，说可以它带码再调才做。
