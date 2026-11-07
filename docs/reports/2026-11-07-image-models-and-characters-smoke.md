# 2026-11-07 SkyCut 0.18.62：全部图片模型与角色系统的真积分验收

## 当前结论

用户 2026-11-07 授权：「允许你消耗积分做真实的 smoke test」。验收对象是本机正式版 **0.18.62**，与公开下载的 DMG 是同一构建，见[构建与打包](../build/build-and-packaging.md)「公开下载发布」。

方式：照 AI 客户端的做法，起 App 包里的 `skycut-mcp` 逐项调用，工程放在后台模式，Sky Studio 用真服务器、真积分。

结果：
- 以下操作全部成功，实际扣费与 SkyCut 本机账一致，共 **208 积分**：
  - 四个新接入的图片模型；
  - 图片换角度；
  - 角色的读、建、改名、重做头像、删除；
  - 带角色生成图片和视频。
- **图片放大失败**，8 积分全额退回。原因在服务器：Sky Studio 调用的 Google `imagen-4.0-upscale-preview` 已下线，返回 404。
  - 网页端同样坏了：网页端最后一次成功是 2026-07-20，之后这是第一次调用。
  - 当天 Sky Studio PR #243 改用 fal 的 SeedVR2 并受控发布，补测 x2 / x3 两次都成功（共 16 积分），见末节「图片放大修好之后补测」。
  - 当日总花费 224 积分。

客户端发现两件事，都不阻塞这次发版，见下文「发现」：
1. 每个新构建第一次读 Key 会弹钥匙串密码框，AI 调用一直等在框后面。
2. `list_characters` 一页太大。

## 真实任务

时间均为 2026-11-07 UTC（北京时间 +8）。

图片模型：

| 操作 | 模型 | Sky Studio 任务号 | 扣费 | 结果 |
| --- | --- | --- | ---: | --- |
| 文生图 | `nano2-lite` 1K | `482646e6-08ab-4be9-9a2f-10759de79b95` | 20 | JPEG 1376×768，存成 `.jpg`（[#334](https://github.com/skysf/SkyCut/pull/334) 按实际字节定扩展名） |
| 文生图 | `nano-banana-pro` 1K | `361a62e0-2054-4809-8fe4-073918e1dc63` | 32 | PNG 1376×768 |
| 文生图 | `gpt-image-2` 1K | `165f568b-25e7-47e1-9c58-291ed7da2454` | 32 | PNG 1088×608，画面里的「SKYCUT TEST」字样正确 |
| 文生图 | `seedream5-pro` 2K | `eb910f4b-238c-4a36-8d47-0ce4154f1771` | 25 | PNG 2848×1600 |
| 换角度 | `qwen-angles` 1K，rotate 45 | `261127d5-a279-490c-aab9-8d58509902bb` | 8 | PNG 1376×768，同一座小屋往右转 45°。在 fal 排队约 4 分钟，全程 289 秒，目录写的典型时长是 60 秒 |
| 图片放大 | `image-upscale` x2，源 1376×768 | `d78f3557-5e5f-4dae-9fde-ef411477b607` | 0（8 已退） | `provider_error`，服务器记录 `Vertex AI upscale failed: 404` |

角色：

| 操作 | 模型 | Sky Studio 任务号 | 扣费 | 结果 |
| --- | --- | --- | ---: | --- |
| 建角色（文字） | `seedream5-flash` 2K | `4bdde66b-5a5e-424a-a8a9-fb8faf058033` | 8 | 正面、侧面、背面、头像四张一致，服务器起名、写了声音描述 |
| 带角色生成图片 | `nano2` 1K | `ff97065a-eeb7-4e41-a569-df32f6d5ca08` | 25 | 服务器选了四个视图，revision 对得上；人物和角色一致 |
| 带角色生成视频 | `minimax-h3` 多模态 480p 5 秒 | `1fbe3c3d-12c9-4929-aace-44a64e71043e` | 50 | 832×480、24 fps、5.18 秒，H.264 + AAC；抽帧人物和角色一致 |
| 改名 | — | — | 0 | 名字换了，revision 不变 |
| 重做头像 | `seedream5-flash` 2K | `75aa781e-4d4e-4c65-b1da-e532b467159c` | 8 | 头像换了，revision 从 `a9132b…` 变成 `a3145c…` |
| 用旧 revision 提交 | `nano2` 1K | — | 0 | 本机直接拒绝 `character_changed`，什么都没送出 |
| 删除 | — | — | 0 | 先回确认码，确认后删掉；再读回 `not_found` |

审批与账：
- 付费确认照 AI 权限走，模式是「请求批准」。
  - 超过草稿默认价的模型和角色的付费操作，先回 `needs_confirmation`，用户授权后带确认码再交。
  - 草稿价以内的直接开始。
- `get_status` 报当日 `spent_today_credits` 208，和逐项实收相加一样；退回的 8 没有记进去。
- `list_characters` 免费读到账号里已有的 28 个角色；`capabilities=true` 读到原生角色的五个模型和价格。

## 发现

### 1. 每个新构建第一次读 Key 弹钥匙串密码框，AI 调用一直等在框后面

现象：
- 装上 0.18.62 后，SkyCut 一启动，系统就弹出钥匙串框，要求输入登录密码；
- 测试会话的第一个 `generate_media`（nano2-lite）120 秒拿不到回答；
- 一直等到用户输完密码（约 3 小时后），这一单才交出去，从交出到完成只用了 28 秒。

账号授权和别的不碰 Key 的工具照常回答。

查到的事实：
- 用 `security dump-keychain -a` 只看属性和访问表，不读密钥，`com.srtflow.SrtFlow.skystudio` 这一条：
  - 解密那一项信任 `/Applications/SkyCut.app`，条件是 `identifier "com.srtflow.SrtFlow" and certificate leaf = H"76d2…"`，每个构建都满足；
  - 但 `partition_id` 那一项列的是 `cdhash:08da45e5…`、`cdhash:0d75ed2c…`，是两个旧构建的代码哈希；
  - 0.18.62 的 CDHash 是 `c5c3568e…`，不在里面。
- `codesign -dvvv` 报 `TeamIdentifier=not set`。没有 Team ID 的 App，钥匙串的分区名单只能按代码哈希记，所以每个新构建第一次读都要用户输密码。
  - 点「始终允许」会把这一构建加进名单；
  - 只点「允许」，下次启动还会再问。
  - 用户这次输完密码后名单里仍没有 0.18.62，下次启动还会问。
- [签名与系统权限](../architecture/code-signing-and-permissions.md)原来写「同一把证书签的下一个构建读前一个构建建的项不弹」。这对 TCC 成立，对钥匙串不成立，已在该文档更正。
- 按[Sky Studio 账号](../architecture/sky-studio-account.md)的设计：
  - 后台问 `/me` 只用不弹框的那一档（`kSecUseAuthenticationUIFail`）；
  - AI 起的活也只用 `.silent`；
  - 读不到应当立刻回「要在设置里点允许」，而不是等。
- 这次弹框正好出在启动时，那时只有后台问 `/me` 读 Key；AI 的读在同一个 `KeychainSecretCache` actor 后面排队。所以很可能这一档拦不住分区名单的密码框，actor 被卡住，后面的读全部跟着等。
  - 这条是推断，还没有用独立探针证实。

影响：只有本机一位用户，每次发新版输一次密码（选「始终允许」）就好，不阻塞这次发版。

要做的（另开 PR）：
- 不弹框的那一档要真不弹：例如读之前关掉本进程的钥匙串交互。
- 给读加时限，让 AI 调用不会无限期等着。
- 用新构建实测。
- 长远看，用 Developer ID 签名后分区名单按 Team ID 记，升级不再问。不过这要用户决定是否加入 Apple 开发者计划，公开分发要过 Gatekeeper 也需要它。

### 2. `list_characters` 一页约 80 KB

默认 `limit=50`，每个角色带四个视图的完整资产地址和缩略图地址。28 个角色的回答约 8 万字，接近或超过 AI 客户端单个工具结果的上限，例如 Claude Code 默认约 2.5 万 token。

挑角色只需要 id、名字、状态、revision 和有哪些视图，资产地址可以留给 `get_character`。另开 PR 改成精简列表。

### 3. 小毛病（不影响结果）

- 换角度、放大的成品没有提示词，文件名落成 `Image.png`。可以改成按源文件名起名。
- 完成之后，`get_job` 的 `phase` 还留着最后一个进行中的阶段（`queued` / `processing`）。
- 角色任务正常完成时，`message` 写的是 `Original Character recovered; …`，读起来像是重启后找回的。

## 产物与边界

- 测试工程在会话的临时目录，后台模式，没有窗口；成品文件只留在本机临时目录，不进仓库。
- 测试角色是这次建的，验收结束已删除。没有碰账号里原有的 28 个角色。
- 测试版 0.18.62（`com.srtflow.SrtFlow.beta`）的钥匙串里没有 Sky Studio Key，所以付费操作只在正式版上验。

## 图片放大修好之后补测

修复：
- [Sky Studio PR #243](https://github.com/skysf/skystudio-aigc-app/pull/243)（合并提交 `f9a353b3`）把图片放大从 Vertex Imagen 换成 fal SeedVR2（`fal-ai/seedvr/upscale/image`）。
  - 一次付费提交，之后只查原单；
  - 只有服务商明确失败才退款；
  - 按解码出来的真实宽高报尺寸。
- 对外 id、显示名、x2 / x3 / x4 和 8 积分都不变，SkyCut 客户端不用改。

发布（用户 2026-11-07 回复「可以发布」后）：
1. 发布前检查：候选部署 `dpl_DBbqNKJy7JEM2urkPxXG2CSrpuHw` 就绪，6 个正式域名都还在上一版。
2. 打开发布开关、重跑合并提交的 Playwright。
3. 受控发布 run `42372345825` 成功，6 个域名都换到候选部署。
4. 开关随即改回 false。

用同一个正式版 0.18.62、真积分补测：

| 操作 | 源 | Sky Studio 任务号 | 扣费 | 结果 |
| --- | --- | --- | ---: | --- |
| 放大 x2 | JPEG 1376×768（nano2-lite 的成品） | `db1434cf-ddfa-4c50-ae8c-a217dfc05e8b` | 8 | PNG 2752×1536 |
| 放大 x3 | PNG 1088×608（gpt-image-2 的成品） | `7907a405-cb28-4e95-a1d2-2b4fce515c32` | 8 | PNG 3264×1824 |

- 耗时：服务器上从提交到完成约 30 秒；SkyCut 这边 `get_job` 报 56 / 62 秒，含它自己的查询间隔。
- 画质：同一块区域并排看，细节明显更清楚，画面内容没有被改。
- 尺寸：这两张都正好是源 × 倍数。SeedVR2 会把不对齐的尺寸往上取整，例如 Codex 实测 412×412 放大 x2 得到 832×832；服务器按真实文件报尺寸。
- 网页端：网页的放大接口同步等 45 秒，超过就先回「还在处理」，成品由图片队列补进作品库。这两次约 30 秒，在窗口内；接近 1650 万像素上限的大图可能会超。
