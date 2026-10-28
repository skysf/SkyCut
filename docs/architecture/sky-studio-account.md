# Sky Studio 账号：Key、`/me`、此刻的授权、照授权拦

> 2026-10-27 引入（[收费方案](../plans/2026-10-27-paid-plans-and-sky-studio-key.md)第 5 刀）。改 `Sources/SrtFlow/SkyStudio/`、`KeychainSecret.swift`、
> 设置里的「Sky Studio」一节、AI 调用的门（`AIToolRouter`）、导出面板上「会带水印」那一行之前必读。接口合同在 **Sky Studio 仓库**（本机 `SkyStudio_APP_Master/cursor-skystudios-app-cinematic`）的
> `docs/agents/skycut-api.md`，以那份为准（2026-10-28 上线，合同从 Sky Studio main 的 5c8d6a0d 起冻结，那边要改先通知）。
> 第一步（5a，#261）只读授权；第二步（5b，#263）照授权拦：MCP 的门、导出水印、导出面板那一行、告诉 AI。**5b 合进去时先关着**：
> Sky Studio 的接口上线、用户在后台给自己开了正式版之前谁都问不到授权，一打开连用户自己的 AI 剪辑也挡住。**2026-10-28 打开**
> （`SkyCutGates.enforcedByDefault = true`）：接口上线、用户的账号开了正式版、测试版 0.18.49 对着真服务器把第六节走完之后。

## 一、规矩

| 决定 | 口径 |
| --- | --- |
| 怎么认人 | 用户在 Sky Studio 网站上建一把 `sk-` Key（右上角头像 → SkyCut；网页上没有叫「设置」的菜单），粘进 SkyCut 的设置。设置里「去 Sky Studio 建 Key」直接打开那个窗口 `https://skystudioai.com/app?skycut=1`（`SkyStudioLinks.keysPage`：没有 Key 的人问不到 `/me`，所以写在 App 里；2026-10-28 和 Sky Studio 定好不改，自检钉着）；**一把 Key 同时管授权和积分**（方案第 7 条）。App 里不做登录；浏览器里一键连接、网站上付款以后再做（2026-10-27 用户定：先做 B 端，后台手动开通） |
| Key 存哪 | 钥匙串一条通用密码：服务名 = bundle id + `.skystudio`（测试版另一条），账号 `api-key`（`SkyStudioKey`）。**身份类的名字，永远不改**（[产品名与代码名](product-name.md)；`checks/product-name.sh` 钉着） |
| 钥匙串怎么读 | 和 fal 的 Key 同一份 `KeychainSecret`（两档：`.silent` 不弹框 / `.interactive` 弹框，探针结论见 [fal.ai 生成](fal-generation.md)第六节）。**后台问 Sky Studio 从不弹授权框**：只走 `keyWithoutPrompt()`，读不到就在设置里说「要授权」，用户点了按钮才弹 |
| 粘进来的话 | 去掉 `Bearer `、引号、首尾空白；要 `sk-` 开头、只有 URL 安全的字符、至少 20 个字。**长度不写死成 46**（那边换了长度这里不该先拒） |
| 存的时候 | 存进钥匙串、马上问一次 `/me`：Sky Studio 回 `invalid_key` 就**不留着这把 Key**；没连上就先留着，之后再问。换一把 Key 时上一把问到的那份作废 |
| 机器号 | 每个请求带 `X-SkyCut-Machine` = SHA-256(硬件 UUID + 盐) 的 64 位小写十六进制（`SkyStudioMachine`）：原始的硬件 UUID 不出本机、不发电脑名。Sky Studio 按它「每台 Mac 只给一次体验」。**盐和算法永远不改**（改了每台 Mac 都成了新机器，又能体验一次）；自检钉着一组算好的值 |
| 地址 | `https://skystudioai.com/api/skycut/v1`，**只有 `SkyStudioAPI` 碰它**。自检 / 冒烟用 `SRTFLOW_SKYSTUDIO_API_BASE` 指到本机的假服务器，**只认回环地址**（Key 不会因此发到别处） |
| 此刻的授权 | 纯函数 `SkyCutLicense.evaluate`：plan、`features`（`mcp` / `watermark`）、`valid_until` 全照服务器的，SkyCut 不写死天数。**没有 Key、没问到过、过了 `valid_until` 都按免费版**（MCP 关、导出带水印）——这是「没有授权」本身的定义 |
| 断网 | 上一次的回答存在 UserDefaults（`SrtFlow.skystudio.me.v1`），照它用到 `valid_until`（服务器定：现在是 72 小时和体验 / 正式到期取早的）。服务器的钟换成本机的：`拿到回答时的本机时间 + (valid_until − server_time)`，本机的钟和服务器差多少都不影响；本机的钟比拿到回答时还早 5 分钟以上（往回拨了）就不作数。**换算只给要和本机的「现在」比的时间**（`valid_until`、体验的起止）：「拿到回答 − server_time」里还有请求在路上的几秒，只拿来显示的「正式版到哪天」照服务器给的那一刻，不换算；「体验还剩几天」不满一天算一天，但不超过体验本身的天数（`trial_ends_at − trial_started_at`）。2026-10-28 真服务器上回答晚到 4–5 秒，刚开始的体验显示成 8 天、开通到 12-31 显示成 1 月 1 日（[案例](../bugfixes/2026-10-28-trial-and-pro-dates-shown-a-day-late.md)） |
| 什么时候问 | `SkyStudioRefresh`：启动时、回到 SkyCut 时，上次问到超过 30 分钟才问；每小时看一眼，超过 6 小时才问；没问到过 / 过期了马上问；没问成至少隔 5 分钟再试。设置里「再查一次」随时问 |
| Key 作废了 | 后台问到 `invalid_key`：清掉存的回答（这把 Key 的授权不再作数，不等到 `valid_until`），设置里说 Sky Studio 不认、请粘一把新的 |
| 版本太老 | `upgrade_required`：设置里照服务器的话说，带下载链接（`download_url`）；存的回答照旧用到 `valid_until` |
| 体验给不了 | `/me` 回 `plan: free` + `trial_unavailable: machine_used`：设置里说「这台 Mac 已经体验过 SkyCut，这个账号在这台 Mac 上没有体验期」 |
| 联系开通 | 不是正式版时设置里写一句「开通正式版请发邮件到 support@skystudioai.com，写上你的 Sky Studio 账号邮箱」（`SkyStudioLinks.supportEmail`），邮箱能选中、旁边一个「复制邮箱」。**不开网页、不做 mailto 链接**（2026-10-27 用户定：软件里写一个邮箱就好；用网页邮箱的人点 mailto 跳出来的是系统「邮件」的设置向导）。正式版由 Sky Studio 后台按账号手动开，所以要写上账号邮箱。没有 Key 的人问不到 `/me`，邮箱写在 App 里，换邮箱要发新版 |
| 服务器的网址 | 只认 https（本机的假服务器给的 http://127.0.0.1 也认），读不成就当没有（`SkyStudioLinks.webURL`） |
| 读回答 | 读得宽：认不出的字段不管、少了可选的不算错、日期带不带毫秒都认（Foundation 自带的 `.iso8601` 不认毫秒，JS 的 `toISOString()` 带毫秒）；少了必须的（`features`、`valid_until`）就不算回答 |
| 报错的话 | 服务器的 `message`（英文、写给人看）原样显示；没连上、回的不像话这两种是 SkyCut 自己的话，经 `L10n` 按界面语言 |
| **照授权拦默认打开** | `SkyCutGates.enforcedByDefault = true`（2026-10-28 起，`checks/SkyStudio/GateChecks.swift` 钉着）。合进来时先关着：接口上线、用户给自己开了正式版之前谁都问不到授权，开早了用户自己的 AI 剪辑也被挡住。测试开关 `skystudio.testGates` 只能打开、**不能用它关掉**（不然一条 `defaults write` 就绕过去了），默认开着之后它不起作用，留着给哪天又得先关上时用 |
| AI 的门 | 此刻的授权不让用 MCP：AI 的工具一个都不做。门在 `AIToolRouter.handle` **核对参数名之后、建调用排队之前**（`SkyStudioAccount.aiRefusal`），不在小程序里（谁都能自己写一个小程序连 App）；工具清单照常列（AI 知道有这些工具，才能告诉用户去开通）。**`get_status` 照常回**，报 `skycut_plan`（套餐、从哪来、AI 能不能用、带不带水印、体验还剩几天、正式版到哪天、出了什么事、请用户做什么）。被挡住的回「Not done」+ 为什么 + 请用户做什么（粘 Key、发邮件开通、点「允许…」、点「再查一次」、更新 SkyCut），话和规矩都在纯值的 `SkyCutGates`（英文；界面语言写的细节不带给 AI） |
| 还没问完时 | 此刻的授权不作数（没问到过、过期了）又有 Key：先问一次 `/me` 再判（正在问就等它；没问成过不到 5 分钟的不再问；最多等一次请求的超时 20 秒，`SkyStudioAccount.settledLicense`）。刚启动、离线几天之后的第一个调用不会因为还没问完就被挡 |
| 导出水印 | 带不带听服务器的 `watermark`：`SkyStudioAccount.exportsWithWatermark`，导出器、导出面板那一行、`export_video` 都问它（[导出水印](export-watermark.md)）。要带却读不出 logo 就不导 |
| 导出面板那一行 | 会带水印时底栏写「导出的视频会带 Sky Studio 水印。开通正式版就不带了：请发邮件到 support@skystudioai.com……」+「复制邮箱」，**不拦导出**（方案第 19 条）；只出声音时不写。只订阅 `SkyStudioAccount` |
| 告诉 AI 带了水印 | `export_video` 开始时（会带）和做完的 `get_job`（带了）都写 `watermark`：带了什么、为什么、怎么去掉（`SkyCutGates.watermarkNote`）。AI 用 `look` 看成片会看到它，要能跟用户说清楚 |

## 二、文件

| 文件 | 管什么 |
| --- | --- |
| `KeychainSecret.swift` | 一条通用密码项的存 / 读 / 删、两档读法、一次运行读一次的缓存（`KeychainSecretCache`）。fal 和 Sky Studio 共用 |
| `SkyStudio/SkyStudioKey.swift` | 钥匙串那一条叫什么、粘进来的话怎么整理 |
| `SkyStudio/SkyStudioMachine.swift` | 硬件 UUID → 机器号 |
| `SkyStudio/SkyStudioAPI.swift` | 请求（地址、四个头）、`GET /me`、错误分成三种（`SkyStudioFailure`：服务器的错 / 没连上 / 回的不像话） |
| `SkyStudio/SkyStudioMe.swift` | `/me` 的回答、怎么读怎么存、存下来的那份（`SkyStudioStoredAnswer`）、几个网页（`SkyStudioLinks`） |
| `SkyStudio/SkyCutLicense.swift` | 此刻的授权（纯）、什么时候再问（`SkyStudioRefresh`，纯） |
| `SkyStudio/SkyStudioProblem.swift` | 问不成 / 存不了 Key 时为什么（纯；设置最后一行、AI 被挡时的话都照它说） |
| `SkyStudio/SkyCutGates.swift` | 照授权拦的规矩（纯）：生不生效、AI 让不让、带不带水印、跟 AI 说的话、`get_status` 的 `skycut_plan` |
| `SkyStudio/SkyStudioAccount.swift` | 存 / 删 Key、问 `/me`、存回答、启动 / 回到 SkyCut / 每小时看一眼；照授权拦的入口（`aiRefusal`、`exportsWithWatermark`、还没问完时先问 `settledLicense`）。`@MainActor` 的小对象，只有设置那一节和导出面板那一行订阅 |
| `SkyStudio/SkyStudioSettingsSection.swift` | 设置里的「Sky Studio」一节 |
| `SkyStudio/SkyStudioProHints.swift` | 开通正式版怎么说：设置里那一行（`SkyStudioContactRow`）、导出面板上「会带水印」那一行（`ExportWatermarkNotice`），共用「复制邮箱」 |

## 三、还没做的

- **发第一个带照授权拦的正式版之前**：正式版和测试版的 Key 各存各的（钥匙串按 bundle id 分开），用户要先在正式版的设置里粘一次 Key，
  不然装上之后用户自己的 AI 剪辑也被挡住（正式版 0.18.47 还没有「Sky Studio」这一节，要先装一个有这一节的版本再粘）。
- 第 6 刀（生成、upscale、克隆改走 Sky Studio 的 `/quote`、`/uploads`、`/jobs`）、第 7 刀（删掉 fal 那条路）。定稿里和 SkyCut 现在做法不一样的地方记在收费方案「Sky Studio 定稿之后」一节。

## 四、已知能绕过去的（不防）

- 改 UserDefaults 里存的回答（把 `valid_until` 改到很久以后）、仓库公开期间自己编一份去掉判断（收费方案第 3 条）。真正收得住的是服务器那一侧：积分、体验按账号和机器记。

## 五、守卫

- `scripts/check-sky-studio.sh`（`check-all.sh` 第 2 组，不碰网络、不碰钥匙串）：Key 的整理和钥匙串那一条的名字；机器号钉死一组值、这台 Mac 读得到、发出去的不是原样的 UUID；
  `/me` 照合同里的样例逐字段读、带毫秒的日期、读得宽、少了必须的不算回答、网址只认 https 和本机、存了读回来一样、服务器时间换本机时间；
  假 URLSession 上看 `/me` 的地址、方法、四个头，401 / 426 / 429 留着 code 和附加字段，502 的网页 / 2xx 读不成 / 断网各是哪一种，环境变量只能指到本机；
  授权：没有 Key / 没问到过 / 过期都按免费版、钟差换算、往回拨不作数、开关只听服务器的；什么时候再问；
  照授权拦（`GateChecks`）：默认打开、测试开关关不掉它；每个工具在没 Key / 免费 / 体验 / 正式 / 没给 mcp 的正式下让不让、`get_status` 永远让；水印听服务器的；
  被挡住时的话（每种原因、请用户做什么、界面语言写的细节不带给 AI）；`skycut_plan`；带了水印时那一句。反向验证（2026-10-28）：规则不看授权，红 97 条。
- `checks/sky-studio-wiring.sh`（扫描，第 1 组）：地址和 URLSession 只在 `SkyStudioAPI`、环境变量只认回环地址；硬件 UUID 只在 `SkyStudioMachine` 读、`X-SkyCut-Machine` 只在 `SkyStudioAPI` 写；
  弹框的那一档读只在 `KeychainSecret.swift`、`SkyStudioAccount` 只有 `promptKeychain` 为真才弹、`promptKeychain: true` 只在设置那一节；设置窗口挂着这一节、启动时 `start()`；
  照授权拦：门在核对参数名之后、建调用排队之前；让不让、带不带水印只在 `SkyStudioAccount` 里调 `SkyCutGates`；导出面板挂着那一行；`export_video` 开始和做完都说水印；`get_status` 报 `skycut_plan`。
  反向验证（2026-10-27）：别处写 `X-SkyCut-Machine`、把后台的取法改成会弹框的 —— 各自红；（2026-10-28）拆掉路由的门、门挪到排队之后、面板不挂那一行、get_status 不报 —— 各自红；恢复后转绿。
- `checks/export-watermark-wiring.sh`：导出器拿 `exportsWithWatermark` 问 `WatermarkPolicy`、读不出 logo 时报错不导、每一处问 `WatermarkPolicy` 都传授权；`scripts/check-export-watermark.sh` 的纯值验加不加。
- `checks/product-name.sh`：钥匙串的服务名 `.skystudio`、UserDefaults 的键 `SrtFlow.skystudio.me.v1`。
- 钥匙串的真读写（`KeychainSecret`）在 `scripts/check-fal-keychain.sh`（本机手动，不在 `check-all` 里）。

## 六、人工回归（Sky Studio 的接口上线之后，发版前）

- [ ] 没有 Key 时点「去 Sky Studio 建 Key」：浏览器打开 Sky Studio 建 SkyCut Key 的那个窗口（登录后）。
- [ ] 设置 → Sky Studio 粘一把新账号的 Key：「账号」是这个账号的邮箱、「套餐」是「体验 · 还剩 7 天」（不是 8 天：回答晚到几秒，见「断网」一行）、积分对得上网站；钥匙串访问里多了「SkyCut Sky Studio API key」一条。
- [ ] 同一台 Mac 换一个新账号的 Key：「免费版」，下面一句说这台 Mac 已经体验过。
- [ ] 粘一把作废的 Key：说 Sky Studio 不认、Key 没存下；网站上作废正在用的那把，点「再查一次」：同样，存的授权清掉。
- [ ] 断网点「再查一次」：说连不上、照上一次的用到什么时候；72 小时之后（或把 `valid_until` 很近的回答存进去）变成免费版。
- [ ] 后台给账号设 `paid_until`：回到 SkyCut 超过 30 分钟或点「再查一次」后是「正式版 · 到 …」，写的就是后台选的那天（不是第二天），开通的那一句不见了。
- [ ] 「复制邮箱」之后粘出来是 support@skystudioai.com，这个邮箱收得到信。
- [ ] 删 Key：钥匙串里那一条没了，「套餐」那几行回到粘 Key 的那一行。
- [ ] 照授权拦打开（测试开关，或打开它的 PR 之后）、没有 Key：让 AI 剪一下，回「Not done」说去哪建 Key、粘到哪；`get_status` 照常回、带 `skycut_plan`。
- [ ] 粘体验账号的 Key：AI 照常剪；导出面板底栏有「会带水印」那一行、「复制邮箱」粘出来对；导出的成片带水印，AI 的 `get_job` 里有 `watermark`。
- [ ] 后台给账号开正式版、点「再查一次」：导出不带水印，面板那一行没了。
- [ ] 存的回答过期（或刚粘上 Key 还没问到）时 AI 的第一个调用：等问完再判（20 秒内回），不是一上来就挡。
