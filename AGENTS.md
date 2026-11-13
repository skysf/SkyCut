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
   [Bug 修复案例索引](docs/bugfixes/INDEX.md) 补一行。
2. 自动化能覆盖的 bug，必须在对应 check 中加入一条修复前会失败的回归守卫，并做
   **反向验证**：临时撤掉修复，确认守卫确实变红，再恢复修复。没红过的守卫不能算
   验证。
3. 自动化够不着的行为（例如手势手感、TCC、系统 UI）必须写入对应架构文档的人工
   回归清单，并在发版前实机验证。
4. 案例中形成的长期约束（“这里只能这样做”）必须另写或更新
   `docs/architecture/` 文档，再由案例链接过去，不能只留在一次性事故记录里。
5. 其他新文档归入 `docs/` 对应分类，并在本文件补索引（Bug 案例的索引单独放在 `docs/bugfixes/INDEX.md`，本文件只链到它）；能更新既有文档时不要另造
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
- 合掉一个之后别的 PR 变 DIRTY（常见于本文件必读表的同一行；`docs/bugfixes/INDEX.md` 按文件名里日期后面那一段排之后基本不撞）：把新 main 合进那条分支、两边都留、推上去等 CI 绿再合；撞在同一行的把两边并进同一行，别留两行。
- 往索引、必读表、名单里加的那一行放在最后一个 commit；同一行、同一块的几件事别同时开 PR。
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
| AGENTS.md 和 `docs/bugfixes/INDEX.md` 的索引：加 / 改 / 收短一条索引或必读表的一行、新加小节、`checks/docs-index-drift.sh` 红了或要改它（`--self-test`）、并行的 PR 撞在索引的同一行、`merge=union` | [文档索引怎么写](docs/architecture/doc-indexes.md)（只许规定的写法，别的都红：链接只有 `[字](相对路径.md)`（可带 `#锚点`），条目只有顶格的 `- [标题](路径.md) — 一句话`、AGENTS.md 的索引小节另许成形的表格；收成一句话时「只有 / 一律」写全例外、实测数字带着条件；超了不抬数；`INDEX.md` 按文件名里日期后面那一段的字母序插，不用 `merge=union`：GitHub 不认）、[索引条目的上限绕得过去，一句话丢了例外和条件](docs/bugfixes/2026-11-13-index-entry-limit-bypassed.md) |
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
| 预览性能、性能计数与基线；新写或改写任何 SwiftUI 视图 / 修饰器 / `NSViewRepresentable` / Canvas；性能那一步红了但没动编辑器界面；往时间线上加一种块 / 行里的列表项；任何要跟着播放头变的界面（订阅播放器时钟、读 `clock.time`）；在视图 body 里读工程的属性、给 `VideoEditProject` 加属性（工程是 `@Observable`） | [预览性能 ratchet](docs/architecture/preview-perf-ratchet.md)（body 第一行要计数，写完跑 `checks/preview-perf-wiring.sh --fix`；计数只许降；时间线上的块不读工程、按值比较 + `.equatable()`；订阅时钟的只许是名单里的小视图）、[方案](docs/plans/2026-09-24-preview-perf-ratchet.md)、[点一下选段卡半秒、拖块滚动跟不上手](docs/bugfixes/2026-09-24-timeline-blocks-observe-whole-project.md)、[播放时每一跳整个编辑器都重算](docs/bugfixes/2026-09-25-playback-wakes-whole-editor.md)、[播放丝滑方案](docs/plans/2026-09-25-smooth-playback.md)、[点一下选中一段，整个编辑器跟着重算](docs/bugfixes/2026-09-26-selection-wakes-whole-editor.md) |
| AI 的一次工具调用、AI 起的长任务从哪开始到哪结束（`AIToolRouter.handle`、`AIJobs.start` / `finish`）、App Nap / 活动断言（`AIKeepAwake`、`ProcessInfo.beginActivity`）、新写一种在后台跑的 AI 活 | [AI 接口（MCP）第四节第 59 条](docs/architecture/ai-control-mcp.md)（新的长任务走 `AIJobs.start` / `finish`；活动断言只在 `AIKeepAwake` 和录屏）、[后台的 AI 活被 App Nap 降速](docs/bugfixes/2026-11-10-ai-work-throttled-by-app-nap.md) |
| 主线程卡顿、心跳看门狗 `MainThreadWatchdog`（含 AI「探一下」读的 `unresponsiveSeconds`）、卡顿日志、冒烟结果里的 `stalls`、挂起主线程抓栈（`MainThreadStackCapture`） | [主线程卡顿日志](docs/testing/main-thread-stalls.md)、[挂起主线程抓栈](docs/architecture/main-thread-stack-capture.md)（挂起期间不分配、不拿锁；挂起和恢复只在 `walkWhileSuspended`）、[导出两次卡死：看门狗挂起主线程抓栈时分配内存](docs/bugfixes/2026-10-06-watchdog-capture-deadlocks-main-thread.md)、[预览性能 ratchet](docs/architecture/preview-perf-ratchet.md) |
| 任何界面文案、翻译、字符串表、应用内语言切换、加一种界面语言（`<code>.lproj` + `AppLanguage` 一个 case）、新加 sheet / popover / 自建宿主视图 | [本地化](docs/architecture/localization.md)（sheet / popover 不继承应用内语言，每个都套 `.appLanguage()`）、[界面语言方案](docs/plans/2026-09-30-ui-languages.md)、[选了简体中文，sheet 和 popover 还是英文](docs/bugfixes/2026-09-24-sheets-ignore-in-app-language.md)、[本地化守卫不扫 `LabeledContent`](docs/bugfixes/2026-09-24-labeledcontent-missing-from-localization-guard.md) |
| AI 接口（MCP）：给 AI 的工具清单与说明、说明书 `skycut_guide`、剪辑风格（recipes / save_recipe）、配旁白（add_voiceover：角色读 `voice_roles`、`SkyStudioVoiceoverStart`、`MCPGuideWrittenTopics`、声音库的声音 `voice_…`、`skip_one_time`、`voice_enroll`）、声音库 `list_voices` / `manage_voices`（经 `SkyStudioJobGate`）、本机的声音 Kokoro（`Sources/SrtFlowKokoro/`、模型的下载与 R2 上的那一份）、`skycut-mcp` 小程序、小程序与 App 的通道、AI 改时间线的规则、这一轮 / 停止 / 撤销这一轮、需要用户点头的事、设置里的「连接 AI」、AI 的手和眼（`edit_clip` 的画面放法、`look`、`listen`、`listen cuts=true`、`edit_subtitles` 的 `replace` / `strip_punctuation`、`get_subtitles` 的 `box`、`look shots` / `look files` / `follow` / `look text_scan` 的 `subtitle_overlaps`、按字取景 `focus=text`）、AI 够得着的现有功能（后台模式、读文稿、整理文件、推子关键帧、形状、定格、音乐库、压缩 / 烧录 / 转字幕、`record_screen`、`export_subtitles`） | [MCP 说明书（skycut_guide）](docs/architecture/mcp-guide.md)（只有说明书预先加载；名片 ≤ 450、参数说明 ≤ 120、参数定义 ≤ 4,500 字节）、[MCP 按需说明方案](docs/plans/2026-11-09-mcp-guide.md)、[AI 接口（MCP）](docs/architecture/ai-control-mcp.md)（一个工具 = 一步撤销，每个改动工具包一层 `AIUndoGrouping.step`；不许弹模态框；参数名按说明核对；总说明 ≤ 1,200、全清单 ≤ 100,000，加工具先把说明挪进说明书、不再抬上限；碰工程的工具收可选的 `project`）、[预览自由变换](docs/architecture/preview-free-transform.md)、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md)、[波形与深度缩放](docs/architecture/audio-waveform.md)、[AI 的改动撤一步，整条时间线空了](docs/bugfixes/2026-09-27-ai-edits-share-one-undo-group.md)、[AI 放素材顺带挂字幕，之后撤一步全空](docs/bugfixes/2026-09-27-ai-undo-swallowed-by-subtitle-attach.md)、[AI 翻译按旧的原文语言去翻，等下载时不吭声](docs/bugfixes/2026-09-27-ai-translation-stale-source-language.md)、[转写认不出语言，AI 被叫去「面板里选」](docs/bugfixes/2026-09-29-ai-told-to-pick-language-in-panel.md)、[婚礼工程之后的五处工具小毛病](docs/bugfixes/2026-09-29-mcp-tool-followups-from-wedding-session.md)、[listen 说 63.5 BPM，cut_to_beat 按 95.3 切](docs/bugfixes/2026-09-29-beat-analysis-window-differs-between-listen-and-cut-to-beat.md)、[字幕带把幻灯片底部的标签也框进去](docs/bugfixes/2026-09-29-text-scan-band-swallows-slide-labels.md)、[text_scan 的裁切量被幻灯片标题拉大](docs/bugfixes/2026-09-29-text-scan-crop-hint-stretched-by-slide-title.md)、[被切掉的字混进字幕行、字幕稀疏时选成幻灯片](docs/bugfixes/2026-09-29-text-scan-cutoff-text-and-sparse-subtitles.md)、[Claude Code 只读到总说明的前一半](docs/bugfixes/2026-09-30-mcp-text-truncated-at-2048.md)、[MCP 方案](docs/plans/2026-09-27-mcp.md)、[配方卡中文稿](docs/plans/2026-09-28-mcp-recipes.md)（改套路先改它，再同步 App 资源里的英文卡）、[剪辑美感方案](docs/plans/2026-10-05-editing-aesthetics.md)、[风格卡给竖屏写的字号大了 1.78 倍](docs/bugfixes/2026-09-29-recipe-sizes-too-big-on-vertical.md) |
| MCP 参数范围 / requested、applied / 静默限幅 / 素材尺寸加载重试 / 单项与批量原子提交 | [MCP 编辑参数合同](docs/architecture/mcp-edit-parameters.md)（范围来自生产代码、越界给合法建议、限幅回实际值、成功后才开撤销组） |
| 合成音效（`Sources/SrtFlow/SoundEffects/`、`add_clips` 的 `sound_effect` / `hit_at`、`AISoundEffectRequest` / `AISoundEffectTool`）、改任何预设的声音、合成器的响度或落点 | [合成音效](docs/architecture/sound-effect-synth.md)（落点是合同；同参数同文件，改声音要 +1 version 并再给用户听；写文件只经一处）、[音效方案](docs/plans/2026-09-30-sound-effects.md)、[AI 接口（MCP）第四节第 43 条](docs/architecture/ai-control-mcp.md)、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md) |
| 云端媒体共用的阶段 / 状态行 / 传输 / 每日账（`Sources/SrtFlow/CloudMedia/`），生成、upscale、旁白、克隆，声音的接口合同（预设声音、角色、声音库、voice_plan、一次性费用、变声的 DTO 和请求），同时开着几个任务（`SkyStudioJobSlots`：声音池 / 共用池）、一段旁白的几批怎么同时交（`SkyStudioVoiceBatchQueue`）、中途换备用（`SkyStudioVoiceFallbackFee`）、本机切句（`SkyStudioVoiceLineAudio`、`SkyStudioVoiceSplitEstimate`）、认声音（`SkyStudioVoicePick`）、角色 list_characters / get_character / manage_characters、图片 camera_angle / upscale | [Sky Studio 的任务](docs/architecture/sky-studio-jobs.md)（全部收费活只走 Sky Studio；交之前在本机按池领槽；退本机只在付费请求之前；付过钱的声音不许在本机卡死）、[fal.ai 生成](docs/architecture/fal-generation.md)（仅供历史复盘） |
| 声音库的工具（`list_voices` / `manage_voices`：`SkyStudioVoiceLibraryTool` / `SkyStudioVoiceRecordingTool` / `SkyStudioVoiceDesignTool`；`SkyStudioVoiceApproval`、`SkyStudioJobGate` 的声音那三样；`voice_library_unavailable`）、声音库的收费单跨重启（`SkyStudioVoiceLibraryOrders`、`SkyStudioVoiceLibraryJob.follow`）、全部权限下的长期授权（`SkyStudioVoiceStanding` 的 `.ask` / `.standing` / `.once`、`/voices/consent-grant`、`SkyStudioVoiceStandingNotice`）、克隆的参考录音（`VoiceReferenceSample` / `VoiceReferenceWindow` / `VoiceReferenceReader`、上传用途 `voice_reference`）、`clone_from` 的移除（`add_voiceover`） | [声音库：参考录音、工具和界面、变声](docs/architecture/voice-library.md)（参考录音 44.1 kHz 单声道 16-bit、10 秒有效人声到 3 分钟；有声门限 `speechRMSFloor` 单独写死；同一件事只开一单、在建的单交之前落盘）、[克隆的参考录音被降到 16 kHz、只截 10 秒](docs/bugfixes/2026-11-10-voice-reference-16khz-short-sample.md)、[Sky Studio 的任务第五节](docs/architecture/sky-studio-jobs.md)、[声音库审查的后续](docs/bugfixes/2026-11-11-voice-library-review-followups.md)、[重启后不记得在建的声音库那一单](docs/bugfixes/2026-11-11-voice-library-job-after-restart.md) |
| 声音库的界面（`Sources/SrtFlow/VoiceLibrary/`：`VoiceLibrarySettingsSection` / `VoiceLibraryStore`、`VoicePickerView` / `VoicePickerRows`、`NewVoiceSheet` / `NewVoiceModel` / `NewVoiceGate`、`VoiceSampleRecorder`、`VoiceSampleLanguage` + `SpokenLanguageProbe`、`manage_voices` 没给 `language` 时（`SkyStudioVoiceRecordingLanguage`）、`DesignVoiceSheet` / `DesignVoiceModel`、`VoiceAudition`、`VoiceLibraryText`；和 AI 的工具共用的 `SkyStudioVoiceRecordingSubmission` / `SkyStudioVoiceDeletion` / `SkyStudioVoiceDesignOrder` / `SkyStudioVoiceLibraryErrors.kind`；麦克风的用途说明） | [声音库第九、十节](docs/architecture/voice-library.md)（界面和 AI 的工具同一条路；勾了授权才造 `consent: true`；会花钱的按钮按下去就锁；语言检测不出来留空、不许猜）、[顶部工作台与统一设置](docs/architecture/workbench-and-settings.md)、[本地化](docs/architecture/localization.md)、[预览性能 ratchet](docs/architecture/preview-perf-ratchet.md)、[即时提示](docs/architecture/instant-tooltips.md)、[签名与系统权限](docs/architecture/code-signing-and-permissions.md)（麦克风）、[字幕语言流](docs/architecture/subtitle-language-flow.md)（语言检测的候选和裁决在 `SpokenLanguageProbe`）、[离屏渲染的图](docs/reports/2026-11-10-voice-library-ui.md)、[设计声音连按下了好几单](docs/bugfixes/2026-11-11-design-voice-ordered-twice.md) |
| 变声（`Sources/SrtFlow/VoiceChange/`：AI 的 `change_voice`（`VoiceChangeTool`）、片段右键「换成我的声音…」和面板（`VoiceChangeActivity` / `VoiceChangePresenter` / `VoiceChangePanel` / `VoiceChangePanelModel`）、`VoiceChangeSource`、`VoiceChangeOrder`、`VoiceChangeJob`、`VoiceChangeLanding`、`VoiceChangeOutputName`；`voice_convert`、上传用途 `voice_convert_source`） | [声音库第十一节](docs/architecture/voice-library.md)（两个入口同一条路；只判每日硬预算、结果不明不重交；落地恰好一次 `perform`、包在 `AIUndoGrouping.step` 里）、[联动](docs/architecture/timeline-linkage.md)、[Sky Studio 的任务](docs/architecture/sky-studio-jobs.md)、[AI 接口（MCP）第四节第 60 条](docs/architecture/ai-control-mcp.md)、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md)、[预览性能 ratchet](docs/architecture/preview-perf-ratchet.md)、[本地化](docs/architecture/localization.md)、[实测](docs/reports/2026-11-11-change-voice.md) |
| 视频 upscale（`Upscale/UpscaleTiers.swift` 从 `/models` 读档位、`UpscaleOffers`、`SkyStudioSpendStore`；AI 的工具 `upscale_clip`（`AIUpscaleTool` / `AIUpscaleNames`、`UpscaleJob.Approval`、`SkyStudioJobGate`）；换源：`EditClip.upscale`（`VideoEditClipUpscaleRecord`）、`ClipSourceSwap`、`VideoEditMediaReferences`、`VideoEditProject+Upscale`；任务：`Sources/SrtFlow/Upscale/`、`UpscaleJob`；界面：`VideoEditInspector+Upscale`、`UpscaleJobStatusView`、`VideoEditTimelineClipBlock` 的右键菜单与角标、`UpscalePanel`、`UpscaleCompareView` / `Stage` / `Playback`、`UpscalePresenter`） | [视频 upscale 方案](docs/plans/2026-10-02-video-upscale.md)、[Sky Studio 的任务](docs/architecture/sky-studio-jobs.md)（扣多少只问 `/quote`、交任务时当 `max_credits`；Key 只发给 Sky Studio）、[smoke test 实测](docs/reports/2026-10-02-upscale-smoke-test.md)、[工程文件「四之五」](docs/architecture/video-edit-project-file.md)、[视频 upscale](docs/architecture/video-upscale.md)（成品的声音一律不要、自己封回原片的；面板起的做完不替换；界面只订阅 `UpscaleActivity`）、[AI 接口（MCP）第四节第 44 条](docs/architecture/ai-control-mcp.md)、[检查器的排版](docs/architecture/inspector-layout.md)、[本地化](docs/architecture/localization.md) |
| 收费与授权：体验 / 正式版、服务器下发的开关（MCP 能不能用、导出加不加水印）、照授权拦（AI 调用的门 `SkyStudioAccount.aiRefusal`、导出面板「会带水印」那一行、`SkyCutGates`）、导出水印、Sky Studio 的 key 与 `api/skycut/v1`、生成 / upscale / 克隆走 Sky Studio | [收费方案](docs/plans/2026-10-27-paid-plans-and-sky-studio-key.md)（开关由服务器下发、SkyCut 不写死天数和规则；MCP 的门在 App 收工具调用的地方、不在小程序里）、[Sky Studio 账号](docs/architecture/sky-studio-account.md)（只有 `SkyStudioAPI` 碰地址；后台问 `/me` 从不弹钥匙串框；机器号的盐永远不改）、[Sky Studio 的任务](docs/architecture/sky-studio-jobs.md)、[真 Codex 冒烟](docs/reports/2026-10-26-codex-client-smoke.md)、[导出水印](docs/architecture/export-watermark.md) |
| 真实窗口、系统权限、手势实测 | [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) |
| 官方原创短片、`generate_media` 的 `film`、镜头状态 / 完成动作 / 声音计划、实际引用与报价 pin、左右接缝审查 | [官方原创短片](docs/architecture/official-film.md)（公开状态与服务端私有配方分开；客户端 / 生产启用 / 真实输出 / 并发验收分开报告）、[Sky Studio 的任务](docs/architecture/sky-studio-jobs.md)、[开着的工程（OpenProjects）](docs/architecture/open-projects.md) |

## 构建与检查入口

- 构建、打包、DMG、公开下载发布、CI 怎么分组、同时能跑几个、本地怎么跑检查：[构建与打包](docs/build/build-and-packaging.md)。素材管线（制备素材、不是检查，**不在 `check-all.sh` 里**）：[音频库素材管线](docs/build/audio-library-pipeline.md)（`scripts/audio-library/`）、[本机配音模型管线](docs/build/voice-model-pipeline.md)（`scripts/voice-models/`，R2 签名只有 `scripts/r2.py` 一份）。
- **推之前**：`scripts/check-local.sh <相关检查>` = 全部扫描守卫（`scripts/check-guards.sh`：`checks/*.sh` + `scripts/check-mcp.sh --scans-only`，约一分钟、不编译）+ 点名的几项。本地的入口都自己换成原生 arm64 的 `/bin/bash`（`scripts/native-arch.sh`）。
- **全部自动检查**：`scripts/check-all.sh`。CI（`.github/workflows/checks.yml`）在每个 PR 上按 `--shard N --of 5` 分到 5 台 macOS runner 跑同一入口，汇总 job `check-all` 给结论；只改了文档的 PR 走快速通道（`scripts/ci-docs-only.sh` 判，只跑扫描守卫）；合并后 main 上那一轮在树已被 PR 那轮绿的 CI 原样验过时只编译、存缓存（`scripts/ci-verified-tree.sh` 判，仓库变量 `CI_VERIFIED_TREE` 设成 `off` 就关）。
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
- `checks/ci-verified-tree.sh` — 合并后 main 上那一轮只在树已被 PR 那轮绿的 CI 原样验过时才不跑检查。
- `checks/client-config-backup.sh` — 连接 AI 客户端时的配置备份和原文件同样的权限。
- `checks/cloud-task-projects.sh` — 生成任务带工程归属，卡片和 MCP 共用分组。
- `checks/copy-project-guard.sh` — 冒烟拷工程不整夹拷「下载」这类大文件夹。
- `checks/dmg-packaging.sh` — DMG 安装引导的接线与模板。
- `checks/docs-index-drift.sh` — 本文件和 `docs/bugfixes/INDEX.md` 的索引是全的、没有死链、每条一行、只有规定的几种写法，`INDEX.md` 按文件名里日期后面那一段排、一份案例只列一次，本文件总大小不超上限；`--self-test` 跑它自带的负例（check-all 里也跑）。
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
- [联动：主轨块挪到哪、删没删，压在它上面的东西跟着走](docs/plans/2026-10-02-timeline-linkage.md) — 「和剪映一样」：跟画面不跟 id；跨段的要底下画面全部同移才跟；字幕句两头各自换算、说的话剩不到一半就删（10-15 起裁切也删）；别的东西真删才连带删；场景表就是自检用例。
- [预览和成片的声音：自己的音频引擎](docs/plans/2026-10-01-audio-engine.md) — 为什么不用 AVPlayer 的合成（每条音轨 40 ms）、架构、时钟对齐、三刀。
- [预览的画面：优化媒体](docs/plans/2026-10-01-video-optimized-media.md) — 只转长 GOP 的源和时间线用到的块、成片永远原片、缓存 10 GB LRU；V1–V3 已合。
- [导出真峰值限幅 + 响度报告，关键帧缓动](docs/plans/2026-09-30-export-limiter-and-easing.md) — −1 dBFS 限幅、响度只报不归一；`easing` AI 默认 ease_in_out、手打默认线性。
- [音效：合成器（给 AI）+ 录音素材库（给用户）](docs/plans/2026-09-30-sound-effects.md) — AI 先搜素材库、没有再合成；样音点头才写代码；`hit_at` 落点。
- [界面语言：加西班牙语、法语、土耳其语](docs/plans/2026-09-30-ui-languages.md) — 先把枚举和守卫改成任意多种语言；译文 AI 出、不审、直接算正式。
- [剪辑风格：五种预设风格（中文稿）](docs/plans/2026-09-28-mcp-recipes.md) — 共用规矩 + 五张卡 + 配音角色表；改套路先改它、再同步 App 资源里的英文卡。
- [让 AI 调用 SkyCut 剪视频：MCP 方案](docs/plans/2026-09-27-mcp.md) — 用户历次拍的板（第一期客户端、看得见、什么时候问用户、不靠外部工具、剪辑风格、配音、fal 生成…）、架构与六块；真实状态看实施报告。
- [隐藏扩到所有块、回到开头、对齐线、字幕拆成两条独立轨](docs/plans/2026-09-26-hide-guides-independent-subtitles.md) — 2026-09-26 五件事拍过的板，字幕独立轨那部分最细。
- [时间线复制 / 剪切 / 粘贴 + 缩放以鼠标为中心 + 纵向缩放](docs/plans/2026-09-26-timeline-clipboard-and-zoom.md) — 2026-09-26 逐条拍的板和实现细节（Z1–Z7、C1–C9）。
- [生成的字幕：去标点、断句、只留一条、藏起来的不转写](docs/plans/2026-09-26-subtitle-generation-style.md) — 调研（主流剪辑软件、Netflix / BBC 的数字）和逐条拍的板。
- [播放丝滑：播放头的每一跳只叫醒跟着它动的东西](docs/plans/2026-09-25-smooth-playback.md) — 左栏和检查器播放中冻住、停下追上；不拿 CPU 数字验收。
- [导出面板改版：三行 + 高级](docs/plans/2026-09-24-export-panel.md) — 分辨率只降不升按短边、不弹保存面板、撞名先提示、记住设置；逐条拍过的板。
- [插进两条轨之间 + 整条轨换位置](docs/plans/2026-09-24-track-insert-and-reorder.md) — 缝上停 0.2 秒拉开再落进新轨；按住轨道头拖整条轨换位；拍过的板。
- [声音场景 + 成片声音改从预览混音读](docs/plans/2026-09-24-sound-scenes.md) — 九个场景、余音越过段尾、效果在段增益之后；成片的声音只做一遍。
- [预览性能 ratchet 方案](docs/plans/2026-09-24-preview-perf-ratchet.md) — 为什么数「活」不数 CPU、只许降不许涨、不拿画质换数字。
- [声音编辑：波形、深度缩放、音量曲线、推子与电平表](docs/plans/2026-09-23-audio-mixing.md) — 曲线属于段、推子属于轨等拍过的板，和三个探针的实测地基。
- [音频库（音乐 / 音效）](docs/plans/2026-09-22-audio-library.md) — R2 按需下载 + 本地导入；网上的素材**只收 CC-BY / CC0**（SA 会传染给用户成片），用户确认可分发的自有素材标 `owned`（09-30 加）；manifest、试听、ducking。
- [从 Finder 拖文件进轨道](docs/plans/2026-09-22-media-file-drop.md) — 拖到指针处：画面撞上往上抬一轨、声音放不下从头找；磁吸开着时主轨落在拼紧之后的位置；多文件首尾相接、⌘V 粘贴文件；和 `addMedia` 的分工。
- [画面段的入场 / 出场动画](docs/plans/2026-09-18-clip-animation.md) — 效果清单、吞掉画面渐变、不露边口径、选型约束与分刀。
- [转场库扩充](docs/plans/2026-08-23-transition-library.md) — 推移 / 擦除 8 种新转场的选型约束（预览斜坡能精确表达才收）与悬停预览选择器。
- [定格方案](docs/plans/2026-08-08-freeze-frame.md) — 产品参数、提交模型、分辨率政策与已知代价。
- [原生录屏方案](docs/plans/2026-08-06-native-screen-recording.md) — 产品目标与阶段方案；当前状态以实施报告为准。
- [原生字幕生成方案](docs/plans/2026-08-06-native-subtitle-generation.md) — SpeechAnalyzer、Translation、缓存与 macOS 15/26 分层。

### 报告（docs/reports/）

- [合并后 main 上那一轮：树已经验过就不再跑检查](docs/reports/2026-11-13-main-ci-verified-tree.md) — 到 11-13 能还原的 358 次合并里 308 次的树和 PR 那轮绿的 CI 测的一模一样（11-04 起 104 次里 77 次）；main 上红过的 24 轮没有一次是 PR 没跟上 main；几种做法的比较、GitHub 上试出来的行为。
- [声音功能的真实冒烟：界面 + AI 工具（2026-11-11）](docs/reports/2026-11-11-voice-real-smoke.md) — 新建 / 设计 / 删声音、变声、读稿、长期授权全过，74.2 积分和账单逐笔对上；撞出的问题修在 #379、#383，音频引擎一直开着当时待拍板。
- [变声（声音 PR 9）：离屏渲染和免费冒烟](docs/reports/2026-11-11-change-voice.md) — 面板三种语言的图、假 Sky Studio 上走全程；没验到真 Sky Studio 和真窗口。
- [MCP 按需说明：迁移完以后的完整实测](docs/reports/2026-11-11-mcp-guide-final-measurement.md) — 61 个工具、两个客户端各 8 个任务：Claude Code 整份预先加载 −7.6%、过 6% 线（加进第 62 个工具后补量 −6.7%），任务 6 被拒 1 → 2 次；Codex 三条开销线按字面没到，已接受并更正口径。
- [声音功能的免费冒烟补跑（声音 PR 3–6）](docs/reports/2026-11-10-voice-free-smoke.md) — 假 Sky Studio 上合批、声音库、并发、换备用全过；没跑到的和看见的五条问题。
- [声音库界面的离屏渲染（声音 PR 8）](docs/reports/2026-11-10-voice-library-ui.md) — 英 / 中 / 西各一张拼图；看图撞出的两件事；没验到的（真麦克风、真 sheet）。
- [MCP 按需说明的基线实测（Claude Code + Codex）](docs/reports/2026-11-10-mcp-guide-baseline.md) — 改之前每轮常驻 1,605 token、整份预先加载 39,646 token；八个任务的调用和脱敏证据。
- [MCP 按需说明的试点实测（Claude Code + Codex）](docs/reports/2026-11-10-mcp-guide-pilot.md) — Claude Code 过线（常驻 −6.5%、预先加载 −2.2%）；Codex 三条数值线没到，协调者按结果放行；任务 7 的规矩修了之后两个客户端补测都停下来问。
- [MCP 按需说明的实施报告（2026-11-10–11 阶段记录）](docs/reports/2026-11-10-mcp-guide-progress.md) — 截至 11-11 方案的七个 PR 都合了（最后是 #377）、三次实测在哪、本机跑检查的偶发；Claude 桌面版的两个任务（用户手动）仓库里没有记录。
- [全部图片模型与角色系统的真积分验收（0.18.62）](docs/reports/2026-11-07-image-models-and-characters-smoke.md) — 新图片模型、换角度、角色全流程成功（208 积分）；撞出的问题和放大超时已修（0.18.63）。
- [一个 PR 从本地到能合要多久：改之前和改之后](docs/reports/2026-11-04-ci-speedup.md) — 本地 24 分钟 → 1.5–3 分钟；PR 的 CI 约 11 分钟 → 缓存热、原样重跑约 6 分钟（冷 7 分 40 秒–8 分钟）；五个 PR 各改了什么。
- [官方原创短片客户端接入](docs/reports/2026-11-04-official-film-client.md) — API 合同、生成接入、公开制作状态的逐项证据；客户端、生产启用、真实输出分开报告。
- [MCP 发现与真实 Codex 选工具实测](docs/reports/2026-11-03-mcp-discovery-and-task-selection.md) — 50 → 55 项、四类真实需求的调用和落盘结果。
- [导出耗时与快速审阅实测（2026-11-02）](docs/reports/2026-11-02-export-profile-review.md) — 107 路输入的教程导出慢在反复解码静止叠层；改完的阶段计时和快速审阅预设的实测。
- [成片检查实施与验证（2026-11-02）](docs/reports/2026-11-02-video-inspection.md) — `inspect_video` 的隔离验证：真实混音 / 画面 / 字幕和试听证据，不改工程。
- [顶部工作台、统一设置与 MCP 验收](docs/reports/2026-10-31-workbench-settings.md) — 单排工具栏、五类统一设置、设置工具的实际证据。
- [Sky Studio 生成与配音真实验收](docs/reports/2026-10-29-sky-studio-generation-and-voice.md) — 6b 五类、6c 旁白 / 合批克隆 / 排队退款、累计积分账。
- [测试版 0.18.48：导出水印和 Claude 桌面版「连接」的冒烟](docs/reports/2026-10-27-beta-watermark-and-claude-desktop-smoke.md) — 水印落点对表；桌面版要真重启才重读配置。
- [真 Codex 连 SkyCut 的冒烟（0.18.47）](docs/reports/2026-10-26-codex-client-smoke.md) — 连接 / 断开、12 步全通；撞出悄悄丢参数和备份权限两个问题。
- [AI 多开补测：屏幕亮着走界面项（0.18.42 → 0.18.45）](docs/reports/2026-10-18-ai-multi-project-ui-smoke.md) — 撞出并修掉三个问题（#241–#243）；怎么在用户用着电脑时测。
- [第四批 AI 反馈的测试版冒烟（0.18.46）](docs/reports/2026-10-18-ai-feedback-batch4-smoke.md) — 折行断在词组边界、预览和成片一样；同一份完整转写下 `listen cuts` 和 cut_speech 的建议一致，只转写四段时入点差一帧。
- [改名 SkyCut 之后的冒烟（0.18.47）](docs/reports/2026-10-18-skycut-rename-smoke.md) — 授权不用重给、两种工程后缀都能开；菜单栏的 App 名取可执行文件名。
- [AI 多开第 ① 刀的冒烟（0.18.38）](docs/reports/2026-10-17-open-projects-slice1-smoke.md) — 两个工程窗口各管各的；撞出「先放内容后挂 delegate」并修好。
- [AI 多开第 ② 刀的冒烟（0.18.39）](docs/reports/2026-10-17-ai-project-routing-slice2-smoke.md) — 一个会话两个工程各进各的、别的会话碰不到；撞出 open_folder 报旧文件夹。
- [AI 多开第 ③ 刀的冒烟（0.18.41）](docs/reports/2026-10-17-ai-headless-slice3-smoke.md) — 后台工程的 MCP 流程跑通；屏幕锁着，真的一个窗口都不开和侧边栏没目检；锁屏时别拿 CG 窗口列表判断窗口关没关。
- [AI 多开第 ④ 刀的冒烟（0.18.42）](docs/reports/2026-10-17-ai-queue-version-slice4-smoke.md) — 一个文件夹两个版本、导出和字幕排队；方案四刀做完。
- [第三批 AI 反馈的测试版冒烟（0.18.35）](docs/reports/2026-10-16-ai-feedback-batch3-smoke.md) — `listen cuts=true` 和字幕行距真机过一遍，撞出 quiet_spot 的 bug。
- [字幕默认单行 + 行数开关的测试版冒烟（0.18.37）](docs/reports/2026-10-16-subtitle-line-count-smoke.md) — `max_lines` 和面板两条路结果一样、撤销各退一层。
- [视频 upscale 实测：六个 fal 模型、19 条真素材](docs/reports/2026-10-02-upscale-smoke-test.md) — 各家的计费规律、只有 FLUX 保留声音、帧数的坑。
- [AI 接口（MCP）第六块实施报告](docs/reports/2026-09-29-mcp-slice6-report.md) — fal.ai 生成：模型表、Key、每日上限、`generate_media`；没对真 fal 验过的。
- [AI 接口（MCP）第三块实施报告](docs/reports/2026-09-28-mcp-slice3-report.md) — 分析数据 + 智能剪：`transcribe`、`listen beats`、`cut_speech`、`cut_to_beat`。
- [AI 接口（MCP）第四块实施报告](docs/reports/2026-09-28-mcp-slice4-report.md) — 本机识别画面：分镜头、一次看几个文件、铺满跟拍；探针实测。
- [AI 接口（MCP）第五块实施报告（2026-09-28–29 阶段记录）](docs/reports/2026-09-28-mcp-slice5-report.md) — 剪辑风格、配音（macOS / Kokoro 的探针与接入）、逐词高亮字幕；验收实剪跑了两轮，PR #81 09-29 合并后的核对和没做完的见正文。
- [AI 接口（MCP）第一块实施报告](docs/reports/2026-09-27-mcp-slice1-report.md) — 23 个工具、CI 与端到端证据、测试版怎么出（`scripts/build-beta-app.sh`）。
- [AI 接口（MCP）第二块实施报告](docs/reports/2026-09-27-mcp-slice2-report.md) — AI 的手和眼（画面放法、去黑边、`look`、`listen`）和现有功能铺满，工具 23 → 37 个。
- [原生录屏实施报告](docs/reports/2026-08-06-native-screen-recording-implementation-report.md) — Phase 0–5 的真实进度、实测证据、偏差和未完成项。

## 架构与长期约束索引

每份一行：链接 + 这份文档管什么。约束本身在文档里；改哪块该读哪几份，见上面「按修改范围选必读文档」。

- [MCP 说明书（skycut_guide）](docs/architecture/mcp-guide.md) — 按需读的工具说明：只有它预先加载、每个工具一个同名主题、目录 ≤ 5,000、一次 ≤ 6,000 且长的分节。
- [SkyCut 官网](docs/architecture/skycut-website.md) — `website/`：只在本地预览、合并 main 后才部署；首屏静图与渐进增强、样式表的先后、小字读得清、SEO / GEO、Guides 文章、对外不提 GitHub。
- [MCP 功能发现与升级后的重连](docs/architecture/mcp-discovery.md) — 分别核对 App、helper 与客户端实际的 schema；最小示例、重连步骤。
- [写代码的规范](docs/architecture/coding-standards.md) — 模块化六条、单文件目标 400 / 上限 600 行、老文件只许降的基线、审查清单。
- [文档索引怎么写](docs/architecture/doc-indexes.md) — AGENTS.md 和 `docs/bugfixes/INDEX.md` 里许写什么、不许写什么（白名单）、三类小节、整份上限和超了怎么收；收成一句话时例外、条件、适用范围不能丢；Bug 案例索引按文件名里日期后面那一段排，并行的 PR 别撞在同一行（为什么不用 `merge=union`）。
- [开着的工程（OpenProjects）](docs/architecture/open-projects.md) — 工程不再是单例：注册表、短 id、全 App 一个代号计数、每个工程自己的撤销、工程窗口、后台工程；谁该找哪一个工程。
- [签名与系统权限](docs/architecture/code-signing-and-permissions.md) — 固定的自签名证书「SrtFlow Signing」（永不重建、仓库钉 SHA-1）；系统授权按签名记账；钥匙串每个新构建仍要输一次密码。
- [产品名与代码名](docs/architecture/product-name.md) — 看得见的叫 SkyCut；身份（bundle id、UTType、钥匙串、数据文件夹…）和代码名永远沿用 SrtFlow。
- [AI 接口（MCP）](docs/architecture/ai-control-mcp.md) — 三段结构（客户端 → `skycut-mcp` → App）、工具清单只有一份、通道、工具在 App 里的规矩（一个工具 = 一步撤销、不弹模态框、什么时候问用户按权限模式和第四节第 6 条、硬预算不能绕过）、「连接 AI」。
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

全部案例的索引在 [docs/bugfixes/INDEX.md](docs/bugfixes/INDEX.md)：每条一行（日期 + 链接 + 一句教训），按文件名里日期后面那一段的字母序排（不按日期；日期每条自己带着）。

- 修 bug 之前、碰到眼熟的症状时，先在那份索引里按关键词搜一遍，有同类案例就先读它。
- 改某块代码时该读的案例，上面「按修改范围选必读文档」已经逐行链好，不用翻整份索引。
- 新案例照 [Bugfix 模板](docs/bugfixes/TEMPLATE.md) 写，写完按文件名里日期后面那一段的字母序插进那份索引，别都加在模板下面（同时开着的 PR 会撞在同一处）；插错了守卫会说该排在谁上面。

## 根目录文档

- [README.md](README.md) — 面向使用者的中英双语项目介绍。
- [SrtFlow-Requirements.md](SrtFlow-Requirements.md) — 产品需求与技术结论总表。
