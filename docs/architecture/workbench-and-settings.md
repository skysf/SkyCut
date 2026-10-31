# 顶部工作台与统一设置

2026-10-31 用户确认：以「常用工具优先」的单排工作台替换永久工具侧栏；设置窗口收齐现有设置，MCP 能发现并调整开放的偏好。

## 布局与入口

- `VideoEditWorkbenchToolbar`：左边素材库、录屏、字幕；中间工程菜单；右边 AI 活动、云端任务、导出、设置、更多。主窗口和工程窗口复用，工程由调用方给，不能假设只有 primary。
- 主窗口和工程窗口都用原生紧凑工具栏；工程菜单依据实际窗口宽度与 AI 状态预算，窄时先缩短工程名，保住常用操作。
- 常用按钮只显示图标，名字和说明用现有 `instantHelp`，保留辅助功能标签。素材库选中态是中性浅灰，导出不染强调色。macOS 26 的分组背景通过 `sharedBackgroundVisibility(.hidden)` 去掉；旧系统用原生工具栏。
- `WorkbenchMoreMenu` 保留压缩、烧字幕、转字幕；有后台 / AI 工程时出现「AI 工程」。浮层里复用 `AIProjectsSidebarSection` 的 List 行，不套 `.equatable()`，停止 / 打开 / 关闭规则不另做一份。
- 其他工具页有「返回剪辑」和设置 / 更多入口；文件菜单原有快捷键、文件中转、队列后台执行继续沿用。

## AI 活动

`AIActivityBanner` 现在是工具栏状态按钮与独立停止键，详情在 popover 中，不占预览高度。CPU 图标代替原星光图标；工作中用浅金色背景。背景先铺不透明的系统底色，再着浅金色 / 灰色；不能只填半透明颜色，后方原生分栏线会透出来（[案例](../bugfixes/2026-10-31-ai-badge-divider-bleed.md)）。

- 关闭详情只改变局部 `showsDetails`，不会 `AIRound.dismiss()`；工作时没有「隐藏状态」。完成 / 停止后才可明确隐藏。下一轮由原有 AIRound 正常重新出现。
- 停止、整轮撤销仍只作用在调用方工程。详见 [AI 接口](ai-control-mcp.md)第五节。
- 只有本工程关联的**一个**正在执行的任务提供有限数进度时显示百分比；多个并行任务、排队、等待用户、普通剪辑调用均不编造整体进度。百分比指当前任务。仅小徽章每秒读取 AIJobs，不订阅播放器时钟。
- 云端任务保持独立入口：紧凑云图标与全局进行中数量，悬浮文字含全局 / 本工程数量，打开后仍按工程分卡片，失败与未知扣费提示保留。

## 唯一设置窗口

SwiftUI `Settings` 场景只装 `SettingsWindowView().appLanguage()`；工具栏用 `SettingsLink`，与 SkyCut → 设置及 ⌘, 打开同一窗口。不得另做语言浮层或另一份设置数据。

| 稳定分类 id | 分类 | 复用组件与数据 |
| --- | --- | --- |
| general | 通用 | AppLanguagePicker / AppLanguageStore |
| ai | 连接 AI | AIConnectSection / AIClientSetup / AIReadGrants |
| editing | 剪辑与声音 | AIRecipesList / AIRecipeLibrary；KokoroVoiceSettingsRow / KokoroVoicePack |
| cache | 媒体缓存 | OptimizedMediaSettingsSection / OptimizedMediaCacheSettings |
| sky_studio | Sky Studio | SkyStudioSettingsSection / SkyStudioAccount / SkyStudioSpendStore |

分类标识与标题在 `SettingsCategory` 一份。保留所有原有账号 / 客户端 / 风格 / 声音 / 缓存行，只有归类变化。剪辑风格依然用 Finder 或文本编辑器改；不新造编辑器。语言选项用各自语言的名字，不再以国旗作入口。语言、缓存上限、AI 额度的持久化键保持原样。

每日额度文本框观察 Store 的外部变化：MCP 调整之后及时更新，切换分类时不能把旧草稿写回去。

## MCP 合同

`get_settings`、`set_settings` 是全 App 工具，不收 project、不换工程、不摆编辑器、不开始一轮、不制造时间线撤销项；仍经过现有 MCP 套餐授权门。

- `get_settings` 默认回五类快照，可传 `section` 限定。返回现值、可写字段、相关已有工具与 GUI 操作入口；不返回 API key 或客户端配置内容。
- `set_settings` 只认明确白名单：`language`（system / en / zh-Hans / es）、`optimized_media_cache_gb`（设置原有十进制档位）、`clear_optimized_media_cache`、`daily_ai_credit_limit`（原 Store 的整数范围，0 每次问）。省略 / null 不动，至少一项有效改动。
- **全部参数先读完、验完再写任何 Store**，错误整次不做。缓存仍由 `OptimizedMediaCacheSettings` 执行，不能绕过它直接删目录 / 写 defaults。清空可能异步完成，用 `get_settings section=cache` 的 `clearing` 核对，不把开始清空说成已完成。
- 每日额度是自动花费的询问阈值，不是硬性消费封顶；提高额度意味着 AI 可免确认花更多积分。工具说明要求只按用户请求改。
- 剪辑风格沿用 recipes / save_recipe，声音安装沿用 add_voiceover download_voices=true / get_job。账号密钥与客户端连接 / 断开仍从设置操作；新读权限仍走现有确认，不能借设置绕过。
- 工具清单、总说明目录都列出新工具；旧小程序通过现有 MCPCatalogSync 获得 App 的新清单。

## 验证与人工回归

自动检查：`checks/workbench-settings-wiring.sh`、本地化 / 多工程 / 预览性能接线守卫，以及 MCP 清单 / 参数检查。实际 App 和小程序通过独立 `.skystudiosmoke` 身份、回环假 Sky Studio 验证设置持久化、错误原子性、工具发现和工程状态不变；不碰生产 Key、客户端连接和真实钱包。

`scripts/check-workbench-toolbar.sh` 是随 GUI 冒烟手动运行的原生渲染检查：生产徽章在不同后景上的中心像素一致，浅色 / 深色、运行 / 完成均不透底；无图形会话的 check-all 不启动 ImageRenderer。

实机回归：

- [ ] 900 / 1180 宽及大窗口都保持一排；长工程名截短后仍可打开文件菜单，所有常用图标可点，hover 显示准确的名字。
- [ ] 设置齿轮、应用菜单与 ⌘, 重复打开同一个窗口；五类内容齐全。工程窗口里的设置入口也能打开。
- [ ] 中文 / 英文 / 西班牙语分别检查工具栏、更多菜单、AI 详情和五类设置；语言切换立即生效，重启后系统菜单一致。
- [ ] 正在剪辑时反复开关 AI 详情，徽章仍在；停止只影响当前工程；完成 / 停止可隐藏，再开始新一轮正常出现。
- [ ] MCP 改语言 / 缓存上限 / 额度，已开的设置同步；在界面改回来后 MCP 读到新值，重新启动仍一致。额度页切走不能恢复旧值。
- [ ] 更多菜单能回到三种工具；队列运行中切换不取消。后台 AI 工程可打开、单独停止、存好后关闭。
- [ ] 云端任务入口的悬浮文字有全局 / 本工程数量；卡片、详情和后台开窗仍沿原路径；真实服务扣费另按既有流程验收。
