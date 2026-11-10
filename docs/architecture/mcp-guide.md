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
5. **主题**：每个工具一个同名主题，第一节叫 `overview`。没迁移的工具，概要从工具定义**现取**（不另抄一份：抄的会漂；迁移过的见第 14 条），`fields` 一节从参数定义
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
10. **地图**（不带 topic 回的那一页，`MCPGuideMap`，2026-11-10 起）：手写、按任务分组、带用户会说的词（9:16、配乐、口头禅、马赛克……）；第一行列出五个通用主题；
    **清单里每个工具都要作为一项列在地图上**（`组名: 工具 (说明), 工具 (说明)`，括号里顺带提到的不算）；≤ 5,000。新加工具时在合适的那一行加上它。
    工具目录 2026-11-09 用户定从总说明搬到这里（方案第八节第 1 条）：Codex 每打印一个工具条目就带一份整份总说明。
11. **五个通用主题**（`MCPGuideSharedTopics`）：rules（每个工具共守的规矩和要 AI 自己守的）、conventions（时间、轨道、id、位置大小、文件、范围、联动和磁吸）、
    paid（Sky Studio 积分：哪些工具、报价、什么时候要点头、每日硬上限、任务）、workflows（常见的活从头到尾）、errors（报错是什么意思、下一步）。
    手写、只用英文，每一段的出处写在代码注释里；名字不和工具撞；提到的名字必须真的存在（工具名、参数名、清单里的选项值、几个结果字段）。
12. **总说明**（`MCPInstructions`）≤ 1,200：入口 + 主动规矩 + 什么时候先读说明书，前 512 字点到 `skycut_guide`（[AI 接口](ai-control-mcp.md)第一节第 6 条）。
13. **报错指路**（方案 3.3）：参数名写错的那句末尾 `Fields: skycut_guide topic=<工具名>.`（`MCPArgumentCheck`）；别的工具报错只在路由 catch `AIToolError`
    那一处统一加 `Guide: skycut_guide topic=<工具名>.`（结构化的报错多一个 `guide` 字段），抛出的地方一个都不改、别处也不许自己再加一份；
    被授权挡住的那句末尾说「说明书照常能用」（`SkyCutGates.aiRefusal`）。
14. **迁移过的工具**（`MCPGuideWrittenTopics.migrated`；2026-11-10 试点 5 个：`edit_clip`、`generate_media`、`set_text`、`add_clips`、`look`，
    同一天 `add_voiceover` 随声音 PR 3 加进来（`MCPGuideVoiceTopics`）、新工具 `list_voices` / `manage_voices` 随声音 PR 6 从第一天起就这么写
    （`MCPGuideVoiceLibraryTopics`），之后两批加在同一张表里，方案 5.3）：
    - **名片 ≤ 450**（目标 350）：第一句说做什么、别的活指到哪个工具；按工具性质写**固定说法**（方案 2.2 第 4、5 条）：只读的 `Read-only`、
      改工程的 `One undo step`、回任务号的 `wait with get_job`、花积分的 `Paid (Sky Studio credits)` + `quote_only`（收它的工具才写：`add_voiceover`
      不收，整段报价在回任务号之前自动做）+ `daily credit limit`、收 `confirm_token` 的 `needs_confirmation`、要先读说明书的最后一句
      `skycut_guide topic=<工具名>`（试点里是 edit_clip、generate_media、look，加上 add_voiceover）。
      会调错、花错钱的话留在名片（方案 5.2 的「名片必含」，各检查照旧查说明）；怎么用好的进说明书（「说明书必含」，检查改查那个主题）。
    - **参数说明 ≤ 120**（目标 80）；带 `minimum` / `maximum` 的说明里写数字（Codex 不显示范围）。删掉的长话必须写进手写的那几节，
      每个迁移 PR 的说明里有「删了哪些句子、去了哪」的表。
    - **单个工具的参数定义 ≤ 4,500 UTF-8 字节**（Codex 超过 5,000 就删光参数说明），例外只有 `edit_clip`、`generate_media`（名单写死、不许变长；
      这两个的参数说明到 PR 7 才保得住，在那之前靠说明书的 `fields`）。
    - **主题**：`overview` = **迁移前的说明原文**（一个字不丢；守卫钉着它的长度，PR 里另有逐字比对的记录）+ 一段新话；后面是手写的几节
      （用法、限制、坑，出处写在代码注释里：`ai-control-mcp.md` 第几条、哪个案例）、例子（过参数定义）、`related`；`fields` 几节自动接在最后。
    - **唯一的例外：没有可搬的原文**（`previousCard` 为 nil）。工具的行为和迁移在同一个 PR 里改了，旧说明照抄进概要等于叫 AI 用已经没有的东西：
      `add_voiceover`（声音方案 4.10 说旧说明过时；4.2–4.4、第十二节：默认 gemini:Charon、去掉 `clone_from`、不再收不带前缀的 Rachel）；
      还有从第一天起就按名片 + 说明书写的新工具（声音 PR 6 的 `list_voices`、`manage_voices`，本来就没有旧说明）。
      它的概要按新行为写，旧说明每一句去了哪写在那个 PR（#355）的说明里；名单写死在 `GuidePilotChecks`（`pilotToolsWithoutPreviousCard`），加一个要改那里。
      分节照声音方案 4.10：voices / models_languages / paid_confirmation / subtitles / batches_recovery / local_voices / pitfalls（合起来超过 6,000，
      第一次只回概要 + 有哪些节）。
15. **`fields` 自动切节**（2026-11-10 定，审查 review-344 第 5 条）：`MCPGuideFields.sections(for:)` 放得下就一节 `fields`；超过 4,500 字
    （留出 6,000 里 JSON 外壳和标题的余量）按**整个第一层参数**切成 `fields`、`fields_2`、`fields_3`……；一个参数连同它的里层不拆开，
    它自己就超过的单独成一节；切完一行不丢、顺序不变。不手工拆：这几节是从参数定义现算的，哪个参数定义一变长，手工拆好的一节就会超。
    现在只有 `generate_media` 切成两节（整份 4,771 字）。

## 四、守卫

- `checks/MCP/GuideChecks.swift`（跟着 `scripts/check-mcp.sh` 跑）：清单里第一个、只读不删不联网、不收 `project`、只有它带 `alwaysLoad`、名片 ≤ 450；
  每个工具一个同名主题、目录里每个工具有**自己那一行**（行首「- 名字:」，别处顺带提到不算）、目录 ≤ 5,000、每个主题第一次回的和每一节 ≤ 6,000；
  没迁移的工具的概要就是现在的说明原文、第一层的每个参数有**自己那一行**（按路径认，里层同名的不算）；手造的长主题先回概要 + 有哪些节、按 section 取、
  写错的 section 回第一次的样子；名字的写法不计较、写错的 topic 回目录 + 猜的、只给 section 说清楚；手写的文字只提真有的名字（和剪辑风格卡共用
  `checks/MCP/CatalogNames.swift`，拿写错名字的样本证明它真会红）；回的每一样都只用英文；App 那一头（`AIGuideTools`）照答、参数名核对收
  `topic` / `section`、挡别的名字。末尾打印目录和最大的一次回答各多少字。
- 地图（`GuideChecks`）：每个工具作为一项列在地图上（去掉括号里的说明、按逗号 / 分号 / 斜杠切开认）、第一行列出五个通用主题、≤ 5,000；
  五个通用主题都在、不空、≤ 6,000、名字不和工具撞、按名字找得到、写错了猜得到（`rule` → `rules`）；地图和通用主题里提到的名字都真的存在。
- `checks/MCP/CatalogTextChecks.swift`：总说明 ≤ 1,200、前 512 字点到 open_folder / get_timeline / look / export_video / skycut_guide；
  `ProtocolChecks` / `ProviderChecks` / `SoundEffectChecks` / `UpscaleToolChecks`：原来要求写在总说明目录里的（不用工程的文件工具、智能剪、`save_recipe`、
  `add_voiceover`、花积分的那一行、`add_clips sound_effect`）改查地图，要 AI 主动做的（只用 SkyCut、`find_audio`、剪整片先挑剪辑风格）还查总说明。
- 报错指路：`ArgumentCheckChecks`（参数名写错的那句指到 `skycut_guide topic=<工具名>`）、`checks/MCP/router-wiring.sh`（路由 catch 那一处用
  `error.result(guide: call.tool)`，别处不许自己调 `result(guide:)`）、`GateChecks`（被挡住的那句以「skycut_guide (the manual) still answers.」结尾）。
- `checks/MCP/GuideContentChecks.swift`：自己走一遍真实清单，每个参数的每一样事实（可选的值、范围、条数、长度、类型并集、`anyOf` 的写法、能不能带别的字段）
  都在它自己那一行，走空了算红；例子过参数定义、只挂在工具主题上，`related` 是真主题，不含 Key / 邮箱 / 链接 / Bearer —— 每条都拿手造的坏样本证明真会红。
- `checks/MCP/GuidePilotChecks.swift`（迁移过的工具，第 14、15 条）：名片 ≤ 450 和按性质该写的固定说法（只读的、收 `confirm_token` 的从参数定义认，
  别的写在检查里）；每条参数说明 ≤ 120、带范围的写数字；参数定义 ≤ 4,500 字节、例外名单正好是 edit_clip 和 generate_media；概要以迁移前的原文开头、
  原文的长度对得上、名片真的改写过；手写的几节不空、只提真有的名字（结果字段名记在 `CatalogNames.swift`）、有例子和相关主题；
  `fields` 几节：真实清单里每个工具切完一行不丢、顺序不变、名字依次、超上限的只许是单独一个参数，再拿手造的大参数定义证明真会切。末尾打印每张迁移过的名片各多少字、哪些工具切了几节。
  没有可搬的原文的名单正好是 add_voiceover、list_voices、manage_voices（拿概要真没以原文开头的工具反过来对一遍）。迁移过的工具的名片也和地图、通用主题一起查名字（`GuideChecks` 的 `runGuideWordingChecks`）。
- `ProviderChecks`（generate_media）：名片必含 Sky Studio / credits / get_job / needs_confirmation / confirm_token / daily credit limit / add_clips / upscale_clip，
  前 512 字点到 upscale / upscale_clip / get_job / add_clips；说明书必含 camera_angle / MiniMax H3 / image_to_video / library / generate_subtitles / add_voiceover。
- `checks/MCP/router-wiring.sh`（扫描）：`skycut_guide` 交给 `AIGuideTools`，和 `recipes` 同一行 Policy、三个都是 false。
- `checks/SkyStudio/GateChecks.swift`（`scripts/check-sky-studio.sh`）：`alwaysAnswered` 正好是 `get_status` 和 `skycut_guide`，没 Key / 免费版时只有这两个让用；
  `answeredBeforeLicenseCheck` 正好是 `skycut_guide`、是 `alwaysAnswered` 的子集；`ProNoticeChecks` 同一口径。
- `checks/sky-studio-wiring.sh` 第 5 节：`aiRefusal` 放行 `answeredBeforeLicenseCheck` 的那一句在 `await settledLicense(` 之前。
- `SkyStudioVoiceChecks`（add_voiceover，和 `ProviderChecks` 同一个做法）：名片必含 recordings: add_clips / default gemini:Charon / Returns job_id; wait with get_job /
  relay voice.note / The daily credit limit always applies / resume=recovery_file, never resend lines / 先读说明书那一句，不再有 Rachel、`clone_from`；`speed` 的说明写着
  「0.5 to 2」；地图「Paid」那一行带着它；主题正好是声音方案 4.10 的那几节、`fields` 在最后，说明书必含 gemini:Charon / eleven:Name / en_male_british / voice_plan /
  cross_language / daily_budget_exceeded / recharge_url / confirm_token / recovery_file / generate_missing / eleven-v4 / download_voices=true / sync_voiceover。
- `SkyStudioVoiceChecks`（声音库，声音 PR 6）：`list_voices` / `manage_voices` 的参数名、动作词表就是 App 分派的五样；名片必含（只读免费 / 不改时间线没有撤销 /
  design 花积分回任务号 / 先问 / 删除按模式 / 先读说明书）、说明书必含（分节照声音方案 4.10、设计一节不写价）、地图的 Voices 一行和 Paid 一行。
- `ArgumentCheckChecks`：名片写着 `needs_confirmation` 的工具，带着 `confirm_token` 再调都过参数核对（[案例](../bugfixes/2026-11-10-voiceover-confirm-token-refused.md)）。
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
| fields 漏掉第一层的 `x`（里层还有同名的） | 6 条：edit_clip / set_text / set_shape 各两条（第一层那一行、按路径找那一行） |
| 长主题的 next_step 里写一个不存在的参数名 | 1 条：措辞检查挑出 `clip_end_ms` |
| `answerLimit` 降到 4,900 | 2 条：generate_media、edit_clip 的 fields 一节超长（真实主题的大小检查管用） |
| 跳过例子的核对 | 3 条：坏样本（不存在的参数、选项外的值、挂在非工具主题上）没被挑出来 |
| 跳过 related 的核对 | 1 条：坏样本里的 no_such_topic 没被挑出来 |
| 去掉凭据的匹配 | 4 条：`sk-` Key、邮箱、链接、Bearer 的坏样本都没被挑出来 |
| 只给 section 时悄悄回目录（修复前那样） | 3 条：没有 section_without_topic、没有 next_step |
| 放行说明书挪到等授权之后（修复前那样） | `checks/sky-studio-wiring.sh` 红（放行在第 5 行、等待在第 4 行） |
| `answeredBeforeLicenseCheck` 改成空 | GateChecks 1 条 |

**反向验证（2026-11-10，地图、通用主题、总说明、报错指路）**：

| 临时弄坏 | 红了 |
| --- | --- |
| 总说明换回 `7a9d8c9` 那一版（2,012 字、没有 skycut_guide） | CatalogTextChecks 4 条：两种样子都超过 1,200、前 512 字没点到 skycut_guide |
| 地图里删掉 `seek` | GuideChecks 1 条：地图没把 seek 列成一项 |
| 把 `seek` 挪进 set_view 的括号里（整词还在地图上） | GuideChecks 1 条：括号里顺带提到的不算一项（按整词找会照样过） |
| 通用主题少了 `errors` | GuideChecks 2 条：主题表不对、errors 主题不在 |
| rules 主题里写一个不存在的参数名 | GuideChecks 1 条：措辞检查挑出 `clip_end_ms` |
| 参数名写错的那句去掉说明书指路 | ArgumentCheckChecks 1 条 |
| 路由 catch 换回不带指路的 `error.result` | `checks/MCP/router-wiring.sh` 红（`check-mcp.sh --scans-only` 退出非 0） |
| 被挡住的那句去掉「skycut_guide 照常能用」 | GateChecks 7 条（七种被挡的原因） |
| 地图的 Paid 那一行去掉 `upscale_clip` | GuideChecks 1 条：地图没把 upscale_clip 列成一项 |

**反向验证（2026-11-10，试点 5 个工具）**：

| 临时弄坏 | 红了 |
| --- | --- |
| `edit_clip` 的名片换回迁移前的 737 字 | GuidePilotChecks 4 条：超过 450、没写 One undo step、没写 skycut_guide topic=edit_clip、名片没改写过 |
| generate_media 的名片去掉「The daily credit limit always applies.」 | 2 条：GuidePilotChecks（固定说法）、ProviderChecks（名片必含） |
| generate_media 的主题里去掉 MiniMax H3（概要里的原文同长改成 H9） | ProviderChecks 1 条：说明书必含 |
| `sound_effect.preset` 的说明换回 258 字的老说明 | GuidePilotChecks 1 条：超过 120 |
| set_text 的 `rotation` 去掉「-360 to 360」 | GuidePilotChecks 1 条：带范围的没写数字 |
| set_text 的 `position` 多 60 个选项（参数定义 4,960 字节） | GuidePilotChecks 1 条：超过 4,500 |
| set_text 的迁移前原文删掉最后一句 | GuidePilotChecks 1 条：原文长度 194，应为 249 |
| edit_clip 的 pitfalls 写一个不存在的参数名 | GuidePilotChecks 1 条：措辞检查挑出 `clip_end_ms` |
| edit_clip 的例子写 `end` | GuideContentChecks 1 条：例子用了没有的参数 |
| `fields` 不切节（上限放大 100 倍） | GuidePilotChecks 4 条：generate_media 一节 4,771 字 53 个参数、手造的没切、超上限、大参数没单独成节 |
| `fields` 切节时丢掉后几节的第一行 | GuidePilotChecks 3 条：generate_media 少行、手造的少行且有一节从里层开始、大参数那一节不对 |
| 三个工具文件整份换回迁移前（说明书的文件和检查不动） | GuidePilotChecks 52 条：四张名片超长、五张都没改写、固定说法、超过 120 的、没写范围数字的 |

## 五、人工回归（发版前在真机上走一遍）

- [ ] Claude Code（2.1.296 以后）连测试版、新会话：不经工具搜索就能调 `skycut_guide`（问它 skycut_guide 说明的第一句；或看 `/mcp` 里 skycut 的工具）。
- [ ] Codex：`ALL_TOOLS` 里找得到 `skycut_guide`；调 `topic=edit_clip` 看得到 `fields`（它自己的 `edit_clip` 条目里参数说明被删光）。
- [ ] Codex：打印 `edit_clip` / `generate_media` 的条目（参数定义超过 5,000 字节，参数说明被删光）之后，调 `skycut_guide topic=edit_clip section=fields`
      读得到每个参数的说明和范围；`section=fields_2` 读得到 generate_media 的后半。
- [ ] 没 Key / 免费版：`skycut_guide` 照答，别的工具（`get_status` 除外）回「Not done」。
