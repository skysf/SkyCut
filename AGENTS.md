# AGENTS.md — 统一协作入口与文档索引

本文件是本仓库**唯一的代理协作规则入口**，适用于 Claude、Codex、Kimi、Gemini、
Copilot 等所有 AI 代理、它们委派的子代理，以及人类贡献者。作用域覆盖整个仓库。

这里只保留两类内容：**必须全局遵守的规则**和**按任务查文档的索引**。设计细节、
历史事故、实施过程和操作步骤分别放在 `docs/` 的对应目录，不在这里展开。

## 唯一入口约定

- 所有代理开始工作时都只读取本文件作为仓库规则；委派子代理时也必须传递本文件的
  约束，不能为不同模型维护不同版本。
- 不得新建 `CLAUDE.md`、`CODEX.md`、`KIMI.md`、`GEMINI.md`、嵌套
  `AGENTS.md`、`.cursorrules`、`copilot-instructions.md` 等第二套规则入口。
- 工具自己的本地配置只能存权限、Hook 等运行设置，不得复制或改写项目规则。
- 新的细节规则应写进 `docs/architecture/` 等对应文档，并从本文件增加链接；不要把
  本文件重新堆成实施记录。

## 开始任务前

1. 先读下方“全局规则”。
2. 在“按修改范围选必读文档”中定位任务，动代码前读完对应文档。
3. 计划文档记录目标和背景；已实施功能的真实状态优先看实施报告、现有代码和检查
   结果。若三者冲突，不要静默猜测，应在本次改动中同步过期文档或明确报告冲突。
4. 修改后、推之前跑 `scripts/check-local.sh <和改动直接相关的检查>`：全部扫描守卫 + 点名的那几项，一项一项跑，
   自动换成原生 arm64、用和 CI 一样的 `/bin/bash`。完整的 `scripts/check-all.sh` 交给 CI：每个 PR 上 5 台 runner
   全跑，绿了才合（2026-11-04 用户定：本地全跑满载十几到三十分钟、笔记本烫；每一项照样在 CI 上跑，步骤一样不少）。

## 全局规则（必须遵守）

### Bug 修复、守卫与文档

1. 修复任何 bug 后，必须按
   [Bugfix 模板](docs/bugfixes/TEMPLATE.md) 在 `docs/bugfixes/` 新增
   `YYYY-MM-DD-<slug>.md`，完整记录“症状 → 根因 → 修复 → 验证 → 教训”，并在
   本文件的 Bug 修复案例索引补一行。
2. 自动化能覆盖的 bug，必须在对应 check 中加入一条修复前会失败的回归守卫，并做
   **反向验证**：临时撤掉修复，确认守卫确实变红，再恢复修复。没红过的守卫不能算
   验证。
3. 自动化够不着的行为（例如手势手感、TCC、系统 UI）必须写入对应架构文档的人工
   回归清单，并在发版前实机验证。
4. 案例中形成的长期约束（“这里只能这样做”）必须另写或更新
   `docs/architecture/` 文档，再由案例链接过去，不能只留在一次性事故记录里。
5. 其他新文档归入 `docs/` 对应分类，并在本文件补索引；能更新既有文档时不要另造
   一份相互竞争的说明。**补索引不是礼节，是必需**：别的代理只读本文件，索引里
   没有的文档它们永远不会打开 —— 由 `checks/docs-index-drift.sh` 钉住（漏一份
   或留一条死链就红）。

### 合并与分支（2026-09-29 用户定）

- 一个 PR 只做一件事、尽量小；CI 的汇总 job `check-all` 绿了就**马上合并**（`gh pr merge N --merge`，绝不 squash），
  不攒着等人看。任务说明里写了由谁合并的，照任务说明。下一件事从合并后的最新 main 开分支，别在旧分支上叠。
- 合并后删分支：`gh pr view N --json state` 是 MERGED 之后才 `git push origin --delete <分支>`。不用 `--delete-branch`：它会把检出着
  这条分支的 worktree 整个删掉（2026-11-05）。merge 报错时先看 state，别接着删分支（2026-11-11 #394 就这样被 GitHub 关掉过）。
  本地的 worktree 和分支照任务说明收尾；没写就留着，别删自己正开着的 worktree。
- 「绿」指 CI 的结论，本地跑过不算。红了先看是不是已知的偶发（性能 ratchet、`check-audio-fade` 第 7b 组，认法见对应
  文档），是就 `gh run rerun --failed`，不是就修；不许带红合。
- 合掉一个之后别的 PR 变 DIRTY（常见于本文件的索引行相邻）：把新 main 合进那条分支、两边都留、推上去等 CI 绿再合。
- 合进 main 不等于发给用户：发版（打 tag、`gh release create`、DMG）仍然另外拍板。
- 开 PR 前必须重新 `git fetch origin`，把当时最新的 `origin/main` 合入当前分支，逐处处理冲突并重新验证；不能只沿用开始任务时的 main，尤其用户在另一个窗口并行优化时，不得覆盖或遗漏那些已合并的改动。

### 官网本地预览与部署成本（2026-11-04 用户定）

- 官网开发与验收只在本地预览：在 `website/` 运行 `npm run dev`，使用本机地址查看；文案、配色、布局、交互调整不发布到 Vercel。
- 禁止为了预览运行 `vercel deploy`、`vercel --prod` 或云端 Redeploy，也不创建、刷新云端 Preview 部署。功能分支 push、PR 创建和更新均不得触发 Vercel 构建。
- 只有最终 PR 的 CI 通过并合并到 `main` 后，才允许由合并后的 `main` 提交触发官网部署；不从本地未合并工作区上传，不用反复部署替代本地验收。
- 本地命令、API 验证和部署分支配置见 [SkyCut 官网](docs/architecture/skycut-website.md)。官网上线与 Mac App 发版分别管理。

### 打包与签名（2026-10-03 起）

- DMG 使用脚本生成的双语 Retina 安装引导背景和固定 Finder 布局，不带旧 txt；正常打包不自动控制 Finder。
  生成 / 模板更新和真挂载验收见 [构建与打包](docs/build/build-and-packaging.md)「DMG 安装窗口」
  （含 macOS 26.5.2 仍沿用用户路径栏 / 状态栏偏好的实测限制；不能把模板字段关闭当成实机已隐藏）。

- 装给用户的包（正式版、测试版）和发版的包，只用固定的签名身份签：`scripts/build-app.sh`、`build-beta-app.sh` 自动经
  `scripts/signing/sign-app.sh` 签。它打出「⚠️ 没有发布用的签名身份，退回 ad-hoc」的包**不许装给用户、不许发版**：ad-hoc 的
  每个版本在 macOS 眼里都是另一个 App，录屏、麦克风、下载文件夹、钥匙串的授权全部作废，录屏那条拨开关都救不回来。
- 签名身份（私钥）在仓库外的 `~/.config/srtflow/signing/`，**永不重建**：换一把证书 = 所有用户再授权一次（`sign-app.sh` 认
  `packaging/signing-identity.sha1` 钉着的那把，对不上就拒签）。换机器把整个目录拷过去；**这个目录必须有备份**（用户的事，
  见到它不在就停下来告诉用户，别去跑 `create-identity.sh`）。细节见 [签名与系统权限](docs/architecture/code-signing-and-permissions.md)。

### 名字（2026-10-18 起）

- 产品名 **SkyCut**（原名 SrtFlow）。仓库里、`docs/` 里出现的 SrtFlow 指的就是它：代码名沿用 SrtFlow（模块、目录、类型名）。
- 给用户和 AI 看的文字写 SkyCut；bundle id、UTType、数据文件夹、UserDefaults 的键、钥匙串、AI 通道、环境变量这些**身份类的名字
  永远沿用 SrtFlow**，改了用户的授权、设置和数据就丢了。新加同类东西照旧用老前缀。由 `checks/product-name.sh` 钉住，
  细节见 [产品名与代码名](docs/architecture/product-name.md)。
- **Sky Studio 的 Google Cloud 项目只有一个**：项目 ID `gen-lang-client-0288826272` 就是控制台里显示名为 `1st-gemini-project` 的那个
  （用户 2026-11-10 确认；这个问题已经被问过很多次）。Sky Studio 生产的 Vertex / Gemini 调用、凭据里的 `project_id`、账单和配额说的
  都是它。文档、日志里看到这两个名字，**不要再问用户是不是同一个项目**。

### 语言

- GitHub 对外可见文字一律使用英文：commit message、分支名、PR、issue、release，
  以及 Actions 的 workflow、job、step 名称与正文。
- `README.md` 保持中英双语；仓库内部 `docs/`、本文件和代码注释维持现状使用中文。

### 工程原则

1. **轻量化优先。** 优先复用 macOS 原生能力（AVFoundation、AppKit、SwiftUI），
   不随意引入第三方依赖。需要自写合成器、自建文件管理等重量级方案时，先征得用户
   同意。既有产品决策：界面上的文件管理交给 Finder（AI 只在用户开口时帮忙整理点名文件夹里的文件；请求批准模式下删除先问，全部权限直接执行并通知，均进废纸篓，
   见 [MCP 方案](docs/plans/2026-09-27-mcp.md) 第 23、24 条）；混合模式不为此自建 Metal 合成器。
2. **复用优先，抽象克制。** 同一模式出现第二次时，按仓库现有粒度抽成共享组件；
   没有真实第二用例时不提前制造泛型和框架。参考：`ResizableFrameBox`、
   `LenientCodableEnum`、`liveApply` / `perform`。
3. **代码要模块化，单文件不许太长**（2026-09-24 用户定的规范，细则见
   [写代码的规范](docs/architecture/coding-standards.md)，**写代码前必读**）：
   - 一个文件只管一件事，新类型、新功能默认开新文件；文件开头写清它管什么、不管什么。
   - **单文件目标 ≤ 400 行，超过 600 行就红**（Swift / shell / Python，测试和检查脚本
     也算）：`checks/source-file-size.sh`。超了就拆，不许靠删注释、挤行凑数。
   - 当时就超了的老文件登记在 `checks/source-file-size-baseline.txt`，**行数只许降不许涨**：
     往里加代码就在同一次改动里拆出等量的行；变短了跑 `checks/source-file-size.sh --update`
     把基线改小。可以顺手拆出职责独立的部分，但不要借题做一次性大重构。
   - 拆的时候优先抽出**有名字的顶层类型**（纯值、接口窄、自检能单独编），不要给
     `VideoEditProject`、`TimelineState` 这种大对象再开一个只有 extension 的文件。

### 验证纪律

- 不得把“命令没执行到”“依赖缺失后跳过”或“只测了纯函数、生产路径没接上”报告为
  通过；检查脚本必须以非零退出码暴露失败。
- `scripts/check-all.sh` 是 CI 的统一总入口（本地也能全跑，不再要求）。GUI 冒烟不在其中，涉及真实窗口、
  系统权限或手势时，另按 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) 执行。
- 修改 shell 脚本前，先读
  [构建版本与 shell 陷阱](docs/bugfixes/2026-08-06-build-version-and-shell-traps.md)。
- **推之前跑 `scripts/check-local.sh`**（它先跑 `scripts/check-guards.sh`：全部 `checks/*.sh` 扫描守卫 + `scripts/check-mcp.sh --scans-only` 编译之前的扫描，原生 arm64 约一分钟、不编译；
  再跑你点名的检查）。**别在 Rosetta 下、别用 PATH 上的 `bash` 跑检查**：Rosetta 下全部守卫要 6–7 分钟、笔记本烫；PATH 上的 bash 是
  Homebrew 的 5.x，和 CI 的 `/bin/bash` 3.2 不是一个解析器（2026-11-05 之前用户的 M1 上它还是 Intel 版、连 Claude Code 的命令 shell
  都被它带进 Rosetta，[本地怎么跑检查](docs/build/build-and-packaging.md)）。搬代码 / 改名之后尤其要跑：守卫按文件名找
  接线，挑着跑几条漏掉的那条只会在 CI 上红（[PR #132 首跑](docs/bugfixes/2026-10-01-pr132-first-ci-run-guard-in-moved-insert.md)，
  同一个坑第三次）。

## 文档目录职责

| 目录 | 放什么 | 不放什么 |
| --- | --- | --- |
| `docs/architecture/` | 已生效的长期约束、数据合同、回归清单 | 一次性修复流水账 |
| `docs/bugfixes/` | 可复盘的 bug 案例与验证证据 | 尚未实施的设想 |
| `docs/plans/` | 功能方案、产品决策、阶段计划 | 冒充当前实施状态 |
| `docs/reports/` | 实施进度、实测结果、偏差和阻塞 | 通用架构规则 |
| `docs/build/` | 构建、打包和产物验收 | 功能设计 |
| `docs/testing/` | 测试与人工冒烟流程 | 某一次 bug 的完整经过 |

## 按修改范围选必读文档

先在左列找到你要改的东西（类型名、文件名、函数名都能搜到），动代码前读完右列的文档。括号里只是最容易踩的一两条，完整的约束在文档里；这张表只管把人带到文档，别往里写摘要。

| 修改范围 | 动手前必读 |
| --- | --- |
| 官网 `website/`、本地网页预览、官网 Vercel 配置与部署、首屏 3D 场景（`website/src/scene*.js`、烤好的静图 `hero-still-*`、`main.js` 里加载场景的那一段） | [SkyCut 官网](docs/architecture/skycut-website.md)（开发只在本地预览，合并 `main` 后才部署；改了场景外观要 `npm run build:hero-still` 重烤并提交指纹；不加 npm 依赖）、[官网首页在手机和 iPad 上版面全乱](docs/bugfixes/2026-11-11-website-phone-layout-lost-to-stylesheet-order.md)、[官网小字：手机上小于 12 px、对比度不够、标题跳级](docs/bugfixes/2026-11-11-website-small-text-contrast-headings-font-shift.md) |
| 构建、打包、版本、授权、shell、CI、签名（`scripts/signing/`） | [签名与系统权限](docs/architecture/code-signing-and-permissions.md)（打包脚本只经 `sign-app.sh` 签；证书永不重建；退回 ad-hoc 的包不许发版）、[构建与打包](docs/build/build-and-packaging.md)、[构建版本与 shell 陷阱](docs/bugfixes/2026-08-06-build-version-and-shell-traps.md)、[包内授权声明过期](docs/bugfixes/2026-08-06-stale-bundled-license-notice.md)、[CI 首跑与吞错](docs/bugfixes/2026-08-08-ci-first-run-sdk-and-swallowed-errors.md) |
| App、小程序、MCP 服务器叫什么（SkyCut / `skycut-mcp` / `skycut`）；新加身份类的字符串（bundle id、UTType、数据文件夹、UserDefaults 的键、钥匙串、AI 通道、环境变量）；界面和给 AI 的话里写产品名 | [产品名与代码名](docs/architecture/product-name.md)（看得见的写 SkyCut；身份类的名字沿用 SrtFlow，新加的同类照旧用老前缀）、[改名方案](docs/plans/2026-10-18-rename-to-skycut.md) |
| 工程存盘、格式版本、素材路径、自动保存、重建预览时开素材（`MediaAssetCache`）、新建 / 打开工程（切工程时清掉上一个的运行时状态、播放头归零） | [工程文件与素材重链接](docs/architecture/video-edit-project-file.md)（素材只开一次、按路径 + 文件身份认；换完整份时间线就要 `scheduleRebuild()`）、[新建工程后播放头停在上一个工程的位置](docs/bugfixes/2026-09-29-new-project-keeps-old-playhead.md)、[工程文件生命周期](docs/bugfixes/2026-08-03-project-file-lifecycle.md)、[运行期素材重链接](docs/bugfixes/2026-08-08-runtime-media-relink.md)、[松手重建预览把每个素材重开一遍](docs/bugfixes/2026-09-25-rebuild-reopens-every-asset.md) |
| 哪个工程：`OpenProjects`（`primary` / `others` / `focused` / `all`）、`VideoEditProject` 的建法、短 id（p1…）、工程代号（`DocumentGenerations`）、每个工程的撤销管理器、退出问每个工程、录屏落回开录的工程、工程窗口（`ProjectWindowController`、`ProjectTeardown`）、导出器归谁（`exporter.belongs(to:)`）；任何新代码要用到工程时 | [开着的工程（OpenProjects）](docs/architecture/open-projects.md)（工程只由注册表建；要工程时找注册表或调用方给的那一个，别假设只有一个；撤销不许退到键窗口的）、[AI 多开方案](docs/plans/2026-10-17-multi-project-ai-editing.md) |
| 时间线捏合、滚动、移动、裁切（`TimelineTrim`：多段一起裁、链接伙伴一起裁）、吸附与对齐线、框选、点击落点（`VideoEditProject.seekFromTimeline`）、扫帧预览、拖动 / 拉框进行中的视图状态（`TimelineDragBox`）、缩放的锚点与纵向缩放 | [时间线缩放](docs/architecture/timeline-pinch-zoom.md)（锚点从时间线自己的滚动几何量，别按坐标 hitTest 找滚动视图）、[捏合放大时鼠标底下的内容跑掉](docs/bugfixes/2026-09-26-pinch-zoom-anchor-never-applied.md)、[时间线拖动手势](docs/architecture/timeline-drag-gestures.md)（会话不进时间线的 `@State`；裁的算法只有 `TimelineTrim` 一份）、[时间线拖动卡顿与对齐](docs/bugfixes/2026-08-09-timeline-clip-drag-lag-and-alignment.md)、[拖文件进轨道](docs/plans/2026-09-22-media-file-drop.md)、[裁切不跟链接](docs/bugfixes/2026-09-25-trim-ignores-linked-clips.md)、[拖块 / 拉框每一拍整条时间线重算](docs/bugfixes/2026-09-25-drag-session-in-timeline-state.md) |
| 联动（`TimelineLinkage` / `TimelineLinkageLanding`、`perform(deletesContent:)`、拖动计划的 `host`）：删 / 挪 / 裁 / 变速 / 定格之后别的轨跟不跟、字幕句怎么跟（`LinkageCueFollow`）、AI 工具结果里的 `linkage` | [联动](docs/architecture/timeline-linkage.md)（跟着画面走不跟 id；规则只在 `perform` / `liveApply` 收尾一处；字幕句按词两头各自换算、说的话剩不到一半就删）、[方案](docs/plans/2026-10-02-timeline-linkage.md)、[拖动手势 §3.7](docs/architecture/timeline-drag-gestures.md)、[联动把字幕当一整块挪](docs/bugfixes/2026-10-15-linkage-moves-subtitles-as-a-block.md)、[裁掉说的话的字幕留在原地、和下一句叠](docs/bugfixes/2026-10-15-linkage-deletes-subtitles-whose-speech-was-trimmed.md)、[换源之后压在上面的东西被挪了一个偏移](docs/bugfixes/2026-10-15-linkage-follows-source-shift-after-swap.md) |
| 工具栏右边那组开关（磁吸 / 吸附 / 联动 / 播放跟随）、剪辑页字幕列表的跟随按钮、播放时时间线跟不跟播放头（`PlayheadFollow`、`TimelinePlayheadLines.followPlayhead`）、冒烟 / 性能场景起手的开关状态、新加一个要记住的开关、磁吸什么时候排 V1（`MainMagnet`、`state.mainMagnet`、`setMagnet`） | [剪辑页上记住的开关](docs/architecture/editor-remembered-toggles.md)（默认值和记忆只有 `EditorToggles` 一份；脚本驱动时永远默认值、不落盘；磁吸跟着工程走、只在改到 V1 的排布时排）、[磁吸开着时改一条音量曲线就合上 V1 的缝](docs/bugfixes/2026-10-02-magnet-closes-v1-gaps-on-any-edit.md)、[联动](docs/architecture/timeline-linkage.md)、[拖动手势 §4.5 / §5](docs/architecture/timeline-drag-gestures.md)、[预览性能 ratchet 第十二节](docs/architecture/preview-perf-ratchet.md) |
| 插进两条轨之间（缝拉开）、整条轨上下换位置、轨道头的拖动（换位 / 下边缘调行高） | [插入缝与整轨换位方案](docs/plans/2026-09-24-track-insert-and-reorder.md)、[拖动手势 §5h / §5i](docs/architecture/timeline-drag-gestures.md)、[视频轨对等化](docs/architecture/video-tracks.md)、[预览性能 ratchet](docs/architecture/preview-perf-ratchet.md)（轨道头的行每跳不重算，别往它的输入里塞闭包） |
| 顶部工作台、图标按钮、更多工具、统一设置窗口、MCP 的 get_settings / set_settings、打开全部权限时的说明（`FullAccessConsentSheet`）和长期授权的记 / 撤 | [顶部工作台与统一设置](docs/architecture/workbench-and-settings.md)（三个设置入口同一个窗口、复用现有 Store；设置工具先全验再写、不碰密钥；选全部权限先弹说明、同意才写）、[声音库第八节第 9 条](docs/architecture/voice-library.md) |
| 界面主题（森林色 / 经典色）、主题设置与 MCP 的 theme、窗口背景与轨道配色、AppKit 自建的窗口 / 面板（浅 / 深跟不跟主题）、切主题 / 系统切深浅色时开着的窗口跟不跟 | [界面主题](docs/architecture/app-themes.md)（浅 / 深只有 `AppThemePalette.colorScheme` 一条；交给 SwiftUI 的永远是明确的浅 / 深、不交 nil；不设 `NSApp.appearance`）、[系统深色时按钮提示深底深字](docs/bugfixes/2026-11-11-tooltip-dark-on-dark-in-forest-theme.md)、[森林色切经典色，开着的窗口只变一半](docs/bugfixes/2026-11-11-theme-switch-leaves-windows-half-light.md) |
| 编辑器分栏、预览区 / 时间线的行结构与最小高度 | [压缩预览区时播放条压到工具栏上](docs/bugfixes/2026-08-12-preview-transport-row-overlap.md) |
| 预览变换、叠化、上层视频轨、导出滤镜、预览合成往合成轨上接东西 | [预览自由变换](docs/architecture/preview-free-transform.md)（「一份时间账」：只从末尾接、合成完裁到总长，多一格就黑屏；切片表按格子去重、换格子别改成四舍五入）、[AI 用 look 看转场和成片对不上](docs/bugfixes/2026-10-14-look-transitions-differ-from-export.md)、[加了几段音效，预览整个黑屏](docs/bugfixes/2026-09-27-preview-black-after-audio-tick-pushed-past-end.md)、[叠化 + 关键帧之后预览全黑](docs/bugfixes/2026-09-29-preview-black-slice-boundaries-straddle-a-tick.md)、[视频轨对等化](docs/architecture/video-tracks.md)、[关键帧动画](docs/architecture/keyframe-animation.md)、[Transform 复审](docs/bugfixes/2026-08-04-transform-review.md)、[导出预渲染复审](docs/bugfixes/2026-08-05-export-prerender-review.md) |
| 从 Finder 拖文件 / ⌘V 粘贴文件进时间线、导入落点 | [拖文件进轨道](docs/plans/2026-09-22-media-file-drop.md)、[滤镜 / 音频库 / 转场卡片拖不进时间线](docs/bugfixes/2026-09-23-in-app-drops-swallowed-by-file-underlay.md)、[外部拖入被内层落点独占（结论已更正）](docs/bugfixes/2026-09-23-timeline-file-drop-claimed-by-inner-drop-region.md)、[拖动手势 §5e-2](docs/architecture/timeline-drag-gestures.md)（主轨保序、唯一落点）、[视频轨对等化](docs/architecture/video-tracks.md) |
| 时间线上的复制 / 剪切 / 粘贴（⌘C ⌘X ⌘V、编辑菜单、右键菜单）、剪贴板类型、粘贴落点、从旧段构造新段（分割 / 复制，别漏字段）、分割之后的链接组（`LinkRegrouping.split`） | [时间线上的复制 / 剪切 / 粘贴](docs/architecture/timeline-clipboard.md)（剪贴板只有一套、不写纯文本；换新身份走编码往返；分割都走 `LinkRegrouping.split`）、[删掉分割出来的一块，整条素材连声音全没了](docs/bugfixes/2026-09-28-split-links-every-piece-together.md)、[方案](docs/plans/2026-09-26-timeline-clipboard-and-zoom.md)、[分割丢了隐藏和音频库的键](docs/bugfixes/2026-09-26-split-drops-hidden-and-library-key.md)、[拖文件进轨道](docs/plans/2026-09-22-media-file-drop.md) |
| 时间线上的任何拖放落点（`.onDrop`：文件 / 滤镜 / 音频库 / 转场卡片）、新的自定义拖放 / 剪贴板类型 | [拖动手势 §5e-2](docs/architecture/timeline-drag-gestures.md)（整条时间线只许一个 `.onDrop`；自定义类型必须在 Info.plist 声明；不能放回 `.forbidden`、不回 `.cancel`）、[转场卡片拖到接缝上没反应](docs/bugfixes/2026-09-23-transition-drop-cancel-ends-session.md)、[滤镜 / 音频库 / 转场卡片拖不进时间线](docs/bugfixes/2026-09-23-in-app-drops-swallowed-by-file-underlay.md)、[滤镜卡片、音频库素材拖不进时间线（类型没声明）](docs/bugfixes/2026-09-23-custom-drag-types-not-declared.md)、[GUI 冒烟流程](docs/testing/gui-smoke-testing.md)（落点路由探针） |
| 轨道模型、时间线行结构、轨道行高、轨道配色、预览点选 | [视频轨对等化](docs/architecture/video-tracks.md)、[工程文件与素材重链接](docs/architecture/video-edit-project-file.md) |
| 段的显隐（V / 眼睛）、隐藏段进不进预览和成片，文字 / 形状 / 滤镜段的隐藏（`rendered*` 清单） | [段的显隐](docs/architecture/clip-visibility.md)、[视频轨对等化](docs/architecture/video-tracks.md)、[上层轨藏起来的段，成片里画面还在](docs/bugfixes/2026-09-26-hidden-upper-clip-still-exported.md) |
| 画面渐入渐出、alpha 斜坡、转场仲裁 | [画面渐入渐出](docs/architecture/video-fades.md)、[声音：音量与渐入渐出](docs/architecture/audio-fades.md) |
| 主轨转场的容量、可用判定、借余料、首尾帧定格补足 | [主轨转场：借余料与定格补足](docs/architecture/transition-handles.md)、[磁吸关着时转场预览有、成片没有](docs/bugfixes/2026-09-20-transition-preview-export-divergence.md) |
| 画面段的入场 / 出场动画、预设效果、预渲染路由 | [画面段的入场 / 出场动画](docs/architecture/clip-animation.md)、[画面渐入渐出](docs/architecture/video-fades.md)、[关键帧动画](docs/architecture/keyframe-animation.md) |
| 画面文字、字体、Core Text 渲染、文字动画、逐帧导出、预览上文字的选中框和可点范围、文字行（行号进模型、上下换行）、数字的等待、老虎机位数不同的两头（`NumberOdometer`） | [画面文字](docs/architecture/text-overlays.md)（把手的可点范围写在 `.offset` 之前；行号进模型、预览与导出同一份叠放序；导出时序列末尾多渲两帧、几段左闭右开）、[带入场动画的字在成片里闪没一帧](docs/bugfixes/2026-10-14-text-blinks-at-animation-seam.md)、[老虎机数字 365 → 90 停在「090」](docs/bugfixes/2026-09-25-odometer-leading-zero.md)、[主字体里没有的字画成乱码](docs/bugfixes/2026-09-29-text-fallback-glyphs-drawn-with-main-font.md)、[拖动手势 §5j](docs/architecture/timeline-drag-gestures.md)、[预览里拖文字，一按下去变成旋转](docs/bugfixes/2026-09-24-text-rotate-handle-hit-area-at-center.md) |
| 滤镜调色、LUT、预览图层滤镜、导出 `lut3d` 段、滤镜段的选中（多选）、任何滤镜下纯黑的地方（空档、黑场、黑底字卡） | [滤镜](docs/architecture/filters.md)（纯黑不抬：`FilterLUT.holdingBlack`）、[滤镜把纯黑抬成灰](docs/bugfixes/2026-10-14-filters-lift-pure-black.md) |
| 画面上的形状（线条 / 长方形 / 正方形 / 圆 / 圆弧）：种类、几何、怎么画（`ShapeOutline`、`ShapePreviewDrawing`、`ShapePNGRenderer`、`ShapeOverlayCanvas`）、入场 / 出场动画（`ShapeAnimation` / `ShapeAnimator`、导出切段 `ShapeOverlayExport`、形状和文字共用的 `OverlayExportFile`）、`set_shape` | [画面上的形状](docs/architecture/shapes.md)（画什么只有 `ShapeOutline.drawing` 一份，预览和导出同一条路径；什么都没露出来时给空路径）、[导出的线条两头各比预览长半个线宽](docs/bugfixes/2026-10-03-exported-lines-longer-than-preview.md)、[画面文字](docs/architecture/text-overlays.md)（只逐帧渲动画进行中的那段）、[盖一块：模糊 / 马赛克](docs/architecture/cover-blur-mosaic.md)（模糊 / 马赛克也是形状的一种） |
| 盖一块（模糊 / 马赛克，`ShapeKind.blur` / `.mosaic`）、预览的第二层播放器（`CoverPreviewLayer`）、导出里的 `gblur` / `pixelize`（`VideoEditCoverExport`）、`set_shape` 的 blur / mosaic、`look text_scan` 给的 `cover`（`AICoverBox`）、遮水印 / 遮旧字幕 | [盖一块：模糊 / 马赛克](docs/architecture/cover-blur-mosaic.md)（不跟着片段走；落点在调色之后、形状之前；预览的蒙版和滤镜别挂同一层）、[滤镜](docs/architecture/filters.md)、[预览自由变换](docs/architecture/preview-free-transform.md)、[AI 接口（MCP）第 38 条](docs/architecture/ai-control-mcp.md)、[预览性能 ratchet](docs/architecture/preview-perf-ratchet.md)（没有盖一块时第二层不建） |
| 工程帧率、关键帧容差、AI 读写关键帧（`edit_clip keyframes` 策略、`relative` 时间）、关键帧的缓动（`Keyframe.easing`、`KeyframeEasing`、预览按帧加密 `KeyframeSliceTimes`） | [工程帧率](docs/architecture/project-frame-rate.md)、[关键帧动画](docs/architecture/keyframe-animation.md)（「AI 接口」「缓动」：报给 AI 的关键帧永远在片段范围里；linear 逐位一致）、[限幅 + 缓动方案](docs/plans/2026-09-30-export-limiter-and-easing.md) |
| 音量、dB、渐入渐出、增益表（`AudioGainTable.swift`）、音频引擎（`Sources/SrtFlow/AudioEngine/`：配置、环、喂样、渲染块、离线渲染）、引擎的图什么时候开着（空闲停图 / 再起 `AudioEngineIdlePolicy` / `AudioEngineIdleKeeper`、`suspend` / `wake` / `recoverIfNeeded`、待钉的锚点 `PlaybackAnchor`、用户在不在 `AppUserPresence`、换工程收引擎 `unloadPreview`、播到头收尾 `PlayerClock.finishAtEnd` / `PlaybackAudioSource.duration`、`AudioRenderClock.hasTicked`）、读素材 / 重采样（`AudioSegmentReader`）、预览合成里没有音轨（配乐比画面长要垫黑底） | [声音：音量与渐入渐出](docs/architecture/audio-fades.md)、[成片的声音](docs/architecture/export-audio-mixdown.md)、[音频引擎](docs/architecture/audio-engine.md)（「结构没变」= 轨 + 段的身份 + 段的几何（`Segment.Structure`）；图只在马上要出声时开着：停着 2 分钟没人用就停（用户定的数，改它先问用户）、停图只许经 `AudioEngineIdleKeeper`；播到头由声音主时钟按总长自己收尾）、[预览的音频引擎一直开着，Mac 不睡](docs/bugfixes/2026-11-11-preview-audio-engine-never-idles.md)、[从 40 秒起一直有沙沙声](docs/bugfixes/2026-10-01-resampler-reset-every-chunk.md)、[配乐比画面长的工程播到画面结尾就停住](docs/bugfixes/2026-10-01-preview-item-shorter-than-timeline-without-audio-tracks.md)、[挪了一段音频，画面挪了、声音还在原地](docs/bugfixes/2026-10-06-audio-engine-replace-keeps-old-segment-positions.md)、[音频引擎方案](docs/plans/2026-10-01-audio-engine.md) |
| 声音场景（喇叭 / 室内 / 室外）、引擎渲染块里的效果链（`SceneBox` / `mixScene`）、余音越过段尾、检查器的声音那一块 | [声音场景](docs/architecture/sound-scenes.md)（效果在段增益之后、推子之前；加 / 去掉场景重开流）、[推子与电平表](docs/architecture/audio-mixer.md)、[成片的声音](docs/architecture/export-audio-mixdown.md)、[声音场景方案](docs/plans/2026-09-24-sound-scenes.md) |
| 导出的声音、离线混音（`ExportAudioMixdown`）、导出图里接音轨的地方、限幅器（`ExportPeakLimiter`）、整段响度（`ExportLoudnessMeter`、`AudioKWeighting`）、面板和 `get_job` 里的响度 / 峰值 | [成片的声音](docs/architecture/export-audio-mixdown.md)（导出图里不许有声音滤镜；成片 = 预览那个音频引擎离线渲出来的；限幅上限 −1 dBFS、响度只报不归一）、[限幅 + 缓动方案](docs/plans/2026-09-30-export-limiter-and-easing.md)、[成片的声音过了 0 dBFS 交给 AAC](docs/bugfixes/2026-09-30-export-mix-over-0dbfs-into-aac.md)、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md)、[主轨转场处预览的声音掉下去一截](docs/bugfixes/2026-09-24-preview-mix-ignores-transition-expansion.md) |
| 优化媒体（`Sources/SrtFlow/OptimizedMedia/`：`MediaInfo.keyframeInterval`、协调者 `OptimizedMediaCoordinator`、换源表）、builder 插画面（`CompositionClipInsert`）、预览重建传 `proxies` 的那一处、预览工具条的「优化媒体 / 原片」（`OptimizedMediaMenu`）、`MediaReadQueue.proxy`、设置里的「优化媒体」一节（`OptimizedMediaCacheSettings` / `OptimizedMediaSettingsSection`）、启动时的过期扫描、转不了的提示 | [优化媒体](docs/architecture/optimized-media.md)（换源只换画面不动时间账、只在停着时换；成片 / 预渲染 / AI 看永远原片；清空之后紧跟 `reset()` + `scheduleRebuild()`；改参数要 +1 版本）、[方案](docs/plans/2026-10-01-video-optimized-media.md)、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md)、[预览性能 ratchet 第十四节](docs/architecture/preview-perf-ratchet.md) |
| 波形显示、深度缩放（缩放上限、标尺刻度、缩略图、超宽内容的绘制） | [波形与深度缩放](docs/architecture/audio-waveform.md)、[时间线缩放](docs/architecture/timeline-pinch-zoom.md)、[拖动手势 §5](docs/architecture/timeline-drag-gestures.md)、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md) |
| `AVAssetReader` 读采样（`copyNextSampleBuffer`），以及在 async 函数 / `Task` 里做任何会卡住线程的事（等信号量、同步 IO、等子进程） | [阻塞的媒体读取](docs/architecture/blocking-media-reads.md)（阻塞的读取走 `MediaReadQueue`；`AudioWindowReader.extract` 只许 `SubtitleGen/` 调，别处要 16 kHz 音频走 `QueuedAudioWindow`）、[打开工程后缩略图和波形全空](docs/bugfixes/2026-09-23-waveform-decode-deadlocks-thread-pool.md) |
| 引擎定位与短探测（`FFmpegRuntime` / `FFmpegRuntimeProbe` / `MediaToolchain`） | [阻塞的媒体读取「引擎启动探测」](docs/architecture/blocking-media-reads.md)（共享截止时间、父进程独占回收、单次定位任务）、[后台引擎短探测无限等待且重复启动](docs/bugfixes/2026-11-04-engine-probe-hangs.md) |
| 音量曲线（段上的音量自动化）、轨道推子 / 总推子、电平表（引擎的槽 `MeterSlot`） | [音量曲线](docs/architecture/audio-volume-curve.md)、[推子与电平表](docs/architecture/audio-mixer.md)（峰值从渲染块来、总表从混音器出口来）、[播放中按 Return，App 在音频线程上崩溃](docs/bugfixes/2026-09-26-meter-crash-on-go-to-start.md)、[声音：音量与渐入渐出](docs/architecture/audio-fades.md)、[声音编辑方案](docs/plans/2026-09-23-audio-mixing.md)、[一条轨上换了音频格式就没声音、预览卡住](docs/bugfixes/2026-09-23-meter-tap-dies-on-audio-format-change.md) |
| Inspector 数值框、拖调、Transform 写入、检查器里的滑杆行（`labelledSlider` / `InspectorSliderRow`）、「Shows for」、Transform 区的关键帧 ‹ ◇ › 和「曲线」菜单 | [Inspector 数值框](docs/architecture/inspector-scrub-number-field.md)（打字提交要立刻 `endLiveEdit`）、[关键帧动画「交互约定」](docs/architecture/keyframe-animation.md) |
| 往检查器里加任何一行（标题 + 控件、下拉、滑杆行） | [检查器的排版](docs/architecture/inspector-layout.md)（一行不许比窄栏宽；菜单 Picker 不许 `.fixedSize()`）、[选了声音场景却看不见选的是哪个](docs/bugfixes/2026-09-24-sound-scene-row-widens-inspector.md) |
| 定格、静帧、图片转视频、在最后一帧里定格（不到一帧的右半）、透明 PNG（`StillAlphaNaming`、`isAlphaStill`、预乘的 ProRes 4444 + 遮罩） | [定格](docs/architecture/freeze-frame.md)（不到一帧的右半拿掉；对着时间的断言只和同一次运行里同一种活比）、[透明 PNG 放到上层轨成了黑方块](docs/bugfixes/2026-10-03-png-transparency-lost.md)、[在最后一帧上定格，静帧后面剩一截原片](docs/bugfixes/2026-09-29-freeze-leaves-sliver-after-still.md)、[静帧自检的耗时断言在 CI 上误报](docs/bugfixes/2026-11-11-still-clip-encode-timing-flake.md)、[定格方案](docs/plans/2026-08-08-freeze-frame.md)、[静帧逐帧解码](docs/bugfixes/2026-08-08-still-clip-decode-per-frame.md) |
| 原生录屏、恢复、退出、导入、录屏的系统授权（`ScreenRecordingPermissions`、`ScreenCapturePermissionRepair`）、AI 录屏（`record_screen`；`ScreenRecordingSession` 的 AI 会话、`ScreenRecordingFileCommit`、`ScreenRecordingOptions.preset`、`AIScreenRecording*` / `AIScreenSource*`） | [录屏生命周期](docs/architecture/screen-recording-lifecycle.md)（AI 起的会话走同一条流程、从不覆盖、入轨包一步撤销）、[让 AI 录屏的方案](docs/plans/2026-10-03-screen-recording-mcp.md)、[录屏中 AI 改帧率：静默不改还回成功](docs/bugfixes/2026-10-03-set-canvas-fps-ignored-while-recording.md)、[签名与系统权限](docs/architecture/code-signing-and-permissions.md)（授权记录钉着签名；文案不写「关掉再打开」）、[录屏开关开着、自定义区域还是说没权限](docs/bugfixes/2026-10-03-screen-recording-permission-stale-after-update.md)、[实施报告](docs/reports/2026-08-06-native-screen-recording-implementation-report.md)（方案中的旧结论不得覆盖它）、[录屏 Phase 2–4 复审](docs/bugfixes/2026-08-07-screen-recording-phase2-4-review.md)、[录屏静止期尾部黑屏](docs/bugfixes/2026-08-11-screen-recording-idle-tail-black.md) |
| 字幕生成、语言检测、翻译、任务取消、转写哪些声音（可听快照）、生成 / 翻译结束时回写工程 | [字幕语言流](docs/architecture/subtitle-language-flow.md)（可听快照与预览同一份隐藏过滤）、[AI 放素材顺带挂字幕，之后撤一步全空](docs/bugfixes/2026-09-27-ai-undo-swallowed-by-subtitle-attach.md)（回写包在 `AIUndoGrouping.step` 里）、[原生字幕生成方案](docs/plans/2026-08-06-native-subtitle-generation.md)、[字幕生成复审](docs/bugfixes/2026-08-06-subtitle-generation-review.md)、[PR #22 后续复审](docs/bugfixes/2026-08-09-pr22-review-followups.md)、[藏起来的片段照样被转写成字幕](docs/bugfixes/2026-09-26-subtitle-generation-transcribes-hidden-clips.md)、[自动检测语言拿音效当探针](docs/bugfixes/2026-09-26-auto-detect-probes-sound-effects.md) |
| 生成出来的字幕长什么样：去标点、断句、一行多长（字数 + 画面宽度）、几行（默认单行；面板的「每条字幕的行数」/ AI 的 `max_lines`）、显示时间、几段素材同时有字只留一条、面板上「只用选中的片段」、机器翻译落字去标点、AI 点名 `strip_punctuation` | [生成的字幕长什么样](docs/architecture/subtitle-generation-style.md)（先断句后去标点；停顿被识别器并进相邻的词，先估开口；默认单行是用户定的）、[字幕比声音早 0.9 秒、片段开头的词丢了](docs/bugfixes/2026-09-26-pause-stretches-next-word.md)、[生成字幕切出 0.1 秒的一条](docs/bugfixes/2026-09-30-subtitle-piece-on-screen-0.1s.md)、[方案与调研](docs/plans/2026-09-26-subtitle-generation-style.md) |
| 字幕轨、眼睛、预览叠层、烧录、布局、预览上字幕画多大（`SubtitleFontScale`）、行距（`BurnInStyle.lineSpacing`）、在哪儿折行（`SubtitleLineWrap`、`SubtitleCJKRows`、`SubtitleRowBreaks`、`SubtitleCJKWords`；烧录把折行点写成 `\N`）、选择（点选互斥 / 框选混选 / ⌘A / ⌘⇧A / 滤镜多选）、字幕的三个编辑入口、工程自己的字幕样式（`subtitleStyle(appWide:)`）与逐词高亮、原文 / 译文两条独立轨、预览上字幕块量高度、AI 读每句的框（`SubtitleLineBoxes` / `AISubtitleBoxes`） | [字幕轨可见性与布局](docs/architecture/subtitle-track-visibility-and-layout.md)（两条轨独立；用样式只问 `subtitleStyle(appWide:)`；折行点预览、AI 的框、成片同一份 `SubtitleLineWrap`）、[成片里的字幕比预览小一截](docs/bugfixes/2026-09-29-subtitle-preview-bigger-than-burn.md)（预览只用 `BurnInSubtitleOverlay` 画）、[预览上字幕的位置和行距和成片对不上](docs/bugfixes/2026-09-29-subtitle-preview-line-box-differs-from-libass.md)、[预览的字幕折行是贪心的，成片是摊匀的](docs/bugfixes/2026-10-15-subtitle-preview-wraps-greedily.md)、[没有空格的长中文字幕，成片整行溢出](docs/bugfixes/2026-10-15-chinese-subtitles-overflow-without-spaces.md)、[字幕自动折行把中文的词拆在两行](docs/bugfixes/2026-10-18-subtitle-wrap-splits-chinese-words.md)、[没下载苹方的 Mac 上中文字幕烧成方框](docs/bugfixes/2026-09-29-chinese-burns-as-boxes-without-pingfang.md)、[圆体烧录字幕英文变成「f=」](docs/bugfixes/2026-09-29-yuanti-cmap-breaks-libass-latin.md)、[字幕叠在一起时点英文落到中文上](docs/bugfixes/2026-09-26-stacked-subtitle-frame-lands-on-translation.md)、[拖动手势 §3.5b](docs/architecture/timeline-drag-gestures.md)、[两条独立轨的方案](docs/plans/2026-09-26-hide-guides-independent-subtitles.md) |
| 标记（所有块 + 标尺：锚在宿主自己的时间轴上、M 的落点、点标尺 = 选中标尺）、时间线块 overlay、扫帧 peek | [轨道块标记](docs/architecture/clip-markers.md)（单击只选中、双击才弹面板）、[悬停影子播放头与删除键](docs/bugfixes/2026-08-08-hover-ghost-playhead-and-delete-key.md)、[点了标记按 ⌫ 删不掉](docs/bugfixes/2026-09-24-marker-delete-key-eaten-by-note-field.md) |
| 音频库（音乐 / 音效两个 store、`AudioLibraryLookup`）、manifest（`hit` / `title_zh` / `owned`）、试听、素材缓存、署名（只问 `needsCredit`）、音效（合成器 + 录音素材库） | [音频库方案](docs/plans/2026-09-22-audio-library.md)、[音效方案](docs/plans/2026-09-30-sound-effects.md)、[音频库素材管线](docs/build/audio-library-pipeline.md)、[声音：音量与渐入渐出](docs/architecture/audio-fades.md)（ducking 的夹紧点）、[AI 接口（MCP）§4 第 23 条](docs/architecture/ai-control-mcp.md)（AI 搜音乐和界面同一个搜索函数、同一个署名口径） |
| 导出面板、编码设置、分辨率档位（压缩 / 烧录 / 剪辑导出）、导出文件名与撞名（`ExportFileName.unoccupied`）、字幕文件名里的语言标签（`SubtitleFileLanguage`）、压缩 / 烧录记住的设置和全 App 的字幕样式 | [导出设置](docs/architecture/export-settings.md)（面板上只放管线真消费的设置；记住的设置在队列创建时读回来，不挂在页面的 `onAppear` 上）、[没记语言的字幕轨，导出的文件名不带语言标签](docs/bugfixes/2026-10-15-subtitle-file-export-missing-language-tag.md)、[存好的字幕样式要先去烧录页转一圈才生效](docs/bugfixes/2026-09-27-remembered-subtitle-style-waits-for-burn-in-page.md)、[导出面板改版方案](docs/plans/2026-09-24-export-panel.md)、[选 1080p，竖屏视频被缩成 608×1080](docs/bugfixes/2026-09-24-resolution-cap-shrinks-portrait-video.md)、[导出面板说「音频原样复制」，其实重新编码](docs/bugfixes/2026-09-24-export-panel-promised-audio-copy.md) |
| 导出水印（`Sources/SrtFlow/Watermark/`；`WatermarkPolicy`；导出图里水印的落点；`Resources/watermark-logo.svg`；`SeededRandom`） | [导出水印](docs/architecture/export-watermark.md)（加不加只问 `WatermarkPolicy`、只有导出器调 `plan()`；整段两个 overlay，不许一段一个） |
| 读用户给的文本文件（字幕文件、讲稿、笔记）的编码 | [用户文本文件的编码](docs/architecture/text-file-encoding.md)（只走 SrtFlowCore 的 `TextDecoding`；UTF-16 不许无条件排在 GBK 前面）、[GBK 字幕读出来是乱码](docs/bugfixes/2026-09-27-gbk-subtitles-read-as-utf16.md) |
| 任何按钮的提示文案、快捷键、hover | [即时提示](docs/architecture/instant-tooltips.md)（不许用系统 `.help`；面板的浅 / 深按主题自己设；宿主的根在 `.appLanguage()` 外面裁成气泡的形状） |
| 预览性能、性能计数与基线；新写或改写任何 SwiftUI 视图 / 修饰器 / `NSViewRepresentable` / Canvas；性能那一步红了但没动编辑器界面；往时间线上加一种块 / 行里的列表项；任何要跟着播放头变的界面（订阅播放器时钟、读 `clock.time`）；在视图 body 里读工程的属性、给 `VideoEditProject` 加属性 | [预览性能 ratchet](docs/architecture/preview-perf-ratchet.md)（body 第一行要计数，写完跑 `checks/preview-perf-wiring.sh --fix`；计数只许降；时间线上的块不读工程、按值比较 + `.equatable()`；订阅时钟的只许是名单里的小视图）、[方案](docs/plans/2026-09-24-preview-perf-ratchet.md)、[点一下选段卡半秒、拖块滚动跟不上手](docs/bugfixes/2026-09-24-timeline-blocks-observe-whole-project.md)、[播放时每一跳整个编辑器都重算](docs/bugfixes/2026-09-25-playback-wakes-whole-editor.md)、[播放丝滑方案](docs/plans/2026-09-25-smooth-playback.md)、[点一下选中一段，整个编辑器跟着重算](docs/bugfixes/2026-09-26-selection-wakes-whole-editor.md) |
| AI 的一次工具调用、AI 起的长任务从哪开始到哪结束（`AIToolRouter.handle`、`AIJobs.start` / `finish`）、App Nap / 活动断言（`AIKeepAwake`、`ProcessInfo.beginActivity`）、新写一种在后台跑的 AI 活 | [AI 接口（MCP）第四节第 59 条](docs/architecture/ai-control-mcp.md)（新的长任务走 `AIJobs.start` / `finish`；活动断言只在 `AIKeepAwake` 和录屏）、[后台的 AI 活被 App Nap 降速](docs/bugfixes/2026-11-10-ai-work-throttled-by-app-nap.md) |
| 主线程卡顿、心跳看门狗 `MainThreadWatchdog`（含 AI「探一下」读的 `unresponsiveSeconds`）、卡顿日志、冒烟结果里的 `stalls`、挂起主线程抓栈（`MainThreadStackCapture`） | [主线程卡顿日志](docs/testing/main-thread-stalls.md)、[挂起主线程抓栈](docs/architecture/main-thread-stack-capture.md)（挂起期间不分配、不拿锁；挂起和恢复只在 `walkWhileSuspended`）、[导出两次卡死：看门狗挂起主线程抓栈时分配内存](docs/bugfixes/2026-10-06-watchdog-capture-deadlocks-main-thread.md)、[预览性能 ratchet](docs/architecture/preview-perf-ratchet.md) |
| 任何界面文案、翻译、字符串表、应用内语言切换、加一种界面语言（`<code>.lproj` + `AppLanguage` 一个 case）、新加 sheet / popover / 自建宿主视图 | [本地化](docs/architecture/localization.md)（sheet / popover 不继承应用内语言，每个都套 `.appLanguage()`）、[界面语言方案](docs/plans/2026-09-30-ui-languages.md)、[选了简体中文，sheet 和 popover 还是英文](docs/bugfixes/2026-09-24-sheets-ignore-in-app-language.md)、[本地化守卫不扫 `LabeledContent`](docs/bugfixes/2026-09-24-labeledcontent-missing-from-localization-guard.md) |
| AI 接口（MCP）：给 AI 的工具清单与说明、说明书 `skycut_guide`、剪辑风格（recipes / save_recipe）、配旁白（add_voiceover：`SkyStudioVoiceoverStart`、`MCPGuideWrittenTopics`、`voice_enroll`）、声音库 `list_voices` / `manage_voices`、本机的声音 Kokoro（`Sources/SrtFlowKokoro/`、模型的下载与 R2 上的那一份）、`skycut-mcp` 小程序、小程序与 App 的通道、AI 改时间线的规则、这一轮 / 停止 / 撤销这一轮、需要用户点头的事、设置里的「连接 AI」、AI 的手和眼（`edit_clip` 的画面放法、`look`、`listen`、`listen cuts=true`、`edit_subtitles`、`get_subtitles` 的 `box`、`look shots` / `look files` / `follow` / `look text_scan`）、AI 够得着的现有功能（后台模式、读文稿、整理文件、推子关键帧、形状、定格、音乐库、压缩 / 烧录 / 转字幕、`record_screen`、`export_subtitles`） | [MCP 说明书（skycut_guide）](docs/architecture/mcp-guide.md)（只有说明书预先加载；名片 ≤ 450、参数说明 ≤ 120、参数定义 ≤ 4,500 字节）、[MCP 按需说明方案](docs/plans/2026-11-09-mcp-guide.md)、[AI 接口（MCP）](docs/architecture/ai-control-mcp.md)（一个工具 = 一步撤销，每个改动工具包一层 `AIUndoGrouping.step`；不许弹模态框；参数名按说明核对；总说明 ≤ 1,200、全清单 ≤ 100,000，加工具先把说明挪进说明书、不再抬上限；碰工程的工具收可选的 `project`）、[预览自由变换](docs/architecture/preview-free-transform.md)、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md)、[波形与深度缩放](docs/architecture/audio-waveform.md)、[AI 的改动撤一步，整条时间线空了](docs/bugfixes/2026-09-27-ai-edits-share-one-undo-group.md)、[AI 放素材顺带挂字幕，之后撤一步全空](docs/bugfixes/2026-09-27-ai-undo-swallowed-by-subtitle-attach.md)、[AI 翻译按旧的原文语言去翻，等下载时不吭声](docs/bugfixes/2026-09-27-ai-translation-stale-source-language.md)、[转写认不出语言，AI 被叫去「面板里选」](docs/bugfixes/2026-09-29-ai-told-to-pick-language-in-panel.md)、[婚礼工程之后的五处工具小毛病](docs/bugfixes/2026-09-29-mcp-tool-followups-from-wedding-session.md)、[listen 说 63.5 BPM，cut_to_beat 按 95.3 切](docs/bugfixes/2026-09-29-beat-analysis-window-differs-between-listen-and-cut-to-beat.md)、[字幕带把幻灯片底部的标签也框进去](docs/bugfixes/2026-09-29-text-scan-band-swallows-slide-labels.md)、[text_scan 的裁切量被幻灯片标题拉大](docs/bugfixes/2026-09-29-text-scan-crop-hint-stretched-by-slide-title.md)、[被切掉的字混进字幕行、字幕稀疏时选成幻灯片](docs/bugfixes/2026-09-29-text-scan-cutoff-text-and-sparse-subtitles.md)、[Claude Code 只读到总说明的前一半](docs/bugfixes/2026-09-30-mcp-text-truncated-at-2048.md)、[MCP 方案](docs/plans/2026-09-27-mcp.md)、[配方卡中文稿](docs/plans/2026-09-28-mcp-recipes.md)（改套路先改它，再同步 App 资源里的英文卡）、[剪辑美感方案](docs/plans/2026-10-05-editing-aesthetics.md)、[风格卡给竖屏写的字号大了 1.78 倍](docs/bugfixes/2026-09-29-recipe-sizes-too-big-on-vertical.md) |
| MCP 参数范围 / requested、applied / 静默限幅 / 素材尺寸加载重试 / 单项与批量原子提交 | [MCP 编辑参数合同](docs/architecture/mcp-edit-parameters.md)（范围来自生产代码、越界给合法建议、限幅回实际值、成功后才开撤销组） |
| 合成音效（`Sources/SrtFlow/SoundEffects/`、`add_clips` 的 `sound_effect` / `hit_at`、`AISoundEffectRequest` / `AISoundEffectTool`）、改任何预设的声音、合成器的响度或落点 | [合成音效](docs/architecture/sound-effect-synth.md)（落点是合同；同参数同文件，改声音要 +1 version 并再给用户听；写文件只经一处）、[音效方案](docs/plans/2026-09-30-sound-effects.md)、[AI 接口（MCP）第四节第 43 条](docs/architecture/ai-control-mcp.md)、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md) |
| 云端媒体共用的阶段 / 状态行 / 传输 / 每日账（`Sources/SrtFlow/CloudMedia/`），生成、upscale、旁白、克隆，声音的接口合同（预设声音、角色、声音库、voice_plan、一次性费用、变声的 DTO 和请求），同时开着几个任务（`SkyStudioJobSlots`：声音池 / 共用池）、一段旁白的几批怎么同时交（`SkyStudioVoiceBatchQueue`）、中途换备用（`SkyStudioVoiceFallbackFee`）、本机切句（`SkyStudioVoiceLineAudio`、`SkyStudioVoiceSplitEstimate`）、认声音（`SkyStudioVoicePick`）、角色 list_characters / get_character / manage_characters、图片 camera_angle / upscale | [Sky Studio 的任务](docs/architecture/sky-studio-jobs.md)（全部收费活只走 Sky Studio；交之前在本机按池领槽；退本机只在付费请求之前；付过钱的声音不许在本机卡死）、[fal.ai 生成](docs/architecture/fal-generation.md)（仅供历史复盘） |
| 声音库的工具（`list_voices` / `manage_voices`：`SkyStudioVoiceLibraryTool` / `SkyStudioVoiceRecordingTool` / `SkyStudioVoiceDesignTool`；`SkyStudioVoiceApproval`、`SkyStudioJobGate` 的声音那三样；`voice_library_unavailable`）、声音库的收费单跨重启（`SkyStudioVoiceLibraryOrders`、`SkyStudioVoiceLibraryJob.follow`）、全部权限下的长期授权（`SkyStudioVoiceStanding`、`/voices/consent-grant`、`SkyStudioVoiceStandingNotice`）、克隆的参考录音（`VoiceReferenceSample` / `VoiceReferenceWindow` / `VoiceReferenceReader`、上传用途 `voice_reference`） | [声音库：参考录音、工具和界面、变声](docs/architecture/voice-library.md)（参考录音 44.1 kHz 单声道 16-bit、10 秒有效人声到 3 分钟；有声门限 `speechRMSFloor` 单独写死；同一件事只开一单、在建的单交之前落盘）、[克隆的参考录音被降到 16 kHz、只截 10 秒](docs/bugfixes/2026-11-10-voice-reference-16khz-short-sample.md)、[Sky Studio 的任务第五节](docs/architecture/sky-studio-jobs.md)、[声音库审查的后续](docs/bugfixes/2026-11-11-voice-library-review-followups.md)、[重启后不记得在建的声音库那一单](docs/bugfixes/2026-11-11-voice-library-job-after-restart.md) |
| 声音库的界面（`Sources/SrtFlow/VoiceLibrary/`：`VoiceLibrarySettingsSection` / `VoiceLibraryStore`、`VoicePickerView` / `VoicePickerRows`、`NewVoiceSheet` / `NewVoiceModel` / `NewVoiceGate`、`VoiceSampleRecorder`、`VoiceSampleLanguage` + `SpokenLanguageProbe`、`SkyStudioVoiceRecordingLanguage`、`DesignVoiceSheet` / `DesignVoiceModel`、`VoiceAudition`、`VoiceLibraryText`；和 AI 的工具共用的 `SkyStudioVoiceRecordingSubmission` / `SkyStudioVoiceDeletion` / `SkyStudioVoiceDesignOrder` / `SkyStudioVoiceLibraryErrors.kind`；麦克风的用途说明） | [声音库第九、十节](docs/architecture/voice-library.md)（界面和 AI 的工具同一条路；勾了授权才造 `consent: true`；会花钱的按钮按下去就锁；语言检测不出来留空、不许猜）、[顶部工作台与统一设置](docs/architecture/workbench-and-settings.md)、[本地化](docs/architecture/localization.md)、[预览性能 ratchet](docs/architecture/preview-perf-ratchet.md)、[即时提示](docs/architecture/instant-tooltips.md)、[签名与系统权限](docs/architecture/code-signing-and-permissions.md)（麦克风）、[字幕语言流](docs/architecture/subtitle-language-flow.md)（语言检测的候选和裁决在 `SpokenLanguageProbe`）、[离屏渲染的图](docs/reports/2026-11-10-voice-library-ui.md)、[设计声音连按下了好几单](docs/bugfixes/2026-11-11-design-voice-ordered-twice.md) |
| 变声（`Sources/SrtFlow/VoiceChange/`：AI 的 `change_voice`（`VoiceChangeTool`）、片段右键「换成我的声音…」和面板（`VoiceChangeActivity` / `VoiceChangePresenter` / `VoiceChangePanel` / `VoiceChangePanelModel`）、`VoiceChangeSource`、`VoiceChangeOrder`、`VoiceChangeJob`、`VoiceChangeLanding`、`VoiceChangeOutputName`；`voice_convert`、上传用途 `voice_convert_source`） | [声音库第十一节](docs/architecture/voice-library.md)（两个入口同一条路；只判每日硬预算、结果不明不重交；落地恰好一次 `perform`、包在 `AIUndoGrouping.step` 里）、[联动](docs/architecture/timeline-linkage.md)、[Sky Studio 的任务](docs/architecture/sky-studio-jobs.md)、[AI 接口（MCP）第四节第 60 条](docs/architecture/ai-control-mcp.md)、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md)、[预览性能 ratchet](docs/architecture/preview-perf-ratchet.md)、[本地化](docs/architecture/localization.md)、[实测](docs/reports/2026-11-11-change-voice.md) |
| 视频 upscale（`Upscale/UpscaleTiers.swift`、`UpscaleOffers`、`SkyStudioSpendStore`；AI 的工具 `upscale_clip`（`AIUpscaleTool` / `AIUpscaleNames`、`UpscaleJob.Approval`、`SkyStudioJobGate`）；换源：`EditClip.upscale`（`VideoEditClipUpscaleRecord`）、`ClipSourceSwap`、`VideoEditMediaReferences`、`VideoEditProject+Upscale`；任务：`Sources/SrtFlow/Upscale/`、`UpscaleJob`；界面：`VideoEditInspector+Upscale`、`UpscaleJobStatusView`、`VideoEditTimelineClipBlock` 的右键菜单与角标、`UpscalePanel`、`UpscaleCompareView` / `Stage` / `Playback`、`UpscalePresenter`） | [视频 upscale 方案](docs/plans/2026-10-02-video-upscale.md)、[Sky Studio 的任务](docs/architecture/sky-studio-jobs.md)（扣多少只问 `/quote`、交任务时当 `max_credits`；Key 只发给 Sky Studio）、[smoke test 实测](docs/reports/2026-10-02-upscale-smoke-test.md)、[工程文件「四之五」](docs/architecture/video-edit-project-file.md)、[视频 upscale](docs/architecture/video-upscale.md)（成品的声音一律不要、自己封回原片的；面板起的做完不替换；界面只订阅 `UpscaleActivity`）、[AI 接口（MCP）第四节第 44 条](docs/architecture/ai-control-mcp.md)、[检查器的排版](docs/architecture/inspector-layout.md)、[本地化](docs/architecture/localization.md) |
| 收费与授权：体验 / 正式版、服务器下发的开关（MCP 能不能用、导出加不加水印）、照授权拦（AI 调用的门 `SkyStudioAccount.aiRefusal`、导出面板「会带水印」那一行、`SkyCutGates`）、导出水印、Sky Studio 的 key 与 `api/skycut/v1`、生成 / upscale / 克隆走 Sky Studio | [收费方案](docs/plans/2026-10-27-paid-plans-and-sky-studio-key.md)（开关由服务器下发、SkyCut 不写死天数和规则；MCP 的门在 App 收工具调用的地方、不在小程序里）、[Sky Studio 账号](docs/architecture/sky-studio-account.md)（只有 `SkyStudioAPI` 碰地址；后台问 `/me` 从不弹钥匙串框；机器号的盐永远不改）、[Sky Studio 的任务](docs/architecture/sky-studio-jobs.md)、[真 Codex 冒烟](docs/reports/2026-10-26-codex-client-smoke.md)、[导出水印](docs/architecture/export-watermark.md) |
| 真实窗口、系统权限、手势实测 | [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) |
| 官方原创短片、`generate_media` 的 `film`、镜头状态 / 完成动作 / 声音计划、实际引用与报价 pin、左右接缝审查 | [官方原创短片](docs/architecture/official-film.md)（公开状态与服务端私有配方分开；客户端 / 生产启用 / 真实输出 / 并发验收分开报告）、[Sky Studio 的任务](docs/architecture/sky-studio-jobs.md)、[开着的工程（OpenProjects）](docs/architecture/open-projects.md) |

## 构建与检查入口

- 构建、打包、DMG、公开下载发布、CI 怎么分组、本地怎么跑检查：[构建与打包](docs/build/build-and-packaging.md)。素材管线（制备素材、不是检查，**不在 `check-all.sh` 里**）：[音频库素材管线](docs/build/audio-library-pipeline.md)（`scripts/audio-library/`）、[本机配音模型管线](docs/build/voice-model-pipeline.md)（`scripts/voice-models/`，R2 签名只有 `scripts/r2.py` 一份）。
- **推之前**：`scripts/check-local.sh <相关检查>` = 全部扫描守卫（`scripts/check-guards.sh`：`checks/*.sh` + `scripts/check-mcp.sh --scans-only`，约一分钟、不编译）+ 点名的几项。本地的入口都自己换成原生 arm64 的 `/bin/bash`（`scripts/native-arch.sh`）。
- **全部自动检查**：`scripts/check-all.sh`。CI（`.github/workflows/checks.yml`）在每个 PR 上按 `--shard N --of 5` 分到 5 台 macOS runner 跑同一入口，汇总 job `check-all` 给结论；只改了文档的 PR 走快速通道（`scripts/ci-docs-only.sh` 判，只跑扫描守卫）。
- **新加检查**要放进 `check-all.sh` 的某个 `shard`：要链接完整 App 目标文件的放第 1 组（只有那台编了完整 App），别的放第 2–5 组里最空的那组；`checks/` 顶层的守卫没进 check-all，CI 一次都不跑（`checks/check-all-shards.sh` 钉着）。文档里提到检查时别写组号（分组只以 `check-all.sh` 为准）。
- 下面每个脚本只留一行。每项具体验哪些情形、用例在哪个文件、偶发怎么认，见 [检查细目](docs/testing/check-catalog.md)；新加或改了检查，在这里补一行，细节写进细目或对应的架构文档。

### 自检（在 `check-all.sh` 里；要编译，多数要 ffmpeg）

- `swift run --arch arm64 SrtFlowCoreChecks` — 核心库：字幕去标点 / 断句 / 行数、折行的文字规矩、逐词高亮。
- `scripts/check-app-theme.sh` — 界面主题的偏好与色表。
- `scripts/check-audio-engine.sh` — 音频引擎：离线渲染 vs oracle 混音器、换配置、空闲停图；另有三个真声卡的模式（`--realtime-recovery` / `--realtime-idle` / `--measure-idle`，只在开发机）。
- `scripts/check-audio-fade.sh` — 渐入渐出 / 音量曲线 / 推子的真实包络、电平表、限幅器、响度（第 7b 组的偶发见推子与电平表）。
- `scripts/check-audio-library.sh` — 音频库清单的解析与双语搜索、音效清单。
- `scripts/check-ci-build-cache.sh` — CI 的 `.build` 缓存：改了照样重编、放回缓存重编 0 样。
- `scripts/check-clip-animation.sh` — 入场 / 出场动画：预览取帧 vs 真导出抽帧。
- `scripts/check-cloud-media.sh` — 云端媒体共用的每日账与阶段。
- `scripts/check-cover-export.sh` — 盖一块（模糊 / 马赛克）在成片里真的盖了。
- `scripts/check-dmg.sh` — DMG 的真实组装、挂载和 Retina 背景。
- `scripts/check-engine-probe.sh` — 引擎启动探测：超时、输出上限、子进程回收、单次定位。
- `scripts/check-export-alpha-compositing.sh` — 上层轨动画段的 fill + matte。
- `scripts/check-export-frame-rate.sh` — 生产导出的帧率与分辨率（真跑导出数帧）。
- `scripts/check-export-profile.sh` — 导出阶段计时、快速审阅、排队 / 取消、PNG 只解码一次。
- `scripts/check-export-watermark.sh` — 导出水印真的叠上了、只在该在的地方。
- `scripts/check-film-production.sh` — 官方原创短片的公开制作状态。
- `scripts/check-filters.sh` — 调色：LUT 数学、预览与成片逐像素、纯黑不抬。
- `scripts/check-freeze-frame.sh` — 定格的时间线变换。
- `scripts/check-localization-coverage.sh` — 界面文案在每张字符串表都配齐、占位符一致。
- `scripts/check-main-thread-watchdog.sh` — 主线程心跳看门狗、挂起抓栈期间不分配。
- `scripts/check-mcp.sh` — AI 接口（MCP）：协议、清单和说明的上限、说明书、AI 改时间线的规则、客户端配置、词表对账（`--scans-only` 只跑编译之前的扫描，含 `checks/MCP/*-wiring.sh`）。
- `scripts/check-media-import.sh` — 拖文件进轨道的落点。
- `scripts/check-optimized-media.sh` — 优化媒体：判据、真转一块、缓存。
- `scripts/check-parameter-limits.sh` — MCP 编辑参数的边界、实际生效值、素材加载重试。
- `scripts/check-player-clock.sh` — 播放头与悬停 peek、`PacedPlayhead`、回到开头、卸片后晚到的回调、播到头收尾。
- `scripts/check-preview-composition.sh` — 预览合成真取帧：素材缓存、时间账、切片表、按块换源、转场的样子。
- `scripts/check-project-file.sh` — 工程存盘与重链接、选择模型、标记、隐藏、关键帧缓动、形状动画等纯值合同。
- `scripts/check-region-framing.sh` — 源矩形取景的 look / 预览 / 导出。
- `scripts/check-screen-recording-feedback.sh` — 录屏收尾的通知、晚到的 Stop、会话附言。
- `scripts/check-screen-recording-writer.sh` — 录屏产物的画面轨盖到结尾（尾部不黑）。
- `scripts/check-shape-render.sh` — 形状：预览和导出逐像素重合、入场 / 出场动画。
- `scripts/check-sky-studio.sh` — Sky Studio 账号、照授权拦、任务 / 报价 / 积分、声音的纯值检查（不碰网络和钥匙串）。
- `scripts/check-still-clip-encode.sh` — 静帧真实编码：图只解一次缩一次、透明的图。
- `scripts/check-subtitle-burn-size.sh` — 预览上的字幕和烧出来的一样：大小、折行、位置、行距、阴影、字体清单。
- `scripts/check-text-render.sh` — 画面文字：渲染图与成片逐点重合、动画、回退字体、接缝。
- `scripts/check-timeline-clipboard.sh` — 复制 / 剪切 / 粘贴、分割不丢字段。
- `scripts/check-timeline-snap.sh` — 吸附、框选命中、点击落点、联动。
- `scripts/check-timeline-zoom.sh` — 缩放的锚点、播放跟随、记住的开关。
- `scripts/check-translation-preflight.sh` — 翻译配对预检与接线。
- `scripts/check-upscale.sh` — 视频 upscale 的任务对着假 Sky Studio 走全程。
- `scripts/check-video-fade.sh` — 上层轨铺满 + 画面渐变的真产物、藏起来的段、透明 PNG。
- `scripts/check-video-inspection.sh` — 成片疑点检查（`inspect_video`）。
- `scripts/check-voice-recovery.sh` — 旁白 / 声音库 / 变声 / 长期授权 / `KeepAwakeChecks`：真 App 对象对着假 Sky Studio。
- `scripts/check-voiceover-sync.sh` — 按旁白段落同步时间线。
- `scripts/check-waveform.sh` — 波形数据逐采样对账、很多文件同时读不死锁。
- `python3 checks/MCP/SmokeClientChecks.py` — 冒烟客户端的断线、协议错误、超时和退出码。

### 扫描守卫（`checks/*.sh`，都在 `check-all.sh` 里；秒级、不编译）

- `checks/ai-keep-awake.sh` — AI 的调用和任务领不降速的那一份、领和还成对。
- `checks/ai-work-queue-wiring.sh` — AI 起的导出 / 转写 / 翻译都经 `AIWorkQueue` 排队。
- `checks/app-theme-wiring.sh` — 主题的浅 / 深：不交 nil、只有一处 `.preferredColorScheme`、不设 `NSApp.appearance`。
- `checks/audio-engine-idle-wiring.sh` — 音频引擎空闲停图、用户回来先起、换工程收引擎、主时钟自己收尾。
- `checks/blocking-media-reads.sh` — 读采样的阻塞循环不许写在 async 函数里；`AudioWindowReader.extract` 只许字幕生成调。
- `checks/check-all-shards.sh` — `checks/` 下每条守卫都在 check-all 里；第 1 组正好是「完整 App」那一摊。
- `checks/check-script-source-lists.sh` — 自检脚本的 swiftc 文件清单不漏同伴文件。
- `checks/ci-build-cache-key.sh` — CI 的 `.build` 缓存 key 带检出目录、工具链、组号和提交，只在 main 上存。
- `checks/ci-docs-only.sh` — 「只改了文档」快速通道只在真的只改了文档时走。
- `checks/client-config-backup.sh` — 连接 AI 客户端时的配置备份和原文件同样的权限。
- `checks/cloud-task-projects.sh` — 生成任务带工程归属，卡片和 MCP 共用分组。
- `checks/copy-project-guard.sh` — 冒烟拷工程不整夹拷「下载」这类大文件夹。
- `checks/dmg-packaging.sh` — DMG 安装引导的接线与模板。
- `checks/docs-index-drift.sh` — 本文件的索引是全的、没有死链、总大小不超上限。
- `checks/encode-settings-memory.sh` — 压缩 / 烧录记住的设置在队列创建时读回来；字幕样式都经 `subtitleStyle(appWide:)`。
- `checks/export-audio-single-pipeline.sh` — 导出图里不许出现声音滤镜。
- `checks/export-watermark-wiring.sh` — 加不加水印只问 `WatermarkPolicy`、落在烧字幕之后缩小之前。
- `checks/exported-types-declared.sh` — 每个 `UTType(exportedAs:)` 都在 `packaging/Info.plist` 里声明。
- `checks/film-production-wiring.sh` — 官方短片公开制作状态的接线。
- `checks/hit-shape-before-offset.sh` — `.contentShape` 不许写在 `.offset` / `.rotationEffect` / `.scaleEffect` 之后。
- `checks/hover-pointer-style.sh` — 悬停指针只用 `.pointerStyle`，不碰 `NSCursor`。
- `checks/inspector-fits-width.sh` — 检查器里的菜单 Picker 不许锁死宽度。
- `checks/inspector-live-binding-wiring.sh` — 检查器的 live 绑定只准接滑块和 scrub。
- `checks/instant-tooltip-wiring.sh` — 提示与快捷键单一来源、提示的根裁成气泡的形状。
- `checks/list-section-not-equatable.sh` — `List` 里 body 带 `Section` 的视图不许套 `.equatable()`。
- `checks/native-local-checks.sh` — 本地跑检查的入口换成原生 arm64、起检查用 `/bin/bash`。
- `checks/no-hardcoded-fps.sh` — 禁止写死帧率。
- `checks/no-legacy-generation.sh` — 旧 fal 客户端 / Key / 设置 / 模型不许回来。
- `checks/no-swallowed-build-output.sh` — 构建日志不得被吞。
- `checks/open-projects-wiring.sh` — 工程不再是单例、撤销不退到键窗口、代号全 App 不重号、导出进度只给发起的工程。
- `checks/optimized-media-wiring.sh` — 优化媒体只换预览、成片永远原片、停着才换、清空之后重建。
- `checks/player-time-no-sync-read.sh` — 不许同步问播放器要时间（`currentTime()`）、Now Playing 关着。
- `checks/preference-reduce-keeps-value.sh` — `PreferenceKey.reduce` 不许写成 `value = nextValue()`。
- `checks/presented-views-app-language.sh` — 每个 sheet / popover / 自建 `NSHostingView` 都套 `.appLanguage()`。
- `checks/preview-perf-wiring.sh` — 每个视图 / `updateNSView` / Canvas 接了性能计数（漏了跑 `--fix` 自动补）；时间线上的块不读工程；订阅时钟的名单。
- `checks/product-name.sh` — 看得见的叫 SkyCut，身份类的名字沿用 SrtFlow。
- `checks/project-file-wiring.sh` — 工程存盘 / 选择 / 隐藏 / 导出这批合同的生产接线；搬代码、改名之后先跑它。
- `checks/region-framing-wiring.sh` — 源矩形取景接进现有编辑 / 批量和原生渲染。
- `checks/release-signing.sh` — 发布版用固定的签名身份签；`tccutil` 只在一处。
- `checks/report-evidence-no-local-paths.sh` — 进仓库的实测证据里没有本机的绝对路径。
- `checks/screen-recording-ai-wiring.sh` — AI 录屏：不开系统选择窗口、不覆盖、入轨包 step、丢弃先问。
- `checks/sfx-catalog.sh` — 音效目录：id 连号永不改、tag 在词表里。
- `checks/shell-brace-in-nested-quotes.sh` — `"$(…)"` 里不许再套带 `{…,…}` 的双引号串（bash 3.2 会拆开）。
- `checks/shell-pipe-grep-q.sh` — 开着 pipefail 时管道末端不许用 `grep -q`。
- `checks/shell-var-boundary.sh` — 裸 `$VAR` 不许紧跟中文 / 全角标点。
- `checks/sky-studio-wiring.sh` — Sky Studio 的地址、机器号、钥匙串、照授权拦、任务、声音库和变声只在该在的地方（分节在 `checks/sky-studio-wiring/`）。
- `checks/source-file-size.sh` — 单文件超过 600 行就红、老文件只许降（变短了跑 `--update`）。
- `checks/subtitle-editing-wiring.sh` — 字幕编辑期间全局快捷键让路。
- `checks/timeline-clipboard-wiring.sh` — 复制粘贴的接线、落点鼠标优先、剪贴板只有一套。
- `checks/timeline-drag-wiring.sh` — 时间线拖动 / 框选 / 缩放 / 联动 / 开关的接线，整条时间线只许一个 `.onDrop`（分节在 `checks/timeline-drag-wiring/`）。
- `checks/transition-handles-wiring.sh` — 主轨转场借余料、定格补足、可点选可删除的接线。
- `checks/voiceover-sync-wiring.sh` — 旁白同步复用生产路径、只有一处提交。
- `checks/workbench-settings-wiring.sh` — 单排工作台、统一设置、MCP 共用 Store。

### 不在 `check-all.sh` 里的

要图形会话的按 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) 跑（无图形会话会假红）。

- `scripts/check-preview-perf.sh` — 预览性能 ratchet：**CI 独有的一步、要图形会话**；check-all 只跑它的 `--self-test`。偶发误报的认法见预览性能 ratchet。
- `scripts/check-filter-preview-attach.sh` — 滤镜挂到播放器上（拍窗口数像素）。要图形会话；改 `VideoEditFilterPreview.swift` 时跑。
- `scripts/check-cover-preview-attach.sh` — 预览上的盖一块真的盖上了。要图形会话；改 `VideoEditCoverPreview.swift` / `VideoEditCoverFilters.swift` 时跑。
- `scripts/check-instant-tooltip-panel.sh` — 提示面板的落点、浅 / 深、四角透明。要图形会话；改 `InstantTooltip.swift` 时跑。
- `scripts/check-theme-switch.sh` — 切主题 / 系统切深浅色之后开着的窗口都跟上。要图形会话。
- `scripts/check-workbench-toolbar.sh` — 工具栏 AI 徽章的像素检查。要图形会话，随 GUI 冒烟手动跑。
- `scripts/check-keychain.sh` — `KeychainSecret` 对真的系统钥匙串走一遍。只在本机跑，不在 CI 里。
- `scripts/gui-smoke/in-process/run.sh <步骤.json> [工程拷贝]` — 进程内 GUI 冒烟（不动鼠标、不抢前台）。要图形会话。
- `scripts/gui-smoke/mcp-client/client.py` — 扮成 AI 客户端驱动装好的测试版；共享客户端 `scripts/gui-smoke/mcpclient.py`。
- `scripts/gui-smoke/sky-studio/` — 对着假 Sky Studio 的免费端到端冒烟（含 `voice_change.py`）。
- `scripts/gui-smoke/client-measure/` — 真 Claude Code / Codex 实测。用用户自己的额度，**每次开跑前问用户**。
- `scripts/gui-smoke/external-file-drag/replay.sh`、`scripts/gui-smoke/drop-routing-probe/probe.sh` — 跨 App 文件拖放重放、SwiftUI 落点路由探针。要图形会话。
- `scripts/render-voice-library.sh <输出目录>` — 声音库 / 变声界面的离屏出图。要图形会话。
- `scripts/signing/create-identity.sh` — 建签名身份，一次性的；见到签名目录不在先停下来告诉用户，别去跑它。
- 官网（在 `website/`）：`tests/*.test.mjs` 和 `npm run check:seo` 在 CI 的网站那一步里；浏览器级的 `scripts/check-hero-browsers.mjs`、`scripts/check-legibility-browsers.mjs`（`npx -y -p playwright@1.65.0 node …`）是手动的、无头、只在 Mac 上；改了首屏场景的外观要 `npm run build:hero-still` 重烤。

## 规划与实施报告索引

每份一行：链接 + 一句话，按日期从新到旧。方案记录目标和拍过的板；已实施功能的真实状态看报告、代码和检查结果。

### 方案（docs/plans/）

- [MCP 按需说明：名片常驻、说明书按需读](docs/plans/2026-11-09-mcp-guide.md) — 2026-11-09 用户审定：`skycut_guide`、名片 ≤ 450 等新上限、七个 PR；6.4 的 Codex 口径 11-11 有更正；真客户端验收每次开跑前问用户。
- [SkyCut 声音方案](docs/plans/2026-11-09-voice-features.md) — 2026-11-10 批准：服务器自动选模型、声音的名字、声音库 / 变声的工具和界面、两种权限模式怎么问、九个 PR。
- [Windows 版 SkyCut：讨论记录（暂缓）](docs/plans/2026-11-07-windows-version.md) — 2026-11-07 用户定「日后再讨论」：已定的、没定的和 Codex 的技术草稿。
- [收费：体验版、导出水印、MCP 门槛，生成改用 Sky Studio 的 key](docs/plans/2026-10-27-paid-plans-and-sky-studio-key.md) — 用户拍的 38 条板（授权和积分、开关由服务器下发、一把 `sk-` key、自助购买 Pro）、两边分工和七刀；2026-11-06 已上线。
- [改名 SkyCut](docs/plans/2026-10-18-rename-to-skycut.md) — 只改看得见的那一层、bundle id 和代码名沿用 SrtFlow、新工程 `.skycut`；本机怎么收拾。
- [AI 多开：一个 AI 会话同时剪几个工程](docs/plans/2026-10-17-multi-project-ai-editing.md) — 用户拍的十条板（可选 `project`、p1…、封顶 8 个、一个会话一组工程）、四刀。
- [第三批 AI 反馈：字幕行距、入点说明、检查 V1 的剪辑点](docs/plans/2026-10-16-ai-feedback-line-spacing-and-cut-check.md) — `listen cuts=true` 不另开工具；行距是倍数 1–2、只能加大。
- [剪辑美感：先把审美写下来，再补零件](docs/plans/2026-10-05-editing-aesthetics.md) — 为什么 AI 剪得普通、导演手册式的卡、参考片只量用户给的文件。
- [让 AI 录屏：record_screen](docs/plans/2026-10-03-screen-recording-mcp.md) — AI 自己选来源、没授权弹一次、开录不问、一边录一边操作；我定的十条。
- [视频 upscale：片段送去放大，比过再换](docs/plans/2026-10-02-video-upscale.md) — 用户拍的 16 条板、实测定下的事实（声音自己封回、帧数要核对）、四刀。
- [联动：主轨块挪到哪、删没删，压在它上面的东西跟着走](docs/plans/2026-10-02-timeline-linkage.md) — 「和剪映一样」：跟画面不跟 id、完全在一段里的才跟、真删才连带删；场景表就是自检用例。
- [预览和成片的声音：自己的音频引擎](docs/plans/2026-10-01-audio-engine.md) — 为什么不用 AVPlayer 的合成（每条音轨 40 ms）、架构、时钟对齐、三刀。
- [预览的画面：优化媒体](docs/plans/2026-10-01-video-optimized-media.md) — 只转长 GOP 的源和时间线用到的块、成片永远原片、缓存 10 GB LRU；V1–V3 已合。
- [导出真峰值限幅 + 响度报告，关键帧缓动](docs/plans/2026-09-30-export-limiter-and-easing.md) — −1 dBFS 限幅、响度只报不归一；`easing` AI 默认 ease_in_out、手打默认线性。
- [音效：合成器（给 AI）+ 录音素材库（给用户）](docs/plans/2026-09-30-sound-effects.md) — AI 先搜素材库、没有再合成；样音点头才写代码；`hit_at` 落点。
- [界面语言：加西班牙语、法语、土耳其语](docs/plans/2026-09-30-ui-languages.md) — 先把枚举和守卫改成任意多种语言；译文 AI 出、不审、直接算正式。
- [剪辑风格：五种预设风格（中文稿）](docs/plans/2026-09-28-mcp-recipes.md) — 共用规矩 + 五张卡 + 配音角色表；改套路先改它、再同步 App 资源里的英文卡。
- [让 AI 调用 SkyCut 剪视频：MCP 方案](docs/plans/2026-09-27-mcp.md) — 用户拍的 58 条板（第一期客户端、看得见、只有删文件才问、不靠外部工具、剪辑风格、配音、fal 生成…）、架构与六块；真实状态看实施报告。
- [隐藏扩到所有块、回到开头、对齐线、字幕拆成两条独立轨](docs/plans/2026-09-26-hide-guides-independent-subtitles.md) — 2026-09-26 五件事拍过的板，字幕独立轨那部分最细。
- [时间线复制 / 剪切 / 粘贴 + 缩放以鼠标为中心 + 纵向缩放](docs/plans/2026-09-26-timeline-clipboard-and-zoom.md) — 2026-09-26 逐条拍的板和实现细节（Z1–Z7、C1–C9）。
- [生成的字幕：去标点、断句、只留一条、藏起来的不转写](docs/plans/2026-09-26-subtitle-generation-style.md) — 调研（主流剪辑软件、Netflix / BBC 的数字）和逐条拍的板。
- [播放丝滑：播放头的每一跳只叫醒跟着它动的东西](docs/plans/2026-09-25-smooth-playback.md) — 左栏和检查器播放中冻住、停下追上；不拿 CPU 数字验收。
- [导出面板改版：三行 + 高级](docs/plans/2026-09-24-export-panel.md) — 分辨率只降不升按短边、不弹保存面板、撞名先提示、记住设置；逐条拍过的板。
- [插进两条轨之间 + 整条轨换位置](docs/plans/2026-09-24-track-insert-and-reorder.md) — 缝上停 0.2 秒拉开再落进新轨；按住轨道头拖整条轨换位；拍过的板。
- [声音场景 + 成片声音改从预览混音读](docs/plans/2026-09-24-sound-scenes.md) — 九个场景、余音越过段尾、效果在段增益之后；成片的声音只做一遍。
- [预览性能 ratchet 方案](docs/plans/2026-09-24-preview-perf-ratchet.md) — 为什么数「活」不数 CPU、只许降不许涨、不拿画质换数字。
- [声音编辑：波形、深度缩放、音量曲线、推子与电平表](docs/plans/2026-09-23-audio-mixing.md) — 曲线属于段、推子属于轨等拍过的板，和三个探针的实测地基。
- [音频库（音乐 / 音效）](docs/plans/2026-09-22-audio-library.md) — R2 按需下载 + 本地导入；**只收 CC-BY / CC0**（SA 会传染给用户成片）；manifest、试听、ducking。
- [从 Finder 拖文件进轨道](docs/plans/2026-09-22-media-file-drop.md) — 拖到哪落到哪、占着就往上抬一轨、多文件首尾相接、⌘V 粘贴文件；和 `addMedia` 的分工。
- [画面段的入场 / 出场动画](docs/plans/2026-09-18-clip-animation.md) — 效果清单、吞掉画面渐变、不露边口径、选型约束与分刀。
- [转场库扩充](docs/plans/2026-08-23-transition-library.md) — 推移 / 擦除 8 种新转场的选型约束（预览斜坡能精确表达才收）与悬停预览选择器。
- [定格方案](docs/plans/2026-08-08-freeze-frame.md) — 产品参数、提交模型、分辨率政策与已知代价。
- [原生录屏方案](docs/plans/2026-08-06-native-screen-recording.md) — 产品目标与阶段方案；当前状态以实施报告为准。
- [原生字幕生成方案](docs/plans/2026-08-06-native-subtitle-generation.md) — SpeechAnalyzer、Translation、缓存与 macOS 15/26 分层。

### 报告（docs/reports/）

- [声音功能的真实冒烟：界面 + AI 工具（2026-11-11）](docs/reports/2026-11-11-voice-real-smoke.md) — 新建 / 设计 / 删声音、变声、读稿、长期授权全过，74.2 积分和账单逐笔对上；撞出的问题修在 #379、#383，音频引擎一直开着当时待拍板。
- [变声（声音 PR 9）：离屏渲染和免费冒烟](docs/reports/2026-11-11-change-voice.md) — 面板三种语言的图、假 Sky Studio 上走全程；没验到真 Sky Studio 和真窗口。
- [MCP 按需说明：迁移完以后的完整实测](docs/reports/2026-11-11-mcp-guide-final-measurement.md) — 61 个工具、两个客户端各 8 个任务：Claude Code 过线（预先加载 −6.7%），Codex 三条开销线按字面没到（已接受）。
- [声音功能的免费冒烟补跑（声音 PR 3–6）](docs/reports/2026-11-10-voice-free-smoke.md) — 假 Sky Studio 上合批、声音库、并发、换备用全过；没跑到的和看见的五条问题。
- [声音库界面的离屏渲染（声音 PR 8）](docs/reports/2026-11-10-voice-library-ui.md) — 英 / 中 / 西各一张拼图；看图撞出的两件事；没验到的（真麦克风、真 sheet）。
- [MCP 按需说明的基线实测（Claude Code + Codex）](docs/reports/2026-11-10-mcp-guide-baseline.md) — 改之前每轮常驻 1,605 token、整份预先加载 39,646 token；八个任务的调用和脱敏证据。
- [MCP 按需说明的试点实测（Claude Code + Codex）](docs/reports/2026-11-10-mcp-guide-pilot.md) — 对照基线过线（常驻 −6.5%、预先加载 −2.2%）；任务 7 的规矩修了之后两个客户端都停下来问。
- [MCP 按需说明的实施报告（进行中）](docs/reports/2026-11-10-mcp-guide-progress.md) — 七个 PR 各做到哪、基线在哪、本机跑检查的偶发。
- [全部图片模型与角色系统的真积分验收（0.18.62）](docs/reports/2026-11-07-image-models-and-characters-smoke.md) — 新图片模型、换角度、角色全流程成功（208 积分）；撞出的问题和放大超时已修（0.18.63）。
- [一个 PR 从本地到能合要多久：改之前和改之后](docs/reports/2026-11-04-ci-speedup.md) — 本地 24 分钟 → 1.5–3 分钟，PR 的 CI 约 11 → 6 分钟；五个 PR 各改了什么。
- [官方原创短片客户端接入](docs/reports/2026-11-04-official-film-client.md) — API 合同、生成接入、公开制作状态的逐项证据；客户端、生产启用、真实输出分开报告。
- [MCP 发现与真实 Codex 选工具实测](docs/reports/2026-11-03-mcp-discovery-and-task-selection.md) — 50 → 55 项、四类真实需求的调用和落盘结果。
- [导出耗时与快速审阅实测（2026-11-02）](docs/reports/2026-11-02-export-profile-review.md) — 107 路输入的教程导出慢在反复解码静止叠层；改完的阶段计时和快速审阅预设的实测。
- [成片检查实施与验证（2026-11-02）](docs/reports/2026-11-02-video-inspection.md) — `inspect_video` 的隔离验证：真实混音 / 画面 / 字幕和试听证据，不改工程。
- [顶部工作台、统一设置与 MCP 验收](docs/reports/2026-10-31-workbench-settings.md) — 单排工具栏、五类统一设置、设置工具的实际证据。
- [Sky Studio 生成与配音真实验收](docs/reports/2026-10-29-sky-studio-generation-and-voice.md) — 6b 五类、6c 旁白 / 合批克隆 / 排队退款、累计积分账。
- [测试版 0.18.48：导出水印和 Claude 桌面版「连接」的冒烟](docs/reports/2026-10-27-beta-watermark-and-claude-desktop-smoke.md) — 水印落点对表；桌面版要真重启才重读配置。
- [真 Codex 连 SkyCut 的冒烟（0.18.47）](docs/reports/2026-10-26-codex-client-smoke.md) — 连接 / 断开、12 步全通；撞出悄悄丢参数和备份权限两个问题。
- [AI 多开补测：屏幕亮着走界面项（0.18.42 → 0.18.45）](docs/reports/2026-10-18-ai-multi-project-ui-smoke.md) — 撞出并修掉三个问题（#241–#243）；怎么在用户用着电脑时测。
- [第四批 AI 反馈的测试版冒烟（0.18.46）](docs/reports/2026-10-18-ai-feedback-batch4-smoke.md) — 折行断在词组边界；`listen cuts` 和 cut_speech 的建议一致。
- [改名 SkyCut 之后的冒烟（0.18.47）](docs/reports/2026-10-18-skycut-rename-smoke.md) — 授权不用重给、两种工程后缀都能开；菜单栏的 App 名取可执行文件名。
- [AI 多开第 ① 刀的冒烟（0.18.38）](docs/reports/2026-10-17-open-projects-slice1-smoke.md) — 两个工程窗口各管各的；撞出「先放内容后挂 delegate」并修好。
- [AI 多开第 ② 刀的冒烟（0.18.39）](docs/reports/2026-10-17-ai-project-routing-slice2-smoke.md) — 一个会话两个工程各进各的、别的会话碰不到；撞出 open_folder 报旧文件夹。
- [AI 多开第 ③ 刀的冒烟（0.18.41）](docs/reports/2026-10-17-ai-headless-slice3-smoke.md) — 后台工程（0 个窗口）全流程；锁屏时别拿 CG 窗口列表判断窗口关没关。
- [AI 多开第 ④ 刀的冒烟（0.18.42）](docs/reports/2026-10-17-ai-queue-version-slice4-smoke.md) — 一个文件夹两个版本、导出和字幕排队；方案四刀做完。
- [第三批 AI 反馈的测试版冒烟（0.18.35）](docs/reports/2026-10-16-ai-feedback-batch3-smoke.md) — `listen cuts=true` 和字幕行距真机过一遍，撞出 quiet_spot 的 bug。
- [字幕默认单行 + 行数开关的测试版冒烟（0.18.37）](docs/reports/2026-10-16-subtitle-line-count-smoke.md) — `max_lines` 和面板两条路结果一样、撤销各退一层。
- [视频 upscale 实测：六个 fal 模型、19 条真素材](docs/reports/2026-10-02-upscale-smoke-test.md) — 各家的计费规律、只有 FLUX 保留声音、帧数的坑。
- [AI 接口（MCP）第六块实施报告](docs/reports/2026-09-29-mcp-slice6-report.md) — fal.ai 生成：模型表、Key、每日上限、`generate_media`；没对真 fal 验过的。
- [AI 接口（MCP）第三块实施报告](docs/reports/2026-09-28-mcp-slice3-report.md) — 分析数据 + 智能剪：`transcribe`、`listen beats`、`cut_speech`、`cut_to_beat`。
- [AI 接口（MCP）第四块实施报告](docs/reports/2026-09-28-mcp-slice4-report.md) — 本机识别画面：分镜头、一次看几个文件、铺满跟拍；探针实测。
- [AI 接口（MCP）第五块实施报告（进行中）](docs/reports/2026-09-28-mcp-slice5-report.md) — 剪辑风格、配音（macOS / Kokoro 的探针与接入）、逐词高亮字幕；验收实剪第一轮。
- [AI 接口（MCP）第一块实施报告](docs/reports/2026-09-27-mcp-slice1-report.md) — 23 个工具、CI 与端到端证据、测试版怎么出（`scripts/build-beta-app.sh`）。
- [AI 接口（MCP）第二块实施报告](docs/reports/2026-09-27-mcp-slice2-report.md) — AI 的手和眼（画面放法、去黑边、`look`、`listen`）和现有功能铺满，工具 23 → 37 个。
- [原生录屏实施报告](docs/reports/2026-08-06-native-screen-recording-implementation-report.md) — Phase 0–5 的真实进度、实测证据、偏差和未完成项。

## 架构与长期约束索引

每份一行：链接 + 这份文档管什么。约束本身在文档里；改哪块该读哪几份，见上面「按修改范围选必读文档」。

- [MCP 说明书（skycut_guide）](docs/architecture/mcp-guide.md) — 按需读的工具说明：只有它预先加载、每个工具一个同名主题、目录 ≤ 5,000、一次 ≤ 6,000 且长的分节。
- [SkyCut 官网](docs/architecture/skycut-website.md) — `website/`：只在本地预览、合并 main 后才部署；首屏静图与渐进增强、样式表的先后、小字读得清、SEO / GEO、Guides 文章、对外不提 GitHub。
- [MCP 功能发现与升级后的重连](docs/architecture/mcp-discovery.md) — 分别核对 App、helper 与客户端实际的 schema；最小示例、重连步骤。
- [写代码的规范](docs/architecture/coding-standards.md) — 模块化六条、单文件目标 400 / 上限 600 行、老文件只许降的基线、审查清单。
- [开着的工程（OpenProjects）](docs/architecture/open-projects.md) — 工程不再是单例：注册表、短 id、全 App 一个代号计数、每个工程自己的撤销、工程窗口、后台工程；谁该找哪一个工程。
- [签名与系统权限](docs/architecture/code-signing-and-permissions.md) — 固定的自签名证书「SrtFlow Signing」（永不重建、仓库钉 SHA-1）；系统授权按签名记账；钥匙串每个新构建仍要输一次密码。
- [产品名与代码名](docs/architecture/product-name.md) — 看得见的叫 SkyCut；身份（bundle id、UTType、钥匙串、数据文件夹…）和代码名永远沿用 SrtFlow。
- [AI 接口（MCP）](docs/architecture/ai-control-mcp.md) — 三段结构（客户端 → `skycut-mcp` → App）、工具清单只有一份、通道、工具在 App 里的规矩（一个工具 = 一步撤销、不弹模态框、只有删文件才问…）、「连接 AI」。
- [视频 upscale](docs/architecture/video-upscale.md) — 片段送 Sky Studio 放大：范围带余料、成品的声音自己封回原片的、做完不替换（对比后才换源）、花积分的规矩。
- [优化媒体](docs/architecture/optimized-media.md) — 预览画面的代理：只转长 GOP 的源、换源只换画面不动时间账、停着才换、成片永远原片；缓存与设置。
- [音频引擎](docs/architecture/audio-engine.md) — 时间线的声音只有这一份（预览实时、成片离线）；渲染块实时安全；图只在要出声时开着（空闲 2 分钟停）。
- [fal.ai 生成](docs/architecture/fal-generation.md) — 历史文档：2026-10-29 起都已迁到 Sky Studio，仅供复盘，不作新实现的依据。
- [合成音效](docs/architecture/sound-effect-synth.md) — 16 个预设：落点 `hit_at` 是合同、同参数同文件（改声音要 +1 version）、写文件只经 `AIAudioFileWriter`。
- [声音库：参考录音、工具和界面、变声](docs/architecture/voice-library.md) — 参考录音的规格和有声门限、界面和 AI 工具同一条路、收费单只下一次、变声的落地。
- [联动](docs/architecture/timeline-linkage.md) — 压在主轨块上的东西跟着它的画面走：十二条规矩、规则只在 `TimelineLinkage.follow` 一处、场景表。
- [剪辑页上记住的开关](docs/architecture/editor-remembered-toggles.md) — 默认值和记忆只有 `EditorToggles` 一份；播放跟随默认关、联动默认开；磁吸跟着工程走。
- [时间线缩放](docs/architecture/timeline-pinch-zoom.md) — 锚点（捏合钉指针、工具栏钉播放头）从滚动几何量；纵向缩放统一行高。
- [时间线上的复制 / 剪切 / 粘贴](docs/architecture/timeline-clipboard.md) — 剪贴板只有一套且不写纯文本、换新身份走编码往返、落点鼠标优先、撞上往上抬。
- [工程文件与素材重链接](docs/architecture/video-edit-project-file.md) — 格式（版本表到 v34）、定位、脏标记与自动保存、换成 upscale 文件的段。
- [时间线拖动手势](docs/architecture/timeline-drag-gestures.md) — 坐标系、吸附与对齐线、唯一落点、拖动会话不进 `@State`、框选、整条时间线只许一个拖放落点、插入缝与整轨换位。
- [预览自由变换](docs/architecture/preview-free-transform.md) — `ClipPlacement` 与预览 / 导出同账；合成的一份时间账。
- [关键帧动画](docs/architecture/keyframe-animation.md) — 源时间锚定、切片与 fill + matte、缓动、AI 接口。
- [工程帧率](docs/architecture/project-frame-rate.md) — 唯一事实来源、容差空间与回归矩阵。
- [声音：音量与渐入渐出](docs/architecture/audio-fades.md) — 唯一夹紧点、转场仲裁、dB 换算、只换增益的快路径。
- [声音场景](docs/architecture/sound-scenes.md) — 效果跑在引擎的渲染块里（段增益之后、推子之前）、一段一条链、余音越过段尾。
- [成片的声音](docs/architecture/export-audio-mixdown.md) — 就是预览那个引擎离线渲出来的；导出图里不许有声音滤镜；真峰值限幅、响度只报。
- [音量曲线](docs/architecture/audio-volume-curve.md) — 曲线属于段（有点时取代 `volume`）、两条管线同一张折线表。
- [波形与深度缩放](docs/architecture/audio-waveform.md) — 一个文件读一次的三层精度；Canvas 只画 `clipBoundingRect`。
- [推子与电平表](docs/architecture/audio-mixer.md) — 三级增益一条账；电平从渲染块来（无锁槽）；已知的偶发。
- [画面渐入渐出](docs/architecture/video-fades.md) — 渐变露出的是下一层、alpha 斜坡两条管线同账、和声音共用夹紧规则。
- [主轨转场：借余料与定格补足](docs/architecture/transition-handles.md) — 不挪用户片段、余料不够用首尾帧定格补、定格字段只在渲染副本里。
- [画面段的入场 / 出场动画](docs/architecture/clip-animation.md) — 五种效果落在三种斜坡上、和画面渐变共用一个槽、铺满不露边。
- [视频轨对等化](docs/architecture/video-tracks.md) — 取消画中画、一轨一色、⌥ 点击穿透、轨道头这一列的动作。
- [用户文本文件的编码](docs/architecture/text-file-encoding.md) — 只走 SrtFlowCore 的 `TextDecoding`；UTF-16 不许无条件排在 GBK 前面。
- [画面文字](docs/architecture/text-overlays.md) — 唯一的绘制入口、版面框即定位框、九种动画与「只逐帧渲动画段」、数字元件、文字行。
- [滤镜](docs/architecture/filters.md) — 时间轴上的调色段、层号进模型、预览挂图层滤镜、纯黑不抬、两条管线的对齐约束。
- [画面上的形状](docs/architecture/shapes.md) — 所有种类画什么只有 `ShapeOutline.drawing` 一份（预览 / 导出 / look 同一条路径）；入场 / 出场动画。
- [盖一块：模糊 / 马赛克](docs/architecture/cover-blur-mosaic.md) — 形状的一种、不跟着片段走；三条管线按构造一致；八条硬约束。
- [录屏生命周期](docs/architecture/screen-recording-lifecycle.md) — 状态机、journal、恢复、退出与快照；AI 起的会话走同一条流程。
- [Inspector 数值框](docs/architecture/inspector-scrub-number-field.md) — 写入、取消、焦点与光标合同。
- [检查器的排版](docs/architecture/inspector-layout.md) — 固定窄栏（约 220pt）：一行不许比它宽、菜单 Picker 不许锁宽度。
- [定格](docs/architecture/freeze-frame.md) — 一次性提交、PNG 归属、波纹范围与静帧管线。
- [字幕语言流](docs/architecture/subtitle-language-flow.md) — 目标语言可见性、预检与自动检测。
- [字幕轨可见性与布局](docs/architecture/subtitle-track-visibility-and-layout.md) — 原文 / 译文两条独立轨、画面上的布局、工程自己的样式与逐词高亮；折行和行框与成片同一份。
- [轨道块标记](docs/architecture/clip-markers.md) — 源时间锚定、标记对所有选择互斥、单击只选中双击才弹面板。
- [即时提示](docs/architecture/instant-tooltips.md) — 不许用系统 `.help`、快捷键单一来源、面板的硬约束。
- [本地化](docs/architecture/localization.md) — 写死的文案每张表都要有、sheet / popover 不继承应用内语言、加一种语言只做两件事。
- [阻塞的媒体读取](docs/architecture/blocking-media-reads.md) — 会卡住线程的读取不许进 Swift 并发线程池；`MediaReadQueue`；引擎启动探测。
- [挂起主线程抓栈](docs/architecture/main-thread-stack-capture.md) — 挂起期间只做系统调用和裸读写：不分配、不拿锁；挂起和恢复只在 `walkWhileSuspended`。
- [预览性能 ratchet](docs/architecture/preview-perf-ratchet.md) — 量的是活不是 CPU、每个视图 body 第一行计数、基线只许降、已知的偶发误报、块不读工程、订阅时钟的名单。
- [导出设置](docs/architecture/export-settings.md) — 分辨率档位封的是短边、只降不升；面板上只放管线真消费的设置；文件名与撞名。
- [导出水印](docs/architecture/export-watermark.md) — 只加在剪辑导出的成片上、加不加只问 `WatermarkPolicy`、落在烧字幕之后缩小之前。
- [Sky Studio 账号](docs/architecture/sky-studio-account.md) — `sk-` Key 存钥匙串、只有 `SkyStudioAPI` 碰地址、此刻的授权是纯函数 `SkyCutLicense`、照授权拦（`SkyCutGates`）。
- [Sky Studio 的任务](docs/architecture/sky-studio-jobs.md) — 生成 / upscale / 声音走 `/models`、`/quote`、`/uploads`、`/jobs`：价只问 `/quote`、交任务只经 `SkyStudioJobRun`、只有排队中的能取消。
- [生成的字幕长什么样](docs/architecture/subtitle-generation-style.md) — 先断句后去标点、一行多长、默认单行、显示时间、几段素材同时有字只留一条。
- [按旁白段落同步时间线](docs/architecture/voiceover-timeline-sync.md) — 显式映射、实测音频与原稿对齐，共用批量事务，一次撤销且不重复联动。
- [官方原创短片](docs/architecture/official-film.md) — 公开镜头 / 声音合同、真实引用报价、不透明 pin；私有配方不进客户端。
- [界面主题](docs/architecture/app-themes.md) — 森林色默认、经典色保留原色；全 App 同一偏好、不进工程；浅 / 深只有 `AppThemePalette.colorScheme` 一条、不交 nil。
- [段的显隐](docs/architecture/clip-visibility.md) — 整轨的眼睛与单段的 V：藏起来的段不进预览、成片和转写；过滤只有 `ClipVisibility.visible` 和 `rendered*` 清单一份。
- [成片疑点检查](docs/architecture/finished-video-inspection.md) — `inspect_video` 只报告、不改工程：冻结工程和范围、回任务号，`get_job` 给疑点和拼图。
- [MCP 编辑参数合同](docs/architecture/mcp-edit-parameters.md) — 范围来自生产代码、越界拒绝并给合法建议、限幅回实际值、先全验再提交、素材没就绪回 loading。
- [顶部工作台与统一设置](docs/architecture/workbench-and-settings.md) — 单排工作台、唯一的设置窗口、`get_settings` / `set_settings` 的合同、AI 操作权限与草稿预算。

## Bug 修复案例索引

每条一行：日期 + 链接 + 一句教训，新案例加在模板下面（按日期从新到旧）。经过、根因、验证都在案例里，这里不写摘要。

- [Bugfix 模板](docs/bugfixes/TEMPLATE.md) — 新案例必须使用的结构。
- [2026-11-11 官网小字：手机上小于 12 px、对比度不够、标题跳级](docs/bugfixes/2026-11-11-website-small-text-contrast-headings-font-shift.md) — 缩小的示意图到手机上要么读得了、要么不显示；小字颜色用量过的变量，行高别留 normal。
- [2026-11-11 官网首页在手机和 iPad 上版面全乱](docs/bugfixes/2026-11-11-website-phone-layout-lost-to-stylesheet-order.md) — 样式表之间的先后不是合同：每份样式表自带自己的平板 / 手机规则。
- [2026-11-11 预览的音频引擎一直开着，Mac 不睡](docs/bugfixes/2026-11-11-preview-audio-engine-never-idles.md) — 图只在要出声时开着；状态按状态判、别按通知判；引擎单独量的数放进 App 要再量。
- [2026-11-11 森林色切经典色，开着的窗口只变一半](docs/bugfixes/2026-11-11-theme-switch-leaves-windows-half-light.md) — `.preferredColorScheme` 交过明确值就别再交 nil。
- [2026-11-11 森林色的提示外面套着一圈直角方框](docs/bugfixes/2026-11-11-tooltip-square-frame-in-forest-theme.md) — 透明面板的根要自己裁成气泡的形状；截图里每处异样都要对上原因再结案。
- [2026-11-11 系统深色时按钮提示深底深字](docs/bugfixes/2026-11-11-tooltip-dark-on-dark-in-forest-theme.md) — `.preferredColorScheme` 只改得了宿主是 contentView 的窗口，嵌套的宿主要设 `windowAppearance`。
- [2026-11-11 钥匙串只是慢，AI 却被叫去点 Allow](docs/bugfixes/2026-11-11-keychain-slow-read-told-to-click-allow.md) — 期限到了只说明还没回答；能分开的原因别报成同一个结果。
- [2026-11-11 重启后不记得在建的声音库那一单](docs/bugfixes/2026-11-11-voice-library-job-after-restart.md) — 账在盘上，它要结的那一单也得在盘上；能去重的在问用户之前去重。
- [2026-11-11 关掉全部权限的回答里长期授权还写「已记上」](docs/bugfixes/2026-11-11-set-settings-stale-standing-consent.md) — 一个回答里同一件事出现两次，两份要在同一时刻取。
- [2026-11-11 静帧自检的耗时断言在 CI 上误报](docs/bugfixes/2026-11-11-still-clip-encode-timing-flake.md) — 尺子要和被量的是同一种活、同一次运行里量；能数的别拿时间推。
- [2026-11-11 设计声音的报价说不出用哪个模型](docs/bugfixes/2026-11-11-design-quote-model-name.md) — 假服务要照真回答的形状造（`model` 在 `voice_plan.selection` 里）。
- [2026-11-11 manage_voices 非要 AI 给 language](docs/bugfixes/2026-11-11-manage-voices-language-required.md) — 期望值要从方案来：实现、说明、检查三处一起错谁也不红。
- [2026-11-11 设计声音连按下了好几单](docs/bugfixes/2026-11-11-design-voice-ordered-twice.md) — 会花钱的按钮按下去就锁，同一件事只开一单。
- [2026-11-11 声音库审查的后续](docs/bugfixes/2026-11-11-voice-library-review-followups.md) — 过闸之前先看在建的那一单；费用的问题受理后才清。
- [2026-11-10 后台的 AI 活被 App Nap 降速](docs/bugfixes/2026-11-10-ai-work-throttled-by-app-nap.md) — AI 的调用和任务各领一份 `AIKeepAwake`，领和还成对。
- [2026-11-10 停下几批旁白只说最先出事的那批](docs/bugfixes/2026-11-10-voiceover-stop-reports-one-batch.md) — 按 `batch_index` 逐批说清，结果不明的句子也要列出来。
- [2026-11-10 繁体旁白合批后切不开，付过钱卡死](docs/bugfixes/2026-11-10-traditional-chinese-batch-split-fails.md) — 对字要折叠繁简、转写语言带字形；假转写不能照抄稿子。
- [2026-11-10 一句拆两批，两种采样率接不起来](docs/bugfixes/2026-11-10-long-line-halves-with-different-sample-rates.md) — 拼接前换成同一个采样率；假协议要按模型回不一样的格式。
- [2026-11-10 转写不了的 Mac 上合批旁白卡死](docs/bugfixes/2026-11-10-packed-batch-without-word-times-stuck.md) — 拿不到字的时间就按字数估句界并报出来，不无限重试。
- [2026-11-10 声音 PR 3–5 审查的几处小问题](docs/bugfixes/2026-11-10-voiceover-review-followups.md) — 换了模型 / 声音要在 `get_job` 里说；批次上限按每句自己的文字。
- [2026-11-10 加已有语言的录音：先问授权、传完才被拒](docs/bugfixes/2026-11-10-add-reference-asks-before-reading-the-voice.md) — 问之前先读对象，能当场拒的别等传完；问句写名字不写 id。
- [2026-11-10 并发检查断言了假服务没按住的完成顺序](docs/bugfixes/2026-11-10-voice-concurrency-check-finish-order.md) — 只断言被按住的那一对的先后。
- [2026-11-10 Sky Studio 接线守卫最后三节从来不会红](docs/bugfixes/2026-11-10-sky-studio-wiring-checks-after-exit.md) — 总闸（失败就 `exit 1`）必须在脚本最后。
- [2026-11-10 云端配音的字幕显示的是转写听成的字](docs/bugfixes/2026-11-10-voiceover-subtitles-show-transcribed-text.md) — 字从稿子来、时间从转写来（`SpeechWordAlignment`）；假转写要会「听错」。
- [2026-11-10 AI 把「画质尽量好」当成点名规格，跳过确认](docs/bugfixes/2026-11-10-overrides-best-quality-skips-approval.md) — 越档要在 `user_request` 的原话里找得到规格的名字。
- [2026-11-10 add_voiceover 会问、却不收 confirm_token](docs/bugfixes/2026-11-10-voiceover-confirm-token-refused.md) — 名片写着 needs_confirmation 的工具都要收 `confirm_token`。
- [2026-11-10 实测证据里漏了本机路径](docs/bugfixes/2026-11-10-measurement-evidence-local-paths.md) — 脱敏按形状换（临时目录、家目录）；进仓库的证据有守卫扫。
- [2026-11-10 浮点素材里的坏采样让 App 崩掉](docs/bugfixes/2026-11-10-voice-reference-nan-sample-crash.md) — 转整数前先排除 NaN / ±Inf、在浮点上夹范围。
- [2026-11-10 参考录音的有声门限借了配音响度的常量](docs/bugfixes/2026-11-10-voice-reference-floor-borrowed-from-voice-level.md) — 和服务器的合同常量单独写死，不借别处的。
- [2026-11-10 克隆的参考录音被降到 16 kHz、只截 10 秒](docs/bugfixes/2026-11-10-voice-reference-16khz-short-sample.md) — 参考录音有自己的规格和读取器，不复用字幕生成的 16 kHz 那个。
- [2026-11-10 说明书的 fields 漏写可选值、类型和条数](docs/bugfixes/2026-11-10-guide-fields-drop-schema-facts.md) — 参数定义里的事实一样不漏，守卫按路径核对每一行。
- [2026-11-10 说明书要等授权问完才回答](docs/bugfixes/2026-11-10-guide-waits-for-license.md) — `skycut_guide` 在等授权之前就放行。
- [2026-11-07 新构建的钥匙串密码框堵住 AI 调用](docs/bugfixes/2026-11-07-keychain-prompt-blocks-ai-calls.md) — 静默读有 3 秒期限、交互读串行；每个构建只给一次非模态的授权提示。
- [2026-11-07 生成图片的扩展名和实际字节不符](docs/bugfixes/2026-11-07-generated-image-extension-from-bytes.md) — 下载后按实际字节定扩展名、不重编码；交付失败不重新生成。
- [2026-11-07 真积分验收后的五处 AI 工具结果](docs/bugfixes/2026-11-07-ai-tool-results-after-character-smoke.md) — 列表回有界的摘要；终态清掉旧阶段；落盘图片报实测尺寸。
- [2026-11-06 录屏已保存却没清楚告知界面和 MCP](docs/bugfixes/2026-11-06-screen-recording-completion-feedback.md) — 完成要有非模态的通知，原会话下一次工具结果里附言。
- [2026-11-06 另一个构建接管了正在录制的账本](docs/bugfixes/2026-11-06-screen-recording-manifest-cross-build.md) — 录屏账本按 bundle id 隔离。
- [2026-11-06 台数满了却引导再买 Pro](docs/bugfixes/2026-11-06-machine-limit-purchase-guidance.md) — 台数的原因优先：只给管理 Mac / 客服，不给购买入口。
- [2026-11-06 Pro 快到期和续费宽限没有提醒](docs/bugfixes/2026-11-06-pro-renewal-and-payment-grace-notices.md) — 设置 / 导出 / AI 共用同一份提醒；说明字段不改功能授权。
- [2026-11-05 声音恢复成功，自检却因固定等待窗口报红](docs/bugfixes/2026-11-05-player-clock-recovery-check-timing.md) — 异步的自检用分阶段的有界条件等待，不用一个固定窗口。
- [2026-11-05 官网演示停在封面且轨道像宽图](docs/bugfixes/2026-11-05-website-demos-stall-on-posters.md) — 视口内主动加载、用解码器时钟；还原旧代码确认守卫变红。
- [2026-11-05 官网 404 被标成英文首页的副本](docs/bugfixes/2026-11-05-website-404-canonical-is-home.md) — 错误页有独立 canonical，确认 / 404 页不收录。
- [2026-11-05 官网未正确识别部分中文设备语言](docs/bugfixes/2026-11-05-website-device-language-falls-back.md) — 根入口按首选语言匹配，所有中文变体用简中，不支持的默认英文。
- [2026-11-05 新下载包被上传前的 404 缓存挡住](docs/bugfixes/2026-11-05-release-download-cached-404.md) — 上传前别探测公开 URL（会留下 4 小时的缺失缓存）：内容寻址对象先传后验。
- [2026-11-05 声音主时钟停住导致预览无法播放](docs/bugfixes/2026-11-05-audio-master-clock-stops-playback.md) — 播放意图不代表音频图仍在运行：开播前和播放中恢复停图、重钉锚点。
- [2026-11-04 CI 的 .build 缓存从没省下过一次编译](docs/bugfixes/2026-11-04-ci-build-cache-never-saved-a-compile.md) — 修改时间按内容设、每组一份按提交存、只在 main 上存。
- [2026-11-04 四条扫描守卫 CI 一次都没跑过](docs/bugfixes/2026-11-04-scan-guards-never-ran-in-ci.md) — 新守卫必须进 check-all 的清单（`checks/check-all-shards.sh` 钉着）。
- [2026-11-04 非零起点让原生尾帧请求落到前一个刻度](docs/bugfixes/2026-11-04-native-frame-request-truncation.md) — 换格子显式取最近的 1/600，不靠截断。
- [2026-11-04 定格拒绝首个使用帧](docs/bugfixes/2026-11-04-freeze-rejects-first-used-frame.md) — 定格用自己的半开区间，段首前插保留完整原段。
- [2026-11-04 换 Key 后旧模型目录回填](docs/bugfixes/2026-11-04-catalog-cache-key-change.md) — 缓存失效要带 epoch，拦住迟到的写回。
- [2026-11-04 成片检查没有疑点却报绘图失败](docs/bugfixes/2026-11-04-inspection-empty-evidence.md) — 分析取样和疑点截图分开；真请求了证据却取不到才算失败。
- [2026-11-04 后台引擎短探测无限等待且重复启动](docs/bugfixes/2026-11-04-engine-probe-hangs.md) — 短探测共享截止时间和输出上限、唯一父进程回收、定位只跑一次。
- [2026-11-04 官方配方收费前被拒，本机预留没释放](docs/bugfixes/2026-11-04-official-recipe-rejection-reservation.md) — 精确的「未准入」和一般 503 分开；被拒要释放预留并留证据。
- [2026-11-04 官方镜头等到名额后仍用旧提交条件](docs/bugfixes/2026-11-04-official-generation-slot-revalidation.md) — 每次收费 POST 之前重新核对账户 / 工程 / 文件 / 有效期。
- [2026-11-04 查原任务时没核对回答里的任务号](docs/bugfixes/2026-11-04-sky-studio-poll-identity.md) — GET 原单在 API 边界就验任务号，错的回答不许先改状态。
- [2026-11-04 清理脚本自检删掉了活动冒烟 App 的 socket](docs/bugfixes/2026-11-04-smoke-cleanup-unlinks-live-socket.md) — 清理器的测试必须隔离文件删除。
- [2026-11-04 官方生成把确认问题缓存成已完成](docs/bugfixes/2026-11-04-official-confirmation-cached-as-completion.md) — 只缓存有真实任务号的启动结果；确认解除后重新过闸。
- [2026-11-04 取消 listen 时跨线程拆掉正在读的 reader](docs/bugfixes/2026-11-04-listen-reader-cancel-during-copy.md) — 原生 copy 和取消不能并发，取消只在读取体那一处收。
- [2026-11-03 文件 listen 的短区间仍读整条音轨](docs/bugfixes/2026-11-03-listen-file-range-reads-whole-audio.md) — 给了源范围就用原生 timeRange 有界读取。
- [2026-11-03 本地构建后缀进了版本头，模型目录被拒](docs/bugfixes/2026-11-03-local-version-header.md) — 版本头只在共享的请求边界规范化。
- [2026-11-03 短导出卡在退出等待](docs/bugfixes/2026-11-03-ffmpeg-exit-wait-runloop.md) — 启动前注册退出回调、排空双管道后再汇合。
- [2026-11-03 MCP 最小示例与真实参数提示](docs/bugfixes/2026-11-03-mcp-usage-guidance.md) — 示例要过参数定义的校验；写错的参数名在结果里提示对的。
- [2026-11-02 helper 更新了清单不等于客户端发现了新工具](docs/bugfixes/2026-11-02-mcp-catalog-refresh-reporting.md) — 分别核对 App、helper、客户端实际拿到的 schema。
- [2026-11-02 导出反复解码静止的文字和形状](docs/bugfixes/2026-11-02-export-redecodes-static-overlays.md) — 静止叠层只解码一次、按本段复制已解的帧；默认质量不变。
- [2026-11-02 MCP 直接指定源画面矩形取景](docs/bugfixes/2026-11-02-mcp-source-region-framing.md) — region 复用原生裁切与 fill 几何，look 和导出同账。
- [2026-11-02 MCP 参数被静默截短，返回值与时间线不一致](docs/bugfixes/2026-11-02-mcp-parameter-limits-and-feedback.md) — 先全验再提交；限幅要回 requested / applied，成功后才开撤销组。
- [2026-11-01 AI 权限与草稿预算](docs/bugfixes/2026-11-01-ai-approval-and-draft-budget.md) — 代理改权限始终要确认；日预算是硬上限。
- [2026-11-01 旁白云端已生成、本地失败后只能人工找回](docs/bugfixes/2026-11-01-voiceover-local-failure-recovery.md) — 每批原音频、映射和进度落盘；默认只恢复已有结果，稳定身份防重复入轨。
- [2026-11-01 更换旁白后画面、标题和字幕仍在旧时间](docs/bugfixes/2026-11-01-voiceover-timeline-sync.md) — 按显式段落映射重新对齐，共用批量事务、避免联动二次位移。
- [2026-10-31 小窗口的分栏线穿过 AI 状态](docs/bugfixes/2026-10-31-ai-badge-divider-bleed.md) — 半透明徽章会漏出后景：垫不透明的底色。
- [2026-10-31 多工程的生成任务没有工程归属](docs/bugfixes/2026-10-31-cloud-tasks-without-project-context.md) — 任务卡片按原工程分组，数量只算进行中的。
- [2026-10-31 七个 Sky Studio 模型与原单结算](docs/bugfixes/2026-10-31-sky-studio-model-expansion.md) — 同 key 只起一单，失败只查原单，扣退费只认 billing。
- [2026-10-30 添加 Key 后旧 AI 会话仍缺生成工具](docs/bugfixes/2026-10-30-generation-tools-missing-after-key-added.md) — 工具始终列全，Key、授权和积分在执行时核对。
- [2026-10-30 生成固定首个模型且缺少多参考](docs/bugfixes/2026-10-30-generation-models-and-reference-inputs.md) — 模型默认值和参考限制可查询；真人拒绝只在退款明确后替换一次。
- [2026-10-30 多项生成横幅挤占预览](docs/bugfixes/2026-10-30-cloud-tasks-cover-preview.md) — 工具栏单入口 + 滚动浮层汇总任务；取消不先删状态。
- [2026-10-29 两种视频拿到同一个确认码](docs/bugfixes/2026-10-29-sky-studio-confirmation-collides.md) — 摘要相同不等于同一件事：确认码绑定完整请求、报价、输入文件和落点。
- [2026-10-29 提交返回的瞬间取消，丢了任务号](docs/bugfixes/2026-10-29-cancelled-submit-loses-job-id.md) — 付费提交的身份先交给调用方，然后才能抛停止。
- [2026-10-29 旁白只读第一块词时间、字幕越过音频尾端](docs/bugfixes/2026-10-29-voice-word-chunks-and-tail.md) — 完整性和时间边界按整份回答和实际文件验，不只测首块样例。
- [2026-10-29 冒烟清理只凭陈旧 PID 停进程](docs/bugfixes/2026-10-29-smoke-stop-stale-pid.md) — 持久 PID 不是进程身份：清理前核对当前命令和测试目录。
- [2026-10-29 MCP 冒烟丢掉失败，后台包装又报成功](docs/bugfixes/2026-10-29-mcp-smoke-hides-failures.md) — 断线 / 坏协议必须显式失败，包装原样传退出码。
- [2026-10-29 损坏的 MCP 回答 id 让读线程退出](docs/bugfixes/2026-10-29-invalid-mcp-smoke-response-id.md) — 协议层先核对字段类型；坏帧必须唤醒等待者。
- [2026-10-28 体验显示「还剩 8 天」、到期日晚一天](docs/bugfixes/2026-10-28-trial-and-pro-dates-shown-a-day-late.md) — 「拿到回答 − 服务器时间」不全是钟差；日历上的哪一天照服务器给的。
- [2026-10-28 Upscale 面板上不肯报价的那一行只写「—」](docs/bugfixes/2026-10-28-upscale-panel-hides-why-quote-failed.md) — 会因内容失败的请求，原因要上界面；规则在服务器上的照它的话说。
- [2026-10-28 停不下来的 upscale 没人再查](docs/bugfixes/2026-10-28-uncancellable-upscale-left-unfinished.md) — 没有长轮询：取消不了的那单接着查到底（`followToEnd`）。
- [2026-10-28 检查器 Upscale 那一节还写着「fal.ai」](docs/bugfixes/2026-10-28-upscale-inspector-still-says-fal.md) — 换提供方要连 verbatim 写死的名字一起搜。
- [2026-10-27 连接 AI 客户端时留的配置备份谁都能读](docs/bugfixes/2026-10-27-client-config-backup-world-readable.md) — 「另写一份」不等于「拷一份」：备份的权限从原文件来。
- [2026-10-27 AI 传了说明上没有的参数，悄悄丢掉、照样做](docs/bugfixes/2026-10-27-unknown-tool-arguments-silently-ignored.md) — 「读得宽」只能对值、不能对名字：不认识的参数名整个调用不做。
- [2026-10-18 侧边栏「AI 在剪的工程」只有标题、没有行](docs/bugfixes/2026-10-18-ai-projects-sidebar-rows-never-shown.md) — List 里 body 带 `Section` 的视图不许套 `.equatable()`。
- [2026-10-18 别的工程的导出显示在每个工程窗口里](docs/bugfixes/2026-10-18-export-progress-shown-in-every-project-window.md) — 单例的状态在多开之后要问「是谁的」（`exporter.belongs(to:)`）。
- [2026-10-18 侧边栏那一行看不到百分比、排队也写「导出中」](docs/bugfixes/2026-10-18-ai-projects-sidebar-row-status.md) — 窄栏里给长短不定的字整行；「有任务」不等于「在做」。
- [2026-10-18 listen cuts=true 说可以不改，cut_speech 却说切在字上](docs/bugfixes/2026-10-18-cut-check-disagrees-with-cut-speech.md) — 检查类工具说「X 会怎么做」就用 X 的输入、读 X 的决定（`AISpeechHearing`）。
- [2026-10-18 字幕自动折行把中文的词拆在两行](docs/bugfixes/2026-10-18-subtitle-wrap-splits-chinese-words.md) — 「能断」和「断在这儿好」是两件事：中日文只在词和词之间断，同一件事别写两份。
- [2026-10-18 仓库改名后 CI 五组全部编不过](docs/bugfixes/2026-10-18-ci-build-cache-breaks-after-repo-rename.md) — 记着绝对路径的缓存，key 里就得有那个路径。
- [2026-10-17 冒烟拷工程把整个「下载」拷走、写满磁盘](docs/bugfixes/2026-10-17-copy-project-copied-all-of-downloads.md) — 整夹拷之前先看来源是什么文件夹；测试工具也要设防。
- [2026-10-17 open_folder 的结果里 output_folder 还是上一个](docs/bugfixes/2026-10-17-open-folder-reports-previous-output-folder.md) — task-local 里只放整个调用里不变的身份，会变的状态现查。
- [2026-10-16 edit_clip 改入点的语义只写在注释里](docs/bugfixes/2026-10-16-edit-clip-trim-semantics-undocumented.md) — 和界面惯例不一样的行为要写进给 AI 的说明。
- [2026-10-16 listen cuts=true 建议的那一格，照做后又被报成切到字](docs/bugfixes/2026-10-16-listen-cuts-suggested-spot-reported-on-speech.md) — 检查类的工具要和自己的建议闭环。
- [2026-10-15 裁掉说的话的字幕留在原地、和下一句叠](docs/bugfixes/2026-10-15-linkage-deletes-subtitles-whose-speech-was-trimmed.md) — 一条规矩的理由只对一类东西成立时，别照搬给另一类。
- [2026-10-15 换源之后压在上面的东西被挪了一个偏移](docs/bugfixes/2026-10-15-linkage-follows-source-shift-after-swap.md) — 同 id 换素材按改之前的素材和入点记账（`Piece.rebased`）。
- [2026-10-15 联动把字幕当一整块挪](docs/bugfixes/2026-10-15-linkage-moves-subtitles-as-a-block.md) — 字幕句两头各自换算（`LinkageCueFollow`）；判「还剩多少」要量对东西。
- [2026-10-15 删除确认码被拒不说原因](docs/bugfixes/2026-10-15-confirmation-token-refused-without-reason.md) — 凭据被拒要说原因；同一个问题等答复时回同一张码。
- [2026-10-15 没记语言的字幕轨，导出的文件名不带语言标签](docs/bugfixes/2026-10-15-subtitle-file-export-missing-language-tag.md) — 语言按文字判 → 记的 → 省略，只有 `SubtitleFileLanguage` 一份。
- [2026-10-15 预览的字幕折行是贪心的，成片是摊匀的](docs/bugfixes/2026-10-15-subtitle-preview-wraps-greedily.md) — 折行点只有 `SubtitleLineWrap` 一份：照渲染器的源码 port，再真烧核。
- [2026-10-15 没有空格的长中文字幕，成片整行溢出](docs/bugfixes/2026-10-15-chinese-subtitles-overflow-without-spaces.md) — 渲染器做不到的，App 算好写成 `\N`、把它的折行关彻底（WrapStyle 2）。
- [2026-10-14 几个 AI 会话共用一个 App，改动落进别人的工程](docs/bugfixes/2026-10-14-ai-edits-land-in-another-sessions-project.md) — 共享的东西要么每个会话各一份、要么每次核对。
- [2026-10-14 滤镜把纯黑抬成灰](docs/bugfixes/2026-10-14-filters-lift-pure-black.md) — 纯黑不抬（`FilterLUT.holdingBlack`）：调色作用于画面，不作用于编辑出来的黑。
- [2026-10-14 App 卡住时 AI 只会干等两分钟](docs/bugfixes/2026-10-14-ai-calls-time-out-silently-when-app-hangs.md) — 等不到要去问、问的路不经过卡住的线程；调用方放弃了被调方要知道。
- [2026-10-14 配音的字幕在逗号处切成短条](docs/bugfixes/2026-10-14-voiceover-subtitles-split-at-commas.md) — 同一套规则用在两种来源上，差别做成显式参数（`splitsAtClauses`），不复制一份。
- [2026-10-14 带入场动画的字在成片里闪没一帧](docs/bugfixes/2026-10-14-text-blinks-at-animation-seam.md) — 序列末尾多渲两帧、各段左闭右开；自检场景要像用户的工程（不对齐的输入）。
- [2026-10-14 Kokoro 的 speed 调到 0.85 几乎听不出慢](docs/bugfixes/2026-10-14-kokoro-speed-barely-changes.md) — 参数名叫 speed 不等于线性管语速：量结果、按结果调（按时长对准）。
- [2026-10-14 AI 用 look 看转场和成片对不上](docs/bugfixes/2026-10-14-look-transitions-differ-from-export.md) — 写下的「做不到」要么去做、要么在用到的地方说出来；压黑 / 闪白照 xfade 的公式算。
- [2026-10-14 App 升级后会话里的小程序还是旧的](docs/bugfixes/2026-10-14-stale-helper-tool-list.md) — 一份接口编在两个活得不一样长的进程里，就在通道上比版本（清单指纹）。
- [2026-10-14 AI 以为成片是 720p](docs/bugfixes/2026-10-14-ai-thinks-export-is-720p.md) — AI 会拿手边任何数字当答案：该说的事实在产出它的工具结果里说。
- [2026-10-14 挪了配音段，它的字幕留在原地](docs/bugfixes/2026-10-14-voiceover-subtitles-stay-behind.md) — 字幕是声音说出来的，就跟声音走（联动规矩 11）；新入口要照样记来源。
- [2026-10-14 审美盲测撞出的六处 AI 工具小毛病](docs/bugfixes/2026-10-14-ai-tool-small-issues-from-blind-test.md) — 结果里只回一个计数等于没回；区分两种东西要挑它们真正不同的那一处。
- [2026-10-14 看门狗自检在 CI 上偶发 Bus error](docs/bugfixes/2026-10-14-watchdog-check-hook-recursion.md) — 钩子回调里「不分配」要算上运行时替你做的事（TLS、独占检查）。
- [2026-10-14 出场动画先快后慢](docs/bugfixes/2026-10-14-exit-animations-front-loaded.md) — 倒数的进度上套缓动方向会反；检查的期望值从意图来，不照实现抄。
- [2026-10-14 cut_speech 把量好的静音切口挪进词里](docs/bugfixes/2026-10-14-cut-speech-trusts-word-times.md) — 为一个用途调过偏的数据不能当另一个用途的真相；改了调用方的值要说出来。
- [2026-10-06 挪了一段音频，画面挪了、声音还在原地](docs/bugfixes/2026-10-06-audio-engine-replace-keeps-old-segment-positions.md) — 「结构没变」按开流时抄死了什么来定，不是按 id；自检要有「换配置」这一步。
- [2026-10-06 导出两次卡死：看门狗挂起主线程抓栈时分配内存](docs/bugfixes/2026-10-06-watchdog-capture-deadlocks-main-thread.md) — 挂起别的线程期间不分配、不拿锁；能数不变量就去数。
- [2026-10-05 上层轨带缓动的关键帧，成片里边缘错开](docs/bugfixes/2026-10-05-overlay-matte-drops-keyframe-easing.md) — 从旧关键帧构造新关键帧只走 remapped / clipped / stretched。
- [2026-10-03 自动检测把英文旁白判成中文](docs/bugfixes/2026-10-03-auto-detect-picks-chinese-for-english.md) — 分不开两边时找一个真能分开的特征（写成了哪种文字），别调门槛。
- [2026-10-03 透明 PNG 放到上层轨成了黑方块](docs/bugfixes/2026-10-03-png-transparency-lost.md) — 每一级都保着 alpha 不等于产物有 alpha；预乘还是直通是数据的一部分。
- [2026-10-03 关掉主窗口就退出了 App，工程变回空的](docs/bugfixes/2026-10-03-closing-window-quits-app.md) — 框架的默认生命周期要先确认；替别人兜底时把兜底这件事告诉对方。
- [2026-10-03 导出的线条两头各比预览长半个线宽](docs/bugfixes/2026-10-03-exported-lines-longer-than-preview.md) — 画法只有 `ShapeOutline.drawing` 一份；对账要比外框，不能只比重合度。
- [2026-10-03 录屏开关开着、自定义区域还是说没权限](docs/bugfixes/2026-10-03-screen-recording-permission-stale-after-update.md) — 授权记录钉着签名：用固定证书签；「开关开着却被拒」先读 TCC 的 `csreq`。
- [2026-10-03 录屏中 AI 改帧率：静默不改还回成功](docs/bugfixes/2026-10-03-set-canvas-fps-ignored-while-recording.md) — 执行入口的闸只亮提示时，AI 那一路要自己先挡。
- [2026-10-03 一条扫描被 bash 3.2 花括号展开拆开，从没生效](docs/bugfixes/2026-10-03-check-mcp-undo-scan-split-by-brace-expansion.md) — 守卫里先把命令替换赋给变量再比；反向验证用 `/bin/bash`。
- [2026-10-03 record_screen 真机首测的四处小毛病](docs/bugfixes/2026-10-03-record-screen-first-device-test.md) — 新工具合并后尽早上真机走一遍：状态组合、时序自检够不着。
- [2026-10-02 AI 起的 upscale 换源后扣费一直是「—」](docs/bugfixes/2026-10-02-upscale-cost-lookup-killed-by-remove.md) — 异步补账要追着已落地的数据写；remove ≠ cancel。
- [2026-10-02 状态行上的小标折成两行](docs/bugfixes/2026-10-02-fal-status-pill-wraps.md) — 一行里谁让步要明说（小件 `fixedSize`、长话去截）。
- [2026-10-02 「撤销这一轮」退不回 V1](docs/bugfixes/2026-10-02-undo-round-repacks-v1.md) — 「换回某一刻」不是一次编辑，别走编辑的收尾（磁吸、联动）。
- [2026-10-02 磁吸开着时改一条音量曲线就合上 V1 的缝](docs/bugfixes/2026-10-02-magnet-closes-v1-gaps-on-any-edit.md) — 会改工程内容的开关是工程的属性；一次编辑只许改它碰到的东西。
- [2026-10-01 带插值的界面文案从没进过字符串表](docs/bugfixes/2026-10-01-interpolated-keys-never-localized.md) — 判不出类型就把几种可能都试一遍，比跳过强。
- [2026-10-01 配乐比画面长的工程播到画面结尾就停住](docs/bugfixes/2026-10-01-preview-item-shorter-than-timeline-without-audio-tracks.md) — 拆掉一样东西之前先问它顺手撑着什么（合成的长度）：垫黑底到总长。
- [2026-10-01 烧录页默认宽度下字幕列被裁](docs/bugfixes/2026-10-01-burn-in-subtitle-column-clipped-at-default-width.md) — `HSplitView` 最后一栏的 ideal 要放得进；截图按用户默认的窗口大小拍。
- [2026-10-01 播放中按空格，图标慢半拍](docs/bugfixes/2026-10-01-meter-current-time-blocks-main-thread.md) — 不许同步问播放器要 `currentTime()`：读时钟外推的 `estimatedTime`。
- [2026-10-01 从 40 秒起一直有沙沙声](docs/bugfixes/2026-10-01-resampler-reset-every-chunk.md) — 流式转换器不能推式喂；周期性小毛刺要按块头 / 块中间分开量。
- [2026-10-01 搬出 builder 的代码后，一条转场守卫还在旧文件里找](docs/bugfixes/2026-10-01-pr132-first-ci-run-guard-in-moved-insert.md) — 同一个坑第三次：推之前跑 `scripts/check-guards.sh` 全部守卫。
- [2026-09-30 Claude Code 只读到总说明的前一半](docs/bugfixes/2026-09-30-mcp-text-truncated-at-2048.md) — 客户端怎么读是接口的一部分：每种上限各要一条守卫。
- [2026-09-30 生成字幕切出 0.1 秒的一条](docs/bugfixes/2026-09-30-subtitle-piece-on-screen-0.1s.md) — 罚分按用户感受到的量算（能在屏上留多久）；规则保不住时退到整体最优。
- [2026-09-30 成片的声音过了 0 dBFS 交给 AAC](docs/bugfixes/2026-09-30-export-mix-over-0dbfs-into-aac.md) — 两份结果互相比之前把每一级单独量一遍；有损编码器不是透明的管子。
- [2026-09-30 动画行的「In」「Out」从没进过字符串表](docs/bugfixes/2026-09-30-animation-in-out-labels-never-localized.md) — 同一个教训撞第三次别再补清单：从声明里找 `LocalizedStringKey` 参数。
- [2026-09-29 修完爆音，en_male 反倒几乎听不见](docs/bugfixes/2026-09-29-kokoro-short-pieces-explode.md) — 验证修复要走生产那条路；一个尖峰不许决定整句的音量。
- [2026-09-29 成片里的字幕比预览小一截](docs/bugfixes/2026-09-29-subtitle-preview-bigger-than-burn.md) — libass 把字号当行高：预览按实际画字的字体乘 `SubtitleFontScale`；样本要带默认值。
- [2026-09-29 预览上字幕的位置和行距和成片对不上](docs/bugfixes/2026-09-29-subtitle-preview-line-box-differs-from-libass.md) — 「一份数值、两个渲染面」要比位置、不只比大小（`SubtitleLineMetrics`）。
- [2026-09-29 新建工程后播放头停在上一个工程的位置](docs/bugfixes/2026-09-29-new-project-keeps-old-playhead.md) — 卸片后晚到的时间回调要丢掉；测异步要让主循环转起来、素材要像真的。
- [2026-09-29 风格卡给竖屏写的字号大了 1.78 倍](docs/bugfixes/2026-09-29-recipe-sizes-too-big-on-vertical.md) — 写给 AI 的数字也是代码：字号按画面高度算，卡里写明画幅并真排一遍。
- [2026-09-29 转写认不出语言，AI 被叫去「面板里选」](docs/bugfixes/2026-09-29-ai-told-to-pick-language-in-panel.md) — 给界面写的报错不能原样交给 AI；要按种类换说法，错误就得有类型。
- [2026-09-29 在最后一帧上定格，静帧后面剩一截原片](docs/bugfixes/2026-09-29-freeze-leaves-sliver-after-still.md) — 切出来不到一帧的那截不是内容，切的操作自己收拾；够一帧的要指出来。
- [2026-09-29 字幕带把幻灯片底部的标签也框进去](docs/bugfixes/2026-09-29-text-scan-band-swallows-slide-labels.md) — 统计量要挑能把两种东西分开的特征；用真素材的逐帧数据定规则。
- [2026-09-29 没下载苹方的 Mac 上中文字幕烧成方框](docs/bugfixes/2026-09-29-chinese-burns-as-boxes-without-pingfang.md) — CoreText 找得到不等于 libass 找得到：回退到私有字体时两边一起换内置字体。
- [2026-09-29 text_scan 的裁切量被幻灯片标题拉大](docs/bugfixes/2026-09-29-text-scan-crop-hint-stretched-by-slide-title.md) — 字幕的上一行要每句都换才认；会破坏内容的补救办法要在提示里说出来。
- [2026-09-29 被切掉的字混进字幕行、字幕稀疏时选成幻灯片](docs/bugfixes/2026-09-29-text-scan-cutoff-text-and-sparse-subtitles.md) — 「谁最多」在样本稀疏时不可靠：用位置先验 + 最低支撑。
- [2026-09-29 搬走调色代码后，一条接线守卫还在旧文件里找](docs/bugfixes/2026-09-29-pr84-first-ci-run-wiring-guard-in-moved-code.md) — 同一个教训撞第二次就变成机制；搬代码也算改接线。
- [2026-09-29 叠化 + 关键帧之后预览全黑](docs/bugfixes/2026-09-29-preview-black-slice-boundaries-straddle-a-tick.md) — 切片边界先落格子再去重（`CompositionSlices`）；主轨不到 0.01 秒的缝两条管线同一个常量。
- [2026-09-29 婚礼工程之后的五处工具小毛病](docs/bugfixes/2026-09-29-mcp-tool-followups-from-wedding-session.md) — 共用串行槽的任务取消要分清谁的；整批拒绝要说「一个都没做」。
- [2026-09-29 主字体里没有的字画成乱码](docs/bugfixes/2026-09-29-text-fallback-glyphs-drawn-with-main-font.md) — 排版给了谁的字形号就用谁画；自检要拿故意缺字的字体。
- [2026-09-29 圆体烧录字幕英文变成「f=」](docs/bugfixes/2026-09-29-yuanti-cmap-breaks-libass-latin.md) — 「CoreText 能解析」不等于「FreeType 能用」：字幕字体清单要过 cmap 体检。
- [2026-09-29 listen 说 63.5 BPM，cut_to_beat 按 95.3 切](docs/bugfixes/2026-09-29-beat-analysis-window-differs-between-listen-and-cut-to-beat.md) — 同一个量两个工具各算一份迟早两个答案：整首歌分析一次、各自取用。
- [2026-09-29 两句字幕改成一句，挪进来的词不再逐词高亮](docs/bugfixes/2026-09-29-subtitle-merge-loses-word-times.md) — 界面有的动作（合并）AI 也要有。
- [2026-09-29 AI 改了入点、分割后关键帧跑到片段外面](docs/bugfixes/2026-09-29-keyframes-outside-clip-after-ai-edits.md) — 给 AI 的接口不照搬给真人的惯例：报出来的关键帧永远在片段范围里。
- [2026-09-28 删掉分割出来的一块，整条素材连声音全没了](docs/bugfixes/2026-09-28-split-links-every-piece-together.md) — 从旧段构造新段时身份类字段（id、组号）不能照抄：分割走 `LinkRegrouping.split`。
- [2026-09-28 点名新开轨的第二首配乐接在了 A1 后面](docs/bugfixes/2026-09-28-new-audio-lands-on-a1.md) — 要记的是意图，不是副作用。
- [2026-09-28 英文男声的配音开头爆音](docs/bugfixes/2026-09-28-kokoro-voiceover-clipping.md) — 合成器的采样不保证在 ±1 以内：写文件只经 `AIAudioFileWriter`、先过 `AIVoiceLevel`。
- [2026-09-27 AI 的改动撤一步，整条时间线空了](docs/bugfixes/2026-09-27-ai-edits-share-one-undo-group.md) — 「按事件分组」只对用户事件成立：每个改动工具包一层 `AIUndoGrouping.step`，别去关自动开的组。
- [2026-09-27 AI 翻译按旧的原文语言去翻，等下载时不吭声](docs/bugfixes/2026-09-27-ai-translation-stale-source-language.md) — 给 AI 的入口按内容现判语言；要人动手的地方必须说出来。
- [2026-09-27 加了几段音效，预览整个黑屏](docs/bugfixes/2026-09-27-preview-black-after-audio-tick-pushed-past-end.md) — 往合成轨上只从末尾接、合成完裁到总长；修 bug 别顺手改到处在用的换算。
- [2026-09-27 拼图函数叫 `sheet(`，被 sheet 语言守卫误判](docs/bugfixes/2026-09-27-contact-sheet-name-trips-sheet-guard.md) — 按名字扫的守卫，名字就是接口：别给函数取 SwiftUI 修饰器的名字。
- [2026-09-27 GBK 字幕读出来是乱码](docs/bugfixes/2026-09-27-gbk-subtitles-read-as-utf16.md) — 编码识别只走 `TextDecoding`；宽容的解码器（UTF-16）只能放最后或先用特征确认。
- [2026-09-27 有音量曲线的段，AI 调 volume_db 听不出变化](docs/bugfixes/2026-09-27-ai-volume-ignored-on-curved-clips.md) — 给 AI 开参数前先看检查器改同一个值时做了什么（整条曲线平移）。
- [2026-09-27 存好的字幕样式要先去烧录页转一圈才生效](docs/bugfixes/2026-09-27-remembered-subtitle-style-waits-for-burn-in-page.md) — 记住的设置在队列创建时读回来，不挂在某一页的 `onAppear` 上。
- [2026-09-27 AI 放素材顺带挂字幕，之后撤一步全空](docs/bugfixes/2026-09-27-ai-undo-swallowed-by-subtitle-attach.md) — 一次调用里所有登记都在同一个 step 里；异步落账各包一层。
- [2026-09-27 批量转换字幕把同名文件悄悄盖掉](docs/bugfixes/2026-09-27-batch-convert-overwrites-existing-files.md) — 写用户文件夹默认不覆盖：先问，或加编号（`ExportFileName.unoccupied`）。
- [2026-09-26 点一下选中一段，整个编辑器跟着重算](docs/bugfixes/2026-09-26-selection-wakes-whole-editor.md) — 工程换成 `@Observable`；换机制后把「以前被顺带刷新」的地方逐个找出来。
- [2026-09-26 上层轨藏起来的段，成片里画面还在](docs/bugfixes/2026-09-26-hidden-upper-clip-still-exported.md) — 过滤清单算出来了，就让每个消费者都走它；要有真导出抽帧。
- [2026-09-26 播放中按 Return，App 在音频线程上崩溃](docs/bugfixes/2026-09-26-meter-crash-on-go-to-start.md) — 从平台回调拿来的时间，当下标之前先问会不会是负的。
- [2026-09-26 字幕叠在一起时点英文落到中文上](docs/bugfixes/2026-09-26-stacked-subtitle-frame-lands-on-translation.md) — `PreferenceKey.reduce` 不许写成 `value = nextValue()`。
- [2026-09-26 捏合放大时鼠标底下的内容跑掉](docs/bugfixes/2026-09-26-pinch-zoom-anchor-never-applied.md) — `hitTest` 吃父视图坐标；已有唯一真相（滚动几何）时别按坐标找第二份。
- [2026-09-26 纵向滚下去后轨道块画到钉住的标尺上面](docs/bugfixes/2026-09-26-tracks-cover-pinned-ruler.md) — 叠放次序只认最外面那层 `.zIndex`；钉住的东西要在真滚过的状态下看。
- [2026-09-26 分割丢了隐藏和音频库的键](docs/bugfixes/2026-09-26-split-drops-hidden-and-library-key.md) — 从旧段构造新段别手写逐字段：加字段时每一处都要过一遍。
- [2026-09-26 藏起来的片段照样被转写成字幕](docs/bugfixes/2026-09-26-subtitle-generation-transcribes-hidden-clips.md) — 「复刻某某合同」的副本会漏：调同一个 `ClipVisibility.visible`。
- [2026-09-26 字幕比声音早 0.9 秒、片段开头的词丢了](docs/bugfixes/2026-09-26-pause-stretches-next-word.md) — 识别器给的词时间不是开口时间（停顿被并进相邻的词）：先估开口。
- [2026-09-26 自动检测语言拿音效当探针](docs/bugfixes/2026-09-26-auto-detect-probes-sound-effects.md) — 「读得出来」不等于「有人说话」：探针长的先、先听有没有人声。
- [2026-09-25 裁切不跟链接](docs/bugfixes/2026-09-25-trim-ignores-linked-clips.md) — 裁的算法只有 `TimelineTrim` 一份：链接伙伴 / 选中的一组同一个量、一起停。
- [2026-09-25 ⌘ 拖框加选把选中的滤镜段丢了](docs/bugfixes/2026-09-25-marquee-additive-drops-filters.md) — 带默认值的字段 + 成员初始化器，加字段时编译器不吭声：去掉默认值。
- [2026-09-25 拖块 / 拉框每一拍整条时间线重算](docs/bugfixes/2026-09-25-drag-session-in-timeline-state.md) — 拖动会话不进时间线的 `@State`：`TimelineDragBox` 持有不订阅。
- [2026-09-25 松手重建预览把每个素材重开一遍](docs/bugfixes/2026-09-25-rebuild-reopens-every-asset.md) — 素材按文件身份进程级缓存（`MediaAssetCache`）；只有一个小视图关心的状态不在工程上发。
- [2026-09-25 PR #71 首跑 CI 红了两项](docs/bugfixes/2026-09-25-pr71-first-ci-run.md) — 期望值和被测值走同一条路径；改接线后按旧名字把 scripts/、checks/ 全 grep 一遍。
- [2026-09-25 老虎机数字 365 → 90 停在「090」](docs/bugfixes/2026-09-25-odometer-leading-zero.md) — 缺省值替缺失的数据说了话：不存在的那一位滚成空白收掉。
- [2026-09-25 播放时每一跳整个编辑器都重算](docs/bugfixes/2026-09-25-playback-wakes-whole-editor.md) — 订阅时钟的只许是名单里的小视图，停着才有意义的读 `PacedPlayhead`。
- [2026-09-24 选 1080p，竖屏视频被缩成 608×1080](docs/bugfixes/2026-09-24-resolution-cap-shrinks-portrait-video.md) — 分辨率档位封的是短边；缺的输入比写错的逻辑更难发现。
- [2026-09-24 选了简体中文，sheet 和 popover 还是英文](docs/bugfixes/2026-09-24-sheets-ignore-in-app-language.md) — SwiftUI 不把语言带进 sheet / popover：每个新宿主自己套 `.appLanguage()`。
- [2026-09-24 导出面板说「音频原样复制」，其实重新编码](docs/bugfixes/2026-09-24-export-panel-promised-audio-copy.md) — 面板上只放这条管线真消费的设置（按管线声明）。
- [2026-09-24 本地化守卫不扫 `LabeledContent`](docs/bugfixes/2026-09-24-labeledcontent-missing-from-localization-guard.md) — 按调用名清单扫的守卫，清单外整类调用是静默盲区。
- [2026-09-24 主轨转场处预览的声音掉下去一截](docs/bugfixes/2026-09-24-preview-mix-ignores-transition-expansion.md) — 两份结果互相比，比不出它们一起错：要有绝对期望，自检走生产入口。
- [2026-09-24 选了声音场景却看不见选的是哪个](docs/bugfixes/2026-09-24-sound-scene-row-widens-inspector.md) — 检查器一行不许比窄栏宽、菜单 Picker 不锁宽度；界面改动要在真窗口里看一眼。
- [2026-09-24 来回换声音场景，换下来的效果链攒着不放](docs/bugfixes/2026-09-24-sound-scene-chains-pile-up.md) — 「等宿主释放再放」而宿主一直活着，等于不放。
- [2026-09-24 点一下选段卡半秒、拖块滚动跟不上手](docs/bugfixes/2026-09-24-timeline-blocks-observe-whole-project.md) — 时间线上的块不读工程：只收值、`Equatable`、构造处套 `.equatable()`。
- [2026-09-24 点了标记按 ⌫ 删不掉](docs/bugfixes/2026-09-24-marker-delete-key-eaten-by-note-field.md) — 点一下就弹带输入框的面板 = 交出键盘：单击只选中、双击才弹。
- [2026-09-24 改得勤就隔一会儿卡一下：自动保存重建书签](docs/bugfixes/2026-09-24-autosave-rebuilds-bookmarks-every-save.md) — 书签按「路径 + inode + 卷」缓存，同名换文件才重建。
- [2026-09-24 预览里拖文字，一按下去变成旋转](docs/bugfixes/2026-09-24-text-rotate-handle-hit-area-at-center.md) — `.contentShape` 写在 `.offset` 之前；样本要不对称才测得出写反的翻转。
- [2026-09-23 从 Finder 拖文件进时间线标尺以下没反应](docs/bugfixes/2026-09-23-timeline-file-drop-claimed-by-inner-drop-region.md) — 拖入由最里面的落点区独占认领；「两套路由」的结论已在同一天的「卡片拖不进时间线」那份里更正。
- [2026-09-23 滤镜 / 音频库 / 转场卡片拖不进时间线](docs/bugfixes/2026-09-23-in-app-drops-swallowed-by-file-underlay.md) — 整条时间线只挂一个落点 `TimelineDropRouter`；两边都落不下去的 A/B 不是证据。
- [2026-09-23 磁吸开着时拖文件的落点框画错位置](docs/bugfixes/2026-09-23-file-drop-frame-ignores-magnet.md) — 画框要在副本上把落地原样走一遍（含 `packMain`）。
- [2026-09-23 滤镜卡片、音频库素材拖不进时间线（类型没声明）](docs/bugfixes/2026-09-23-custom-drag-types-not-declared.md) — 自定义拖放类型必须在 Info.plist 声明。
- [2026-09-23 转场卡片拖到接缝上没反应](docs/bugfixes/2026-09-23-transition-drop-cancel-ends-session.md) — 不能放时回 `.forbidden`；`.cancel` 会结束整轮拖放。
- [2026-09-23 音量线上的点按不住、偏着抓会跳](docs/bugfixes/2026-09-23-volume-curve-points-unclickable.md) — 重叠路径的非零环绕数会抵消成洞；自检要测命中测试真正用的形状。
- [2026-09-23 CI 说清单缺文件，其实不缺](docs/bugfixes/2026-09-23-grep-q-sigpipe-false-red.md) — pipefail 下管道末端不用 `grep -q`（上游吃 SIGPIPE）。
- [2026-09-23 打开工程后缩略图和波形全空](docs/bugfixes/2026-09-23-waveform-decode-deadlocks-thread-pool.md) — 阻塞的读取循环不进 Swift 并发线程池；可能死锁的自检带普通线程上的看门狗。
- [2026-09-23 一条轨上换了音频格式就没声音、预览卡住](docs/bugfixes/2026-09-23-meter-tap-dies-on-audio-format-change.md) — 一条合成音轨只装一种格式；自检素材要有几种格式。
- [2026-09-21 源文件清单守卫只盯着枢纽文件](docs/bugfixes/2026-09-21-source-list-guard-only-watched-the-hub.md) — 守卫要扫清单里的每一个文件；别开只有 extension 的文件。
- [2026-09-21 刚加进轨道的素材没贴左边](docs/bugfixes/2026-09-21-timeline-content-centered-horizontally.md) — 上一条的横向孪生：居中的毛病两轴一起钉。
- [2026-09-21 时间线右边小半个视口是死区](docs/bugfixes/2026-09-21-timeline-right-padding-dead-zone.md) — `minWidth` 撑出来的空白不自带命中区：命中区要盖在填满视口之后。
- [2026-09-20 磁吸关着时转场预览有、成片没有](docs/bugfixes/2026-09-20-transition-preview-export-divergence.md) — 「两段是否相叠」两条管线只许一套判据；断言要造不相叠的几何。
- [2026-09-20 拖短转场时遮罩整块往右挪](docs/bugfixes/2026-09-20-transition-mask-drifts-when-shortened.md) — 宽度有下限时，位置要跟着补偿。
- [2026-09-20 悬停光标卡住](docs/bugfixes/2026-09-20-hover-cursor-stack.md) — 全 App 共用一个 `NSCursor` 栈，漏押 / 错弹一次就全局卡住。
- [2026-09-20 播放头断线、点标尺没反应](docs/bugfixes/2026-09-20-playhead-line-broken-and-ruler-dead.md) — 内容比视口矮会被 SwiftUI 纵向居中，命中区不跟着 `.offset` 走。
- [2026-09-18 轨道一多就没法上下滚](docs/bugfixes/2026-09-18-timeline-cannot-scroll-vertically.md) — 时间线双向滚动、轨道头 / 标尺各自钉住；裸 VStack 会替整条界面要高度。
- [2026-09-18 框选的框不跟鼠标](docs/bugfixes/2026-09-18-marquee-anchored-at-stale-scroll-offset.md) — 手势要用的量现读 `NSScrollView`，别用异步观察值。
- [2026-09-18 预渲染烤进了该让位的渐变](docs/bugfixes/2026-09-18-prerender-fade-ignores-transition.md) — 临时时间线没有邻居：依赖邻居的仲裁由调用方算好传进去，仲裁只有一处。
- [2026-09-18 自检脚本的源文件清单漏掉新依赖](docs/bugfixes/2026-09-18-check-script-source-list-drift.md) — 手抄的清单会漂。
- [2026-08-23 提示悬浮在打开文件对话框上](docs/bugfixes/2026-08-23-tooltip-survives-open-panel.md) — 靠 hover 退出维护的状态要有打断信号兜底（mouseDown / keyDown / resignKey）。
- [2026-08-22 带空 cue 的工程字幕文件导不出](docs/bugfixes/2026-08-22-subtitle-export-empty-cue-verification.md) — 「哪些 cue 会被写出去」只能是序列化器一份账；cue 文本先消毒空行。
- [2026-08-22 编辑译文退格删字，整条 cue 消失](docs/bugfixes/2026-08-22-subtitle-editing-backspace-deletes-cue.md) — 全局快捷键要给字幕草稿让路，⌫ 的每条到达路径都得堵。
- [2026-08-16 竖图缩略图的隐形命中区盖死标尺](docs/bugfixes/2026-08-16-clipped-thumbnail-hit-area-covers-ruler.md) — `.clipped()` 只裁绘制不裁命中；块内装饰必须不吃事件。
- [2026-08-16 形状叠层不跟播放头](docs/bugfixes/2026-08-16-shape-overlay-ignores-playhead.md) — 按 displayTime 取内容的叠层必须直接订阅 `PlayerClock`。
- [2026-08-12 渐入开头爆音](docs/bugfixes/2026-08-12-audio-fade-in-pop.md) — 混音器的增益有 de-zipper：别拿常量提前量赌平台的平滑窗口，断言上移到结构不变量。
- [2026-08-12 提示弹在很远的地方、还没翻译](docs/bugfixes/2026-08-12-instant-tooltip-first-show-far-off.md) — `NSHostingView` 会把尺寸约束灌给面板，摆好 ≠ 摆定；本地化查不到是静默降级。
- [2026-08-12 压缩预览区时播放条压到工具栏上](docs/bugfixes/2026-08-12-preview-transport-row-overlap.md) — VStack 里谁让步必须显式声明。
- [2026-08-12 转场前面有硬切就导不出](docs/bugfixes/2026-08-12-xfade-timebase-mismatch.md) — xfade 硬检查 timebase，concat 输出固定 AVTB。
- [2026-08-12 框选复审的五条后续](docs/bugfixes/2026-08-12-marquee-review-followups.md) — 「整组同一位移」收口到一处；自检入口比生产浅一层会假绿。
- [2026-08-12 双击字幕的浮层弹在很偏左](docs/bugfixes/2026-08-12-cue-popover-anchored-at-row-origin.md) — `.offset` 只改渲染不改布局框；验位置的样本别挑在原点附近。
- [2026-08-12 字幕三入口首测](docs/bugfixes/2026-08-12-subtitle-editing-surfaces-smoke-fixes.md) — `HSplitView` 不保护最后一栏；临时行不能给自己上焦点。
- [2026-08-12 字幕编辑复审的六条后续](docs/bugfixes/2026-08-12-subtitle-editing-review-followups.md) — 视图里的草稿会被「先写盘再销毁视图」漏掉；CAS 基线必须是会话快照。
- [2026-08-11 录屏静止期尾部黑屏](docs/bugfixes/2026-08-11-screen-recording-idle-tail-black.md) — 画面轨短于容器、fragment 与守卫的触发条件。
- [2026-08-09 同语种翻译](docs/bugfixes/2026-08-09-subtitle-translate-after-same-language.md) — 可见选择与提交前预检。
- [2026-08-09 PR #22 后续复审](docs/bugfixes/2026-08-09-pr22-review-followups.md) — 格式版本、语言检测、可听性与取消。
- [2026-08-09 翻译第二次卡在 0/N](docs/bugfixes/2026-08-09-translate-stuck-at-zero.md) — configuration 换代与看门狗。
- [2026-08-09 时间线拖动卡顿与对齐](docs/bugfixes/2026-08-09-timeline-clip-drag-lag-and-alignment.md) — 渲染偏移、吸附与唯一落点。
- [2026-08-08 运行期素材重链接](docs/bugfixes/2026-08-08-runtime-media-relink.md) — 素材移动后的重核对。
- [2026-08-08 悬停影子播放头与删除键](docs/bugfixes/2026-08-08-hover-ghost-playhead-and-delete-key.md) — peek 语义与统一删除入口。
- [2026-08-08 静帧循环解码过慢](docs/bugfixes/2026-08-08-still-clip-loop-decode-slow.md) — image2 输入帧率。
- [2026-08-08 CI 首跑与吞错](docs/bugfixes/2026-08-08-ci-first-run-sdk-and-swallowed-errors.md) — SDK 与构建日志不许被吞。
- [2026-08-08 主轨乱序黑帧](docs/bugfixes/2026-08-08-main-track-array-order-black-frame.md) — 主轨按时间顺序，竖版布局。
- [2026-08-08 静帧逐帧解码](docs/bugfixes/2026-08-08-still-clip-decode-per-frame.md) — 单帧解码、loop 滤镜与性能守卫。
- [2026-08-07 录屏地基复审](docs/bugfixes/2026-08-07-screen-recording-foundation-review.md) — 假绿、外部真值与状态机。
- [2026-08-07 录屏 Phase 2–4 复审](docs/bugfixes/2026-08-07-screen-recording-phase2-4-review.md) — 接线、恢复、退出与真实首测。
- [2026-08-06 字幕生成复审](docs/bugfixes/2026-08-06-subtitle-generation-review.md) — 切窗、身份、取消、账本与缓存。
- [2026-08-06 构建版本与 shell 陷阱](docs/bugfixes/2026-08-06-build-version-and-shell-traps.md) — 版本兜底、变量边界与 pipefail；改 shell 脚本前必读。
- [2026-08-06 字幕面板语言默认值](docs/bugfixes/2026-08-06-subtitle-panel-language-defaults.md) — 占位值与隐藏选择。
- [2026-08-06 包内授权声明过期](docs/bugfixes/2026-08-06-stale-bundled-license-notice.md) — 生成器与忽略产物。
- [2026-08-05 Inspector 拖调](docs/bugfixes/2026-08-05-inspector-scrub-field-gestures.md) — 编辑态、焦点与亚像素容差。
- [2026-08-05 导出预渲染复审](docs/bugfixes/2026-08-05-export-prerender-review.md) — 覆盖、alpha、取消与临时文件。
- [2026-08-04 编辑器工具复审](docs/bugfixes/2026-08-04-editor-tools-review.md) — 工具模式、升轨和旋转包络。
- [2026-08-04 半透明绿底](docs/bugfixes/2026-08-04-opacity-green-background.md) — 默认合成器背景陷阱。
- [2026-08-04 Transform 复审](docs/bugfixes/2026-08-04-transform-review.md) — 格式版本、叠化与缓存原子性。
- [2026-08-04 AVFoundation 预渲染](docs/bugfixes/2026-08-04-prerender-avfoundation-pitfalls.md) — 空轨与透明背景。
- [2026-08-03 时间线捏合缩放](docs/bugfixes/2026-08-03-trackpad-pinch-zoom.md) — 事件序列与 Rosetta 旧产物。
- [2026-08-03 工程文件生命周期](docs/bugfixes/2026-08-03-project-file-lifecycle.md) — 数据丢失路径与失败分支。
- [2026-08-03 逐帧预览](docs/bugfixes/2026-08-03-scrub-preview-keyframe-snap.md) — 零容差与链式 seek。
- [2026-08-03 裁切闪烁与半速](docs/bugfixes/2026-08-03-trim-flicker-halved.md) — 坐标反馈、动画与去抖。

## 根目录文档

- [README.md](README.md) — 面向使用者的中英双语项目介绍。
- [SrtFlow-Requirements.md](SrtFlow-Requirements.md) — 产品需求与技术结论总表。
