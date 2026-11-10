# MCP 说明书：skycut_guide

> 已生效的长期约束（2026-11-10 起）。为什么这样设计、每条拍板和迁移的七个 PR 见
> [MCP 按需说明方案](../plans/2026-11-09-mcp-guide.md)（第八节 8 条用户已定，推翻哪一条之前先读它）。
> AI 接口总的规矩见 [AI 接口（MCP）](ai-control-mcp.md)，这里只写说明书自己的合同。

## 一、是什么、为什么

`skycut_guide` 是一个只读、免费、马上回、不碰工程的工具：不带 `topic` 回一份目录，`topic=<工具名>` 回那个工具的说明书，
长的主题分节取。它是「名片常驻、说明书按需读」里按需读的那一半：

- **Claude Code**（默认开工具搜索）每轮常驻的只有总说明和工具名，某个工具的完整定义用到才加载；
  2.1.296 起总说明和预先加载的工具说明截在 4,096 字、按需加载的截在 16,384 字（[官方文档](https://code.claude.com/docs/en/mcp)
  「Tool search for MCP server authors」，2,048 是更早的版本）。
- **Codex**（0.147 起、GPT-5.6 以后的模型走代码模式）里 SkyCut 的工具不在初始提示里，模型在 `exec` 里筛 `ALL_TOOLS`、把条目打印出来才看得到；
  **每个条目都背一份整份总说明**，参数定义超过 5,000 字节时参数说明被全部删掉、也不显示 minimum / maximum（方案 1.3、1.4）。
- 所以长的「怎么用好」放进说明书：用到才读、一次读一节；会调错、花错钱、删错东西的规矩仍写在名片和结果里、由服务器挡（方案第三节）。

## 二、做到哪

迁移分七个 PR（方案 7.1）。每个 PR 合了没有、实测的数字、过程中的偏差和本机跑检查时遇到的事，记在
[MCP 按需说明的实施报告](../reports/2026-11-10-mcp-guide-progress.md)；这里只写已经生效的合同。

## 三、合同（只能这样做）

1. **App 来答**（`Sources/SrtFlow/AIGuideTools.swift`），照 `recipes` 的路子：路由的 Policy 和 `recipes` 同一行 —— 不排队、不摆窗口、
   不算这一轮。说明永远和正在跑的 App 一致。内容和挑法在库里（`SrtFlowMCPKit`），App 只转一手。
2. **没开通也照答**，和 `get_status` 一样（`SkyCutGates.alwaysAnswered = [.getStatus, .skycutGuide]`，方案第八节第 5 条）：
   没开通时 AI 也能把 SkyCut 能做什么说清楚。所以说明书里**不许有凭据、账号信息、私有配方**（同 `MCPProductionSchema` 注释的约定；
   守卫查 `sk-` 的 Key、邮箱、http(s) 链接、Bearer）。**连授权都不等**（`SkyCutGates.answeredBeforeLicenseCheck`）：说明书的回答不看授权，
   路由的门在等授权问完（读钥匙串、问 `/me`，最长 20 秒）**之前**就放行它；`get_status` 照旧等，它报的 `skycut_plan` 就是问完的授权
   （[案例](../bugfixes/2026-11-10-guide-waits-for-license.md)）。
3. **在清单里**：排**第一个**（按清单顺序展示的客户端最先看到；顺序稳定，有利于提示缓存）；只读、不删、不联网；**不收 `project`**；
   条目带 `_meta: {"anthropic/alwaysLoad": true}` —— Claude Code 把它预先加载、省掉一次工具搜索（官方：这个标记适合「每轮都要的少数工具」，
   **只有它带**，守卫钉着；预先加载的工具说明截在 4,096，名片远在其内）。Codex 不认这个键，不碍事。名片 ≤ 450（UTF-16）。
4. **内容放哪**：`SrtFlowMCPKit` 里的 Swift 常量（`MCPGuideTopics`；以后手写的节按工具组分文件、每个 ≤ 400 行）。不用 `Bundle.module`
   （打好的 App 里没有那个 bundle，第四节第 32 条）。**只写英文、不另留中文稿**（方案第八节第 7 条）：中文的规矩以 `docs/architecture/` 为准，
   每节在代码注释里写出处。
5. **主题**：每个工具一个同名主题，第一节叫 `overview`。PR 1 的概要从工具定义**现取**（不另抄一份：抄的会漂），`fields` 一节从参数定义
   **现算**（`MCPGuideFields`）—— Codex 删掉的参数说明和不显示的范围在这里读得到。**参数定义里有的事实一样都不许漏**（名片承诺了）：名字、
   类型（含 `["string","null"]` 这种并集、`anyOf` / `oneOf` 的每一种写法和它自己的可选值）、必填、可选的值（任何类型：数字的也写）、范围写成数字、
   条数和长度的上下限、能不能带别的字段、说明，里层（对象、数组里的对象、`anyOf` 里的对象）往里缩进（[案例](../bugfixes/2026-11-10-guide-fields-drop-schema-facts.md)）。
   以后的 PR 改短名片之前，**先把说明原样搬进主题**（一个字不丢），再写名片；手写的节里提到的工具名、参数名、选项值必须真的存在。
6. **一次回多少**（量整份结果的 JSON 文字，UTF-16 —— App 原样写成一段文字交给客户端，模型读的就是它）：目录 ≤ 5,000；
   一个主题第一次回的、每一节 ≤ 6,000（方案定的硬限 8,000；守卫按 6,000 查，写超了就拆节）。放得下整份回（第一节不加标题，其余加
   「## 名字」）；放不下先回 `overview` + 有哪些节 + `next_step`，再按 `section` 取。
7. **写错了**：`topic` 写错回目录 + `unknown_topic` + `did_you_mean`（包含关系优先、再按编辑距离 ≤ 2，最多 3 个），不报错；`section` 写错回第一次的样子
   + `unknown_section`；只给 `section` 不给 `topic` 回目录 + `section_without_topic` + `next_step`（说清楚要一起给，不悄悄回目录）。
   名字不计较大小写、连字符、空格（`Edit-Clip` = `edit_clip`）。
8. **回的样子**：主题 `{topic, sections, section, text, examples, related, next_step}`，空的不写；目录 `{text}`（写错时加 `unknown_topic` / `did_you_mean`，
   只给 section 时加 `section_without_topic` / `next_step`）。
9. **例子和相关主题**：例子只许挂在工具主题上、必须过那个工具的参数定义（参数名过 `MCPArgumentCheck`、值过类型 / 可选值 / 范围 / 条数）；
   `related` 里的名字必须是真主题。

## 四、守卫

- `checks/MCP/GuideChecks.swift`（跟着 `scripts/check-mcp.sh` 跑）：清单里第一个、只读不删不联网、不收 `project`、只有它带 `alwaysLoad`、名片 ≤ 450；
  每个工具一个同名主题、目录里每个工具有**自己那一行**（行首「- 名字:」，别处顺带提到不算）、目录 ≤ 5,000、每个主题第一次回的和每一节 ≤ 6,000；
  PR 1 的概要就是现在的说明原文、第一层的每个参数有**自己那一行**（按路径认，里层同名的不算）；手造的长主题先回概要 + 有哪些节、按 section 取、
  写错的 section 回第一次的样子；名字的写法不计较、写错的 topic 回目录 + 猜的、只给 section 说清楚；手写的文字只提真有的名字（和剪辑风格卡共用
  `checks/MCP/CatalogNames.swift`，拿写错名字的样本证明它真会红）；回的每一样都只用英文；App 那一头（`AIGuideTools`）照答、参数名核对收
  `topic` / `section`、挡别的名字。末尾打印目录和最大的一次回答各多少字。
- `checks/MCP/GuideContentChecks.swift`：自己走一遍真实清单，每个参数的每一样事实（可选的值、范围、条数、长度、类型并集、`anyOf` 的写法、能不能带别的字段）
  都在它自己那一行，走空了算红；例子过参数定义、只挂在工具主题上，`related` 是真主题，不含 Key / 邮箱 / 链接 / Bearer —— 每条都拿手造的坏样本证明真会红。
- `checks/MCP/router-wiring.sh`（扫描）：`skycut_guide` 交给 `AIGuideTools`，和 `recipes` 同一行 Policy、三个都是 false。
- `checks/SkyStudio/GateChecks.swift`（`scripts/check-sky-studio.sh`）：`alwaysAnswered` 正好是 `get_status` 和 `skycut_guide`，没 Key / 免费版时只有这两个让用；
  `answeredBeforeLicenseCheck` 正好是 `skycut_guide`、是 `alwaysAnswered` 的子集；`ProNoticeChecks` 同一口径。
- `checks/sky-studio-wiring.sh` 第 5 节：`aiRefusal` 放行 `answeredBeforeLicenseCheck` 的那一句在 `await settledLicense(` 之前。
- `checks/MCP/CatalogTextChecks.swift`：总说明点到 `skycut_guide`（「目录里有清单的每个工具名」，PR 2 起改查说明书的地图）。

**反向验证（2026-11-10，PR 1）**：每条单独临时弄坏、跑真的守卫、确认变红、再恢复（恢复后工作区和提交逐字节一致）。

| 临时弄坏 | 红了 |
| --- | --- |
| 目录生成时漏掉 `seek` | GuideChecks 2 条：目录里没有 seek；写错 topic 时回的目录里也没有 |
| `topic(named:)` 认不出 `look` | GuideChecks 2 条：look 没有主题；App 那一头答不出 look |
| 关掉分节（太长也整份回） | GuideChecks 5 条：手造的长主题第一次回的不是概要、带了整份、没有 next_step、写错的 section 没退回概要；next_step 的文字也没了 |
| 名片加长到 467 字 | GuideChecks 1 条：名片超过 450 |
| 去掉 `_meta` | GuideChecks 2 条：没有 alwaysLoad；「只有它预先加载」变成一个都没有 |
| 目录开头写进汉字 | GuideChecks 1 条：只用英文 |
| 概要改掉一个词（`get_timeline` → `the timeline`） | GuideChecks 6 条：说明里有 get_timeline 的六个工具，概要不再是原文 |
| 猜名字的函数什么都不回 | GuideChecks 2 条：写错的 topic 没有 did_you_mean；「clip」猜不出带 clip 的 |
| 总说明里去掉 `skycut_guide` | CatalogTextChecks 2 条：没配 / 配了提供方两种样子的目录都缺 skycut_guide |
| Policy 把 `.skycutGuide` 挪到排队的那一行 | router-wiring：`check-mcp.sh --scans-only` 退出非 0，报「must share recipes' Policy row」 |
| `alwaysAnswered` 去掉 `skycut_guide` | 19 条：GateChecks 3 条（集合不对、没 Key、免费版）+ ProNoticeChecks 16 条（续约提醒的各种组合） |

**反向验证（2026-11-10，审查 review-344 之后的修正）**：同样每条单独弄坏、跑真的守卫、恢复后工作区和提交一致。

| 临时弄坏 | 红了 |
| --- | --- |
| fields 只写字符串的可选值（修复前那样） | 6 条：`camera_angle` 的三个档位、`optimized_media_cache_gb`，外加点名的两处 |
| fields 不认类型并集和 anyOf（修复前那样，写成 any） | 8 条：`production`、`seam_review.previous` / `next`、`duration` 的三种写法，外加点名的两处 |
| fields 不写条数的上下限（修复前那样） | 12 条：三个批量工具的 1 到 100 项、`clips` / `ids` / `lines` / `paragraphs` 至少 1 项…… |
| 目录漏掉 `edit_clip` 那一行（批量工具的标题里还提到它） | 1 条：目录里没有 edit_clip 自己那一行（以前按整词找会照样过） |
| fields 漏掉第一层的 `x`（里层还有同名的） | 7 条：edit_clip / set_text / set_shape 各两条，外加「走到的事实不到 250 条」 |
| 长主题的 next_step 里写一个不存在的参数名 | 1 条：措辞检查挑出 `clip_end_ms` |
| `answerLimit` 降到 4,900 | 2 条：generate_media、edit_clip 的 fields 一节超长（真实主题的大小检查管用） |
| 跳过例子的核对 | 3 条：坏样本（不存在的参数、选项外的值、挂在非工具主题上）没被挑出来 |
| 跳过 related 的核对 | 1 条：坏样本里的 no_such_topic 没被挑出来 |
| 去掉凭据的匹配 | 4 条：`sk-` Key、邮箱、链接、Bearer 的坏样本都没被挑出来 |
| 只给 section 时悄悄回目录（修复前那样） | 3 条：没有 section_without_topic、没有 next_step |
| 放行说明书挪到等授权之后（修复前那样） | `checks/sky-studio-wiring.sh` 红（放行在第 5 行、等待在第 4 行） |
| `answeredBeforeLicenseCheck` 改成空 | GateChecks 1 条 |

## 五、人工回归（发版前在真机上走一遍）

- [ ] Claude Code（2.1.296 以后）连测试版、新会话：不经工具搜索就能调 `skycut_guide`（问它 skycut_guide 说明的第一句；或看 `/mcp` 里 skycut 的工具）。
- [ ] Codex：`ALL_TOOLS` 里找得到 `skycut_guide`；调 `topic=edit_clip` 看得到 `fields`（它自己的 `edit_clip` 条目里参数说明被删光）。
- [ ] 没 Key / 免费版：`skycut_guide` 照答，别的工具（`get_status` 除外）回「Not done」。
