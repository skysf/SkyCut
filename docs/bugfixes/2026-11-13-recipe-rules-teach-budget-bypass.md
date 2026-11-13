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
  suspended」（等 2 秒就超时）；不重编、直接再跑一遍全过，没算进上面的证据。原因（自检对着墙上时钟的期限）和修法见
  [后来的案例](2026-11-13-listen-range-checks-timed-out-under-load.md)。
- 推之前 `scripts/check-local.sh mcp docs-index-drift`：全部扫描守卫绿，`check-mcp` 7,736 条全过，`docs-index-drift` 绿。

## 教训 / 防回归

- 给 AI 的话不只在工具说明和说明书里，剪辑风格的卡也是：改花钱的合同、目录、清单怎么列时，同一次改动里搜一遍
  `Sources/SrtFlow/Resources/recipe*.md` 和中文稿。
- 卡里不写死会变的目录事实（档位、模型、「没有 …」）；花钱的合同细节指到说明书，卡里只写剪片时要记住的那一层。
- 守卫对着事实查（清单真的怎么列、结果码叫什么、哪两件事不能写成一回事）；钉原词的守卫会替过期的那句站岗。
- 长期约束见 [AI 接口（MCP）](../architecture/ai-control-mcp.md)第四节第 32 条。

## 后续（2026-11-13，同一天另一个 PR）：边界外同一类的几处一起清了

上面那个 PR 只改剪辑风格，报告里留了几处同一类的过期说法在边界外；这一次照「合同改了，别处的话没跟上」逐处清掉（不改 App 的行为）：

- **代码里的死常量和过期的注释**：`MCPVocabulary.videoResolutions` / `generationAspects`、`SkyStudioGeneration.videoResolutions`
  （注释写「H3 只有这两档」「没有 1080p」，没有一个工具用它们）删了，`SkyStudioGeneration` 剩下的画幅 / 768p 注明是「目录没给取值时的兜底」；
  `DailySpendPolicy` 里 fal 时代的两条死路（价格不明每次问、配旁白超额度退档）和「超了就问」的叫法（`.ask` 改 `.overLimit`）、
  `applyDocumentRepair` 的 `annotation:`（查 fal 实收回写工程那一路，10-28 删了）也删了。`AIUpscaleTool`、`SkyStudioGenerateTool`、`SkyStudioJobGate`、
  `UpscaleJob`、`UpscalePanel`、`AISession`、`SkyStudioAccount`、`MCPGenerationTools` 等注释里还写着 11-01 之前的规矩（超了每日上限回确认码、
  面板超了只标红、确认码绑着摘要、存了 Key 才列）或把 fal 当现行的，改成现在的说法；检查和脚本的说明（`ProviderChecks`、`UpscaleToolChecks`、
  两份 `SpendChecks`、`scripts/check-mcp.sh`、`scripts/check-sky-studio.sh`、`checks/sky-studio-wiring.sh`、指向已删的 fal 脚本的几处）同样。
- **架构文档**：[AI 接口（MCP）](../architecture/ai-control-mcp.md)第四节第 7 条的「送 fal 的任务跑着时 get_job 带阶段」改成 Sky Studio 的阶段和
  `skystudio_job_id`；第 6、34、44、45 条、人工清单和已知不足里把 fal、旧预算规矩、旧上限当现行的话改掉或注明当时；
  [Sky Studio 的任务](../architecture/sky-studio-jobs.md)、[视频 upscale](../architecture/video-upscale.md)（含人工回归第 8 步：超了上限现在是
  `daily_budget_exceeded`，不是确认码）、[合成音效](../architecture/sound-effect-synth.md)同样；[检查细目](../testing/check-catalog.md)补上
  `RecipeContractChecks`。
- **共用规矩补第 13 条**（中文稿先改，再同步英文资源）：存了 Sky Studio 的 Key 时 `add_voiceover` 也花积分 —— 回任务号之前整段报一次价、
  按每日硬上限整体预留，超了 `daily_budget_exceeded` 就停、用户要才换本机的声音；细节指到说明书的 `add_voiceover`、`paid` 两个主题。
  对着 [Sky Studio 的任务](../architecture/sky-studio-jobs.md)第五节和说明书核过。
- **守卫**：`RecipeContractChecks` 加一条事实型的：卡里叫 AI 用到的花钱工具（照说明书 `paid` 主题「Which tools.」那一句认，不另抄名单），
  共用规矩里都得有一条同时讲到它和积分。反向验证（编好的自检二进制直接读资源）：删掉第 13 条 **1 条红**（点名 add_voiceover）；
  留着第 13 条但去掉 credits 这个词 **1 条红**；把第 13 条改成「超了每日上限回 needs_confirmation、带 confirm_token 再调」，原有的那条
  **1 条红**；逐字节放回（`cmp` 对过）后 **7,739 条 MCP 检查全过**。
- 方案、报告、案例里写当时目录事实的句子是那一天的记录，照[文档索引怎么写](../architecture/doc-indexes.md)第三节第 5 条只补注记、不改写：
  收费方案「H3 只有 480p / 768p」那一句补了「这是 10-27 那一版合同，档位以 `/models` 为准」。
- 判断为不是同一类、没动的：文档里写的 `SrtFlow/配音` 这类文件夹名照 AGENTS.md「名字」一节，docs 里的 SrtFlow 指的就是 SkyCut
  （新建的叫 `SkyCut/`、老的照认，[产品名](../architecture/product-name.md)）。

## 后续二（2026-11-13，同一天 Codex 审查之后）：一次性建声音那一支、needs_confirmation 的含义、检查的三个漏洞

Codex 读代码审了上面两次改动（审查 D6R-01、02、03、07，没跑过），这一次逐条对着代码确认、都属实，一起改了（不改 App 的行为）。

**症状**

- **D6R-01**：第 13 条一概说「回任务号之前整段报价、整体预留，把价告诉用户（结果里的 `credits`）」。声音库的声音要先建这种语言的
  MiniMax 版时，`SkyStudioVoiceoverStart` 在整体预留之前就交给 `SkyStudioVoiceOneTimeStep`，回的是建声音那一步：要问的 `needs_confirmation`，
  或者已经起的 `kind: voice_enroll` 任务 —— 它的 `credits` 是建版本的钱，旁白还没读、没预留；同一个版本已经在建时回那一单（`already_building`），
  连 `credits` 都没有。照卡读，AI 会把建版本的价报成旁白的总价、说旁白已经预留了。
- **D6R-07**：第 11 条说「`needs_confirmation` 意味着请求批准模式下超出了低成本草稿」、「更高档位重做这一步会问用户」。`SkyStudioGenerateTool`
  在报价之前先过 `AIWorkspace.confirmReading`：读点名文件夹以外的参考文件也回 `needs_confirmation`，连 `quote_only=true` 都先问；
  反过来，全部权限、用户点名过这个规格（`user_requested_overrides` + 原话）、这个工程批准过的（`approval_scope=project`），`SkyStudioJobGate.decide`
  直接起任务，不问。
- **D6R-02**：检查从说明书 `paid` 主题「Which tools.」那一句认花钱的工具，只防「一个都没认出」。说明书把那一句拆成两句（仍然正确），
  就只认出 generate_media，同时删掉第 13 条也不红 —— 用改之前的检查实跑：**32 条全绿**。
- **D6R-03**：预算只认 daily / budget / limit，「Over the spending cap, retry with confirm_token.」不红；嵌套列表「- Over the daily limit:」下面一项
  「- retry with confirm_token.」切成两段也不红 —— 用改之前的检查实跑，两种都 **33 条全绿**。

**根因**

1. 写第 11、13 条时对着的是正常路径（普通旁白、超出草稿的那一问），没看提前返回的分支：一次性费用、在建的那一单、读别处的文件先问、
   花钱之前退回本机的声音、不问就起任务的三种情形。规矩里「某个状态就是某个意思」「这一步一定会 …」的话，在这些分支上就错了。
2. 检查是受限的文字扫描（认得出的写法才查得到），却没有自己的坏例子：认工具名只防「空」不防「少」，预算词表和切段都没有一组「必须抓到 / 不许误报」
   的句子钉着，所以换个说法、换个列表结构就漏。

**修复**

- 共用规矩第 11 条（中文稿先改，再同步英文）：`needs_confirmation` 不管为什么问，都照结果的 `question` 问、同意才带 `confirm_token`，付费规格的那一问
  带着价格和原因；`quote_only=true` 可能先问能不能读别处的参考文件；更高档位重做「先报价，再照实际返回的走」：回 `needs_confirmation` 才问，
  直接回了任务号就是不用问（全部权限、用户点名过、工程里批准过）。
- 第 13 条：Sky Studio 的声音花积分，SkyCut 自己的和这台 Mac 的不花，Sky Studio 用不了时预设和角色在花钱之前换成本机的声音（`voice.note` 说）；
  普通的旁白回任务号之前整段报价、整体预留；要先建声音的版本时回的是建声音那一步（`needs_confirmation`，或 `kind: voice_enroll`，在建的
  `already_building` 不另花钱），那一笔是建版本的钱、旁白还没读没预留，跟着 `next_step`（建，或 `skip_one_time=true` 不花一次性费用就读），
  建好了再调一次 `add_voiceover`。
- 说明书 `add_voiceover` 的付费那一节同样把「回任务号之前整段预留」说满了：改成「普通旁白的任务号之前」，建声音那一单的 `credits` 是建版本的、
  不是旁白的价，补上 `already_building`，`skip_one_time=true` 只在 `next_step` 给了不花钱的那个时能用（点名的模型要 MiniMax 版时没有，
  `SkyStudioVoiceOneTimeStep` 报错叫 AI 改 `model=auto`）。`already_building` 登记进结果字段名（`CatalogNames.swift`），`SkyStudioVoiceChecks` 钉住这两句。
- 同一类再扫一遍：第 11 条和电影开头卡「生成的视频自带声音」改成「大多自带」（H3 自带、有 `generate_audio` 开关的照目录默认，目录是服务器给的）；
  中文稿第四节的语速补一句「只对本机的声音有用」；[Sky Studio 的任务](../architecture/sky-studio-jobs.md)第三节、[视频 upscale](../architecture/video-upscale.md)
  「花钱」那一行和人工回归第 8 步同样把「请求批准模式下回确认码」说满了，补上 [AI 接口（MCP）](../architecture/ai-control-mcp.md)第 44 条已经写着的例外
  （用户原话点了名的、本工程批准过的不再问；`AIUpscaleTool` 带着「放大」这类点名词）。核过、照旧成立的：没 Key 时 generate_media 报错（`hasKey` / 照授权拦）、`daily_budget_exceeded`
  什么都不起（`budgetBlocked`，旁白的一次性费用那一支也是）、两种音效默认 −8 dB（`SoundEffectClipGain.defaultDB`）、Sky Studio 的声音不认 `speed`、
  字幕样式只改这个工程、`music_credits` 只管音乐库。
- 检查：切段、切句、认预算词、认「把 needs_confirmation 说成一个原因」「把会问说满」拆进新的 `checks/MCP/RecipeTextScan.swift`，嵌套的列表项带着
  每一层父项的话、段落后面的列表带着那一段，预算词补上 cap / ceiling / quota / allowance（cap 要整词，caption 不算），每个函数自带坏话和合规的话
  （`runRecipeTextScanSelfChecks`）。`RecipeContractChecks`：花钱的工具钉在 `recipePaidTools`（生产代码里没有结构化的清单：`MCPToolName.provider`
  说的是去哪消费，免费的 list_* 也是 Sky Studio、配旁白却是 nil），说明书 `paid` 主题那一句和地图「Paid」那一行都要正好认出它，循环按钉住的清单走；
  讲 `add_voiceover` 积分的那一条要讲到 `voice_enroll`、`already_building`、`next_step`；`needs_confirmation` 不写成某一个原因、共用规矩留着「照结果的
  question 问」那句、「SkyCut 会问」不说满。拆说明书那一句、写错第 13 条这两种坏例子也写进了检查自带的例子。

**验证**（反向验证用同一份检查源文件编的小二进制，只换了入口、只跑 GuideChecks / GuidePilotChecks / RecipeChecks / SkyStudioVoiceChecks 四组共
3,809 条；它直接读仓库里的资源，改说明书、改检查的那几条重编；「改之前的检查」是 HEAD 的 `RecipeContractChecks.swift` 单独编的；每次换完逐字节
放回修好的文件，`cmp` 对过）：

| 放回去的坏例子 | 新检查 | 改之前的检查 |
| --- | --- | --- |
| D6R-01：第 13 条换回改之前的 | 1 条红（讲旁白积分的那一条没讲建声音那一步） | — |
| D6R-01：新第 13 条去掉 `already_building` 那半句 | 1 条红 | — |
| D6R-02：说明书「Which tools.」拆成两句 + 删第 13 条 | 3 条红（只认出 generate_media、add_voiceover 没有花积分的规矩、旁白那一条） | 32 条全绿（漏） |
| D6R-02：只拆说明书那一句、第 13 条留着 | 1 条红（认出来的不是那六个） | — |
| D6R-02：地图「Paid」那一行少列 change_voice | 2 条红（这一条 + 原有的地图检查） | — |
| D6R-03：第 11 条加「Over the spending cap, retry with confirm_token.」 | 1 条红 | 33 条全绿（漏） |
| D6R-03：第 11 条加嵌套的「- Over the daily limit: / - retry with confirm_token.」 | 1 条红 | 33 条全绿（漏） |
| D6R-07：第 11 条那两句换回改之前的 | 2 条红（说成一个原因、「SkyCut asks」说满） | — |
| 共用规矩整份换回改之前的 | 3 条红（D6R-01、07 各条） | 33 条全绿 |
| 说明书付费那一节换回改之前的 | 2 条红（`SkyStudioVoiceChecks` 新钉的两句） | — |
| 检查自己：嵌套项不带父项 | 10 条红（自带的例子） | — |
| 检查自己：预算词退回 daily / budget / limit | 4 条红（spending cap、ceiling、quota、caps） | — |

全部放回后整跑 `scripts/check-mcp.sh` 的自检：**7,797 条全过**（原来 7,739 条；多的是自带的例子和新的几条）。

**教训**

- 写给 AI 的花钱规矩，要对着代码里每个提前返回的分支核一遍（一次性费用、在建的那一单、先问能不能读文件、花钱之前退本机、不用问就起任务），
  不只看正常路径；规矩里只写「照实际返回的走」，不替状态码说它是什么原因。
- 文字扫描的检查要带自己的坏例子和合规例子：认得出的写法才查得到，扫不出来不等于对。
- 长期约束补进 [AI 接口（MCP）](../architecture/ai-control-mcp.md)第四节第 32 条的 ④、⑤。
