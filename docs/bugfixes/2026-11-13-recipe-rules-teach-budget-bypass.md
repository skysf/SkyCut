# 2026-11-13 剪辑风格的共用规矩还在教 AI 用确认码越过每日预算

## 症状

2026-11-13 Codex 全量复查文档索引时顺带读到（复查报告第 3 节 D01、D05），没有人在实剪里撞上。剪辑风格的共用规矩第 11 条
（英文那份是 App 资源 `Sources/SrtFlow/Resources/recipes-shared-rules.md`，AI 调 `recipes` 读一套全文时接在后面；中文稿在
[配方卡](../plans/2026-09-28-mcp-recipes.md)）教 AI 的花钱流程和现行合同不符：

- 「超了每日积分上限时结果是 `needs_confirmation`，用户同意才带着 `confirm_token` 再调一次」。2026-11-01 起每日预算是硬上限：
  `SkyStudioJobGate.decide` 先判预算，超了回 `status: blocked`、`code: daily_budget_exceeded`，什么都不起、不发码，`next_step` 明说
  不许要一次性越额，全部权限也一样。AI 照卡去问用户「要不要超」，用户点了头也没有码可带 —— 卡和结果说的是两回事。
- 「视频先用 `480p` 出草稿，留下的镜头再用 `768p` 重做（Sky Studio 的视频没有 1080p）」。这是 10-28 只有 MiniMax H3 一个视频模型时的事：
  10-31 扩充模型之后目录里有 1080p 的视频模型（Wan 3.0 是 480p / 720p / 1080p，`checks/SkyStudio/Fixtures/models-2026-10-31.json`），
  没有 768p；草稿本来由 SkyCut 按目录挑（`AIDraftPolicy`：视频取 720p 同档，H3 是 768p）。照卡点名 768p，没有这一档的模型当场拒
  （`SkyStudioModelPolicy`：「… accepts resolution …」）；能做 1080p 的，AI 也想不到。

同一类的另外几处一起查出来：

- 共用规矩的条件句写着「(the user added a Sky Studio key; otherwise skip this rule)」，中文稿写着「只有用户存了 Sky Studio 的 Key 才在工具清单里」。
  2026-10-30 起清单始终列出 `generate_media`，Key、套餐、积分在调用时核对（[那次的案例](2026-10-30-generation-tools-missing-after-key-added.md)
  删的就是「存了 Key 才列出」这句，卡里漏了）。
- 电影开头、科幻两张卡（中英）写着「先 480p 出草稿」「480p first」；电影开头、带货两张英文卡写着「no fal needed」「no fal」（10-28 起都走 Sky Studio）。
- 中文稿第四节「对话里点名能换……或者（第 ③ 刀之后）一段要克隆的声音」：2026-11-10 `add_voiceover` 去掉了 `clone_from`；同一节的声音表也没说
  10-29 起存了 Key 时角色先走 Sky Studio 的声音、花积分。

App 的行为一直是对的（硬上限、草稿、清单都照合同做），错的是 AI 读到的话。

## 根因

1. **给 AI 的花钱流程散在好几处，合同改的时候只改了其中两处。** 10-30（清单始终列出）、10-31（七个新模型）、11-01（硬预算 + 草稿审批）
   三次改动都改了工具说明（`MCPGenerationTools.swift`）和总说明（`MCPInstructions.swift`），各有检查守着；三次都没碰
   `Sources/SrtFlow/Resources/recipe*.md` 和中文稿。剪辑风格的英文卡是 App 资源、中文稿在 `docs/plans/`，看起来像方案和素材，
   不像会被 AI 原样读到的合同文字。
2. **合同那头没有一处提醒要同步。** 讲硬上限和草稿审批的 [AI 接口（MCP）](../architecture/ai-control-mcp.md)第四节第 6 条、
   [Sky Studio 的任务](../architecture/sky-studio-jobs.md)第十一节、[统一设置](../architecture/workbench-and-settings.md)和 11-01 的案例都没写
   「剪辑风格第 11 条也在教这一套」；第 39 条提到共用规矩第 11 条，只管它要写成条件句。
3. **检查钉的是当时的原词，不是事实。** `RecipeChecks` 要求共用规矩里有 `needs_confirmation`、`confirm_token`、`credits in` 和 `480p`：
   合同变了它照样绿，谁只把 `480p` 删掉反而会红 —— 守卫在替过期的那句站岗。
4. **出不了声。** App 照硬上限拦、照目录拒档位，没有多扣钱，报错也不会指到卡上；这一段只在 AI 按一种风格剪整条片子、又要生成素材、
   又碰上预算或档位时才用得上，冒烟没走过这条路。

## 修复

- 共用规矩第 11 条，先改中文稿、再同步英文：条件句只说「清单里有它」，没存 Key 时它直接报错、这条就跳过；花积分的规矩以
  `skycut_guide topic=paid` 为准，卡里只留剪片时要记住的几句 —— 先报价（`quote_only=true`）；`needs_confirmation` 只在请求批准模式、
  要的超出低成本草稿时出现，问了用户再带 `confirm_token`；`daily_budget_exceeded` 是每日硬上限，就此停下，码和全部权限都越不过去，
  告诉用户去设置里调、用户明说才用 `set_settings` 帮着改，也不拆小请求去凑；视频草稿用 SkyCut 按模型挑的低成本草稿（不传 `resolution`），
  留下的镜头按那个模型在目录里有的更高档报价、重做（`get_status models=true`）。
- 电影开头、科幻：「480p」改成「先出低成本草稿（共用规矩第 11 条）」；电影开头、带货的「no fal」改成「no credits」，中文稿补上
  「本机合成，不花积分」，两边对上。
- 中文稿第四节：补一句 10-29 起存了 Key 时角色先走 Sky Studio 的声音（`/models` 的 `voice_roles` 定、花积分）；「一段要克隆的声音」
  改成声音库里的声音（`voice_…`），写明 `clone_from` 11-10 去掉了。
- 检查：新的 `checks/MCP/RecipeContractChecks.swift`（`runRecipeChecks` 调它）对着生产行为和现行说法查，原来钉原词的那条从
  `RecipeChecks.swift` 拿掉；`CatalogNames.swift` 一句同样过期的注释（「只有存了 Key 才在清单里」）顺手改了。
- 长期约束写进 [AI 接口（MCP）](../architecture/ai-control-mcp.md)第四节第 32 条；第 6 条加一句「改这几条时一起改共用规矩第 11 条」，
  第 39 条补上新检查的名字。不改 App 的行为代码。

## 验证

- `RecipeContractChecks`（在 `scripts/check-mcp.sh` 里）：
  1. 条件句「If generate_media is among your tools」到冒号之间不许提 key —— 前提是 `MCPToolName.listed(providers: [])` 里有 `generate_media`
     （清单真的不按 Key 过滤；哪天又按 Key 藏，这条自己让开）；
  2. 共用规矩讲到 `quote_only`、`needs_confirmation`、`confirm_token`、`daily_budget_exceeded`；五张卡和共用规矩里没有一句话同时提到
     每日预算（daily / budget / limit）和 `needs_confirmation` / `confirm_token`（按段、按句号切，冒号分号不切）；
  3. 讲生成素材的句子（generat / draft / remake / Sky Studio / text_to_video / image_to_video）不带档位（`480p`、`1080p`、`2K` 这类）；
  4. 五张卡和共用规矩不提 fal、`cost_usd`；原来的条件句、每张卡的「Generated media」两条照旧。
- 反向验证（编好的自检二进制直接读仓库里的资源，换文件不用重编）：
  - 四个资源文件整份换回改之前的版本：**9 条红** —— 条件句提了 key、缺 `quote_only`、缺 `daily_budget_exceeded`、「When the result is
    needs_confirmation (over the daily credit limit) …」那一句、三处档位（共用规矩、电影开头、科幻）、两处 fal（电影开头、带货）；
  - 只把共用规矩的确认和硬上限那两条换回旧的一句：**2 条红**（缺 `daily_budget_exceeded`、预算和确认码同一句）；
  - 留着 `daily_budget_exceeded` 那条、另加一句「Over the daily credit limit the result is also needs_confirmation」：**1 条红**；
  - 只把草稿那条换回「480p 出草稿、768p 重做（Sky Studio has no 1080p video）」：**1 条红**。
  每次换完逐字节放回修好的文件（`cmp` 对过），再跑全绿：**7,736 条 MCP 检查全过**。
- 第一次整跑（边编译边跑、机器负载高）有一条和这次无关的检查红了：`ListenRangeChecks` 的「bounded file listen must work with overview
  suspended」（等 2 秒就超时）；不重编、直接再跑一遍全过，没算进上面的证据。
- 推之前 `scripts/check-local.sh mcp docs-index-drift`：全部扫描守卫绿，`check-mcp` 7,736 条全过，`docs-index-drift` 绿。

## 教训 / 防回归

- 给 AI 的话不只在工具说明和说明书里，剪辑风格的卡也是：改花钱的合同、目录、清单怎么列时，同一次改动里搜一遍
  `Sources/SrtFlow/Resources/recipe*.md` 和中文稿。
- 卡里不写死会变的目录事实（档位、模型、「没有 …」）；花钱的合同细节指到说明书，卡里只写剪片时要记住的那一层。
- 守卫对着事实查（清单真的怎么列、结果码叫什么、哪两件事不能写成一回事）；钉原词的守卫会替过期的那句站岗。
- 长期约束见 [AI 接口（MCP）](../architecture/ai-control-mcp.md)第四节第 32 条。
