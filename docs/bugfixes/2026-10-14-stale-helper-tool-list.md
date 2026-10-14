# 2026-10-14 App 升级之后，会话里的小程序还是旧的，新加的工具和选项用不上

## 症状

2026-10-06 审美盲测：六条片子都是在 App 升级（加了急停 / 回弹 / 弹簧三种关键帧缓动，v32）之前开的 AI 会话里剪的，
AI 看到的 `set_keyframes` 的 `easing` 选项里没有 snap / overshoot / spring，一条都没用上（风格卡里写着要用）。App 本身已经是新的。

## 根因

工具清单（`MCPToolName`、每个工具的说明和参数、选项词表 `MCPVocabulary`）编在 `srtflow-mcp` 小程序里：这是对的 —— 客户端一启动就要清单，
不能为了列清单把 SrtFlow 拉起来（[AI 接口（MCP）](../architecture/ai-control-mcp.md) 第一节第 1 条）。可小程序是 AI 客户端**开会话时**启动的
子进程，一直跑到会话结束；App 升级、重开之后，这个会话里跑的还是升级前的那个小程序，清单停在旧版。App 收到的调用照做，可 AI 看到的
清单是旧的，新工具、新选项它不知道（旧小程序还会把新工具名当成「Unknown tool」拦下来）。两边之间没有任何东西比过版本。

## 修复

- `MCPCatalogSync`（SrtFlowMCPKit）：`fingerprint` = 编进这份程序的全部工具清单的 FNV-1a 指纹（两边按同一份 JSON 文本算，不用每个进程换种子的
  Hasher）；`catalogResult` = 全部工具的定义 + 哪些要提供方。
- 通道：App 的每个回答带上自己的指纹（`MCPBridge.Response.catalog`，老 App 不带、老小程序不认，照旧能通）；新的一种请求
  `MCPBridge.catalogTool`，App 在收发线程上当场答（同「探一下」，不经主线程）。
- 小程序：回答里的指纹和自己的不一样、也不是已经换上的那份，就向 App 要清单（`AppConnection.fetchCatalog`）、换上（`MCPCatalogOverride`）：
  从此 `tools/list` 按它列（照旧按配没配 fal 过滤）、调用时认它的工具名；老一代客户端发一次 `notifications/tools/list_changed`
  （它会重新要清单），新一代靠清单的缓存时间；那一次的结果里加一句「SrtFlow 在会话开始后升级了，清单已经换成新的」。
- 总说明（instructions）只在握手时给，换不了 —— 写进文档。这套逻辑只救得了从这一版起的小程序：这一版以前的小程序不认指纹，照旧要重开会话。
- 长期约束写进 [AI 接口（MCP）](../architecture/ai-control-mcp.md) 第一节第 1 条。

## 验证

- `scripts/check-mcp.sh` 的 `CatalogSyncChecks`：纯值（没报指纹 / 指纹一样不换、报了别的才换、换上的不再要、新工具名认得、按提供方过滤、
  通知只给一次）；**真起小程序**接一个「升级过的」假 App（回答带着另一个指纹、给出的清单多一个工具）：第一次调用的结果里说清单换了、
  老一代客户端收到一次 `list_changed`、`tools/list` 里有新工具、调用新工具照样转给 App、只要一次清单、之后的调用不再说；
  指纹一样的假 App：不要清单、不发通知、新工具名照旧拦下。
- 扫描（`checks/MCP/router-wiring.sh`）：App 在收发线程上答 `catalogTool`。
- 反向验证（不合并的草稿 PR #188，CI）：`MCPCatalogOverride.needsRefresh` 改成永远不换 —— 第 4 组 check-mcp 红 7 条：指纹不同不去换、
  升级后的第一次调用不说清单换了、老一代客户端收不到一次 list_changed、tools/list 里没有 App 的新工具、调新工具到不了 App、只取一次清单。

## 教训 / 防回归

- **一份接口定义编在两个进程里、两个进程活得不一样长，就要在通道上比版本**：小程序跟着会话活，App 跟着用户升级 —— 编译期的穷举
  只保证同一次构建两边一致。
