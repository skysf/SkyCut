# 2026-11-10 AI 把「画质尽量好」当成用户点名的规格，跳过了花积分前的确认

## 症状

MCP 按需说明的 Codex 实测（[试点实测](../reports/2026-11-10-mcp-guide-pilot.md)「Codex 这一半」）任务 7：用户只说「给这个工程生成一张封面图，画质尽量好」，
在「请求批准」模式下 Codex（gpt-6.1-sol / max）两次（改之前的 `7a9d8c9`、试点的 `f76032e`）都是先 `quote_only` 报价，
再带 `user_requested_overrides: true` 直接起了生成任务：4K（基线那次还有 `quality=highest`）是它自己挑的，却当成用户点名的规格，
没停下来问（假 Sky Studio 的 1 积分）。Claude Code 同一句话两次都停在 `needs_confirmation` / 报价之后问了用户。

## 根因

- 「请求批准」模式下超过草稿（更高分辨率、更长时长、最高画质、更贵的模型）要问；用户自己点名的规格不重复问。App 看不到对话，
  只能靠代理自己说「这是用户点名的」：`user_requested_overrides=true` 就免问（`SkyStudioJobGate.decide` 里 `!userRequested`）。
- 「点名」只写在说明里（「true only for explicit user overrides, never the assistant's plan」；试点的 spending 一节写得更死：
  「only when the user explicitly asked for that specification themselves, never for your own choice」），Codex 读了这一节照样设 —— 它把
  「画质尽量好」理解成用户明确要最高画质。闸只认这一个布尔值，形容词和规格名分不开。
- 任务 7 2026-11-10 换题（原来点名「4K」测不出）就是为了测这条；Claude Code 守住了，所以基线的 Claude Code 一半没暴露。

## 修复

用户 2026-11-10 定：只有用户明确点名了这个具体规格（「4K」「用 GPT Image 2」）才算，「画质尽量好 / 最好的」这类形容不算，必须先报价再问；
能在 SkyCut 这边加一道挡就加。

- **App 这边加了一道挡**（`Sources/SrtFlow/AIOverrideQuote.swift`，纯值）：`user_requested_overrides=true` 时要同时给 `user_request`
  （用户原话里点名规格的那一段），每一项越档都要在里面找得到它的名字 —— 分辨率（4K / 2160p / 2160，`AIDraftPolicy.overrides` 按档位换算）、
  时长（10s / 10 秒 / 10 seconds）、最高画质（highest / 最高）、更贵的模型和比不了价的模型（模型 id / 名字，「GPT Image 2」=「gpt-image-2」）；
  付费 upscale 认 upscale / 放大 / 超分，付费角色认 character / 角色 / headshot / 头像。比较不分大小写、去掉空白和连字符。
  找不到就照常回 `needs_confirmation`（`SkyStudioJobGate.decide`），结果里 `overrides_not_applied` 说是没带原话还是哪一项没点名 ——
  **不报错**：报错会逼代理编一段原话重试，回确认码则把它带回「问用户」的正路。
- **名片和说明书写死**：generate_media 的名片「user_requested_overrides needs user_request, the user's words naming it (4K, a model),
  never "best quality"」（正好 450 字）；三个工具（generate_media、upscale_clip、manage_characters）的参数说明、generate_media 的 spending 一节、
  通用的 paid 主题、upscale_clip / manage_characters 的 spending 一节都改成同一个说法。
- 官方原创短片（`SkyStudioOfficialGenerateTool`）的越档存在缓存的计划里、只有文字，这次只查带没带原话（名字为空的一项），没改它的计划结构。

## 验证

- `scripts/check-sky-studio.sh`（`AccessChecks`）：带 `user_request` 点名 2K → 直接预留；不带原话、原话是「画质尽量好」「best quality please」→
  都回 `needs_confirmation`，带 `overrides_not_applied`，一分钱不预留；两项越档只点了一项 → 仍要问。纯值：4K 认 4k / 2160p、模型名带空格认 id、
  最高画质认「最高画质」、时长认「10 秒」「10 seconds」，「画质尽量好」「要最好的」「best quality」「as good as possible」「高清一点」一项都不算。
- `scripts/check-mcp.sh`（`GuidePilotChecks`）：名片上钉着「user_requested_overrides needs user_request」「never "best quality"」；参数表加了 `user_request`。
- 反向验证：把闸里的 `!userNamedIt` 换回 `!userRequested`（只认布尔值），`AccessChecks` 的三条「still asks」和「every setting must be named」变红；恢复后绿。
- 真客户端：修完用 Codex 和 Claude Code 各补跑一次任务 7，结果记在 [试点实测](../reports/2026-11-10-mcp-guide-pilot.md)「任务 7 修了之后补跑」。

## 教训 / 防回归

- 让代理「自己声明」的开关只是诚信制：说明写得再死，模型对「明确」的理解不一样（Claude Code 和 Codex 就分成两边）。能让 App 核对的，
  就要它交出能核对的东西（这里是用户原话里的规格名），核对不上就退回问人，而不是只信一个布尔值。
- 长期约束写在 [顶部工作台与统一设置](../architecture/workbench-and-settings.md)「AI 操作权限与草稿」。
