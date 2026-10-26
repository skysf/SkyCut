# 2026-10-27 AI 传了说明上没有的参数，SkyCut 悄悄丢掉、照样做

## 症状

2026-10-26 第一次用真的 Codex 连 SkyCut 冒烟（[报告](../reports/2026-10-26-codex-client-smoke.md)第四节）：让它加一行「0 到 3 秒」的标题，
它调 `set_text` 传了 `start: 0, end: 3`。字加上了、结果报 `end: 3`，看起来全对。

可 `set_text` 的时间参数是 `start` + `duration`，根本没有 `end`。SkyCut 把 `end` 扔了、时长用了默认的 3 秒 —— 这次对上纯属碰巧。
要是 AI 说「0 到 5 秒」，标题会悄悄只有 3 秒，结果里也不说；AI 以为做对了，用户看成片才发现。Codex 在报告末尾说了一句「set_text 收了一个说明里没有的 end」，
才被注意到。

## 根因

- 工具读参数只按名字取自己认识的（`AIToolArguments.double("duration")` 这样），**没有任何一处看「传来的名字里有没有不认识的」**。
  所有工具、所有层都是这样：第一层、`add_clips` 每一段里的字段、`edit_subtitles` 的 `style` 里的字段，写错名字一律当没传。
- `AIToolIO.swift` 开头写着「参数读得宽一点」—— 那是对**值**宽（`"3.5"` 当数字、`"true"` 当布尔），本意是别因为格式小差别失败；
  对**名字**也「宽」就成了悄悄做错。
- Claude 一直没撞上，是因为它基本照说明填参数；GPT 更爱按自然的说法起名字（「从 0 到 3 秒」→ `end`）。换一个客户端，这类错就冒出来了。

## 修复

- 新增 `Sources/SrtFlowMCPKit/MCPArgumentCheck.swift`（纯值）：拿工具的说明（`MCPToolName.definition.inputSchema`）核对传来的名字 ——
  第一层、说明里写了字段的里层对象、数组里的对象都查；有一个不认识，就回一句写给 AI 的话：哪个名字、在哪（`clips[1]`、`clips[0].sound_effect`）、
  **什么都没做**、这里收哪些名字；大小写 / 下划线不一样时猜一个（`fontSize` → `font_size`），给了 `end` 而工具收 `duration` 时说「duration = end 减 start」。
- `AIToolRouter.handle` 认出工具之后、建调用排队之前问它：有问题就整个调用不做（不排队、不摆窗口、不开一轮）。
- 照收的三种：值是 null 的（等于没传）；`project`（哪个工具都能带：子代理被要求每次都带，不收它的工具带了也不碍事）；
  里层没写字段的对象（`generate_media` 的 `options`：原样转给模型）。
- 动手前把「实现里读、说明上没写」的名字全查了一遍：第一层只有 `set_shape` 把 `length` 当 `width` 的别名（说明里写在 width 那一句），
  登记进 `MCPArgumentCheck.aliases` 照收；14 个里层对象的读取代码读的字段都在说明里。拿的是小程序 `tools/list` 回的真清单，不是读源码猜的。
- 长期约束写进 [AI 接口（MCP）](../architecture/ai-control-mcp.md)第四节第 52 条：实现里认、说明上没写的别名必须登记，不然会被挡掉。

为什么是「挡掉」而不是「照做 + 在结果里提醒」：做了再提醒，错的东西已经落在工程里了（3 秒的标题），AI 还得再改一次；
挡掉只多一个来回，AI 拿到的话里就有正确的名字，什么都不会做错。

## 验证

- `checks/MCP/ArgumentCheckChecks.swift`（`scripts/check-mcp.sh`，CI 第 4 组）：冒烟里那次原样的调用被挡、话里有 `"end"`、「nothing was done」、指向 duration；
  认识的名字和 null 照过；`get_job` 带 `project` 照过；只收 project 的 `get_timeline` 列出 project；`fontSize` 猜 `font_size`；
  `set_shape` 的 `length` 照过；`clips[1]` 和 `clips[0].sound_effect` 里写错的字段报出位置；`style` 里写错的字段被挡；`options` 照收；
  **每个工具把说明上第一层的全部名字都传一遍都过**（以后改说明、加参数，这一步保证核对不会把说明上写着的挡掉）。
- `checks/MCP/router-wiring.sh`（扫描）：核对写在 `handle` 里、在 `let call = Call(` 之前。
- 反向验证：本机把路由里那三行拿掉，扫描红（「handle 没在建 Call 之前核对参数名」），放回去绿；
  纯值那一组：`problem` 开头加一句 `return nil`（撤掉修复），60 项里 8 项红（冒烟那次调用、只收 project、猜名字、两层里层、style），放回去 60 项全过。
- 本机只编了 `SrtFlowMCPKit` 这个模块和这一组检查（一个最小的入口：两个小文件链到编好的模块上，不编整个自检二进制）；完整的 `check-mcp` 交给 CI（照用户的规矩）。

## 教训 / 防回归

- **「读得宽」只能对值，不能对名字。** 对值宽是少失败，对名字宽是悄悄做错；AI 写错名字时它要的是「哪儿不对」，不是被默默纠正成默认值。
- **只在一个客户端上测过的接口，换个客户端就会冒出新的错法。** Claude 照说明填、Codex 按自然说法起名字；接新的 AI 客户端时先拿最便宜的模型跑一遍
  （[报告](../reports/2026-10-26-codex-client-smoke.md)），看它的「看着别扭的地方」。
- 核对拿说明当准：新加参数写进说明就自动认；实现里想偷偷认个别名，要么写进说明，要么登记进 `MCPArgumentCheck.aliases`。
