# Sky Studio 账号：Key、`/me`、此刻的授权

> 2026-10-27 引入（[收费方案](../plans/2026-10-27-paid-plans-and-sky-studio-key.md)第 5 刀第一步）。改 `Sources/SrtFlow/SkyStudio/`、`KeychainSecret.swift`、
> 设置里的「Sky Studio」一节之前必读。接口合同在 **Sky Studio 仓库**（本机 `SkyStudio_APP_Master/cursor-skystudios-app-cinematic`）的
> `docs/agents/skycut-api.md`，以那份为准（2026-10-27 定稿时是分支 `feat/skycut-api` 的 08bd908a，接口还没上线）。
> 这一步**只读授权、什么都不拦**：照着开关拦（MCP 的门、导出水印）是第二步（5b），要等 Sky Studio 的接口上线、用户给自己开了正式版再合。

## 一、规矩

| 决定 | 口径 |
| --- | --- |
| 怎么认人 | 用户在 Sky Studio 网站上建一把 `sk-` Key，粘进 SkyCut 的设置；**一把 Key 同时管授权和积分**（方案第 7 条）。App 里不做登录；浏览器里一键连接、网站上付款以后再做（2026-10-27 用户定：先做 B 端，后台手动开通） |
| Key 存哪 | 钥匙串一条通用密码：服务名 = bundle id + `.skystudio`（测试版另一条），账号 `api-key`（`SkyStudioKey`）。**身份类的名字，永远不改**（[产品名与代码名](product-name.md)；`checks/product-name.sh` 钉着） |
| 钥匙串怎么读 | 和 fal 的 Key 同一份 `KeychainSecret`（两档：`.silent` 不弹框 / `.interactive` 弹框，探针结论见 [fal.ai 生成](fal-generation.md)第六节）。**后台问 Sky Studio 从不弹授权框**：只走 `keyWithoutPrompt()`，读不到就在设置里说「要授权」，用户点了按钮才弹 |
| 粘进来的话 | 去掉 `Bearer `、引号、首尾空白；要 `sk-` 开头、只有 URL 安全的字符、至少 20 个字。**长度不写死成 46**（那边换了长度这里不该先拒） |
| 存的时候 | 存进钥匙串、马上问一次 `/me`：Sky Studio 回 `invalid_key` 就**不留着这把 Key**；没连上就先留着，之后再问。换一把 Key 时上一把问到的那份作废 |
| 机器号 | 每个请求带 `X-SkyCut-Machine` = SHA-256(硬件 UUID + 盐) 的 64 位小写十六进制（`SkyStudioMachine`）：原始的硬件 UUID 不出本机、不发电脑名。Sky Studio 按它「每台 Mac 只给一次体验」。**盐和算法永远不改**（改了每台 Mac 都成了新机器，又能体验一次）；自检钉着一组算好的值 |
| 地址 | `https://skystudioai.com/api/skycut/v1`，**只有 `SkyStudioAPI` 碰它**。自检 / 冒烟用 `SRTFLOW_SKYSTUDIO_API_BASE` 指到本机的假服务器，**只认回环地址**（Key 不会因此发到别处） |
| 此刻的授权 | 纯函数 `SkyCutLicense.evaluate`：plan、`features`（`mcp` / `watermark`）、`valid_until` 全照服务器的，SkyCut 不写死天数。**没有 Key、没问到过、过了 `valid_until` 都按免费版**（MCP 关、导出带水印）——这是「没有授权」本身的定义 |
| 断网 | 上一次的回答存在 UserDefaults（`SrtFlow.skystudio.me.v1`），照它用到 `valid_until`（服务器定：现在是 72 小时和体验 / 正式到期取早的）。服务器的钟换成本机的：`拿到回答时的本机时间 + (valid_until − server_time)`，本机的钟和服务器差多少都不影响；本机的钟比拿到回答时还早 5 分钟以上（往回拨了）就不作数 |
| 什么时候问 | `SkyStudioRefresh`：启动时、回到 SkyCut 时，上次问到超过 30 分钟才问；每小时看一眼，超过 6 小时才问；没问到过 / 过期了马上问；没问成至少隔 5 分钟再试。设置里「再查一次」随时问 |
| Key 作废了 | 后台问到 `invalid_key`：清掉存的回答（这把 Key 的授权不再作数，不等到 `valid_until`），设置里说 Sky Studio 不认、请粘一把新的 |
| 版本太老 | `upgrade_required`：设置里照服务器的话说，带下载链接（`download_url`）；存的回答照旧用到 `valid_until` |
| 体验给不了 | `/me` 回 `plan: free` + `trial_unavailable: machine_used`：设置里说「这台 Mac 已经体验过 SkyCut，这个账号在这台 Mac 上没有体验期」 |
| 联系开通 | 不是正式版时设置里有「联系开通」：打开 `/me` 的 `upgrade_url`，没有（或没有 Key）就打开 `https://skystudioai.com/skycut`（`SkyStudioLinks.upgradePage`）。**这个网址定了就别改**：老版本的 SkyCut 一直打开它。2026-10-27 定稿的合同里还没有这一页和 `upgrade_url`，已请 Sky Studio 那边补 |
| 服务器的网址 | 只认 https（本机的假服务器给的 http://127.0.0.1 也认），读不成就当没有（`SkyStudioLinks.webURL`） |
| 读回答 | 读得宽：认不出的字段不管、少了可选的不算错、日期带不带毫秒都认（Foundation 自带的 `.iso8601` 不认毫秒，JS 的 `toISOString()` 带毫秒）；少了必须的（`features`、`valid_until`）就不算回答 |
| 报错的话 | 服务器的 `message`（英文、写给人看）原样显示；没连上、回的不像话这两种是 SkyCut 自己的话，经 `L10n` 按界面语言 |

## 二、文件

| 文件 | 管什么 |
| --- | --- |
| `KeychainSecret.swift` | 一条通用密码项的存 / 读 / 删、两档读法、一次运行读一次的缓存（`KeychainSecretCache`）。fal 和 Sky Studio 共用 |
| `SkyStudio/SkyStudioKey.swift` | 钥匙串那一条叫什么、粘进来的话怎么整理 |
| `SkyStudio/SkyStudioMachine.swift` | 硬件 UUID → 机器号 |
| `SkyStudio/SkyStudioAPI.swift` | 请求（地址、四个头）、`GET /me`、错误分成三种（`SkyStudioFailure`：服务器的错 / 没连上 / 回的不像话） |
| `SkyStudio/SkyStudioMe.swift` | `/me` 的回答、怎么读怎么存、存下来的那份（`SkyStudioStoredAnswer`）、几个网页（`SkyStudioLinks`） |
| `SkyStudio/SkyCutLicense.swift` | 此刻的授权（纯）、什么时候再问（`SkyStudioRefresh`，纯） |
| `SkyStudio/SkyStudioAccount.swift` | 存 / 删 Key、问 `/me`、存回答、启动 / 回到 SkyCut / 每小时看一眼（`@MainActor` 的小对象，只有设置那一节订阅） |
| `SkyStudio/SkyStudioSettingsSection.swift` | 设置里的「Sky Studio」一节 |

## 三、还没做的

- **第 5 刀第二步（5b）**：`WatermarkPolicy.mark()` 改问 `SkyCutLicense` 的 `watermark`（logo 读不出要拦住导出，[导出水印](export-watermark.md)第二节）；MCP 的门挡在 App 收工具调用的地方（`AIToolRouter.handle`，`get_status` 照常回、报授权）；
  导出面板「会带水印 · 联系开通」；`export_video` 的结果里告诉 AI 带了水印、为什么。冒烟时没有真服务器，用 `SRTFLOW_SKYSTUDIO_API_BASE` 指到本机假服务器给一个正式版。
  **等 Sky Studio 的接口上线、用户给自己开了正式版再合**：不然之后打的包里用户自己的 AI 剪辑也被挡住。
- 第 6 刀（生成、upscale、克隆改走 Sky Studio 的 `/quote`、`/uploads`、`/jobs`）、第 7 刀（删掉 fal 那条路）。定稿里和 SkyCut 现在做法不一样的地方记在收费方案「Sky Studio 定稿之后」一节。

## 四、已知能绕过去的（不防）

- 改 UserDefaults 里存的回答（把 `valid_until` 改到很久以后）、仓库公开期间自己编一份去掉判断（收费方案第 3 条）。真正收得住的是服务器那一侧：积分、体验按账号和机器记。

## 五、守卫

- `scripts/check-sky-studio.sh`（`check-all.sh` 第 2 组，不碰网络、不碰钥匙串）：Key 的整理和钥匙串那一条的名字；机器号钉死一组值、这台 Mac 读得到、发出去的不是原样的 UUID；
  `/me` 照合同里的样例逐字段读、带毫秒的日期、读得宽、少了必须的不算回答、网址只认 https 和本机、存了读回来一样、服务器时间换本机时间；
  假 URLSession 上看 `/me` 的地址、方法、四个头，401 / 426 / 429 留着 code 和附加字段，502 的网页 / 2xx 读不成 / 断网各是哪一种，环境变量只能指到本机；
  授权：没有 Key / 没问到过 / 过期都按免费版、钟差换算、往回拨不作数、开关只听服务器的；什么时候再问。
- `checks/sky-studio-wiring.sh`（扫描，第 1 组）：地址和 URLSession 只在 `SkyStudioAPI`、环境变量只认回环地址；硬件 UUID 只在 `SkyStudioMachine` 读、`X-SkyCut-Machine` 只在 `SkyStudioAPI` 写；
  弹框的那一档读只在 `KeychainSecret.swift`、`SkyStudioAccount` 只有 `promptKeychain` 为真才弹、`promptKeychain: true` 只在设置那一节；设置窗口挂着这一节、启动时 `start()`。
  反向验证（2026-10-27）：别处写 `X-SkyCut-Machine`、把后台的取法改成会弹框的 —— 各自红；恢复后转绿。
- `checks/product-name.sh`：钥匙串的服务名 `.skystudio`、UserDefaults 的键 `SrtFlow.skystudio.me.v1`。
- 钥匙串的真读写（`KeychainSecret`）在 `scripts/check-fal-keychain.sh`（本机手动，不在 `check-all` 里）。

## 六、人工回归（Sky Studio 的接口上线之后，发版前）

- [ ] 设置 → Sky Studio 粘一把新账号的 Key：「账号」是这个账号的邮箱、「套餐」是「体验 · 还剩 7 天」、积分对得上网站；钥匙串访问里多了「SkyCut Sky Studio API key」一条。
- [ ] 同一台 Mac 换一个新账号的 Key：「免费版」，下面一句说这台 Mac 已经体验过。
- [ ] 粘一把作废的 Key：说 Sky Studio 不认、Key 没存下；网站上作废正在用的那把，点「再查一次」：同样，存的授权清掉。
- [ ] 断网点「再查一次」：说连不上、照上一次的用到什么时候；72 小时之后（或把 `valid_until` 很近的回答存进去）变成免费版。
- [ ] 后台给账号设 `paid_until`：回到 SkyCut 超过 30 分钟或点「再查一次」后是「正式版 · 到 …」，「联系开通」不见了。
- [ ] 「联系开通」打开的那一页存在、没登录也能看。
- [ ] 删 Key：钥匙串里那一条没了，「套餐」那几行回到粘 Key 的那一行。
