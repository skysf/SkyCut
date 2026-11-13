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

| 修改范围 | 动手前必读 |
| --- | --- |
| 官网 `website/`、本地网页预览、官网 Vercel 配置与部署、**首屏 3D 场景（`website/src/scene*.js`、烤好的静图 `hero-still-*`、`main.js` 里加载场景的那一段）** | [SkyCut 官网](docs/architecture/skycut-website.md)（开发只在本地预览，功能分支不构建，最终 PR 合并 `main` 后才部署；「首屏的质感与渐进增强」：烤好的静图是默认画面，没有 WebGL / 减少动态效果 / 太慢 / 关 JS 都看它，不许退到另一种画面；改了场景外观要 `npm run build:hero-still` 重烤并提交指纹；不加 npm 依赖；「样式表的先后」：构建不保留样式表挂的顺序，每份样式表自带自己的平板 / 手机规则，`responsive.css` 只管 `base.css` 的东西；「小字读得清」：手机上看得见的字 ≥ 12 px、放不下的不显示，演示区的灰绿小字用 `--show-quiet` 并登记底色，示意图里的标签不是标题，行高别留 `normal`）、[首页在手机和 iPad 上版面全乱](docs/bugfixes/2026-11-11-website-phone-layout-lost-to-stylesheet-order.md)、[官网的小字](docs/bugfixes/2026-11-11-website-small-text-contrast-headings-font-shift.md) |
| 构建、打包、版本、授权、shell、CI、**签名（`scripts/signing/`：发布版用固定的自签名证书，系统权限才跨版本有效）** | [签名与系统权限](docs/architecture/code-signing-and-permissions.md)（打包脚本只经 `sign-app.sh` 签；证书永远不重建、换机器拷 `~/.config/srtflow/signing/`，仓库钉着它的 SHA-1；退回 ad-hoc 的包不许发版）、[构建与打包](docs/build/build-and-packaging.md)、[构建版本与 shell 陷阱](docs/bugfixes/2026-08-06-build-version-and-shell-traps.md)、[包内授权声明](docs/bugfixes/2026-08-06-stale-bundled-license-notice.md)、[CI 首跑与吞错](docs/bugfixes/2026-08-08-ci-first-run-sdk-and-swallowed-errors.md) |
| **App、小程序、MCP 服务器叫什么**（SkyCut / `skycut-mcp` / `skycut`），**新加身份类的字符串**（bundle id、UTType、数据文件夹、UserDefaults 的键、钥匙串、AI 通道、环境变量）、界面和给 AI 的话里写产品名 | [产品名与代码名](docs/architecture/product-name.md)（看得见的写 SkyCut；身份和代码名沿用 SrtFlow、永远不改的那张表；新加的同类东西照旧用老前缀）、[改名方案](docs/plans/2026-10-18-rename-to-skycut.md)（为什么只改看得见的、分几步、本机怎么收拾） |
| 工程存盘、格式版本、素材路径、自动保存、**重建预览时开素材（`MediaAssetCache`）**、**新建 / 打开工程（切工程时清掉上一个的运行时状态、播放头归零）** | [工程文件与素材重链接](docs/architecture/video-edit-project-file.md)（四之末：运行中素材只开一次，按路径 + 文件身份认，原地改写也算换了文件；五：卸片之后播放器的时间回调晚到一拍、没挂条目就丢掉，换完整份时间线就要 `scheduleRebuild()`）、[新工程停在上一个工程的位置](docs/bugfixes/2026-09-29-new-project-keeps-old-playhead.md)、[工程生命周期事故](docs/bugfixes/2026-08-03-project-file-lifecycle.md)、[运行期素材重链接](docs/bugfixes/2026-08-08-runtime-media-relink.md)、[重建把每个素材重新打开一遍](docs/bugfixes/2026-09-25-rebuild-reopens-every-asset.md) |
| **哪个工程**：`OpenProjects`（主窗口那个 `primary` / 工程窗口里或后台（没有窗口、不建预览）的 `others` / 菜单作用的 `focused` / 全部 `all`）、`VideoEditProject` 的建法、短 id（p1…）、**工程代号全 App 不重号**（`DocumentGenerations`）、每个工程的撤销管理器（不许退到键窗口的）、退出问每个工程、录屏落回开录的工程、**工程窗口**（`ProjectWindowController`：delegate 交出工程自己的撤销管理器、先挂 delegate 再放内容；按键 / 时间线几何 / 录屏框 / upscale 面板只认自己的；关工程的收拾 `ProjectTeardown`；换 / 关一个工程只停它自己的活；导出器全 App 一个，进度 / 停止 / 成片只给发起导出的那个工程：`exporter.belongs(to:)`）；**任何新代码要工程时找注册表或调用方给的那一个，别再假设只有一个** | [开着的工程](docs/architecture/open-projects.md)（谁找哪一个的表、代号为什么全 App 一个计数、撤销为什么不许退到键窗口、工程窗口里哪些只认自己的、探针和冒烟的证据）、[AI 多开方案](docs/plans/2026-10-17-multi-project-ai-editing.md)（后面几刀：AI 按 `project` 找工程、后台工程、排队） |
| 时间线捏合、滚动、移动、裁切（一段能裁多少、多段一起裁、链接伙伴一起裁）、吸附与对齐线（裁切也吸）、框选、点击落点（点空白 / 点块本体都移播放头，唯一入口 `VideoEditProject.seekFromTimeline`，§5f）、扫帧预览、**拖动 / 拉框进行中的视图状态（`TimelineDragBox`）**、**缩放的锚点（捏合钉指针、工具栏钉播放头）与纵向缩放（统一行高）** | [捏合缩放](docs/architecture/timeline-pinch-zoom.md)（锚点从时间线自己的滚动几何量，别按坐标 hitTest 找滚动视图；纵向缩放统一成一个高度）、[锚点从来没生效](docs/bugfixes/2026-09-26-pinch-zoom-anchor-never-applied.md)、[拖动手势](docs/architecture/timeline-drag-gestures.md)（§0b 会话不进时间线的 `@State`：盒子持有不订阅、块只收自己那份；§3.6 裁的算法只有 `TimelineTrim` 一份、整组一起停）、[拖动卡顿与落点](docs/bugfixes/2026-08-09-timeline-clip-drag-lag-and-alignment.md) 、[拖文件进轨道](docs/plans/2026-09-22-media-file-drop.md)、[裁切不跟链接](docs/bugfixes/2026-09-25-trim-ignores-linked-clips.md)、[拖动会话住在时间线的 @State 里](docs/bugfixes/2026-09-25-drag-session-in-timeline-state.md) |
| **联动**（工具栏的链子开关开着时，压在主轨块上的上层轨 / 音频轨 / 文字 / 形状 / 滤镜 / 字幕句跟着它挪、跟着它删；`TimelineLinkage` / `TimelineLinkageLanding`、`perform(deletesContent:)`、拖动计划的 `host`）、删 / 挪 / 裁 / 变速 / 定格之后别的轨跟不跟、**字幕句怎么跟（`LinkageCueFollow`）**、AI 工具结果里的 `linkage` | [联动](docs/architecture/timeline-linkage.md)（跟着**画面**走不跟 id、完全在一段里的才跟、跨段的全部挪同一个量才跟、只有真删才连带删、规则只在 `perform` / `liveApply` 收尾一处、拖动中压着的东西是成员且没有障碍、撞上让开；**规矩 12：字幕句两头各自换算、说话的那几秒剩不到一半就删（裁切也删，2026-10-15 用户定）、按词不按显示时间**）、[方案](docs/plans/2026-10-02-timeline-linkage.md)（每条怎么定的）、[拖动手势 §3.7](docs/architecture/timeline-drag-gestures.md)、[联动把字幕当一整块挪](docs/bugfixes/2026-10-15-linkage-moves-subtitles-as-a-block.md)、[裁掉说的话的字幕留在原地和下一句叠](docs/bugfixes/2026-10-15-linkage-deletes-subtitles-whose-speech-was-trimmed.md)、[换源之后压在上面的东西被挪了一个偏移](docs/bugfixes/2026-10-15-linkage-follows-source-shift-after-swap.md)（同 id 换素材按改之前的素材和入点记账） |
| 工具栏右边那组开关（磁吸 / 吸附 / **联动** / **播放跟随**）、剪辑页字幕列表的跟随按钮、**播放时时间线跟不跟播放头**（`PlayheadFollow`、`TimelinePlayheadLines.followPlayhead`）、冒烟 / 性能场景起手的开关状态、新加一个要记住的开关、**磁吸什么时候排 V1（`MainMagnet`、`state.mainMagnet`、`setMagnet`）** | [剪辑页上记住的开关](docs/architecture/editor-remembered-toggles.md)（默认值和记忆只有 `EditorToggles` 一份、字面量就是产品口径；脚本驱动时永远默认值、写不落盘；联动默认开（2026-10-02）、播放跟随默认关、只碰横向、停下不滚回、Return 回到开头照旧滚回最左；**磁吸 2026-10-02 起跟着工程走**：存进工程文件、老工程缺键 = 关、记住的只当新建工程的默认，只在改到 V1 的排布时排）、[磁吸改一条音量曲线就合上 V1 的缝](docs/bugfixes/2026-10-02-magnet-closes-v1-gaps-on-any-edit.md)、[联动](docs/architecture/timeline-linkage.md)、[拖动手势 §4.5 / §5](docs/architecture/timeline-drag-gestures.md)、[预览性能 ratchet 第十二节](docs/architecture/preview-perf-ratchet.md)（时间线上只有播放头竖线和标尺把手订阅时钟） |
| 插进两条轨之间（缝拉开）、整条轨上下换位置、轨道头的拖动（换位 / 下边缘调行高） | [插入缝与整轨换位方案](docs/plans/2026-09-24-track-insert-and-reorder.md)、[拖动手势](docs/architecture/timeline-drag-gestures.md)（§5h 插入缝、§5i 整轨换位）、[视频轨对等化](docs/architecture/video-tracks.md)（轨道头这一列）、[预览性能 ratchet](docs/architecture/preview-perf-ratchet.md)（轨道头的行每跳不重算，别往它的输入里塞闭包） |
| 顶部工作台、图标按钮、更多工具、统一设置窗口、MCP 的 get_settings / set_settings、**打开全部权限时的说明（`FullAccessConsentSheet`）和长期授权的记 / 撤** | [顶部工作台与统一设置](docs/architecture/workbench-and-settings.md)（单排、无永久工具侧栏、三个设置入口同一个窗口、复用现有 Store；AI 活动不可误隐藏、只报真实任务进度；设置工具先全验再写，不碰密钥与权限确认；**选全部权限先弹说明、同意才写 Store 并记长期授权，切回撤掉；set_settings 的问句带同一段说明、令牌绑那一版**）、[声音库](docs/architecture/voice-library.md)第八节第 9 条 |
| 界面主题、默认森林色 / 经典色、主题设置与 MCP 的 theme、窗口背景与轨道界面配色、**AppKit 自建的窗口 / 面板（浅 / 深跟不跟主题）**、**切主题 / 系统切深浅色时开着的窗口跟不跟** | [界面主题](docs/architecture/app-themes.md)（森林色默认，经典色保留原色；全 App 同一偏好，所有呈现根共用，不进工程、不改素材与导出颜色；浅 / 深只有 `AppThemePalette.colorScheme` 一条，`.preferredColorScheme` 只改得了宿主就是 contentView 的窗口，宿主垫在别的视图下的自建面板要设 `windowAppearance`；交给 SwiftUI 的永远是明确的浅 / 深：经典色换成系统此刻的那一个（`resolvedColorScheme(system:)` + `SystemColorScheme`），不交 nil，SkyCut 不设 `NSApp.appearance`）、[系统深色时提示深底深字](docs/bugfixes/2026-11-11-tooltip-dark-on-dark-in-forest-theme.md)、[切经典色开着的窗口只变一半](docs/bugfixes/2026-11-11-theme-switch-leaves-windows-half-light.md) |
| 编辑器分栏、预览区/时间线的行结构与最小高度 | [播放条压到工具栏上](docs/bugfixes/2026-08-12-preview-transport-row-overlap.md) |
| 预览变换、叠化、上层视频轨、导出滤镜、**预览合成往合成轨上接东西（只从末尾接、合成完裁到总长、换格子别改成四舍五入、切片表按格子去重、主轨接缝不到 0.01 秒的零头不算空隙）** | [预览自由变换](docs/architecture/preview-free-transform.md)（「一份时间账」：多一格就黑屏；压黑 / 闪白照 xfade 的公式逐帧算、闪白垫白底，关键帧段推移按每片的摆放裁画布）、[look 看转场和成片对不上](docs/bugfixes/2026-10-14-look-transitions-differ-from-export.md)、[加了音效预览整个黑屏](docs/bugfixes/2026-09-27-preview-black-after-audio-tick-pushed-past-end.md)、[叠化 + 关键帧之后预览全黑](docs/bugfixes/2026-09-29-preview-black-slice-boundaries-straddle-a-tick.md)（边界各自截断落在相邻两格；两条管线同一个 `mainGapTolerance`）、[视频轨对等化](docs/architecture/video-tracks.md)、[关键帧动画](docs/architecture/keyframe-animation.md)、[Transform 复审](docs/bugfixes/2026-08-04-transform-review.md)、[预渲染复审](docs/bugfixes/2026-08-05-export-prerender-review.md) |
| 从 Finder 拖文件 / ⌘V 粘贴文件进时间线、导入落点 | [拖文件进轨道](docs/plans/2026-09-22-media-file-drop.md)、[卡片被文件落点吞了](docs/bugfixes/2026-09-23-in-app-drops-swallowed-by-file-underlay.md)、[外部拖入被内层落点独占](docs/bugfixes/2026-09-23-timeline-file-drop-claimed-by-inner-drop-region.md)（结论已更正）、[拖动手势](docs/architecture/timeline-drag-gestures.md)（主轨保序、§5e-2 唯一落点）、[视频轨对等化](docs/architecture/video-tracks.md) |
| 时间线上的复制 / 剪切 / 粘贴（⌘C ⌘X ⌘V、编辑菜单、块和轨道空白处的右键菜单）、剪贴板类型、粘贴落点（鼠标优先、否则播放头）、从旧段构造新段（分割 / 复制，别漏字段）、**分割之后的链接组** | [复制粘贴](docs/architecture/timeline-clipboard.md)（剪贴板只有一套、不写纯文本；每一样换新身份走编码往返；撞上了往上抬、几组保住上下关系；三之二：分割都走 `LinkRegrouping.split`，一对切开是两对）、[分割后整串互为伙伴](docs/bugfixes/2026-09-28-split-links-every-piece-together.md)、[方案](docs/plans/2026-09-26-timeline-clipboard-and-zoom.md)、[分割丢了隐藏和音频库的键](docs/bugfixes/2026-09-26-split-drops-hidden-and-library-key.md)、[拖文件进轨道](docs/plans/2026-09-22-media-file-drop.md) |
| 时间线上的任何拖放落点（`.onDrop`：文件 / 滤镜 / 音频库 / 转场卡片）、新的自定义拖放 / 剪贴板类型 | [拖动手势 §5e-2](docs/architecture/timeline-drag-gestures.md)（整条时间线只许一个 `.onDrop`；自定义类型必须在 Info.plist 声明；不能放回 `.forbidden` 不回 `.cancel`）、[转场拖放被 `.cancel` 取消](docs/bugfixes/2026-09-23-transition-drop-cancel-ends-session.md)、[卡片被文件落点吞了](docs/bugfixes/2026-09-23-in-app-drops-swallowed-by-file-underlay.md)、[自定义类型没声明](docs/bugfixes/2026-09-23-custom-drag-types-not-declared.md)、[GUI 冒烟流程](docs/testing/gui-smoke-testing.md)（落点路由探针） |
| 轨道模型、时间线行结构、轨道行高、轨道配色、预览点选 | [视频轨对等化](docs/architecture/video-tracks.md)、[工程文件与素材重链接](docs/architecture/video-edit-project-file.md) |
| 段的显隐（V / 眼睛）、隐藏段进不进预览和成片，文字 / 形状 / 滤镜段的隐藏（`rendered*` 清单） | [段的显隐](docs/architecture/clip-visibility.md)、[视频轨对等化](docs/architecture/video-tracks.md)、[上层轨藏起来的段还在成片里](docs/bugfixes/2026-09-26-hidden-upper-clip-still-exported.md) |
| 画面渐入渐出、alpha 斜坡、转场仲裁 | [画面渐入渐出](docs/architecture/video-fades.md)、[声音：音量与渐入渐出](docs/architecture/audio-fades.md) |
| 主轨转场的容量、可用判定、借余料、首尾帧定格补足 | [主轨转场：借余料与定格补足](docs/architecture/transition-handles.md)、[转场预览有、成片没有](docs/bugfixes/2026-09-20-transition-preview-export-divergence.md) |
| 画面段的入场/出场动画、预设效果、预渲染路由 | [画面段的入场 / 出场动画](docs/architecture/clip-animation.md)、[画面渐入渐出](docs/architecture/video-fades.md)、[关键帧动画](docs/architecture/keyframe-animation.md) |
| 画面文字、字体、Core Text 渲染、文字动画、逐帧导出、预览上文字的选中框和可点范围、**文字行（行号进模型、行序 = 叠放序、上下换行）**、数字的等待、**老虎机位数不同的两头（`NumberOdometer`）** | [画面文字](docs/architecture/text-overlays.md)（把手的可点范围写在 `.offset` 之前；没选中的字只认看得见的部分；行号进模型，预览与导出同一份叠放序；老虎机不存在的那一位滚成空白收掉，居中和右对齐右边不动；导出时序列末尾多渲两帧、几段左闭右开，接缝那一帧不空不叠）、[字在接缝上闪没一帧](docs/bugfixes/2026-10-14-text-blinks-at-animation-seam.md)、[老虎机停在「090」](docs/bugfixes/2026-09-25-odometer-leading-zero.md)、[主字体里没有的字画成乱码](docs/bugfixes/2026-09-29-text-fallback-glyphs-drawn-with-main-font.md)（排版给了谁的字形号就用谁画）、[拖动手势 §5j](docs/architecture/timeline-drag-gestures.md)、[拖字变成旋转](docs/bugfixes/2026-09-24-text-rotate-handle-hit-area-at-center.md) |
| 滤镜调色、LUT、预览图层滤镜、导出 `lut3d` 段、滤镜段的选中（多选）、**任何滤镜下纯黑的地方（空档、黑场、黑底字卡）** | [滤镜](docs/architecture/filters.md)（纯黑不抬：`FilterLUT.holdingBlack`，只收往亮里调的、按输入最亮的通道、连续不出台阶）、[滤镜把纯黑抬成灰](docs/bugfixes/2026-10-14-filters-lift-pure-black.md) |
| 画面上的形状（线条 / 长方形 / 正方形 / **圆 / 圆弧**）：种类、几何、怎么画（`ShapeOutline`、`ShapePreviewDrawing`、`ShapePNGRenderer`、`ShapeOverlayCanvas`）、**形状的入场 / 出场动画**（`ShapeAnimation` / `ShapeAnimator`、导出切段 `ShapeOverlayExport`、形状和文字共用的导出接法 `OverlayExportFile`、检查器的「动画」一节）、`set_shape` | [画面上的形状](docs/architecture/shapes.md)（所有种类画什么只有 `ShapeOutline.drawing` 一份、预览和导出同一条路径，只各自上色；什么都没露出来时给空路径、不许裁到空区域；圆弧从 12 点钟顺时针、扫过 `arcSweep`；动画和文字同名同曲线、出场是入场倒放、时刻先钉到工程帧上、只逐帧渲动画那两截；v30 / v31）、[导出的线比预览长](docs/bugfixes/2026-10-03-exported-lines-longer-than-preview.md)、[画面文字](docs/architecture/text-overlays.md)「导出：只逐帧渲动画进行中的那段」、[盖一块](docs/architecture/cover-blur-mosaic.md)（模糊 / 马赛克也是形状的一种，没有动画） |
| **盖一块（模糊 / 马赛克，`ShapeKind.blur` / `.mosaic`）**、预览的第二层播放器（`CoverPreviewLayer`）、导出里的 `gblur` / `pixelize`（`VideoEditCoverExport`）、`set_shape` 的 blur / mosaic、`look text_scan` 给的 `cover`（`AICoverBox`）、遮水印 / 遮旧字幕 | [盖一块](docs/architecture/cover-blur-mosaic.md)（形状的一种、时间线上的一段、**不跟着片段走**；落点在调色之后、形状之前；三条管线按构造一致：裁出这一块、在这块里做效果、边缘外延、贴回去；预览的蒙版和滤镜别挂同一层；`CIPixellate` 的格子要设成从左上角起算；框取偶数往外收；力度按画面高换算）、[滤镜](docs/architecture/filters.md)（预览不走自定义合成器、图层滤镜的地基）、[预览自由变换](docs/architecture/preview-free-transform.md)（源画面框换画布框的变换顺序）、[AI 接口（MCP）](docs/architecture/ai-control-mcp.md)（第 38 条）、[预览性能 ratchet](docs/architecture/preview-perf-ratchet.md)（没有盖一块时第二层不建、性能计数不变） |
| 工程帧率、关键帧容差、**AI 读写关键帧（报出来的永远在片段范围里、`edit_clip keyframes` 策略、`relative` 时间）**、**关键帧的缓动（`Keyframe.easing`、`KeyframeEasing`、预览按帧加密 `KeyframeSliceTimes`、AI 默认 easeInOut）** | [工程帧率](docs/architecture/project-frame-rate.md)、[关键帧动画](docs/architecture/keyframe-animation.md)「AI 接口」「缓动」（linear 逐位一致、只对画面的六条轨、v27；急停 / 回弹 / 弹簧是 v32，冲过头的两条夹宽高下限、最低值放宽）、[限幅 + 缓动方案](docs/plans/2026-09-30-export-limiter-and-easing.md) |
| 音量、dB、渐入渐出、增益表（`AudioGainTable.swift`）、**音频引擎（`Sources/SrtFlow/AudioEngine/`：配置、环、喂样、渲染块、离线渲染）**、**引擎的图什么时候开着（空闲停图 / 再起：`AudioEngineIdlePolicy` / `AudioEngineIdleKeeper`、`suspend` / `wake` / `recoverIfNeeded`、待钉的锚点 `PlaybackAnchor`、用户在不在 `AppUserPresence`、换工程收引擎 `unloadPreview`、播到头由主时钟按总长自己收尾 `PlayerClock.finishAtEnd` / `PlaybackAudioSource.duration`、「报过时间没有」的内存序 `AudioRenderClock.hasTicked`）**、**读素材 / 重采样（`AudioSegmentReader`：拉式喂转换器、延续按输出帧判）**、预览合成里没有音轨（配乐比画面长要垫黑底） | [声音：音量与渐入渐出](docs/architecture/audio-fades.md)、[成片的声音](docs/architecture/export-audio-mixdown.md)、[音频引擎](docs/architecture/audio-engine.md)（合同：段落和增益的规则只有一份、渲染块实时安全、一段一条流、**「结构没变」= 轨 + 段的身份 + 段的几何（`Segment.Structure`：挪 / 裁 / 变速 / 换文件要重开流，只有增益、场景的参数、推子能在流活着时换）**；**第二节第 11 条：图只在马上要出声时开着 —— 没有声音不开、停着 2 分钟没人用就停（2026-11-11 用户定的数，改它先问用户；规矩只有 `AudioEngineIdlePolicy` 一份、停图只许经 `AudioEngineIdleKeeper`）、用户回到 SkyCut（变成活动的、窗口变成主 / 键窗口、鼠标移进窗口、按键）就在后台先起好、时钟要出声时还停着就当场起并从原处开播（不许让播放头先按 host 时间空走：起声卡时整个进程被拖住，先走的那一截会被跳过）、重启之后的采样时间不能指望（在播的锚点待钉）、换工程 / 时间线空了收引擎、**播到头由声音主时钟按总长自己收尾、在尽头再按播放不开播、不听播放器的「播到头」通知（会晚到、排到下一轮、不会再发第二次）**、后台起图没起来回到故意停着（不空转）、**一个判断只读一次图的状态（原子的，后台随时改：`AudioGraphRun.State.isUp`）**；第 8 条：「报过时间没有」先写数再 release 发布、acquire 读**；第三节：合成里只有画面、画面收得早要垫黑底铺到总长；读取器按块读 = 一口气读）、[预览的音频引擎一直开着](docs/bugfixes/2026-11-11-preview-audio-engine-never-idles.md)、[每 4096 帧重采样器重新起步](docs/bugfixes/2026-10-01-resampler-reset-every-chunk.md)、[条目比时间线短](docs/bugfixes/2026-10-01-preview-item-shorter-than-timeline-without-audio-tracks.md)、[挪了段之后声音还在原地](docs/bugfixes/2026-10-06-audio-engine-replace-keeps-old-segment-positions.md)、[音频引擎方案](docs/plans/2026-10-01-audio-engine.md)（分刀和数字） |
| 声音场景（喇叭 / 室内 / 室外）、引擎渲染块里的效果链（`SceneBox` / `mixScene`）、余音越过段尾、检查器的声音那一块 | [声音场景](docs/architecture/sound-scenes.md)（效果在段增益之后、推子之前；一段一条链、段尾之后喂零散余音；加 / 去掉场景重开流）、[推子与电平表](docs/architecture/audio-mixer.md)、[成片的声音](docs/architecture/export-audio-mixdown.md)、[声音场景方案](docs/plans/2026-09-24-sound-scenes.md) |
| 导出的声音、离线混音（`ExportAudioMixdown`）、导出图里接音轨的地方、**限幅器（`ExportPeakLimiter`）、整段响度（`ExportLoudnessMeter`、`AudioKWeighting`）、面板和 `get_job` 里的响度 / 峰值 / 压了多少** | [成片的声音](docs/architecture/export-audio-mixdown.md)（导出图里不许有声音滤镜；成片 = 预览那个音频引擎离线渲出来的、同一份 `AudioEngineConfig`；写 f32 之前过真峰值限幅器、上限 −1 dBFS、总长不变，响度只报不归一，预览不限幅是已知差异）、[限幅 + 缓动方案](docs/plans/2026-09-30-export-limiter-and-easing.md)、[过 0 交给 AAC](docs/bugfixes/2026-09-30-export-mix-over-0dbfs-into-aac.md)、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md)、[转场那条缝上预览的声音掉下去](docs/bugfixes/2026-09-24-preview-mix-ignores-transition-expansion.md) |
| **优化媒体**（`Sources/SrtFlow/OptimizedMedia/`：关键帧间隔的探测 `MediaInfo.keyframeInterval`、解码速度、判据、缓存、转一块、协调者 `OptimizedMediaCoordinator`、换源表 / 顺序）、**builder 插画面（`CompositionClipInsert`）**、预览重建传 `proxies` 的那一处、预览工具条的「优化媒体 / 原片」（`OptimizedMediaMenu`）、`MediaReadQueue.proxy`、**设置里的「优化媒体」一节（`OptimizedMediaCacheSettings` / `OptimizedMediaSettingsSection`：占用 / 上限 / 清空）、启动时的过期扫描、转不了的提示** | [优化媒体](docs/architecture/optimized-media.md)（只转长 GOP 且按这台机器算；原分辨率 4K 减半；H.264 0.5 秒关键帧无 B 帧只有画面、**经视频合成读、块的轨从块头盖到块尾**；源时间 10 秒一块；缓存按路径找按身份认、改参数要 +1 版本、10 GB LRU；读和编只在 MediaReadQueue 上；**换源只换画面不动时间账、格子相加正好、差一块退回原片；只在停着时换、某段的块齐了才换、最多 3 秒一次；先转播放头附近的；成片 / 预渲染 / AI 看永远原片；菜单只订阅协调者；性能台架量原片；第 16 条：清空之后紧跟 `reset()` + `scheduleRebuild()`、`removeAll` 只许设置那一节的模型调；上限十进制几档、键只经 Store、改小当场 enforce；启动时 proxy 队列上过期；转不了的只在菜单里标、不进提示条**）、[方案](docs/plans/2026-10-01-video-optimized-media.md)、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md)、[预览性能 ratchet](docs/architecture/preview-perf-ratchet.md) 第十四节 |
| 波形显示、深度缩放（缩放上限、标尺刻度、缩略图、超宽内容的绘制） | [波形与深度缩放](docs/architecture/audio-waveform.md)、[捏合缩放](docs/architecture/timeline-pinch-zoom.md)、[拖动手势](docs/architecture/timeline-drag-gestures.md) §5、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md) |
| `AVAssetReader` 读采样（`copyNextSampleBuffer`），以及在 async 函数 / `Task` 里做任何会卡住线程的事（等信号量、同步 IO、等子进程） | [阻塞的媒体读取](docs/architecture/blocking-media-reads.md)（字幕生成那个写在 async 里的读取器 `AudioWindowReader.extract` 只许 `SubtitleGen/` 调，别处要同样的 16 kHz 音频走 `QueuedAudioWindow`）、[缩略图和波形全空](docs/bugfixes/2026-09-23-waveform-decode-deadlocks-thread-pool.md) |
| 引擎定位与短探测（`FFmpegRuntime` / `FFmpegRuntimeProbe` / `MediaToolchain`） | [阻塞的媒体读取](docs/architecture/blocking-media-reads.md)「引擎启动探测」（单候选共享截止时间、双输出总量、父进程独占回收、单次定位任务），[后台引擎探测卡住](docs/bugfixes/2026-11-04-engine-probe-hangs.md) |
| 音量曲线（段上的音量自动化）、轨道推子 / 总推子、电平表（引擎的槽 `MeterSlot`） | [音量曲线](docs/architecture/audio-volume-curve.md)、[推子与电平表](docs/architecture/audio-mixer.md)（第三节：峰值从渲染块来、总表从混音器出口来、槽按键登记、界面每拍取走）、[播放中按 Return 崩溃](docs/bugfixes/2026-09-26-meter-crash-on-go-to-start.md)、[声音：音量与渐入渐出](docs/architecture/audio-fades.md)、[声音编辑方案](docs/plans/2026-09-23-audio-mixing.md)、[一条轨上换了音频格式](docs/bugfixes/2026-09-23-meter-tap-dies-on-audio-format-change.md) |
| Inspector 数值框、拖调、Transform 写入、检查器里的滑杆行（`labelledSlider` / `InspectorSliderRow`，右边的数值框能打字）、「Shows for」、**Transform 区的关键帧 ‹ ◇ › 和「曲线」菜单** | [Inspector 数值框合同](docs/architecture/inspector-scrub-number-field.md)（滑杆行的数值框：打字提交要立刻 `endLiveEdit`）、[关键帧动画](docs/architecture/keyframe-animation.md)「交互约定」（曲线菜单按播放头所在那一段） |
| 往检查器里加任何一行（标题 + 控件、下拉、滑杆行） | [检查器的排版](docs/architecture/inspector-layout.md)（固定窄栏，一行不许比它宽；菜单 Picker 不许 `.fixedSize()`）、[声音场景那一行把检查器撑宽](docs/bugfixes/2026-09-24-sound-scene-row-widens-inspector.md) |
| 定格、静帧、图片转视频、**在最后一帧里定格（不到一帧的右半）**、**透明 PNG（`StillAlphaNaming`、`isAlphaStill`、预乘的 ProRes 4444 + 遮罩）** | [定格长期约束](docs/architecture/freeze-frame.md)（第 4 节：不到一帧的右半拿掉；第 4a3 节：真用到了透明的图转预乘 ProRes 4444 + 灰度遮罩，预览垫黑底、导出先反预乘、带关键帧的 matte 用它自己的遮罩）、[透明 PNG 成了黑方块](docs/bugfixes/2026-10-03-png-transparency-lost.md)、[静帧后面剩一截](docs/bugfixes/2026-09-29-freeze-leaves-sliver-after-still.md)、[静帧自检的耗时断言在 CI 上误报](docs/bugfixes/2026-11-11-still-clip-encode-timing-flake.md)（4a2 节：对着时间的断言只和同一次运行里同一种活的对照比，能数的就数）、[定格方案](docs/plans/2026-08-08-freeze-frame.md)、[静帧逐帧解码事故](docs/bugfixes/2026-08-08-still-clip-decode-per-frame.md) |
| 原生录屏、恢复、退出、导入、**录屏的系统授权（`ScreenRecordingPermissions`、`ScreenCapturePermissionRepair`）**、**AI 录屏（`record_screen`；`ScreenRecordingSession` 的 AI 会话、`ScreenRecordingFileCommit`、`ScreenRecordingOptions.preset`、`AIScreenRecording*` / `AIScreenSource*`）** | [录屏生命周期](docs/architecture/screen-recording-lifecycle.md)（含产物合同；「AI 起的会话」：同一条流程、差别只在 `ScreenRecordingSession`，设置页 / 残缺框 / 系统选择窗口只给手动的会话，AI 起的从不覆盖、入轨包一步撤销）、[让 AI 录屏的方案](docs/plans/2026-10-03-screen-recording-mcp.md)（用户拍的板：AI 自己选来源、没授权弹一次、开录不问、一边录一边操作）、[录屏中 set_canvas 改帧率静默不改](docs/bugfixes/2026-10-03-set-canvas-fps-ignored-while-recording.md)、[签名与系统权限](docs/architecture/code-signing-and-permissions.md)（授权记录钉着签名；拨开关救不回钉着旧签名的记录，App 每个构建最多删一次自己的记录再请求；文案不写「关掉再打开」）、[开关开着还是说没权限](docs/bugfixes/2026-10-03-screen-recording-permission-stale-after-update.md)、[实施报告](docs/reports/2026-08-06-native-screen-recording-implementation-report.md)、[Phase 2–4 复审](docs/bugfixes/2026-08-07-screen-recording-phase2-4-review.md)、[静止期尾部黑屏](docs/bugfixes/2026-08-11-screen-recording-idle-tail-black.md)；方案中的旧结论不得覆盖实施报告 |
| 字幕生成、语言检测、翻译、任务取消、**转写哪些声音（可听快照）**、**生成 / 翻译结束时回写工程** | [字幕语言流](docs/architecture/subtitle-language-flow.md)（第 7 条：可听快照与预览同一份隐藏过滤）、[回写要自己成一步撤销](docs/bugfixes/2026-09-27-ai-undo-swallowed-by-subtitle-attach.md)（包在 `AIUndoGrouping.step` 里）、[原生字幕生成方案](docs/plans/2026-08-06-native-subtitle-generation.md)、[字幕生成复审](docs/bugfixes/2026-08-06-subtitle-generation-review.md)、[PR #22 后续复审](docs/bugfixes/2026-08-09-pr22-review-followups.md)、[藏起来的片段照样被转写](docs/bugfixes/2026-09-26-subtitle-generation-transcribes-hidden-clips.md)、[自动检测拿音效当探针](docs/bugfixes/2026-09-26-auto-detect-probes-sound-effects.md)（探针长的先、先听有没有人声） |
| 生成出来的字幕长什么样：**去标点**、**断句**（逗号拆小句、太短的并、并不进去整句一起挑、放不下的怎么切、中文按词边界）、**一行多长**（字数 + 画面宽度）、**几行**（默认单行；生成面板的「每条字幕的行数」/ AI 的 `max_lines` 跟着工程走）、**显示时间**（最短、2 帧间隔、接上、说完多停）、**几段素材同时有字只留一条**、面板上「只用选中的片段」、机器翻译落字去标点、AI 点名 `strip_punctuation` 整轨去标点 | [生成的字幕长什么样](docs/architecture/subtitle-generation-style.md)（先断句后去标点、时间在整条轨上排；**停顿被识别器并进相邻的词，先估开口**；切法是动态规划不是贪心；**默认单行（2026-10-16 用户定）、两行时折行点两行差不多宽 + 断在好断的地方 + 中文不切词**；中文按整句判语言；去重叠只比不同素材）、[停顿被算进相邻的词](docs/bugfixes/2026-09-26-pause-stretches-next-word.md)、[切出 0.1 秒的一条](docs/bugfixes/2026-09-30-subtitle-piece-on-screen-0.1s.md)（太短按能留多久罚、并不进去整句一起挑）、[方案与调研](docs/plans/2026-09-26-subtitle-generation-style.md)（别的剪辑软件怎么做、Netflix / BBC 的数字、用户逐条拍的板） |
| 字幕轨、眼睛、预览叠层、烧录、布局、**预览上字幕画多大（按 libass 的字号口径）**、**行距（`BurnInStyle.lineSpacing`：预览的行间距、AI 的框、烧录垫的空行同一个数，只能加大）**、**在哪儿折行（预览、AI 的框、成片同一份：`SubtitleLineWrap` 没有中日文的段照 libass 的摊匀算；有中日文的段只在词和词之间断、挑行是 `SubtitleCJKRows`、断在哪好是 SrtFlowCore 的 `SubtitleRowBreaks`、词边界是 `SubtitleCJKWords`（生成字幕切条同一份）；烧录把折行点写成 `\N` 不让 libass 自己折）**、选择（点选互斥 / 框选混选 / ⌘A 全选 / ⌘⇧A 取消 / 滤镜多选）、字幕的三个编辑入口、**工程自己的字幕样式（`subtitleStyle(appWide:)`）与逐词高亮（词的时间、预览和烧录同一份）**、**原文 / 译文两条独立轨**（挪裁删拆互不影响、译文的来源表、两个翻译按钮、画面上叠在一起 / 分开摆、按时间切块）、预览上字幕块量高度、**AI 读每句的框（`SubtitleLineBoxes` / `AISubtitleBoxes`：和拖框、字号比例、行高同一份合同）** | [字幕轨可见性与布局](docs/architecture/subtitle-track-visibility-and-layout.md)（第 3 条：两条轨独立、来源表现算过期；布局 2：译文布局为 nil = 叠在原文下面、量块高不许被默认值盖掉；「工程自己的样式与逐词高亮」：用样式只问 `subtitleStyle(appWide:)`、只有带词时间的句子亮、词的时间跟着编辑走）、[成片比预览小](docs/bugfixes/2026-09-29-subtitle-preview-bigger-than-burn.md)（预览只用 `BurnInSubtitleOverlay` 画，按实际画字的那一款字体乘 `SubtitleFontScale`）、[预览的位置和行距和成片对不上](docs/bugfixes/2026-09-29-subtitle-preview-line-box-differs-from-libass.md)（行框也按 libass 的摆：`SubtitleLineMetrics`，一行一个 Text 放 VStack、负行距要靠它、整块按对齐挪一点只动画面）、[预览的折行是贪心的、成片是摊匀的](docs/bugfixes/2026-10-15-subtitle-preview-wraps-greedily.md)（折行点只有 `SubtitleLineWrap` 一份：照 libass 的 WrapStyle 0 port，预览一行一个 Text 只画算好的那一行、AI 的框也问它）、[没有空格的长中文字幕成片整行溢出](docs/bugfixes/2026-10-15-chinese-subtitles-overflow-without-spaces.md)（libass 只在空格处折：烧录照 `SubtitleLineWrap` 写 `\N`、WrapStyle 2，中日文在字之间折、标点避头尾，韩文只在空格处；可用宽度只在 `SubtitleLineWrap.usableWidth` 算）、[字幕自动折行把中文的词拆开](docs/bugfixes/2026-10-18-subtitle-wrap-splits-chinese-words.md)（中日文只在词和词之间断，句中空格和标点后面优先、助词不起头、名字和「5分钟」不拆；别回到任意两个字之间都能断）、[没下载苹方时中文烧成方框](docs/bugfixes/2026-09-29-chinese-burns-as-boxes-without-pingfang.md)（回退到系统私有字体时预览和烧录一起换内置字体，烧录用 `\fn` 点名）、[圆体烧录英文变「f=」](docs/bugfixes/2026-09-29-yuanti-cmap-breaks-libass-latin.md)（字幕字体清单扫描要过 cmap 体检，坏的不进清单）、[叠在一起时点英文落到中文](docs/bugfixes/2026-09-26-stacked-subtitle-frame-lands-on-translation.md)、[拖动手势 §3.5b](docs/architecture/timeline-drag-gestures.md)、[两条独立轨的方案](docs/plans/2026-09-26-hide-guides-independent-subtitles.md) |
| 标记（所有块 + 标尺：锚在宿主自己的时间轴上、裁头不挪、M 的落点只有一份、点标尺 = 选中标尺）、时间线块 overlay、扫帧 peek | [标记](docs/architecture/clip-markers.md)（单击只选中、双击才弹面板：点一下就弹带输入框的面板 = 交出键盘；第十一节：标尺选中着 M 才打标尺、不算有东西可删）、[悬停影子播放头](docs/bugfixes/2026-08-08-hover-ghost-playhead-and-delete-key.md)、[标记 ⌫ 删不掉](docs/bugfixes/2026-09-24-marker-delete-key-eaten-by-note-field.md) |
| 音频库（音乐 / 音效两个 store、面板的分段、`AudioLibraryLookup` 两个库一起找）、manifest（`hit` / `title_zh` / `owned`）、试听、素材缓存、署名（只问 `needsCredit`）、**音效（合成器 + 录音素材库）** | [音频库](docs/plans/2026-09-22-audio-library.md)、[音效方案](docs/plans/2026-09-30-sound-effects.md)、[音频库素材管线](docs/build/audio-library-pipeline.md)、[素材管线](docs/build/audio-library-pipeline.md)、[声音：音量与渐入渐出](docs/architecture/audio-fades.md)（ducking 的夹紧点）、[AI 接口](docs/architecture/ai-control-mcp.md) §4 第 23 条（AI 搜音乐、放上时间线、署名句，和界面同一个搜索函数、同一个署名口径） |
| 导出面板、编码设置、分辨率档位（压缩 / 烧录 / 剪辑导出）、导出文件名与撞名（面板上先问再替换；批量转换、压缩 / 烧录、AI 的输出加编号，`ExportFileName.unoccupied`）、**字幕文件名里的语言标签（`SubtitleFileLanguage`：按文字判 → 记的 → 省略，面板和 AI 同一份）**、**压缩 / 烧录记住的设置和全 App 的字幕样式** | [导出设置](docs/architecture/export-settings.md)（面板上只放管线真消费的设置；记住的设置在队列创建时读回来，不挂在页面的 `onAppear` 上）、[没记语言的轨导出的文件名不带标签](docs/bugfixes/2026-10-15-subtitle-file-export-missing-language-tag.md)、[字幕样式要先去烧录页转一圈](docs/bugfixes/2026-09-27-remembered-subtitle-style-waits-for-burn-in-page.md)、[导出面板改版方案](docs/plans/2026-09-24-export-panel.md)、[竖屏被缩小](docs/bugfixes/2026-09-24-resolution-cap-shrinks-portrait-video.md)、[音频原样复制是假话](docs/bugfixes/2026-09-24-export-panel-promised-audio-copy.md) |
| **导出水印**（`Sources/SrtFlow/Watermark/`：logo 读成路径、画成 PNG、跳的表、进滤镜图；`WatermarkPolicy` 加不加；导出图里水印的落点；`Resources/watermark-logo.svg`；`SeededRandom`） | [导出水印](docs/architecture/export-watermark.md)（只加在剪辑导出的成片上；加不加只问 `WatermarkPolicy`（授权那一半只从 `SkyStudioAccount.exportsWithWatermark` 来，要加却读不出 logo 就不导）、只有导出器调 `plan()`；烧字幕之后、缩小之前；整段两个 overlay、平衡的分段树，不许一段一个 overlay；logo 只认 M / L / Z、读不全回 nil） |
| 读用户给的文本文件（字幕文件、讲稿、笔记）的编码 | [用户文本文件的编码](docs/architecture/text-file-encoding.md)（只走 SrtFlowCore 的 `TextDecoding`；UTF-16 不许无条件排在 GBK 前面）、[GBK 字幕读成乱码](docs/bugfixes/2026-09-27-gbk-subtitles-read-as-utf16.md) |
| 任何按钮的提示文案、快捷键、hover | [即时提示](docs/architecture/instant-tooltips.md)（第五节第 6 条：面板的浅 / 深按主题自己设；第 7 条：宿主的根在 `.appLanguage()` 外面裁成气泡的形状，不然森林色的底色铺成一圈直角方框） |
| 预览性能、性能计数与基线；**新写或改写任何 SwiftUI 视图 / 修饰器 / `NSViewRepresentable` / Canvas**（body 第一行要计数，写完跑 `checks/preview-perf-wiring.sh --fix` 自动补）；性能那一步红了但没动编辑器界面；**往时间线上加一种块 / 行里的列表项**；**任何要跟着播放头变的界面**（订阅播放器时钟、在 body 里读 `clock.time`、按钮能不能点看播放头）；**在视图 body 里读工程的属性、给 `VideoEditProject` 加属性**（工程是 `@Observable`） | [预览性能 ratchet](docs/architecture/preview-perf-ratchet.md)（计数必须接满、只许降、**已知的偶发误报怎么认、怎么重跑**、什么时候能重定基线、**时间线上的块不读工程、按值比较 + `.equatable()`（List 里会产出几行的视图不许套）**、**第十二节：订阅时钟的只许是名单里的小视图，停着才有意义的读 `PacedPlayhead`**、**第十三节：body 读了什么就只被什么叫醒，大视图少读、不驱动界面的存储 `@ObservationIgnored`、读不可观察的东西要自己找叫醒的来源**）、[预览性能 ratchet 方案](docs/plans/2026-09-24-preview-perf-ratchet.md)、[每个块都订阅着整个工程](docs/bugfixes/2026-09-24-timeline-blocks-observe-whole-project.md)、[播放时每一跳叫醒整个编辑器](docs/bugfixes/2026-09-25-playback-wakes-whole-editor.md)、[播放丝滑方案](docs/plans/2026-09-25-smooth-playback.md)、[点一下选中一段整个编辑器跟着重算](docs/bugfixes/2026-09-26-selection-wakes-whole-editor.md) |
| **AI 的一次工具调用、AI 起的长任务从哪开始到哪结束**（`AIToolRouter.handle`、`AIJobs.start` / `finish`）、**App Nap / 活动断言**（`AIKeepAwake`、`ProcessInfo.beginActivity`）、新写一种在后台跑的 AI 活 | [AI 接口（MCP）](docs/architecture/ai-control-mcp.md)第四节第 59 条（AI 的调用和任务各领一份不降速的、领和还成对；新的长任务走 `AIJobs.start` / `finish`；活动断言只在 `AIKeepAwake` 和录屏）、[App Nap 降速的案例](docs/bugfixes/2026-11-10-ai-work-throttled-by-app-nap.md)（量的时候 App 要真看不见、量等的那一段） |
| 主线程卡顿（播放中按键慢半拍）、心跳看门狗 `MainThreadWatchdog`（含 AI「探一下」读的 `unresponsiveSeconds`）、卡顿日志、冒烟结果里的 `stalls`、**挂起主线程抓栈（`MainThreadStackCapture`）** | [主线程卡顿日志](docs/testing/main-thread-stalls.md)（默认开着、栈是超过阈值那一刻抓的一次快照、卡顿次数不进性能 ratchet 的账；日志突然断了 = 看门狗自己也可能卡住）、[挂起主线程抓栈](docs/architecture/main-thread-stack-capture.md)（挂起期间只做系统调用和裸读写：不分配、不拿锁、不碰要现场取元数据的类型；挂起和恢复只在 `walkWhileSuspended`）、[导出两次卡死](docs/bugfixes/2026-10-06-watchdog-capture-deadlocks-main-thread.md)、[预览性能 ratchet](docs/architecture/preview-perf-ratchet.md) |
| 任何界面文案、翻译、字符串表、应用内语言切换、**加一种界面语言（`<code>.lproj` + `AppLanguage` 一个 case，别处不改）**，新加 sheet / popover / 自建宿主视图 | [本地化](docs/architecture/localization.md)（第三节第 3 条：sheet / popover 不继承应用内语言；第五节：加一种语言）、[界面语言方案](docs/plans/2026-09-30-ui-languages.md)（先西班牙语、译文不审直接算正式、不标 Beta）、[sheet 全是英文](docs/bugfixes/2026-09-24-sheets-ignore-in-app-language.md)、[守卫不扫 LabeledContent](docs/bugfixes/2026-09-24-labeledcontent-missing-from-localization-guard.md) |
| AI 接口（MCP）：给 AI 的工具清单与说明、**说明书 `skycut_guide`（按需读的工具说明：目录、每个工具一个同名主题、分节）**、**剪辑风格（预设风格与用户存的，工具 recipes / save_recipe）**、**配旁白（add_voiceover：Sky Studio 的预设声音（不点名 gemini:Charon、角色读 `voice_roles`、先整段报价再回任务号，`SkyStudioVoiceoverStart`；名片 + 说明书主题和试点的五个同一张表 `MCPGuideWrittenTopics`；**声音库的声音 `voice_…` 读稿不退本机、要先建 MiniMax 版时问 / `skip_one_time` / 点头起 `voice_enroll`**）、**声音库 `list_voices` / `manage_voices`（列、用录音建声音先问授权、设计先问一次性费用、改名、删除按模式；都只经 `SkyStudioJobGate`）**、SrtFlow 自己的声音 Kokoro、没下载时 macOS 的声音）、`Sources/SrtFlowKokoro/` 这个模块、模型的下载与 R2 上的那一份**、`skycut-mcp` 小程序、小程序与 App 的通道、AI 改时间线的规则、「看得见」（一轮开始时摆出剪辑页、每步定位）、这一轮 / 停止 / 撤销这一轮、需要用户点头的事、设置里的「连接 AI」、**AI 的手和眼**（`edit_clip` 的铺满 / 完整显示 / 裁切 / 位置大小、去黑边、对准主体、`look` 看、`listen` 听、**`listen cuts=true` 一次查 V1 每个剪辑点在不在停顿里、切到哪个词**；`edit_subtitles` 的批量改字 `replace` / `strip_punctuation`；`get_subtitles` 每句的 `box`、`look text_scan` 的 `subtitle_overlaps` 撞水印）、**AI 的眼睛（第 4 块：分镜头 `look shots`、一次看几个文件 `look files`、铺满跟拍 `follow`；第 5 块：扫画面里的字 `look text_scan`、按字取景 `focus=text`）**、**AI 够得着的现有功能**（后台模式、读文稿、整理文件、访达选中、推子关键帧、形状、复制、定格、音乐库、压缩 / 烧录 / 转字幕、**录屏 `record_screen`**、**导出字幕文件 `export_subtitles`**） | [MCP 说明书](docs/architecture/mcp-guide.md)（App 照 recipes 的路子答、没开通也照答、只有它预先加载；目录 ≤ 5,000、一次 ≤ 6,000、长的分节（第一次回列出每一节讲什么、叫它只读要用的）；改短名片之前先把说明原样搬进主题；名片 ≤ 450 且写按性质的固定说法、参数说明 ≤ 120 且写范围、参数定义 ≤ 4,500 字节（2026-11-10 迁移完起对全部工具，例外 edit_clip、generate_media）、fields 太长自动切节；迁移做到哪看它的「现在做到哪」）、[MCP 按需说明方案](docs/plans/2026-11-09-mcp-guide.md)（第八节 8 条用户已定、七个 PR）、[AI 接口（MCP）](docs/architecture/ai-control-mcp.md)（**第四节第 54 条：批量编辑 edit_clips / set_texts / set_shapes，整批先验、一次提交 / 撤销，单项规则共用，异步准备后拒绝旧快照**；**第四节第 52 条：参数名按说明核对，说明上没有的名字整个调用不做；实现里认、说明上没写的别名要登记进 `MCPArgumentCheck.aliases`**；**第三节「App 卡住的时候」：小程序每 15 秒探一下、App 在收发线程上答、卡 30 秒放弃并让 App 也放弃、还卡着不再发；第四节第 4 条：菜单建好就交出打开主窗口的动作、后台开回来放最后面**；**第四节第 46 条：一个会话一组工程 —— 碰工程的工具收可选的 `project`（短 id p1、p2…；不带 = 这个会话最后打开的，子代理要一直带）、小程序记着会话的一组工程、每个请求带上；App 排到调用之后、摆窗口之前定落在哪个（`AIProjectTargeting`），别的会话的一律不做并说清楚、安静 5 分钟算放手；按工程排队；每个调用的文件夹走 `AICallContext`；`close_project`、最多开 8 个；这一轮 / 停止 / 撤销这一轮每个工程一份（`AIRound`），停止只停那个工程；同一个文件夹出几个版本时文件名带 `version`、第二个工程不给就拒**；**第四节第 45 条：录屏 —— AI 自己选来源、从不开系统选择窗口，没授权一次运行只请求一次，start 等真开录才回来，录制中不摆窗口，入轨包一步撤销，从不覆盖，丢弃先问进废纸篓**；**第一节第 6 条：总说明是入口 + 主动规矩、≤ 1,200（工具目录 2026-11-09 用户定搬进说明书地图，每个工具都列在地图上）、每个工具的名片 ≤ 450（2026-11-10 迁移完起对全部工具）、Codex 要前 512 字自成一体，只用英文；往总说明里加东西先问是不是要 AI 主动做；全清单 ≤ 100,000（带外壳的 UTF-16，上限和量法只在 `checks/MCP/CatalogBudget.swift`；2026-10-02 从 72,000 抬到 80,000、10-14 到 90,000、10-17 到 100,000、11-07 到 110,000，2026-11-10 迁移完收回 100,000，都是用户定的；以后加工具先把说明挪进说明书，不再为说明文字抬上限）**；第四节 14–24 条逐个工具写着复用了哪条手动的路；读点名文件夹以外的文件都走 `AIWorkspace.confirmReading`；压缩 / 烧录排进现成的队列、条目自带设置、不替用户开跑、三个文件工具的 `folder` 可指定放哪；清单只有一份、两代协议都接、一个工具 = 一步撤销且每个改动工具包一层 `AIUndoGrouping.step`（别去关按事件自动开的组；要 await 的先 plan 再同步 apply）、不许弹模态框、只有删文件、读别处的文件、fal 花钱超了额度才问（别处的文件问一次、记住文件夹；撞名加编号；确认码三十分钟、同一件事等答复时回同一张、拒绝说原因；「连接」顺带放行客户端那层；工具不按个数卡、说明总长度有上限）、阻塞收发只在自己开的线程上；第四节 11–13 条：铺满是一扇窗映满画布、先裁切再摆放；29–31 条：镜头切点学 PySceneDetect、长视频走任务、跟拍只跟人且换镜头跳过去、裁切不能做关键帧所以只动摆放框中心，look 按预览的层序合成、每层调现成的那份，listen 读波形那一份、窗和均方桶对齐）、[预览自由变换](docs/architecture/preview-free-transform.md)（裁切和摆放的模型）、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md)（Vision 的 perform 在 `MediaReadQueue.analysis` 上跑）、[波形与深度缩放](docs/architecture/audio-waveform.md)（均方和峰值同一遍读）、[AI 的改动撤一步全空了](docs/bugfixes/2026-09-27-ai-edits-share-one-undo-group.md)、[挂字幕落在 step 外面，之后撤一步全空](docs/bugfixes/2026-09-27-ai-undo-swallowed-by-subtitle-attach.md)（一次调用里所有登记都在同一个 step 里；异步落账各包一层）、[AI 翻译按旧的原文语言去翻](docs/bugfixes/2026-09-27-ai-translation-stale-source-language.md)（要人动手就走 `waiting_for_user` + 提示条）、[叫 AI 去面板里选语言](docs/bugfixes/2026-09-29-ai-told-to-pick-language-in-panel.md)（界面的报错叫人去点哪儿的，AI 那一路换成它能照做的话）、[婚礼工程之后的五处工具小毛病](docs/bugfixes/2026-09-29-mcp-tool-followups-from-wedding-session.md)（字面 `\n`、切工程只取消绑工程的转写、look 无效合成要报错、整批拒绝要说清、结果带工程名listen 和 cut_to_beat 的拍子不一致](docs/bugfixes/2026-09-29-beat-analysis-window-differs-between-listen-and-cut-to-beat.md)（鼓点按整首歌分析一次、各自取用）、[字幕带把幻灯片标签也框进去](docs/bugfixes/2026-09-29-text-scan-band-swallows-slide-labels.md)（字幕带只量底边同一条线的那一堆；选哪一堆见下下条）、[裁切量被幻灯片标题拉大](docs/bugfixes/2026-09-29-text-scan-crop-hint-stretched-by-slide-title.md)（字幕的上一行要每句都换才认；提示写明裁的是整条带、裁完抽帧看）、[贴底被切掉的字混进字幕行、字幕稀疏时选成幻灯片](docs/bugfixes/2026-09-29-text-scan-cutoff-text-and-sparse-subtitles.md)（贴着画面底边的薄片不算字幕行；字幕是够多的几堆里**最下面**的一堆，不是「不同的字最多」的那堆 —— 数量在字幕稀疏时不可靠）、[总说明和 edit_clip 的说明被截在 2,048 字](docs/bugfixes/2026-09-30-mcp-text-truncated-at-2048.md)（量模型真正读到的那一份；规矩按「主动 / 某个工具 / 某个结果」分三层放）、[MCP 方案](docs/plans/2026-09-27-mcp.md)、[配方卡中文稿](docs/plans/2026-09-28-mcp-recipes.md)（改套路先改它、再同步 App 资源里的英文卡）、[剪辑美感方案](docs/plans/2026-10-05-editing-aesthetics.md)（卡是导演手册：每张卡有标杆 / 品味 / 别这样，共用规矩里有先出分镜表、品味、AI 剪片的通病、交片前再看一遍、从参考片学风格，`RecipeChecks` 钉着；参考片只量用户给的文件、不从网上下）、[风格卡给竖屏的字号大了](docs/bugfixes/2026-09-29-recipe-sizes-too-big-on-vertical.md)（字号按画面高度算，卡里写明画幅） |
| **MCP 参数范围 / requested、applied / 静默限幅 / 素材尺寸加载重试 / 单项与批量原子提交** | [MCP 编辑参数合同](docs/architecture/mcp-edit-parameters.md)（范围来自生产代码、越界给合法建议、限幅回实际值、成功后才开撤销组） |
| **合成音效**（`Sources/SrtFlow/SoundEffects/`、`add_clips` 的 `sound_effect` / `hit_at`、`AISoundEffectRequest` / `AISoundEffectTool`）、改任何预设的声音、合成器的响度或落点 | [合成音效](docs/architecture/sound-effect-synth.md)（落点是合同、混响按峰值比例、两道电平、同参数同文件且改声音要 +1 version 并再给用户听、默认都短、写文件只经一处）、[音效方案](docs/plans/2026-09-30-sound-effects.md)（三轮试听怎么定的）、[AI 接口（MCP）](docs/architecture/ai-control-mcp.md) 第四节第 43 条、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md) |
| 云端媒体共用的阶段 / 状态行 / 传输 / 每日账（`Sources/SrtFlow/CloudMedia/`），生成、upscale、旁白、克隆，**声音的接口合同（预设声音、角色、声音库、voice_plan、一次性费用、变声的 DTO 和请求）**，**同时开着几个任务（`SkyStudioJobSlots`：声音池 / 共用池）、一段旁白的几批怎么同时交（`SkyStudioVoiceBatchQueue`）、中途换备用** | [Sky Studio 的任务](docs/architecture/sky-studio-jobs.md)（**第一节「领槽」：交之前在本机按池领槽，和服务器一样分（声音的六种进声音池、槽数照 /me、读不到声音池都进共用池），只 GET 的恢复不领、429 照旧兜底；第五节「几批同时交」：各批按顺序领槽同时交、回来的顺序不管、切句和落地照原来的顺序，一批出了事后面没交的不再交、先记下再还槽；中途换了备用后面的批带 `voice_plan.fallback.selection`、结果带 `line_models`；`fallback_needs_one_time` 可恢复、get_job 问那笔一次性费用（声音 PR 6 `SkyStudioVoiceFallbackFee`：resume + 令牌建 MiniMax 版、`skip_one_time` 照原来的模型重试）**；**第十四节：声音 PR 1 只有纯值和 `SkyStudioAPI` 的请求，PR 3 把 add_voiceover 的读稿接上（第五节）；整段报价带 `params.batches`、每批 `params.plan` 原样带回（点名时 `plan.model` 就是点名的那个）、和钱有关的读得严；只认 `voice_…`、服务商 id 不进 SkyCut；429 的 `pool`；目录快照原样拷自 Sky Studio 的导出（那边目录改了就重新拷）**；**第十三节：Sky Studio 角色 list_characters / get_character / manage_characters；服务器引用 / revision / 实际模式，原生角色能力目录、六种库写入、稳定任务号 / 持久回执 / 原单恢复，换账号清缓存和待确认**；**第十二节：图片 camera_angle / upscale 的单图、类型化移动 / 倍率、确认身份与按实际字节落盘；和视频 upscale_clip 分开**；**第五节「本机切句」：付过钱的声音不许在本机卡死 —— 对字不计较繁简、转写语言带字形（`AITextLanguage.speechLanguage`）、一句的几片采样率不一样换成一样的再接（`SkyStudioVoiceLineAudio`）、转写不了的 Mac 上切不开就按字数估句界并报出来（`SkyStudioVoiceSplitEstimate`）；分批的上限按每句自己的文字**；**第五节：旁白先认声音（`SkyStudioVoicePick`）、整段报价、整体预留，再回任务号；退本机只在付费请求之前；每批带同一个 `params.plan`；每批原音频 / 段落映射 / 进度持久保留（恢复记录 version 2，只认 2）；`add_voiceover resume` 默认只恢复已有结果，`generate_missing` 只补明确未生成批次、照记录的选择再报价，稳定 UUID / 回执防止重复入轨**；全部收费活只走 Sky Studio；共用组件用 Cloud / DailySpend 命名，旧 fal 运行路径已删除）；[fal.ai 生成](docs/architecture/fal-generation.md)仅供历史复盘 |
| **声音库的工具**（`list_voices` / `manage_voices`：`SkyStudioVoiceLibraryTool` / `SkyStudioVoiceRecordingTool` / `SkyStudioVoiceDesignTool`；授权 / 一次性费用 / 删除的令牌和问句 `SkyStudioVoiceApproval`、`SkyStudioJobGate` 的声音那三样；`voice_library_unavailable`）、**声音库的收费单跨 SkyCut 重启**（`SkyStudioVoiceLibraryOrders`：在建的设计 / 建 MiniMax 版落盘、重启后接着跟、受理时并单；`SkyStudioVoiceLibraryJob.follow`）、**全部权限下的长期授权**（`SkyStudioVoiceStanding`：声音那几件事 `.ask` / `.standing` / `.once`、`/voices/consent-grant` 的记 / 撤、升级时补记；`SkyStudioVoiceStandingNotice` 那段说明）、**克隆的参考录音**（`VoiceReferenceSample` / `VoiceReferenceWindow` / `VoiceReferenceReader`：44.1 kHz 单声道 16-bit、10 秒有效人声到 3 分钟、超过自动挑一段、有效人声怎么数、上传用途 `voice_reference`；`add_voiceover` 的 `clone_from` 2026-11-10 已去掉） | [声音库](docs/architecture/voice-library.md)（规格和 Sky Studio 3.4 同一个口径；有效人声 = 20 ms 一格、均方根 ≥ 0.0056 的整格（≈ −45.04 dBFS，和服务器的合同、服务器放宽到 0.0055；常量 `speechRMSFloor` 单独写死、不借配音响度的 `AIVoiceLevel`），只在 `VoiceReferenceWindow` 数，写好的 16-bit 采样再数一遍、以它为准；浮点源的 NaN / ±Inf 记 0、不许崩；参考录音在报价之前做好，人声不够当场拒；挑段：人声最多 → 前 15 秒更密 → 早，切在 ≥ 0.2 秒的停顿里、离两头 40 ms；读只在 `MediaReadQueue.analysis`，不许再用字幕生成那个 16 kHz 的 `AudioWindowReader`；旧的 `clone_from` 过渡期哪个服务器都走不通，声音 PR 3 删了，生产入口等声音 PR 6 的 manage_voices）、[参考录音被降到 16 kHz](docs/bugfixes/2026-11-10-voice-reference-16khz-short-sample.md)、[Sky Studio 的任务](docs/architecture/sky-studio-jobs.md) 第五节、[声音库](docs/architecture/voice-library.md)第十节（**设计 / 建 MiniMax 版的任务 `SkyStudioVoiceLibraryJob` 按 `identity` 只开一单、过闸之前先看在建的；费用的问题受理后才清；`consent_outdated` 刷新目录再问；第 11 条：在建的单交之前落盘（`SkyStudioVoiceLibraryOrders`），读到 Key / 看「已经在建」之前 / 任务起手都先 `resume`、只 GET 跟到底、按原来那一笔结，先删记录再改账，交的回答丢了的那一单在受理时并进来**）、[声音库审查的后续](docs/bugfixes/2026-11-11-voice-library-review-followups.md)、[重启之后不记得在建的那一单](docs/bugfixes/2026-11-11-voice-library-job-after-restart.md) |
| **声音库的界面**（`Sources/SrtFlow/VoiceLibrary/`：设置 → 剪辑与声音的「声音库」一节 `VoiceLibrarySettingsSection` / `VoiceLibraryStore`、声音选择器 `VoicePickerView` / `VoicePickerRows`（变声面板也用它）、新建声音 / 加录音 `NewVoiceSheet` / `NewVoiceModel` / `NewVoiceGate`、现在录 `VoiceSampleRecorder`、录音的语言 `VoiceSampleLanguage` + `SpokenLanguageProbe`（**`manage_voices` 没给 `language` 时也用这一份：`SkyStudioVoiceRecordingLanguage`**）、设计声音 `DesignVoiceSheet` / `DesignVoiceModel`、试听 `VoiceAudition`、界面上的话 `VoiceLibraryText`；和 AI 的工具共用的 `SkyStudioVoiceRecordingSubmission` / `SkyStudioVoiceDeletion` / `SkyStudioVoiceDesignOrder` / `SkyStudioVoiceLibraryErrors.kind`；麦克风的用途说明） | [声音库](docs/architecture/voice-library.md)第九节（**界面和 AI 的工具同一条路**：参考录音只经 `VoiceReferenceSample.prepare`、建 / 加 / 删的请求只从 `SkyStudioVoiceRecordingSubmission.swift` 发、设计只经 `SkyStudioVoiceDesignOrder`；**授权是对话框里的一勾，勾上了才造 `consent: true`**，认得的版本显示译文、没见过的版本显示服务器的英文原文；设计的按钮就是确认、照报价先过每日硬预算、改了字报价作废；语言检测不出来留空不许猜（AI 那一路：`manage_voices` 的 `language` 可选，给了照给的、不识别，不给就用同一份识别、识别成了什么写进问句和结果，识别不出来报 `language_undetected` 叫它带上 `language` 再调，第八节第 3 条）；声音库用不了时预设照常；试听的临时链接不存盘；视图不读工程、不订阅时钟；`"Language"` 是「界面语言」，录音的语言用专用的键）、[顶部工作台与统一设置](docs/architecture/workbench-and-settings.md)、[本地化](docs/architecture/localization.md)、[预览性能 ratchet](docs/architecture/preview-perf-ratchet.md)、[即时提示](docs/architecture/instant-tooltips.md)、[签名与系统权限](docs/architecture/code-signing-and-permissions.md)（麦克风）、[字幕语言流](docs/architecture/subtitle-language-flow.md)（语言检测的候选和裁决在 `SpokenLanguageProbe`，两边共用）、[离屏渲染的图](docs/reports/2026-11-10-voice-library-ui.md)、[声音库](docs/architecture/voice-library.md)第十节（**会花钱的按钮按下去就锁、同一件事只开一单、临时文件夹只在 `VoiceLibraryTemp` 起名、整份读录音只经 `SkyStudioVoiceRecordingSubmission.make`**）、[设计声音连按下了好几单](docs/bugfixes/2026-11-11-design-voice-ordered-twice.md) |
| **变声**（`Sources/SrtFlow/VoiceChange/`：AI 的 `change_voice`（`VoiceChangeTool`）、片段右键「换成我的声音…」和它的面板（`VoiceChangeActivity` / `VoiceChangePresenter` / `VoiceChangePanel` / `VoiceChangePanelModel`）、截声音 `VoiceChangeSource`、定语言和报价 `VoiceChangeOrder`、任务 `VoiceChangeJob`、落地的规则 `VoiceChangeLanding`、文件名 `VoiceChangeOutputName`；`voice_convert`、上传用途 `voice_convert_source`） | [声音库](docs/architecture/voice-library.md)第十一节（**两个入口同一条路**；能变的段、上限只读 `/models`；传单声道 16-bit WAV、最高 48 kHz，截声音在收费之前；`target_language` 只在知道语言且目标声音有这种参考时带；只判每日硬预算、不发确认码，结果不明不重交；**落地恰好一次 `perform`、包在 `AIUndoGrouping.step` 里**：原段静音不删、两条新音频轨、三段链接、曲线平移、长几毫秒只在时间线上裁；这一段没了 / 工程换了只留文件；块只往 Activity 写目标、面板的视图不读工程）、[联动](docs/architecture/timeline-linkage.md)、[Sky Studio 的任务](docs/architecture/sky-studio-jobs.md)、[AI 接口（MCP）](docs/architecture/ai-control-mcp.md) 第四节第 60 条、[阻塞的媒体读取](docs/architecture/blocking-media-reads.md)、[预览性能 ratchet](docs/architecture/preview-perf-ratchet.md)、[本地化](docs/architecture/localization.md)、[实测](docs/reports/2026-11-11-change-voice.md) |
| **视频 upscale**（2026-10-28 起送 Sky Studio：`Upscale/UpscaleTiers.swift` 档位 / 目标 / 上限从 `/models` 读、`UpscaleOffers` 面板问模型和 `/quote`、积分的账 `SkyStudioSpendStore`；**AI 的工具 `upscale_clip`**（`AIUpscaleTool` / `AIUpscaleNames`、`UpscaleJob.Approval`、做完直接换源、花积分经 `SkyStudioJobGate`）；**换源**：`EditClip.upscale` 记录（`VideoEditClipUpscaleRecord`）、`ClipSourceSwap` 平移 / 换回、`VideoEditMediaReferences` 原片配书签、`VideoEditProject+Upscale`；**任务**：`Sources/SrtFlow/Upscale/` 的范围 / 裁一段 / 封回原声 / 起名 / 流水线 / `UpscaleJob`；**界面**：检查器一节 `VideoEditInspector+Upscale`（检查器的一段 body，不是单独的视图）+ `UpscaleJobStatusView`、右键菜单与块角标（`VideoEditTimelineClipBlock`）、面板 `UpscalePanel`、对比窗口 `UpscaleCompareView` / `Stage` / `Playback`、`UpscalePresenter`） | [视频 upscale 方案](docs/plans/2026-10-02-video-upscale.md)（用户拍的 16 条板、分刀）、[Sky Studio 的任务](docs/architecture/sky-studio-jobs.md)（**扣多少只问 `/quote`、交任务时当 `max_credits`；只有排队中的能取消；积分每日上限默认 1,000；Key 只发给 Sky Studio**）、[smoke test 实测](docs/reports/2026-10-02-upscale-smoke-test.md)（fal 时代 19 条的账单、声音 / 帧数的坑）、[工程文件与素材重链接](docs/architecture/video-edit-project-file.md)「四之五」（换源 = 源时间整体平移、盖不住不换、原片配书签不进 mediaURLs、分割抄记录）、[视频 upscale](docs/architecture/video-upscale.md)（**范围带 1 秒余料按原片算、一次最长 30 秒放不下先少留余料、最高 30 fps、裁出来的只有画面、送上去之前探一遍那个文件当 `params.source`、成品的声音一律不要自己封回原片的、HEVC 点名 hvc1、文件放原片旁边撞名加编号、面板起的做完不替换、面板上的报价就是确认、做完按实收改账、没花出去的退回；第三节：界面只订阅 `UpscaleActivity`、块不做 IO、对比窗口两个播放器同一个主机时间起步不读 currentTime；进度（阶段、上传 / 下载的字节比例、处理了多久 + 这一档通常几分钟）检查器那一节和工具栏任务浮层同一份；第五节：AI 起的和面板同一份数、花积分经 `SkyStudioJobGate`、Key 不弹授权框、做完直接换源且那一下自己包 `AIUndoGrouping.step`**）、[AI 接口（MCP）](docs/architecture/ai-control-mcp.md) 第四节第 44 条、[检查器的排版](docs/architecture/inspector-layout.md)、[本地化](docs/architecture/localization.md) |
| **收费与授权**：体验 / 正式版、服务器下发的开关（MCP 能不能用、导出加不加水印）、**照授权拦（AI 调用的门 `SkyStudioAccount.aiRefusal`、导出面板「会带水印」那一行、`SkyCutGates`）**、**导出水印**、Sky Studio 的 key 与 `api/skycut/v1`、生成 / upscale / 克隆从 fal 改走 Sky Studio、删掉自带 fal Key 那条路 | [收费方案](docs/plans/2026-10-27-paid-plans-and-sky-studio-key.md)（2026-10-26 / 27 拍的 20 条板和七刀；前五刀已合，其中 5b 照授权拦合进去时先关着，**2026-10-28 接口上线、用户给自己开了正式版之后打开**（`SkyCutGates.enforcedByDefault = true`；发带它的正式版之前用户要先在正式版里粘一次 Key），第 6、7 刀照 Sky Studio main 5c8d6a0d 冻结的合同做，做到哪看合进 main 的 PR；先做 B 端，C 端先只放「联系开通」；开关由服务器下发、SkyCut 不写死天数和规则；MCP 的门槛在 App 收工具调用的地方、不在小程序里；水印只加在导出的成片上；upscale 和 Sky Studio 网页同一套上限：一次最长 30 秒（余料算在里面）、最高 30 fps，从 `/models` 读；「Sky Studio 定稿之后」一节是第 6 刀要跟着改的；接口合同在 Sky Studio 仓库的 `docs/agents/skycut-api.md`）、[Sky Studio 账号](docs/architecture/sky-studio-account.md)（Key 存钥匙串 `<bundle id>.skystudio`、和 fal 共用 `KeychainSecret`；只有 `SkyStudioAPI` 碰地址；机器号是硬件 UUID 的哈希、盐永远不改；后台问 `/me` 从不弹钥匙串框；没有 Key / 没问到过 / 过了 `valid_until` 按免费版，服务器的钟换成本机的；照授权拦：AI 的门在 `AIToolRouter` 核对参数名之后、建调用排队之前，`get_status` 照常回并报 `skycut_plan`，还没问完先问一次再判，规矩和给 AI 的话在纯值的 `SkyCutGates`）、[Sky Studio 的任务](docs/architecture/sky-studio-jobs.md)（第 6 刀：模型、价、上限从 `/models` 来，扣多少只问 `/quote` 并当 `max_credits`；交任务和取消只经 `SkyStudioJobRun`：满了等着用同一个 idempotency_key 再交、交的请求不跟着取消、照 `poll_after_seconds` 问、只有排队中的能取消；成品永久在作品库、SkyCut 照旧下到本机；Key 只发给 Sky Studio）、[真 Codex 冒烟](docs/reports/2026-10-26-codex-client-smoke.md)、[导出水印](docs/architecture/export-watermark.md)（加不加只问 `WatermarkPolicy`，授权那一半照服务器的 `watermark`；照授权拦 2026-10-28 起打开） |
| 真实窗口、系统权限、手势实测 | [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) |
| 官方原创短片、`generate_media` 的 `film`、镜头状态 / 完成动作 / 声音计划、实际引用与报价 pin、左右接缝审查 | [官方原创短片](docs/architecture/official-film.md)（公开状态与服务端私有配方分开；真实引用报价、双侧审查、完成历史不能重演；客户端 / 生产启用 / 真实输出 / 并发验收分开报告）、[Sky Studio 的任务](docs/architecture/sky-studio-jobs.md)、[开着的工程](docs/architecture/open-projects.md) |

## 构建与检查入口

- 官网样式表的先后（构建按共用关系分块，覆盖规则不许排在基础规则前面）：`website/tests/css-cascade.test.mjs`（源码级）和 `npm run check:seo`（按每个构建出来的页面实际加载的样式块核对），都在 CI 的网站那一步里。

- 官网的小字（手机上不小于 12 px、演示区对比度、标题层级、首屏不随字体挪动、演示打字时对话窗不变高）：`website/tests/legibility.test.mjs` 在 CI 的网站那一步里；浏览器里量的那一半 `npx -y -p playwright@1.65.0 node scripts/check-legibility-browsers.mjs` 是手动的（无头、只在 Mac 上，**不在 `check-all.sh` 里**），见 [SkyCut 官网](docs/architecture/skycut-website.md)「小字读得清」。

- 官网首屏的静图与浏览器检查（在 `website/`）：改了场景外观后 `npm run build:hero-still` 重烤（无头 Chromium + Pillow），`tests/hero-scene.test.mjs` 的指纹钉着「改了没重烤」；浏览器级的手动检查 `npx -y -p playwright@1.65.0 node scripts/check-hero-browsers.mjs`（三个内核 36 格（含首屏几栏的版面哨兵）+ 版面框 + 18 项回退行为，全程无头、只在 Mac 上、Playwright 不是依赖，**不在 `check-all.sh` 里**），见 [SkyCut 官网](docs/architecture/skycut-website.md)「首屏的质感与渐进增强」。

- 导出阶段计时与快速审阅：`scripts/check-export-profile.sh`（真实任务/排队/取消、PNG 仅解码一次，以及真实短进程退出/双管道/错误/取消的回归），合同见 [导出设置](docs/architecture/export-settings.md)与[子进程退出](docs/architecture/blocking-media-reads.md)，实测见 [2026-11-02 导出耗时与快速审阅](docs/reports/2026-11-02-export-profile-review.md)。

- 公开制作状态：`scripts/check-film-production.sh` / `checks/film-production-wiring.sh`（真实模型的图 / CAS、绑定与审查失效、实际转场 / 画布 / 混音、原生帧角色、目录换 Key；完整工具 / undo / 后台媒体另经 MCP 验收），合同见[官方原创短片](docs/architecture/official-film.md)。

- 引擎启动探测：`scripts/check-engine-probe.sh`（合成短命令的超时、双输出上限、退出码、文件描述符、退出回收窗口、候选去重和单次定位；不读取媒体或调用云端），合同见[阻塞的媒体读取](docs/architecture/blocking-media-reads.md)「引擎启动探测」。

- 成片 MCP 疑点检查：`scripts/check-video-inspection.sh`（独立合成工程、真实混音/画面/字幕与试听，不编辑工程）；合同见 [成片疑点检查](docs/architecture/finished-video-inspection.md)，实测见 [2026-11-02 成片检查](docs/reports/2026-11-02-video-inspection.md)。

- 构建与打包的 Rosetta / arm64 要求、常用命令、打包和验收（含 DMG Retina 背景 / Finder 布局）、公开下载发布（含 0.18.59–0.18.66 的签名包与下载回读记录）：
  [docs/build/build-and-packaging.md](docs/build/build-and-packaging.md)。
- 音频库素材的制备与上传（音乐：选曲 → 规格化 → manifest → R2；音效：手写目录 → 峰值归一 + 落点 → manifest → R2）：
  [docs/build/audio-library-pipeline.md](docs/build/audio-library-pipeline.md)。
- 本机配音模型（Kokoro）的整理与上传（钉版本的来源 → 整理 + 清单 → R2，密钥放仓库外）：
  [docs/build/voice-model-pipeline.md](docs/build/voice-model-pipeline.md)。脚本在 `scripts/voice-models/`，R2 签名只有 `scripts/r2.py` 一份，
  **不在 `check-all.sh` 里**。
  脚本在 `scripts/audio-library/`，**不在 `check-all.sh` 里**（它制备素材，不是检查）。
- 全部自动检查：`scripts/check-all.sh`。CI 在每个 PR 上运行同一入口：
  `.github/workflows/checks.yml`，按 `--shard N --of 5` 分到 5 台免费的 macOS runner 上并行跑，
  由一个叫 `check-all` 的汇总 job 给结论（分组、组数校验、汇总 job 为什么不能被跳过，见
  [构建与打包「CI」一节](docs/build/build-and-packaging.md)）。新加检查要放进某个 `shard`：要链接完整 App 目标文件的
  放第 1 组（只有那台编了完整 App），别的放第 2–5 组里最空的那组；文档里提到检查时别写组号（分组只以 check-all.sh 为准）。
- 核心库：`swift run --arch arm64 SrtFlowCoreChecks`（含字幕折行的文字规矩 `SubtitleRowBreakChecks`：中日文的词在哪、能在哪儿断、断在哪好；含逐词高亮：词对到去完标点的字上、此刻亮哪个、跟着编辑走、按词切段、ASS 标签，`SubtitleWordChecks`）。
- 生成的字幕长什么样（去标点、断句、一行多长、显示时间、几段素材同时有字只留一条，用例是用户工程里真实转写出来的句子）：
  `SrtFlowCoreChecks` 的 `SubtitlePunctuationChecks` / `SubtitleSegmentationChecks` / `SubtitleSourceOverlapChecks`；
  藏起来的段不转写、「只用选中的片段」在 `scripts/check-project-file.sh`（`HiddenItems.swift`、`SubtitleSources.swift`）+ 接线扫描 `checks/project-file-wiring.sh`；
  几行（默认单行、两行的折行点）在 `SubtitleSegmentationChecks` 的 `checkTwoLineBreaks`，行数跟着工程走在 `scripts/check-project-file.sh` 第 46 组
  （`SubtitleMaxLines.swift`）、AI 的 `max_lines` 在 `scripts/check-mcp.sh` 的 `SubtitleLinesChecks`、接线同样在 `checks/project-file-wiring.sh`。
- 工程存盘与素材重链接、选择模型（点选互斥 / 框选混选）、轨道块标记：
  `scripts/check-project-file.sh`；这批合同**有没有被生产代码调用**的接线扫描（隐藏清单、调色 / 盖一块 / 形状 / 文字读 `rendered*`、
  字幕生成的可听快照等）单独成 `checks/project-file-wiring.sh`：秒级、不编译、进 check-all，**搬代码 / 改名之后先在本地跑它**
  （原来接在上一个脚本末尾的编译后面，本地跑不到，[PR #84 首跑 CI](docs/bugfixes/2026-09-29-pr84-first-ci-run-wiring-guard-in-moved-code.md) 才红）。
- 播放头与悬停 peek 状态机，以及播放头的慢读法 `PacedPlayhead`（只跟「放置」、播放中不跟、停下追上一次、
  不认悬停），还有「回到开头」（Return / Home）只由 `goToStart` 请时间线滚回最左、普通 seek 不许，
  以及卸片之后晚到的时间回调不许把播放头写回旧位置（真播放器、ffmpeg 现做的带声音素材），还有播到头由声音主时钟自己收尾（播放头正好钉在总长上、不再往后走）、在尽头不 seek 直接再按播放不开播、旧的「播到头」通知晚到时已经回退重播的新一轮照样播（真播放器 + 2 秒的短素材）：
  `scripts/check-player-clock.sh`。
- 不许同步问播放器要时间（`currentTime()`，会被播放器的锁堵住主线程）、AVKit 的 Now Playing 必须关着、电平条读时钟外推的
  `estimatedTime`：`checks/player-time-no-sync-read.sh`；外推的算术在 `scripts/check-player-clock.sh` 第 12 组。
- 音频引擎的等价自检（同一条时间线：引擎离线渲染 vs 纯 Swift 的 oracle 混音器（`checks/AudioEngine/Oracle.swift`：ffmpeg 解码 + 逐采样乘增益表），逐 10 ms 窗口比 RMS ≤ 0.15 dB、帧数正好、零欠载；电平表的槽、场景、变速；**换配置之后按新的几何出声**（第 13 组 `Replace.swift`：按 A 建引擎、`replace(B)`、渲 = 直接按 B 建，B 是挪一段 / 裁头 / 裁尾 / 变速 / 换文件；只改音量仍是同一个结构、走快路径）；**引擎不是一直开着的**（`Idle.swift` / `IdleEngine.swift`：规矩、照规矩停 / 起（假引擎 + 自己拨的钟 + 真计时器）、停过再起播放头一帧不跳、播着停图位置不跳、没有声音不起图、后台起图没起来不空转（注一个起不来的图），手动渲染、无需声卡；`IdleHandoff.swift`：后台正好从 starting 交接到 running 的那一下图照样算开着、管空闲的不撤计时器（`didReadState` 把那一下原样造出来，外加真并发的旁证）；`Presence.swift`：用户在不在从启动就看、只往后走、指针移出不算））：
  `scripts/check-audio-engine.sh`（第 4 组，要 ffmpeg 造素材）；开发机另有三个真声卡的模式（全程静音，CI 的虚拟机没有声卡）：`--realtime-recovery`（被系统停掉再恢复、不跳出去）、`--realtime-idle`（空闲停图、冷着开播第一拍就是起点的声音、先动一下再按不用等、没有声音的时间线播着图不开；加 `--silent-only` 只跑送数字静音的那几段）、`--measure-idle [停多少秒] [几轮]`（量停过之后第一次播放多等多久，只打印）。接线：`checks/audio-engine-idle-wiring.sh`（扫描守卫：引擎交给管空闲的、换工程 / 时间线空了收引擎、2 分钟、用户回来在后台起（四样信号齐全、启动就看、移出不算、只往后走）、要出声时当场起不让播放头空走、在播的锚点待钉和「报过时间没有」的内存序、主时钟自己收尾且不听「播到头」通知、日志不在主线程上写、起不来不空转、一个判断只读一次图的状态）。
- 优化媒体：判据是纯函数（长 GOP 且按这台机器的解码速度才转）、关键帧间隔扫采样表量得出、解码速度量得出、真转一块
  （0.5 秒内必有关键帧、没有 B 帧、帧数 / 尺寸 / 时长 / 旋转对、首尾帧和源一样、不带声音、最后一块到源结尾、能取消）、变帧率的源
  （静止期一帧撑住、整块都在静止期里也盖住整块、块头先出一帧、块尾到源结尾、29.97 的格子）、缓存按身份认、超上限丢最久没用的、过期删、
  上限从设置读（默认 10 GB 十进制、低于下限按下限、几档）、过期的天数、清空之后什么都不剩且还能再落块：`scripts/check-optimized-media.sh`
  （第 2 组；素材 AVAssetWriter 现写，不依赖 ffmpeg）。**按块换源**（段跨几块插几段、时间账不动、画面同原片、块没齐 / 没了退回原片、
  变速 / 上层轨 / 4K 减半、先转播放头附近的）在 `scripts/check-preview-composition.sh` 第 0d 组；接线（换源只在预览重建、成片 / 预渲染 /
  AI 看永远原片、停着才换、切工程作废、菜单不读工程、性能台架量原片；清空之后紧跟 reset + 重建、缓存目录和上限的键只经 Store、
  改上限立刻 enforce、启动时在 proxy 队列上过期、转不了的只在菜单里标不写提示条）：`checks/optimized-media-wiring.sh`（扫描守卫）。
- 主线程心跳看门狗（主线程没卡不误报、卡过阈值记时长 / context / 栈、日志文件、stop 之后不记），以及挂起主线程抓栈期间
  抓栈线程一次都不分配 / 释放内存（第 6 组：`malloc_logger` 钩子逐次数，确定性）、主线程不停分配时连续抓栈不卡死（第 7 组）：
  `scripts/check-main-thread-watchdog.sh`；日志在哪、怎么读见 [主线程卡顿日志](docs/testing/main-thread-stalls.md)。
- 预览合成真取帧，以及素材缓存命中时合成逐帧一样、同一路径换了文件或原地改写过必须重开，
  还有往合成轨上接素材只从末尾接、合成完正好和时间线一样长（多一格视频合成就无效 → 黑屏），
  以及切片表按格子铺、首尾相接（接缝差 0.2 毫秒、画面比配乐早收 0.3 毫秒都不许空出一格），主轨接缝的零头那一格不黑，
  还有压黑 / 闪白逐帧对 xfade 的公式、闪白露出白底、带关键帧的段推移真滑动（`TransitionLook.swift`）：
  `scripts/check-preview-composition.sh`。
- 录屏产物画面轨盖到 T1（尾部不黑）：`scripts/check-screen-recording-writer.sh`。
- 上层视频轨动画段 fill + matte：`scripts/check-export-alpha-compositing.sh`。
- 入场/出场动画的两条管线对账（预览取帧 vs 真导出抽帧）：`scripts/check-clip-animation.sh`。
- 上层视频轨铺满 + 画面渐变的真产物（真跑导出再抽帧），以及上层轨藏起来的段不进成片、透明 PNG 的透明处露出下面那一层
  （预览、静态的成片、带关键帧的成片）、上层轨带缓动的关键帧 matte 和画面按同一条曲线走：`scripts/check-video-fade.sh`。
- 检查器的 live 绑定只准接滑块和 scrub（离散控件没有结束信号，快照会挂着把
  下一次改动抹掉）：`checks/inspector-live-binding-wiring.sh`。
- 画面文字：渲染图与成片**逐点重合**（同一个渲染函数是这套东西的全部前提），
  以及动画的「模型给多少、成片就是多少」、预览上的可点范围、老虎机首帧 / 末帧就是起止值，
  还有主字体里没有的字（✨、汉字）用回退字体画（和直接用那款字体画的墨迹重合），以及带动画的字切成的几段在接缝上每一帧正好贴一层（几段拼接的主轨 +
  起点不在帧格子上，`SeamFrames.swift`）：
  `scripts/check-text-render.sh`。
- 形状：预览那个画法（`ShapePreviewDrawing`，离屏渲一张）和导出那张（`ShapePNGRenderer`）逐像素重合（白色形状铺黑底：最亮的一点、墨迹外框、
  重合度、平均差；五种形状 × 描边 / 实心 × 不动 / 画到一半 / 擦除 / 缩放 / 半透明，「画了 0」两边都空），以及入场 / 出场动画真跑导出抽帧
  （入场画到一半、中间一整圈、出场淡到一半、段外没有、只逐帧渲动画那两截）：`scripts/check-shape-render.sh`（第 5 组）；
  纯值的一半（求值、笔顺、存盘、v31）在 `scripts/check-project-file.sh` 第 44 组。
- 预览上的字幕和烧出来的一样大（预览那个视图离屏渲一张、照导出那条路真烧一帧比字的外框：几种字体、字体里没有的字按回退的那一款（Helvetica 里的中文本机走苹方、CI 没下载苹方就两边换冬青黑体；韩文）、默认样式的粗体、逐词高亮放大），以及回退到系统私有字体时换内置字体的规矩，还有**在哪儿折行**（`WrapChecks`：25 种放不进一行的句子 —— 两行 / 三行 / 五行、中英混排、很长的单词、布局覆盖、9:16、左 / 右对齐、逐词高亮放大、两个空格、带换行、没有空格的中文、带标点的中文、中英文连着写、带空格的韩文 —— 预览离屏渲 vs 真烧按墨迹切成几行比每一行的左右沿，预览每行的宽还要等于 `SubtitleLineWrap` 算的；外加折行的规矩本身：100 号五行的每一行是哪几个字、中文在词和词之间折两行摊匀、L16 测试工程那几句在 56 / 72 / 96 号 × 0.4–1 个画面宽下词和「5分钟」都不拆（名字 72 号以内不拆）、句中的空格是首选的断点、逗号 / 开括号 / 长音不落在行首 / 行尾、日文在假名和汉字之间折（只纯算：假名的回退字体在没下载苹方的机器上预览比成片宽 2.5%，另案）、韩文只在空格处、超长单词照旧溢出、行首行尾的空格不算、亮着的词放大那一行变宽，以及烧录的 ASS 是 WrapStyle 2、折行点写成 `\N`、亮着的词换算到新的字里），还有字幕在预览和成片里摆的**位置**（底部 / 居中 / 顶部 × 一两行 × 英文 / 混排 × 五种字体，上下沿差 ≤ 3 px：libass 的行框用 win 量度、预览用 hhea；**行距** 1.4 / 1.25 的两行样本，烧录垫的空行和预览多出的间距量出来要一样）、字幕**阴影**真画出来的像素（中灰底上白字，预览和成片各量右下多出来的暗处：偏多少、最黑的一点有多黑，透明度写反、哪一边没画都会红），以及字幕字体清单的 cmap 体检（手造的坏 format 12 子表判不安全、装了圆体的机器上它不进清单）：`scripts/check-subtitle-burn-size.sh`；ASS 里点名字体和逐词高亮一起写在 `SrtFlowCoreChecks` 的 `SubtitleWordChecks`。
- `.contentShape` 不许写在 `.offset` / `.rotationEffect` / `.scaleEffect` 之后（几何效果只挪画面、
  不挪布局框，可点范围会留在原位）：`checks/hit-shape-before-offset.sh`。
- `PreferenceKey.reduce` 不许写成 `value = nextValue()`（兄弟节点的默认值会把量出来的尺寸盖成零）：
  `checks/preference-reduce-keeps-value.sh`。
- 放进 `List` 的视图里 body 带 `Section` 的，构造处不许套 `.equatable()`（EquatableView 在 List 里只算一行，整节只剩标题）：
  `checks/list-section-not-equatable.sh`。
- 滤镜调色：LUT 数学（强度那条等式）、层号规则，以及**预览与成片逐像素比对**
  （配方 ↔ CoreImage ↔ 真跑 ffmpeg），以及纯黑不抬（十款的纯黑那一格、CoreImage 渲纯黑、真导出里黑底素材和空档盖了褪色胶片还是纯黑）：`scripts/check-filters.sh`。
- 滤镜挂到播放器上这段接线（拍窗口数像素）：`scripts/check-filter-preview-attach.sh`。
- 盖一块（模糊 / 马赛克）在成片里真的盖了（真跑生产导出再抽帧：只改那一块、块外和基线一致、外接框就是那块、高斯剖面贴着理想的阶跃响应、马赛克格子边长对且从左上角起算、只在那一段时间里盖、形状压在它上面不被糊、调色在它前面、藏起来的不导出、不算总长）：`scripts/check-cover-export.sh`（`check-all.sh` 第 5 组）。
- 导出水印真的叠上了、只在该在的地方（纯值：logo 的路径、PNG 白字带阴影 70%、跳的表不连续同一处、四角 / 正中多大放哪、分段表达式逐时刻求值一致且平衡；真导出开着 / 不开各导一遍抽帧比：每一段落在表上那一处、4 秒边界上正好换、盖满画面的形状上面照样有、不加时参数里没有水印、缩到 480p 之后还在那一角）：`scripts/check-export-watermark.sh`（`check-all.sh` 第 5 组）；加不加只问 `WatermarkPolicy`（纯值里验：授权要加 / 测试开关才加、要加却读不出 logo 抛错）、导出器拿授权问且读不出 logo 不导、每一处问它都传授权、只有导出器调 `plan()`、叠在烧字幕之后缩小之前：`checks/export-watermark-wiring.sh`（第 1 组）。
- 预览上的盖一块真的盖上了（生产的 `CoverHostView` 放进真窗口、拍屏数像素：块里糊成混色块外还是硬的、改动的行正好是块的上下沿、调色带上了、马赛克格线从块的左上角起算、两块同时盖、撤掉之后回到参照）：`scripts/check-cover-preview-attach.sh`。**要图形会话，故意不在 `check-all.sh` 里**，改 `VideoEditCoverPreview.swift` / `VideoEditCoverFilters.swift` 时按 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) 跑。
  **要图形会话，故意不在 `check-all.sh` 里**，改 `VideoEditFilterPreview.swift`
  时按 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) 跑。
- 声音渐入渐出、音量曲线与推子的真实包络（预览 = 引擎离线渲、导出 = 真跑 ffmpeg 两条管线），电平表（挂着表离线渲，
  对账轨道表 / 总表 / 红灯），以及过 0 dBFS 的混音过真峰值限幅器（没过顶逐采样原样、过顶一个采样不超上限、稳态正弦不削成方波、
  尖峰时刻不变、总长不变）、整段响度按 BS.1770 且和 ffmpeg 的 `ebur128` 一致、成片响度和混音一致（第 10 组）：`scripts/check-audio-fade.sh`（带看门狗：渲混音卡住
  4 分钟就判红，并说出卡在哪一组；CI 上第 7b 组「2 倍速曲线 · 导出」差 1–2 dB 偶发，认法见
  [推子与电平表](docs/architecture/audio-mixer.md)「已知的偶发」）。
- 波形数据（多级峰值、原始采样块）逐采样对账，以及**很多文件同时读**必须全部读完、
  不许把线程池堵死（看门狗判红）：`scripts/check-waveform.sh`。
- 成片的声音只有一条管线（导出图里不许出现声音滤镜，混音是预览那个音频引擎按同一份 `AudioEngineConfig`
  离线渲出来的）：`checks/export-audio-single-pipeline.sh`。
- 读采样的阻塞循环（`copyNextSampleBuffer`）不许写在 async 函数里（会占住 Swift 并发
  线程池的线程，文件一多整档 QoS 死锁）：`checks/blocking-media-reads.sh`；同一条还钉着白名单上那个例外（`AudioWindowReader.extract`）
  只许字幕生成调，别处走 `QueuedAudioWindow`（读取在 `MediaReadQueue` 上）。
- 生产导出帧率与分辨率（真跑导出：数帧、读成片尺寸 —— 只降不升、按短边、像素是方的）：
  `scripts/check-export-frame-rate.sh`；禁止写死帧率扫描：
  `checks/no-hardcoded-fps.sh`。
- 关键帧的缓动（每种曲线的值、linear 逐位一致、set / clipped / stretched / remapped 保曲线、存盘按需写键 + 老文件 + v27 / v32、冲过头时宽高留下限和最低不透明度放宽、切片按帧 / 线性一片不多 / 400 片上限）：
  `scripts/check-project-file.sh` 第 39 组；AI 的 `set_keyframes easing`（默认 easeInOut、词表对账、读回来带曲线）在 `scripts/check-mcp.sh`；缓动的缩放真合成
  （片数 = 帧数、四分之一处的面积按曲线）在 `scripts/check-preview-composition.sh`。
- 定格时间线变换（含在最后一帧里定格时不到一帧的右半不留）：`scripts/check-freeze-frame.sh`。
- 按钮提示与快捷键单一来源、提示的根在 `.appLanguage()` 外面裁成气泡的形状（气泡的形状只写一处）：`checks/instant-tooltip-wiring.sh`。
- 检查器里的菜单 Picker 不许锁死宽度（锁了会把整列撑宽、右边被裁）：`checks/inspector-fits-width.sh`。
- 字幕编辑期间全局快捷键让路（⌫ 不删正在编辑的 cue）：
  `checks/subtitle-editing-wiring.sh`。
- 界面文案在 en 原文表和每一张译文表都配齐（表按 `Resources/*.lproj/` 现场找，`InfoPlist.strings` 一并对账）、无重复键、占位符一致：
  `scripts/check-localization-coverage.sh`。
- 提示面板的真实落点（摆好之后不许自己变）、浅 / 深（系统深色 + 森林色时仍是浅色面板）和气泡外面四个角透明（森林色不许露出一圈直角方框）：`scripts/check-instant-tooltip-panel.sh`。
- 切主题、系统切深浅色之后，开着的主窗口（SwiftUI 场景）、工程窗口、录屏控制条、sheet、popover、提示面板的窗框、SwiftUI 读到的浅 / 深、画出来的底色都和新主题一致（森林色永远浅，经典色跟系统）：`scripts/check-theme-switch.sh`。**要图形会话，故意不在 `check-all.sh` 里**，改主题的浅 / 深、呈现根、自建窗口的外观时按 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) 跑；写法（不交 nil、只有一处 `.preferredColorScheme`、不设 `NSApp.appearance`）由 `checks/app-theme-wiring.sh` 在 check-all 里钉着。
  **要图形会话，故意不在 `check-all.sh` 里**（无图形会话会假红），改
  `InstantTooltip.swift` 时按 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) 跑。
- 时间线缩放的锚点（横向钉指针那一刻、工具栏钉播放头 / 视口正中、纵向按行认的那一处），以及播放跟随
  （开关关着到哪都不推、开着只在边上推、推到 15%）和剪辑页记住的开关（五个默认值、没记过 / 记坏了读默认值、脚本驱动时永远默认值）：
  `scripts/check-timeline-zoom.sh`；接线（不许 hitTest 找滚动视图、唯一缩放入口、⌥ / ⌘↓⌘↑ 纵向）在
  `checks/timeline-drag-wiring.sh` 的缩放一节（`checks/timeline-drag-wiring/zoom.sh`），记住的开关 / 播放跟随的接线
  （默认值的字面量、只从 `EditorToggles` 读写、工具栏四个开关在小视图里、播放头竖线里推横向滚动正好两处）在
  `checks/timeline-drag-wiring/toggles.sh`。
- 时间线吸附、框选命中与生产落点，以及点一下播放头落到哪（全局夹紧、点块不出这一块：`TimelineSeek`），还有**联动**（压在主轨块上的东西跟着
  它的画面走：删 / 换位 / 切删 / 裁头 / 变速 / 定格 / 粘贴的同素材新段不算 / 撞上让开 / 拖动计划的名单，第 1f 组 `checks/TimelineSnap/Linkage.swift`；
  同 id 换了素材（upscale 换源、edit_clip 换文件）什么都不挪，第 1i 组 `LinkageSwap.swift`）：
  `scripts/check-timeline-snap.sh`；拖动/框选接线扫描：`checks/timeline-drag-wiring.sh`（拆在 `checks/timeline-drag-wiring/` 下的几节一起
  `source` 进来，含「拖动会话不进时间线的 @State」`drag-box.sh`、联动的接线 `linkage.sh`：`perform` / `liveApply` 收尾调 `TimelineLinkage.follow`、
  只有 ⌫ / delete_items / cut_speech 传 `deletesContent: true`、三个拖动计划带上压着的东西）。
- 冒烟拷工程的脚本不许整夹拷「下载」「桌面」「文稿」、家目录、根目录，太大的文件夹也不拷（真跑脚本、假的家目录）：`checks/copy-project-guard.sh`。
- **进程内 GUI 冒烟**（人在用这台机器时也能跑：不动鼠标、不抢前台，按步骤表点 / 拖 / 滚 / 按键，
  结果里带选择、各段位置和每个视图重算了几次）：`scripts/gui-smoke/in-process/run.sh <步骤.json> [工程拷贝]`。
  **要图形会话，不在 `check-all.sh` 里**；格式与坑见 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md)「四之六」。
- **真客户端实测**（真 Claude Code / Codex 跑八个任务：每轮 SkyCut 常驻多少 token、整份预先加载多少、找工具花多少、选没选对、规矩守没守）：
  `scripts/gui-smoke/client-measure/`（`compare.py` 和上一次对照、按方案 6.4 判）。用用户自己的额度、**每次开跑前问用户**（2026-11-10 用户同意方案剩下的两次 Claude Code 实测直接跑），隔离的测试身份 + 假 Sky Studio，**不在 `check-all.sh` 里**；见 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md)「四之十」。
- 实测证据（`docs/reports/*.json`）和实测脚本自带的数据（`scripts/gui-smoke/client-measure/*.json`）里没有本机的绝对路径（临时目录的名字里带着账户名）：`checks/report-evidence-no-local-paths.sh`。
- **扮成 AI 客户端驱动测试版**（MCP 冒烟：起 App 包里的 `skycut-mcp`，照 JSON 调用表发工具调用，`look` 的图存成 jpg）：
  `scripts/gui-smoke/mcp-client/client.py`。要装好的测试版、素材复制到 scratchpad，见 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md)「四之七」。
- 跨 App 的文件拖放重放（自带拖源，Finder 不吃合成事件）：
  `scripts/gui-smoke/external-file-drag/replay.sh`。**要图形会话，故意不在
  `check-all.sh` 里**，按 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md) 跑。
- SwiftUI 落点路由探针（每格一种 `.onDrop` 组合，回调全记日志；改时间线的落点结构
  之前先在这儿测）：`scripts/gui-smoke/drop-routing-probe/probe.sh`。同样要图形会话、
  不在 `check-all.sh` 里。
- 从 Finder 拖文件进轨道的落点（撞上就抬一轨、多文件接龙、隐藏轨跳过、落地后
  主轨仍按时间排序）：`scripts/check-media-import.sh`；接线扫描（含「整条时间线
  只许一个 `.onDrop`」）在 `checks/timeline-drag-wiring.sh` 里。
- AI 接口（MCP）：给 AI 的文字按客户端怎么读（总说明 ≤ 1,200 字、每个工具的名片 ≤ 450、参数说明 ≤ 120 且写范围、参数定义 ≤ 4,500 字节（例外 edit_clip、generate_media）、前 512 字自成一体且点到 skycut_guide、只用英文，`CatalogTextChecks`；全清单 ≤ 100,000，`CatalogBudget`）、说明书 `skycut_guide`（清单里第一个、只有它预先加载、名片 ≤ 450、每个工具一个同名主题、地图把每个工具列成一项、五个通用主题（rules / conventions / paid / workflows / errors）、一次 ≤ 6,000 且长的分节、写错的回地图 + 猜的、报错指到说明书、手写的文字只提真有的名字、只用英文、App 照答，`GuideChecks`；fields 写全每个参数的可选值 / 类型并集 / anyOf / 条数 / 长度、例子过参数定义、related 是真主题、不含凭据，`GuideContentChecks`；迁移过的工具名片上写按性质的固定说法、迁移前的原文还在、fields 自动切节不丢行，`GuidePilotChecks`；和 recipes 同一行 Policy 在 `checks/MCP/router-wiring.sh`；不等授权在 `GateChecks` + `checks/sky-studio-wiring.sh`）、小程序说的协议（老一代握手 / 新一代每个请求自带版本，真起小程序、假 App 接调用，几百 KB 的图原样穿过通道）、AI 改时间线的规则、客户端配置的增删、词表和 App 类型对账、打包把小程序装进 Helpers 且先签它，
  新东西默认放哪（点名的文件夹 → 工程的家 → 下载，没有「影片」；AI 改了没存过的工程马上存）、窗口只在一轮开始时摆到前面，
  以及 AI 的手和眼：铺满时窗的四角正好落在画布四角（各种比例 × 焦点）、去黑边、对准主体（真让 Vision 认一张图、框不许上下反）、
  look 的拼图和文字描述、listen 的电平 / 静音段 / 曲线，总说明里「不用外部工具改素材」那一句；现有功能铺满的纯值规则
  （剪辑的其余设置、轨道推子、关键帧、形状、复制一份、音乐库的署名句、压缩 / 烧录的参数与起名），以及压缩 / 烧录的条目
  自带设置、不替用户开跑（扫描）；配音的音量（峰值超过满幅的一句真写成 .m4a 读回来不削波、两种声音只经一处写文件）；什么时候问（只有删文件和读别处的文件会问、读过的文件夹记住、撞名加编号，扫描）、记住哪里、
  「连接」时写进 Claude Code / Codex 的放行配置、工具清单总长度的上限；第 4 块的镜头切点与翻页、跟拍（窗的两边落在画布两边、
  只跟人、换镜头跳过去）；第 5 块的剪辑风格（配方卡的格式、合并与查找、存一套 / 删一套，**卡里提到的工具名、参数名、选项值都存在**，卡里的字号写明画幅、9:16 的上限用生产的排版真排得下）、
  set_text 补的零件（字距、动画时长、强调、数字滚动）和实心形状、add_voiceover（挑声音、语速表、标记 → 词、配音的字幕不覆盖已有的）、
  字幕的 style（只改工程自己的样式、给了位置收掉拖框的布局、逐词高亮的开关和倍数、烧录用不了的字体报错、烧录一批自带的样式）、
  扫画面里的字（字幕带、固定的字、满屏的字互不混，字幕带的框不被贴在字幕上面的幻灯片标题拉大、被画面底边切掉的字不算字幕行、字幕稀疏而幻灯片字多时仍选字幕，没人字多按字对准）；**合成音效**（16 个预设的结构自检：峰值 / 响度 / 落点 / 末尾 / 确定性 / 同参数同文件名 / 频谱走向、`sound_effect` 条目怎么读、落点怎么算开头、词表对账；扫描：写文件只经 `AIAudioFileWriter`、渲染在 `MediaReadQueue.analysis` 上）：
  `scripts/check-mcp.sh`；**录屏**（参数怎么读、窗口 / 屏幕 / 麦克风怎么挑、区域的比例换成点、词表和 `RegionAspectRatio` 对账，`ScreenRecordingToolChecks`）也在这里；**几个工程、几个会话**（小程序记一组工程、真起小程序验子代理各带各的 `project`、每个工具碰不碰 / 收不收 `project`，`ProjectBindingChecks`；落在哪 / 归谁 / 什么时候拒、5 分钟放手、到顶列出能关的，`ProjectTargetingChecks`）也在这里；**App 卡住的时候**（什么时候放弃、怎么说、放弃了的不做，真起小程序接卡死 / 忙的假 App，`HangChecks`）也在这里；**画面多大**（导出报成片的宽高帧率、look 报文件本身的尺寸，`VideoSizeChecks`）也在这里；**导出字幕文件**（写哪几条轨、`<名字>.<语言>.srt`、撞名整组加编号从不覆盖，`SubtitleFileChecks`）也在这里；**一次查完 V1 的剪辑点**（listen cuts=true：每一段的头尾都是剪辑点、挨着的合成一个、跨转场带 transition、开着缝的各报各的，在它声音的源时间轴上判、建议换回这一段自己的源时间，`CutCheckChecks`；**判的输入和 cut_speech 同一份**（`AISpeechHearing`：整个文件的电平、门限、词），L16 原片真量的电平上两边判得一样、建议就是 cut_speech 的落点，`SpeechHearingChecks`）也在这里；**参数名按说明核对**（说明上没有的名字整个调用不做、里层也查、每个工具说明上的全部名字都过，`ArgumentCheckChecks`；核对在路由排队之前，`checks/MCP/router-wiring.sh`）也在这里。
- AI 录屏的接线（扫描守卫）：AI 起的录制不开系统选择窗口、设置页 / 残缺框只给手动的会话、不覆盖、不写手动的偏好、入轨包 `AIUndoGrouping.step`、
  录制中不把 SrtFlow 摆到前面、丢弃先问且进废纸篓、授权一次运行只请求一次、浮窗在左下角、录制中换工程 / 改帧率先挡：`checks/screen-recording-ai-wiring.sh`。
- Sky Studio 账号与照授权拦（收费方案第 5 刀）：`scripts/check-sky-studio.sh`（`check-all` 第 2 组，不碰网络、不碰钥匙串）：Key 的整理与钥匙串那一条的名字、机器号钉死一组值（盐改了就红）、`/me` 照合同里的样例读（带毫秒的日期、读得宽、少了必须的不算回答）、假 URLSession 上的请求（地址、四个头）和三种失败、环境变量只能指到本机、此刻的授权（没有 Key / 没问到过 / 过期按免费版、钟差、往回拨）与什么时候再问、照授权拦（`GateChecks`：默认打开、测试开关关不掉它、每个工具 × 每种授权让不让且 `get_status` 永远让、水印听服务器的、被挡住时的话、`skycut_plan`）；接线（地址只在 `SkyStudioAPI`、硬件 UUID 只在 `SkyStudioMachine`、后台不弹钥匙串框、设置和启动接上了、AI 的门在核对参数名之后建调用之前、导出面板挂着「会带水印」那一行、`export_video` 和 `get_status` 说授权、交任务和取消只经 `SkyStudioJobRun`、认证头只在 `SkyStudioAPI.request()` 写一次）：`checks/sky-studio-wiring.sh`（扫描守卫）。同一个脚本还管**第 6 刀的任务**（`JobChecks` / `JobRunChecks`：`/models`、`/quote`、`/jobs` 发什么读什么、取消的两种结果、`/uploads` 之后 PUT 只带服务器给的头不带 Key、下载成品；`SkyStudioJobRun` 满了等着用同一个 idempotency_key 再交、照 `poll_after_seconds` 问、断网几次不算、停的时候排队中退钱 / 开始了取消不了且接着查到底）和 **generate_media 送 Sky Studio 的那一份**（`GenerationChecks`：词表和 `SkyStudioGeneration` 对账、每种的默认值、用不上的参数说一句不送、请求体、确认码的记号、离谁最近的画幅、成品的扩展名）；接线第 9 条钉着生成的把关在建任务之前、Key 不弹框、状态行和 get_job 的阶段与 `skystudio_job_id`。
- 云端媒体：`scripts/check-sky-studio.sh` 验证现行接口 / 任务 / 报价 / 积分 / 配音，`VoiceSlotChecks` 验按池领槽（两个池对上服务器的名单、先来先得、对着假服务器数同时开着的单、429 看 `pool`）；`scripts/check-cloud-media.sh` 验证共用每日账与阶段；`checks/no-legacy-generation.sh` 禁止旧 fal 客户端 / Key / 设置 / 模型和网络路径回来。
  `scripts/check-voice-recovery.sh`（第 1 组）链接真实 App 对象：回任务号之前整段报价一次、每批同一个 `params.plan`、额度 / 服务器拒都在花钱之前停、服务器不答退本机（`StartChecks.swift`）；字幕时间（`TimingChecks.swift`，声音 PR 5：普通旁白合批、字幕是稿子的字、转写不了的预设整段 eleven-v4 / 别的按字数估、转写模型在第一批之前装、装不上再报价）；几批同时交、后交的先回仍照原来的顺序落地、中途换备用之后的批带备用的选择、`fallback_needs_one_time` 之后只补没做成的（`ConcurrencyChecks.swift`，声音 PR 4）；第二批云端成功而本地失败后只恢复已有音频、只补第三批（照记录的选择再报价）、字幕 / 片段不重复、原子入轨撤销与未知单不重放；付过钱的声音不卡死（`PaidAudioChecks.swift`，2026-11-10 审查：繁体稿合批而转写写成简体、长句两片 24 kHz / 44.1 kHz、转写不了的 Mac 上 eleven-v4 的 `words` 用不了按字数估句界、`get_job` 运行中和失败后带 `voice.note`），纯值的一半在 `scripts/check-sky-studio.sh` 的 `VoiceSplitChecks`。
  `scripts/check-sky-studio.sh` 的 `VoicePickChecks` 对着目录快照认声音（默认 gemini:Charon、角色只认 voice_roles、英式男声、本机退档按性别）。
  声音库（声音 PR 6）和全部权限下的长期授权（声音 PR 7）：`scripts/check-sky-studio.sh` 的 `VoiceLibraryToolChecks`（列出来的、令牌绑的身份、`SkyStudioJobGate` 的授权 / 一次性费用 / 删除在 `.ask` / `.standing` / `.once` 下、错误的话）、`VoiceStandingNoticeChecks`（打开全部权限时那段说明：价目照目录快照、授权那句和 Sky Studio 的一字不差）、
  `scripts/check-voice-recovery.sh` 的 `LibraryChecks`（真 App 对象：建声音先问授权、删除按模式、设计、用声音库的声音配旁白的一次性费用、声音库用不了不退本机）与 `FallbackFeeChecks`（旁白中途备用要先建 MiniMax 版：get_job 问价、普通 resume 留着这一笔、`skip_one_time` 照原来的模型重试、令牌按报价记账起 `voice_enroll` 再 `generate_missing` 读完）与 `StandingChecks`（全部权限 + 长期授权什么都不问、没有就问一次并补记、Sky Studio 拒了再问、set_settings 记 / 撤、升级补记）、
  `checks/sky-studio-wiring/voice-library.sh`（`checks/sky-studio-wiring.sh` 第 11 节 source 进来：`consent: true` / `standing_grant` 只在放行之后造、长期授权只经 `SkyStudioVoiceStanding`、改模式的地方都告诉它、`/voices` 路径只在一处、没有服务商 id 的样子）。
  `scripts/check-mcp.sh` 的 `ProviderChecks` / `SkyStudioVoiceChecks` 验证清单、旧标记兼容、参数名、本机选声、词时间（克隆参考录音的 WAV 见下一条）；`SkyStudioVoiceChecks` 还查 add_voiceover 的名片必含 / 说明书必含，名片上限、固定说法、参数说明和主题的分节和试点的五个一起在 `GuidePilotChecks`，会问就收 `confirm_token` 在 `ArgumentCheckChecks`；`scripts/check-keychain.sh` 是本机真实钥匙串回归，不在 CI 里。
  免费端到端在 `scripts/gui-smoke/sky-studio/`，见 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md)四之八；共享客户端在 `scripts/gui-smoke/mcpclient.py`，断线 / 坏协议必须显式失败。
- 声音库的收费单只下一次、账只记一次（2026-11-11 审查之后）：`scripts/check-voice-recovery.sh` 的 `LibraryOrderChecks`（真 App 对象 + 会排队 / 去重 / 改价 / 退款、
  实扣不等于上限的假 Sky Studio：设计连按只下一单、同一份再起回开着的那一单、账按实收、`price_changed` 带新价和下一步、MiniMax 版在建时再调跟着那一单、
  授权那句升版本用新文案再问、临时文件夹只清一天以前的、`QueuedAudioWindow` 出 16 kHz 且能取消）、`FallbackFeeChecks.repricedChecks`（建的那一单没受理：问题还在、
  记下新价）、`LibraryUIChecks.outdatedStatementChecks`、`PaidAudioChecks.neverMatchesChecks`（每次都切不开的批第二次按字数估）、
  `LibraryRestartChecks`（跨一次重启：旧进程的任务停在下一次问之前、新进程只看盘上的；建 MiniMax 版在建时重启再调不问不记、跟着那一单，
  两单设计重启后读到 Key 就接着跟、按实收 / 退回，交的回答丢了再点头时并成一笔，实收落在预留那一天）；
  `checks/sky-studio-wiring.sh` 第 13 节（拆在 `checks/sky-studio-wiring/voice-library-orders.sh`）。规矩见 [声音库](docs/architecture/voice-library.md)第十节。
  这项检查每次运行用自己的 bundle id（`…voicerecoverycheck.run<pid>`），几个会话同时跑不共用 UserDefaults。
- 声音库的界面（声音 PR 8）：`scripts/check-sky-studio.sh` 的 `VoiceLibraryUIChecks`（纯值：选择器三组的顺序和预设名单、按这一排的语言取性别 / 样音、说明按界面语言挑、「新建」为什么还灰着、服务器的错误是哪一种）、
  `scripts/check-voice-recovery.sh` 的 `LibraryUIChecks`（真 App 对象 + 假 Sky Studio：Store 的几种样子 / 改名 / 删除再发一次 / 临时链接 / 「声音库变了」，新建声音没勾授权什么都不传、勾了和 `manage_voices` 同一个 key、人声不够当场说、语言预选，设计先问价、按下去过每日硬预算、改字报价作废，录音机，界面上的话）、
  `checks/sky-studio-wiring.sh` 第 12 节（拆在 `checks/sky-studio-wiring/voice-library-ui.sh`：`consent: true` 在对话框里只许勾过之后造、建 / 加 / 删只从一个文件发、设计先过额度再起任务、界面不用确认码、视图不读工程）、
  `checks/project-file-wiring.sh`（语言检测的候选和裁决钉在 `SpokenLanguageProbe`）；出图 `scripts/render-voice-library.sh <输出目录>`（三种界面语言各一套 PNG，**要图形会话、不在 `check-all.sh` 里**，见 [GUI 冒烟流程](docs/testing/gui-smoke-testing.md)第五节）。规矩见 [声音库](docs/architecture/voice-library.md)第九节。
- 变声（声音 PR 9）：`scripts/check-voice-recovery.sh` 的 `VoiceChangeChecks`（真 App 对象 + 假 Sky Studio `VoiceChangeHTTP`：落地的规则、先报价后上传的单声道 WAV、一次 `voice_convert`、`target_language` 什么时候带、收费之前停下来的几种、一步撤销 / 重做、这一段没了 / 工程换了只留文件、没做成退回、结果不明不重交、面板背后的那一份）、`scripts/check-mcp.sh` 的 `SkyStudioVoiceChecks`（名片、说明书、地图）、`checks/sky-studio-wiring.sh` 第 14 节（拆在 `checks/sky-studio-wiring/voice-change.sh`：两个入口同一条路、先过预算再起任务、不用确认码、落地一次 perform、块只写目标、面板不读工程）、`checks/MCP/router-wiring.sh`（落地那一下包在 `AIUndoGrouping.step` 里）；免费冒烟 `scripts/gui-smoke/sky-studio/voice_change.py`、出图 `scripts/render-voice-library.sh` 的第 9、10 张（**都要图形会话或起测试 App、不在 `check-all.sh` 里**）。规矩见 [声音库](docs/architecture/voice-library.md)第十一节。
- `manage_voices` 的 `language` 可选（2026-11-11）：`scripts/check-voice-recovery.sh` 的 `LibraryLanguageChecks`（真 App 对象，识别换成假的：不给时识别一次、问句和结果写识别成了什么、照原样带令牌再调建成；识别不出来回 `language_undetected` 和「带上 language 再调」、什么都不传；给了照给的、识别一次都不叫；`add_reference` 同一条路）、
  `scripts/check-mcp.sh` 的 `SkyStudioVoiceChecks`（只有 `action` 必给、参数说明和 `create` 一节照可选写、有一个例子不带 `language`）、
  `checks/sky-studio-wiring/voice-library-ui.sh` 末尾一段（识别只有 `SpokenLanguageProbe` ← `VoiceSampleLanguage` 一份、只许对话框和 `manage_voices` 用；工具里不许再当必填、识别在做参考录音之后问授权之前）。规矩见 [声音库](docs/architecture/voice-library.md)第八节第 3 条。
- 克隆的参考录音：`scripts/check-mcp.sh` 的 `VoiceReferenceChecks`（挑段的纯值规则、门限 0.0056 的合同、坏采样记 0，和照规矩直写的穷举对账）与 `VoiceReferenceFileChecks`（现写 44.1 kHz / 48 kHz 立体声 / AAC / 32 位浮点素材真走 `VoiceReferenceSample.prepare`，把写出来的 WAV 按字节读回来；含贴着门限的样本、浮点刚过门限而量化后不够的样本、带 NaN / ±Inf 的样本），扫描守卫 `checks/MCP/voice-reference-wiring.sh`（门限单独写死、不借 `AIVoiceLevel`）。真 App 对象上的那几条（克隆只传一次、人声不够在报价之前拒）随 `clone_from` 在声音 PR 3 删了，建声音的真 App 检查跟声音 PR 6 加。规矩见 [声音库](docs/architecture/voice-library.md)。
- 视频 upscale：`scripts/check-upscale.sh`（`check-all` 第 2 组，要 ffmpeg 造带声音的素材，不碰网络）：范围（三选一、余料、对齐、夹住、一次最长 30 秒放不下先少留余料）、
  Sky Studio 的档位（`/models` 读成 `UpscaleTier`、能升到哪几档、上限、送不送得了）、起名落盘、封回原声的参数、真裁一段、流水线对着假 Sky Studio 走全程（裁 → 探 → `/uploads` + PUT →
  `/jobs` → 等 → 下载 → 封声 → 落盘记实收的积分；整个 mp4 直接上传、排队中停下替它取消、被拒没有文件）；接线在 `checks/sky-studio-wiring.sh` 第 8 条。
- 时间线复制 / 剪切 / 粘贴：拿什么、换新身份（除了 id 每个字段照抄）、粘到哪（撞上往上抬、几组保住上下关系、
  声音各找一条、链接组换新号、文字 / 滤镜 / 字幕句各自的行规矩），外加分割不丢字段、分割后链接组一对还是一对：
  `scripts/check-timeline-clipboard.sh`；接线（编辑菜单三项、右键菜单、落点鼠标优先含 Finder 文件、标尺不算轨道、
  剪贴板只有一套且不写纯文本）：`checks/timeline-clipboard-wiring.sh`。
- 静帧真实编码，图只解一次、缩一次（数 ffmpeg 报的解码次数；多出来那 119 帧的耗时和同一次运行里产物尺寸的小图比、上限 2.5 倍或多 0.25 秒，规则自检钉着 CI 慢 runner 的数、1.2 倍抖动不红、6 倍退化红），以及透明的图（哪张算用到了透明、预乘的 ProRes 4444 + 灰度遮罩的真产物、按图挑缓存名、老缓存不再认）：`scripts/check-still-clip-encode.sh`。
- 翻译配对预检与接线：`scripts/check-translation-preflight.sh`。
- 音频库清单：解析的宽容边界（不认识的字段忍、单条坏数据跳过、**版本号更高整份
  拒绝**）与双语搜索（中英都能命中同一个 tag、多词是「与」），以及音效清单的 `title_zh` / `hit` / `owned` 不署名 / 按中文标题搜：
  `scripts/check-audio-library.sh`。
- 音效目录（`scripts/audio-library/sfx-catalog.tsv`：id 连号永不改、来源唯一、中英标题、tag 都在词表里、来源方）：
  `checks/sfx-catalog.sh`。
- 压缩 / 烧录记住的设置和字幕样式在队列创建时读回来（不挂在页面的 `onAppear` 上），剪辑页和 AI 的字幕样式都经
  `subtitleStyle(appWide:)`（工程自己的样式优先）：`checks/encode-settings-memory.sh`。
- 构建日志不得被吞：`checks/no-swallowed-build-output.sh`。
- CI 的 `.build` 缓存：key 和 restore-keys 带检出目录（`github.workspace`，仓库改名 / 换目录后不捡旧目录编的缓存）、工具链指纹、组号和提交，
  取 / 存分开且同一个 key、只在 main 上绿了才存、编译之前修改时间按内容设（`scripts/ci-stable-mtimes.py`）：`checks/ci-build-cache-key.sh`；
  按内容设的时间比上次编译早时照样重编（不拿旧目标文件测新代码）、新 checkout 放回 `.build` 重编 0 样，在小包上真走一遍：`scripts/check-ci-build-cache.sh`。
- CI 的「只改了文档」快速通道（`scripts/ci-docs-only.sh` 判：只有 `docs/` 和根目录三份说明才算，改名算删旧加新；是就只跑扫描守卫）
  只在真的只改了文档时走、每一步重活都看判断的结论、触发条件里不许有 paths（必需的 check-all 会永远等不到结论）：`checks/ci-docs-only.sh`。
- `checks/` 顶层的每一条扫描守卫都在 `scripts/check-all.sh` 里（CI 只跑 check-all 列着的；check-guards 按通配符跑，漏进 check-all 的本地照样绿），
  以及第 1 组正好是「完整 App」那一摊（App 编得过 + 链接完整 App 目标文件的检查，这种检查也只许在第 1 组）：`checks/check-all-shards.sh`。
- 「连接」AI 客户端时第一次改配置前存的备份，一建出来就和原文件同样的权限（只有 `AIClientConfigWrite` 写 `.skycut-backup`、`AIClientSetup` 经过它）：
  `checks/client-config-backup.sh`；行为（600 的备份还是 600、照原文件不一律 600、链接按目标算、再改不动备份）在 `scripts/check-mcp.sh` 的 `ConfigBackupChecks`。
- DMG 安装引导的接线 / 模板：`checks/dmg-packaging.sh`；真实组装、挂载和 Retina 背景：`scripts/check-dmg.sh`。
- 发布版用固定的签名身份签（打包脚本只经 `scripts/signing/sign-app.sh`、它有身份就用并核对钉着的证书、ad-hoc 只在没有身份那一支、
  `packaging/signing-identity.sha1` 钉着正好一把），录自定义区域请求授权之前先删钉着旧签名的记录、`tccutil` 只在一处、文案不再叫人
  「关掉再打开」：`checks/release-signing.sh`。建签名身份 `scripts/signing/create-identity.sh` 是一次性的、**不在 `check-all.sh` 里**。
- 产品名与代码名（看得见的叫 SkyCut；bundle id、UTType、数据文件夹、钥匙串、AI 通道这些身份沿用 SrtFlow，改了就丢用户的授权、设置和数据）：
  `checks/product-name.sh`。
- 工程不再是单例（全仓没有 `VideoEditProject.shared`、工程只由 `OpenProjects` 建、撤销不退到键窗口、工程代号全 App 一个计数、
  退出问每个工程、录屏落回开录的工程）：`checks/open-projects-wiring.sh`。
- 代码文件的行数上限（超过 600 行就红，老文件只许降不许涨，变短了用 `--update` 改小基线）：
  `checks/source-file-size.sh`。
- shell 脚本里裸 `$VAR` 不许紧跟中文 / 全角标点（bash 会把首字节吃进变量名，
  `set -u` 下当场退出）：`checks/shell-var-boundary.sh`。
- 开着 pipefail 的 shell 脚本里，管道末端不许用 `grep -q`（命中就退出，上游吃 SIGPIPE，
  整条管道判失败 → 时灵时不灵的假红；查变量用 `<<<`，查管道用 `grep -c … >/dev/null`）：
  `checks/shell-pipe-grep-q.sh`。
- `"$(…)"` 里不许再套带 `{…,…}` 的双引号字符串（CI 的 /bin/bash 3.2 会把它花括号展开、拆成几个词；放在 `[ ]` 里就是 too many arguments、
  `if` 走 else，守卫永远不红 —— 先赋给变量再比较）：`checks/shell-brace-in-nested-quotes.sh`。
- 每个 sheet / popover 的内容、每个自建的 `NSHostingView` 都必须套 `.appLanguage()`（SwiftUI
  不把应用内语言带进 sheet / popover）：`checks/presented-views-app-language.sh`。
- 代码里每个 `UTType(exportedAs:)` 都必须在 `packaging/Info.plist` 里声明（没声明的
  类型系统认不出，拖放会被静默拒绝）：`checks/exported-types-declared.sh`。
- 预览性能 ratchet（起真 App 按固定场景数「做了多少件活」，只许降不许涨）：
  `scripts/check-preview-perf.sh`。**CI 独有**：第 1 组里单独一步，要图形会话，**不在
  `check-all.sh` 里**；check-all 只跑它的比对规则自检（`--self-test`）。偶尔会误报退步
  （CI 虚拟机上的已知干扰），认法和处理见架构文档「已知的偶发误报」。每个视图、
  `updateNSView`、Canvas 都接了计数：`checks/preview-perf-wiring.sh`；新写视图漏了计数，
  跑 `checks/preview-perf-wiring.sh --fix` 自动补上。同一个守卫还钉着**时间线上的块不许
  读工程的属性、必须 `Equatable` 且构造处套 `.equatable()`**，以及**订阅播放器时钟的只许是名单里跟着播放头动的
  小视图**（根视图、时间线本体、检查器、素材库、字幕列表都持有不订阅）。
- AI 起的导出 / 转写 / 翻译排队（四个入口都经 `AIWorkQueue`、不再回「已经在做」、取消先从队里拿、`get_job` 报 `queued` / `queue_position`）：
- AI 在干活时不让 App Nap 降速、领和还成对（活动断言只在 `AIKeepAwake` 和录屏开关、路由领了紧跟 `defer` 还、任务 `start` 领 `finish` 还）：`checks/ai-keep-awake.sh`（扫描守卫）；计数、重复还、兜底还、真走一次工具调用和任务都还回来在 `scripts/check-voice-recovery.sh` 的 `KeepAwakeChecks`。
  `checks/ai-work-queue-wiring.sh`（扫描守卫）。
- 全部扫描守卫一条命令：`scripts/check-guards.sh`（跑 `checks/*.sh` 每一条，再加 `scripts/check-mcp.sh --scans-only` —— check-mcp 编译之前那一段扫描、连同它 source 进来的 `checks/MCP/*-wiring.sh`，以前只在 CI 上跑得到；推之前必跑；`check-all.sh` 照样逐条跑它们，`checks/check-all-shards.sh` 钉着两边对得上）。
- 本地推之前那一步：`scripts/check-local.sh <相关的检查>`（扫描守卫 + 点名的几项；完整的一遍交给 CI）。本地跑检查的三个入口
  （check-local / check-guards / check-all）在 Rosetta 下会换成原生 arm64 的 `/bin/bash` 重跑自己（`scripts/native-arch.sh`）、
  起检查用 `/bin/bash` 不用 PATH 上的 bash：`checks/native-local-checks.sh`（装了 Rosetta 就真起一个 x86_64 的探针看它换没换成原生）。
- 本文件的索引必须是全的：`docs/` 下每一份文档都要能从这里找到，且没有死链 ——
  `checks/docs-index-drift.sh`。只读 AGENTS.md 的代理打不开索引外的文档，
  所以漏一行等于那份文档不存在。

## 规划与实施报告索引

- [声音功能的真实冒烟：界面那一半 + AI 工具那一半（2026-11-11）](docs/reports/2026-11-11-voice-real-smoke.md) — 夜里测试账号是 SkyCut 免费套餐（AI 工具被拦），只走 App 的界面（进程内驱动 + 新的 `voice` 一步、隔离测试 App、临时 Key）：新建声音（授权那一勾）、Qwen3 设计、删声音、右键变声 10 秒（两条新轨、原声静音、一步撤销、都补齐到 10 秒）全过，40 积分，设计的报价写成「Sky Studio」修在 #379；早上开了 AI 开关补跑第八节：库里的声音读中英混合稿 2 批（IndexTTS2）、繁体合批切句（转写是 zh_TW、没有 local_split）、967 字长句拆 2 批接缝无爆音、全部权限的长期授权（记 / 不问建删 / 提示条 / 撤）、App Nap（任务跑着优先级 28、做完回到 4）全过，34.2 积分；两半 74.2 积分 = USD 0.30，和 Sky Studio 的任务、余额、fal 账单、Vertex Monitoring 逐笔对上；`set_settings` 回答里长期授权说反修在 #383；主窗口有过声音之后音频引擎一直开着（Mac 不空闲睡眠、不 App Nap）待拍板。

- [变声（声音 PR 9）：离屏渲染和免费冒烟](docs/reports/2026-11-11-change-voice.md) — 变声面板英 / 中 / 西各一张拼图（选了声音带报价、还没有自己的声音；看图撞出按钮被截字）；真 App + 真 MCP + 本机假 Sky Studio 走全程（报价 → 上传 → 一次任务 → 两条新轨 → 撤销）；没验到的（真 Sky Studio、真窗口、本机语言检测）。
- [声音功能的免费冒烟补跑（声音 PR 3–6）](docs/reports/2026-11-10-voice-free-smoke.md) — 假 Sky Studio 上跑 `voice.py`（合批 + 对齐字幕）、声音库（两种权限模式的问法、加语言、改名、删除、`voice_…` 读稿的一次性费用、设计、撤销）、几批同时交（两个池、停、恢复、429）和中途换备用，全部通过；没跑到的（装转写模型、浮层那一行、PR 7 的长期授权）和看见的问题（AI 的活在后台被 App Nap 降到优先级 4、机器忙时超时等五条）。

- [声音库界面的离屏渲染（声音 PR 8）](docs/reports/2026-11-10-voice-library-ui.md) — 生产的视图 + 假 Sky Studio，英 / 中 / 西各一张拼图（设置那一节的三种样子、浏览预设、新建声音、加录音、设计带报价）；看图撞出的两件事（`"Language"` 是「界面语言」、整个设置窗口会拍进用户自己的风格名）；没验到的（真麦克风、真 Sky Studio、真 sheet、本机语言检测）。

- [MCP 按需说明的基线实测（Claude Code + Codex）](docs/reports/2026-11-10-mcp-guide-baseline.md) — 改之前的 main 7a9d8c9：SkyCut 每轮常驻 1,605 token、整份预先加载 39,646 token（约 2.5 字一个 token，比方案估的高 45%）；八个任务的调用、被拒、落盘断言，任务 7 换题前后两次都留；[脱敏证据](docs/reports/2026-11-10-mcp-guide-baseline-evidence.json)；Codex 一半（0.167、gpt-6.1-sol / max）：第一次请求里 SkyCut 占 64 token（0.167 给每个 MCP 服务器列一行带总说明开头，不是 0）、全打一遍工具 49,485 token 截在约 1 万、只看得到 12 个，找工具打印里 46% 是重复的总说明，任务 7 把「画质尽量好」当成点名、没停下来问；[Codex 证据](docs/reports/2026-11-10-mcp-guide-baseline-codex-evidence.json)。

- [MCP 按需说明的试点实测（Claude Code + Codex）](docs/reports/2026-11-10-mcp-guide-pilot.md) — 试点合进 main（08fa1b3）之后跑任务 1、4、5、7 + 整份预先加载，对照基线按方案 6.4 判：过线（结果、规矩和基线一样，每轮常驻 −6.5%、整份预先加载 −2.2%）；任务 7 读了 11 次说明书、输入 +41%，比开销看输入合计不看花费（缓存冷热）；[脱敏证据](docs/reports/2026-11-10-mcp-guide-pilot-evidence.json)；#358 之后补跑任务 7：读说明书 11 → 5 次、输入回到基线 +2.9%
  （[补跑证据](docs/reports/2026-11-10-mcp-guide-pilot-task7-rerun-evidence.json)）；Codex 一半（f76032e，0.167、gpt-6.1-sol / max，四个测试 App 并行）：和基线比没有退步，任务 7 两边都把「画质尽量好」当成用户点名、自带
  `user_requested_overrides` 没停下来问；全打一遍的原始 token −27%、找工具打印的总字数 −13.6%、重复总说明占比 48% → 38%（6.4 的三条按字面没到，截断和方案自己的估算见报告）；
  [Codex 证据](docs/reports/2026-11-10-mcp-guide-pilot-codex-evidence.json)；协调者按结果放行两批；任务 7 的规矩修了之后（`user_requested_overrides` 要 `user_request` 原话点名规格）补跑，Codex、Claude Code 都停下来问（[Codex](docs/reports/2026-11-10-mcp-guide-overrides-task7-codex-evidence.json)、[Claude Code](docs/reports/2026-11-10-mcp-guide-overrides-task7-claude-evidence.json) 证据）。

- [MCP 按需说明：迁移完以后的完整实测（Claude Code + Codex）](docs/reports/2026-11-11-mcp-guide-final-measurement.md) — 说明书 PR 1–6 合完之后的 main `803f4ee`（61 个工具），两个客户端各跑 8 个任务，对照基线按方案 6.4 判：落盘结果都和基线一样；被拒 Claude Code 任务 6 是 1 → 2 次、Codex 4 → 0 次；任务 7 两个客户端都没绕过确认（Codex 一次先做了不用确认的 1K 草稿、再到 4K 要确认时停下来问）；Claude Code 每轮常驻 1,605 → 1,494 token、整份预先加载 39,646 → 36,645（−7.6%，过 6% 的线；`change_voice` 合进来之后用 `fb49bf5` 再量是 37,009、−6.7%，仍过）；Codex 三条开销线按字面没到（找工具打印的总字数 −24.8%、重复总说明占 43.7%、第一次请求 67 token）和为什么（全打一遍被截在约 4 万字、每个条目背一份总说明），全打一遍的原始 token −29.4%、每个条目 −32.9%；读说明书 26 / 46 次；2026-11-11 定的三件事（接受 Codex 的现状并在方案 6.4 加更正、低价草稿照规矩直接做所以任务 7 算过、`change_voice` 合了再量一次整份预先加载，已量）；[Claude Code 证据](docs/reports/2026-11-11-mcp-guide-final-measurement-evidence.json)、[Codex 证据](docs/reports/2026-11-11-mcp-guide-final-measurement-codex-evidence.json)、[Codex 任务 7 加跑](docs/reports/2026-11-11-mcp-guide-final-measurement-codex-task7-rerun-evidence.json)、[`fb49bf5` 的预先加载](docs/reports/2026-11-11-mcp-guide-final-measurement-preload-fb49bf5-evidence.json)。

- [MCP 按需说明的实施报告（进行中）](docs/reports/2026-11-10-mcp-guide-progress.md) — 七个 PR 各做到哪、基线实测在哪、任务 7 换题、本机跑检查的偶发（`ListenRangeChecks` 负载高时超时、换分支后 `.build` 留下的目标文件）。

- [MCP 按需说明：名片常驻、说明书按需读](docs/plans/2026-11-09-mcp-guide.md) — 2026-11-09 用户审定第八节 8 条、11-10 批准施工（6.4 的 Codex 开销口径 2026-11-11 有一条更正，照迁移完的实测）：各客户端一轮里实际读了什么（Claude Code 按需加载、2.1.296 起 4,096 / 16,384；Codex 代码模式里每个条目背一份总说明、超过 5,000 字节的参数定义删光说明）、说明书工具 `skycut_guide`（没开通也照答、预先加载）、名片 ≤ 450 / 参数说明 ≤ 120 / 全清单 100,000 等新上限、先于声音的 3 个工具、分批迁移的七个 PR、真客户端验收每次开跑前问用户。

- [SkyCut 声音方案](docs/plans/2026-11-09-voice-features.md) — 2026-11-09 定稿、11-10 用户批准施工（Sky Studio 那份方案在 Sky Studio 仓库）：配旁白改成服务器自动选模型（`model: auto`，整段一次 `/quote` 回 `voice_plan`，跨语言先提示）；声音的名字（`voice_…`、`gemini:<名字>`、`eleven:<名字>`，8 个角色读 `/models` 的 `voice_roles`，默认 `gemini:Charon`，MiniMax 的 voice_id 永不出服务器）；MCP 新增 `list_voices` / `manage_voices` / `change_voice`、去掉 `clone_from`；请求批准 / 全部权限两种模式下一次性费用、录音授权、删声音怎么问（打开全部权限时讲清价目、记长期授权）；参考录音 44.1 kHz、10 秒有效人声到 3 分钟、超长自动挑一段；字幕时间（本机对齐 / 点名 `eleven-v4` / 按字数估）；声音任务单独一个池（8 个）、普通旁白也合批、几批同时交；界面（声音库、选择器、新建 / 设计声音、片段右键变声）；九个 PR 的拆法、自动检查和人工回归清单。

- [2026-11-07 全部图片模型与角色系统的真积分验收（0.18.62）](docs/reports/2026-11-07-image-models-and-characters-smoke.md) — 四个新图片模型、换角度、角色的读 / 建 / 带角色生成图片和视频 / 改名 / 重做头像 / 删除全部成功（208 积分，和本机账一致），旧 revision 被拒不送出；图片放大一开始坏在 Sky Studio 的服务商（Google 下线了 Imagen 放大，已退款），当天换成 fal SeedVR2 后补测 x2 / x3 通过；每个新构建第一次读 Key 弹钥匙串密码框、AI 调用等在框后面；`list_characters` 一页约 80 KB 太大；这三项和网页端放大超时都已修好（0.18.63、Sky Studio PR #244），末节是修复与实测。

- [Windows 版 SkyCut：讨论记录（暂缓）](docs/plans/2026-11-07-windows-version.md) — 2026-11-07 用户、Claude、Codex 讨论一轮后用户定「日后再讨论、现在都待定」：已定的（共享 Swift 核心不做第二套代码、Mac 新功能照常做、两边工程互开 + 随包一套开源字体、Windows 字幕识别用 whisper.cpp、先不签名、ARM 先不做、支持 Win10 / Win11、Pro 两台不分平台、用那台没独显的 Win11 当测试机），没定的（配音、翻译、字体带多少、声音场景 Mac 不变 Windows 另做、中日文分词、素材库随不随包、商店、测试机情况），以及 Codex 的技术草稿（苹果框架替代表、模型与安装包大小、测试分层、R1–R12 探针、41–68 人周）。

- [2026-11-04 一个 PR 从本地到能合要多久：改之前和改之后](docs/reports/2026-11-04-ci-speedup.md) — 本地 24 分钟满载 → 1.5–3 分钟单核原生，PR 的 CI 10 分 55 秒 → 约 6 分钟（缓存热）、编 App 2 分 43 秒 → 15 秒；五个 PR 各改了什么、怎么量的、还剩什么。

- [2026-11-04 官方原创短片客户端接入](docs/reports/2026-11-04-official-film-client.md) — API 合同、生成接入、公开制作状态与后台验收逐项证据；客户端、服务端生产启用、真实视频和并发容量分开报告。

- [2026-11-03 MCP 发现与真实 Codex 选工具实测](docs/reports/2026-11-03-mcp-discovery-and-task-selection.md) — 50 → 55 项、已有导出参数、通知缓存与退出后 resume，四类真实需求的调用 / 任务 / 落盘结果；[脱敏调用证据](docs/reports/2026-11-03-mcp-discovery-evidence.json)保留实际参数、失败与有效重试。

- [2026-10-31 顶部工作台、统一设置与 MCP 验收](docs/reports/2026-10-31-workbench-settings.md) — 单排工具栏、五类统一设置、全 App 设置工具；2,686 项 MCP 检查、原子拒绝、双向同步、最小窗口与 AI 状态恢复的实际证据。

- [原生录屏方案](docs/plans/2026-08-06-native-screen-recording.md) — 产品目标与阶段方案；
  当前状态以实施报告为准。
- [原生字幕生成方案](docs/plans/2026-08-06-native-subtitle-generation.md) — SpeechAnalyzer、
  Translation、缓存与 macOS 15/26 分层。
- [定格方案](docs/plans/2026-08-08-freeze-frame.md) — 产品参数、提交模型、分辨率政策与
  已知代价。
- [转场库扩充](docs/plans/2026-08-23-transition-library.md) — 推移/擦除 8 种新转场的
  选型约束（预览斜坡能精确表达才收）与悬停预览选择器。
- [画面段的入场/出场动画](docs/plans/2026-09-18-clip-animation.md) — 产品决策（效果清单、
  吞掉画面渐变、不露边口径）、选型约束与分刀。
- [音频库（音乐 / 音效）](docs/plans/2026-09-22-audio-library.md) — 两个来源（R2 按需下载
  + 本地导入）、**只收 CC-BY / CC0 的授权政策**（SA 会传染给用户成片）、manifest 数据
  契约、试听流播与 ducking、素材筛选管线与分刀。
- [从 Finder 拖文件进轨道](docs/plans/2026-09-22-media-file-drop.md) — 拖到哪就落到哪、那儿占着就**往上抬一轨**、多文件首尾相接、类型不匹配横向照用纵向退默认轨，以及 ⌘V 粘贴文件；
  与 `addMedia`（没有落点的那条老路）的分工。
- [声音编辑：Logic 式波形、深度缩放、音量曲线、推子与电平表](docs/plans/2026-09-23-audio-mixing.md) —
  用户授权「按体验最丝滑的方式定」之后拍的全部板（曲线属于段、推子属于轨、常显贴线操作、
  总表放标尺行、M/S 这轮不做）及理由，外加三个探针的实测地基（`aeval` 必须在 `adelay`
  之前、Canvas 只画 `clipBoundingRect`、音频 tap 看不到音量且不能每次换 mix 都新建）。
- [导出面板改版：三行 + 高级](docs/plans/2026-09-24-export-panel.md) — 标题 / 导出至 / 分辨率摆在外面、其余收进「高级」，分辨率只降不升按短边、不再弹保存面板、撞名先提示再确认、记住设置加「恢复默认」；逐条拍过的板和理由。
- [插进两条轨之间 + 整条轨换位置](docs/plans/2026-09-24-track-insert-and-reorder.md) — 拖素材块 / Finder 文件 /
  音频库素材在缝上停 0.2 秒、缝拉开成 28pt 的窄缝再落进新轨（主轨下面不开缝、原轨只剩这一段时紧挨的两条缝不开）；
  按住轨道头拖整条轨换位置（学 Logic，调行高挪到下边缘，其余轨实时滑开）；逐条拍过的板和理由。
- [声音场景 + 成片声音改从预览混音读](docs/plans/2026-09-24-sound-scenes.md) — 选中有声音的段时给它套
  「喇叭 / 室内 / 室外」九个场景（海边不做：没有海浪声就和室外一样）、2–3 个通俗滑杆、余音越过段尾、效果排在段增益之后；
  先把成片的声音改成离线读预览那份混音（用户：「两遍效率很低」），之后声音功能都只做一遍。
- [预览性能 ratchet 方案](docs/plans/2026-09-24-preview-perf-ratchet.md) — 为什么数「活」不数 CPU
  指令（托管 runner 读不到计数器、CPU 时间差两倍的探针实测）、不挂自托管 runner、不许拿画质换数字、
  只许降不许涨（要加开销先在别处省回来）等拍过的板。
- [播放丝滑：播放头的每一跳只叫醒跟着它动的东西](docs/plans/2026-09-25-smooth-playback.md) — 用户说播放卡、
  授权「按体验丝滑的方式来优化」之后拍的板：左栏播放中冻住、停稳刷一次、不认悬停、点卡片作用在显示的那条缝；
  检查器播放中不跟、停下追上；工具栏按钮照样实时；字幕列表只在换句时重算；不拿 CPU 数字验收。
- [隐藏扩到所有块、回到开头、对齐线整套、字幕拆成两条独立轨](docs/plans/2026-09-26-hide-guides-independent-subtitles.md) —
  2026-09-26 一个 PR 里的五件事拍过的板；字幕独立轨那部分最细：译文有自己的 ID 和来源表、「过期」现算、
  两条轨画面上默认叠成一块（`translationLayout` 为 nil）、拖一条就分开、预览和烧录读同一份按时间切好的块、
  两个重译按钮各自动哪些句子。
- [时间线上的复制 / 剪切 / 粘贴 + 缩放以鼠标为中心 + 纵向缩放](docs/plans/2026-09-26-timeline-clipboard-and-zoom.md) —
  2026-09-26 用户逐条拍的板（撞上了照拖文件往上抬一轨、单独的纵向缩放用 ⌥ 捏合、只动视频 / 音频轨、
  纵向缩放时全部统一成一样高、工具栏缩放钉播放头）、讨论时列的默认做法，以及我定的实现细节（Z1–Z7、C1–C9）。
- [生成的字幕：去标点、按主流规范断句、同时有字只留一条、藏起来的不转写](docs/plans/2026-09-26-subtitle-generation-style.md) —
  用户看着南极工程提的四件事（重叠、藏起来的还在生成、字幕不该有标点、长句拆开）、先查清的事实（重叠两个来源、翻译是一条一条送的）、
  调研（Premiere / Resolve / FCP / 剪映 / Descript 怎么选声音和处理同时说话；Netflix 英文与简体中文、BBC 的数字）、
  逐条拍的板（跟随素材「先不用」、双语顺序「不改」）和我定的实现细节。
- [让 AI 调用 SrtFlow 剪视频：MCP 方案](docs/plans/2026-09-27-mcp.md) — PR #81 已合并（2026-09-29，main 40a16a5）：第一到第四块、第五块的 ①–④ 和扫画面里的字做完，随后模糊 / 马赛克块（PR #84）和第 6 块 fal.ai 生成（PR #85）也合进了 main（真实状态看实施报告）。2026-09-27 访谈拍的 28 条板 + 实测后补的 4 条（AI 改了没存过的工程自动存、默认位置不要「影片」没给文件夹放「下载」、第 31 条 AI 不靠外部工具——裁切 / 看 / 听做成 SrtFlow 自己的工具、第 32 条窗口一轮只摆一次），以及 2026-09-28 讨论工具上限时补的 4 条（第 33 条不按个数卡、守三条；第 34 条只有删文件才问、别处的文件问一次记住文件夹；第 35 条「连接」顺带放行客户端的权限；第 36 条 SkyStudio 的 MCP 以后另做、生成类工具提供方可换），和同一天讨论第 5 块拍的板（第 37–56 条：HyperFrames 不装、学它的长处自己做；逐词高亮字幕；剪辑风格 AI 自己挑、不做斜杠命令、中文叫「剪辑风格」不叫「套路」；配方卡中文稿；自存套路；配音三档 fal > 本机开源模型 > macOS；本机模型用 CoreML 不用 MLX、听完样音选 Kokoro、八个角色的音色、模型放我们的 R2；克隆放第 6 块走 fal；五刀的顺序；AI 改字幕样式只改当前工程、第 ④ 刀之后插「扫画面里的字」和模糊 / 马赛克块），以及 2026-09-29 第 6 块动工时追加的两条（第 57 条：视频只用 `minimax/h3-max/`、加音乐音效、预设只用最新的模型；第 58 条：花钱超了额度在提示条上问、配旁白同步不问、额度不够退档）：
  第一期 Claude + Codex（ChatGPT 聊天框要隧道、用 Codex 代替）、除录屏外全部功能、默认看得见（每步定位高亮）、
  ⌘Z + 撤销这一轮、只有动硬盘才问（后来收成只有删文件才问）、本机 Vision 识别画面、按文字剪 / 删静音 / 踩点、剪辑套路（MCP Prompts）、
  fal.ai 生成（每日上限）；架构（`srtflow-mcp` 只传话、干活的只有 App 本体、协议自己写不引 SDK）、六块分块与两个真实验收任务。
- [剪辑风格：五种预设风格（中文稿）](docs/plans/2026-09-28-mcp-recipes.md) — MCP 第 5 块的剪辑风格内容：怎么用（AI 自己挑、一句话告诉用户、用户的话优先）、
  所有剪辑风格共用的规矩（先摸清素材、先问平台、9:16 安全区、字和声音的口径、不编造、导出前自检）、带货 / 课程推广、电影开头、科幻、纪录片、
  日常 vlog 五张卡（画幅、时长、按秒的结构、镜头、转场、动画、滤镜、字体、字幕、配乐、配音、自检）、配音音色的角色表、要补的零件、给 App 用的 .md 格式。
- [导出真峰值限幅 + 响度报告，关键帧缓动](docs/plans/2026-09-30-export-limiter-and-easing.md) — 2026-09-30 用户拍板「先做 1 和 2」：
  写 f32 之前把硬削换成流式真峰值限幅器（−1 dBFS、前瞻 5 ms、释放 80 ms、总长不变）+ BS.1770 整段响度只报不归一（面板一行、`get_job` 四个字段）；
  关键帧加 `easing`（linear / easeIn / easeOut / easeInOut，AI 默认 ease_in_out、手打默认线性）、预览按帧加密切片；检查器曲线选择器单独一个小 PR；
  然后出 Beta 0.18.5 让用户真剪。
- [音效：合成器（给 AI）+ 录音素材库（给用户）](docs/plans/2026-09-30-sound-effects.md) — 2026-09-30 用户拍的板：合成器先在 scratchpad 渲样音试听、点头才写产品代码；
  AI 先搜素材库、没有再合成、真实声音才走 fal；63 个 SouthPole 录音全收进 R2 素材库（默认不随 App 带）、授权加「自有 / 已授权」一类；
  三个 PR 的分刀、`hit_at` 落点、原型里学到的（Freeverb 湿声按干声峰值比例混）、决策门。
- [预览和成片的声音：自己的音频引擎（播放 / seek 无感）](docs/plans/2026-10-01-audio-engine.md) — 2026-10-01 用户拍板：大工程播放中点时间线等 1–1.5 秒、
  按空格播放头 0.5 秒才动，压力测试量到 AVPlayer 的合成「每条音轨 40 ms、串行、参数无效」是固有开销；自己做音频引擎
  （AVAudioEngine 做图 / 设备 / 求和，自己写按游标取样 + 增益 / 渐变 / 曲线 / 推子 / 场景 / 电平的渲染核心，每轨后台解码预读、
  **不缓存**，22 轨 seek 9 ms）、成片同步切到引擎离线渲染、视频留在 AVPlayer 只做优化媒体；全部数字、架构、时钟对齐怎么验、
  每个功能怎么搬、三刀、风险；用户看过再动代码。
- [预览的画面：优化媒体（长 GOP 的源转成密关键帧的代理）](docs/plans/2026-10-01-video-optimized-media.md) — 音频引擎之后的下一刀（用户看过再动代码；V1–V3 都已合进 main，2026-10-01）：
  探每个源的关键帧间隔 + 这台机器的解码速度，只转长 GOP 的源、只转时间线用到的块（源时间 10 秒一块）、原分辨率 H.264 0.5 秒一个关键帧无 B 帧、
  4K 减半、HDR 出 HEVC Main10；builder 按段换源、转好之前照用原片、停着时才换；预览窗口「优化媒体 / 原片」默认优化、成片永远原片；
  缓存 ~/Library/Caches 上限 10 GB、LRU、30 天不用自动删；探针数字（关键帧 0.5 秒 → seek 27–36 ms）、自检、三刀。
- [视频 upscale：轨道上的片段一键送 fal 放大，比过再换](docs/plans/2026-10-02-video-upscale.md) — 2026-10-02 用户拍的 16 条板（画布自由选、带余料、换当前工程里用到的所有处、
  文件名 `<原名>_<宽x高>_<档位>.mp4`、做完先弹对比窗口点 Replace 才换、留 Topaz precision / generative + FLUX + 字节 standard / pro），实测定下的事实（声音要自己封回去、帧数要核对），
  四刀的分法（地基 / 换源 / 任务 / 界面）。
- [联动：主轨块挪到哪、删没删，压在它上面的东西跟着走](docs/plans/2026-10-02-timeline-linkage.md) — 2026-10-02 用户要「和剪映一样」、授权我按用户体验定全部细节：
  跟着画面走不跟块的 id（分割 / cut_speech / 定格切出来的新 id 照样认）、完全在一段里的才跟、跨段的全部挪同一个量才跟（配乐铺整片永远不被顺手删掉）、
  只有真删才连带删（裁切让画面没了的留在原地）、单向、撞上让开、同一个开关语义扩大且默认改成开、AI 按开关走、一处收口（`perform` 收尾）；
  场景表就是自检的用例。
- [界面语言：加西班牙语、法语、土耳其语，按系统自动选](docs/plans/2026-09-30-ui-languages.md) — 2026-09-30 用户定：「按系统自动选」本来就有（`.system` + 包里的 `.lproj`）；
  先一个 PR 把枚举和守卫改成任意多种语言，再先做西班牙语一种在真窗口看排版、之后定法语 / 土耳其语；泛化的 `es` / `fr` / `tr`；
  译文由 AI 出、**用户不做审核、直接算正式、不标 Beta**；复数和小数点先照英文。风险：法 / 西比英文长两到三成而检查器是窄栏、每个 PR 从此要给每种语言译文。
- [让 AI 录屏：record_screen](docs/plans/2026-10-03-screen-recording-mcp.md) — 2026-10-03 用户要「把录屏相关的所有功能变成 MCP」、拍板 AI 自己选来源
  （没授权弹一次、授权后 SrtFlow 不再弹任何窗口；macOS 自己约 30 天的提醒关不掉）、开录不问、AI 能一边录一边操作电脑；我定的十条（浮窗放左下角、录制中不摆窗口、
  残缺的不弹框照样落地、从不覆盖、停止 = 留着、丢弃先问进废纸篓……）、查清的事实、分刀。
- [剪辑美感：先把审美写下来，再补零件，最后做画面特效](docs/plans/2026-10-05-editing-aesthetics.md) — 2026-10-05 用户说 AI 剪出来
  「质感、美感很普通」、看过分析后「按你的建议来」：为什么普通（卡只写用量、画面层只有三种斜坡、AI 只看静帧不查美感）、
  从 HyperFrames 的技能文件学到的（带数字的品味规则、标杆和交片前自查、先分镜后动手）、拍的板（先写导演手册式的卡；分镜表
  发了接着做；参考片只量用户给的文件、不从网上下；像素层特效先走「特效那一小段预渲染」的探针；审美回归集盲选）、分刀，
  以及《起义》那个链接为什么不下载、Greengrass 式的「我的风格」怎么来的。
- [第三批 AI 反馈：字幕行距、入点说明、一次检查 V1 的剪辑点](docs/plans/2026-10-16-ai-feedback-line-spacing-and-cut-check.md) — 2026-10-16 用户转来测试员的
  第 8–10 条、定「按你的建议来」：三条都做、顺序 9 → 10 → 8 各一个 PR；检查剪辑点做成 `listen cuts=true` 不另开工具（只查 V1、转写只读缓存、
  相邻的两段合成一个剪辑点）；字幕行距是倍数 1–2、下限 1，烧录用一行很矮的空行当垫片（ASS 没有行距、只能加大）且必须真烧量过，工程文件不 +1 版本；
  圆体挨得紧的量化原因（win 量度 1.008 em vs 苹方 1.400）。
- [AI 多开：一个 AI 会话同时剪几个工程](docs/plans/2026-10-17-multi-project-ai-editing.md) — 2026-10-17 用户拍的十条板（工具带可选 `project`、
  `open_project` / `new_project` 回 p1…、不给 = 这个会话最后打开的那个；`close_project`、封顶 8 个；看得见的工程开时摆一次窗口；停止 / 撤销按工程；
  版本名；`get_job` 报队列位置；一个会话一组工程、别人的不许碰；headless = 0 个窗口、主窗口「AI 在剪的工程」列表；要点头的走聊天里的确认码；
  清单上限抬到 100,000），我定的细节（同一个文件只开一份、主窗口空着才装进去、别的会话安静 5 分钟算放手、路由按工程排队、工作区文件夹按工程、
  每个工程自己的撤销管理器先探针、`set_view` 不带 project 也改开着的），四刀各拆两个 PR。
- [改名 SkyCut](docs/plans/2026-10-18-rename-to-skycut.md) — 2026-10-18 用户拍板：名字 SkyCut（和 SkyDict、SkySheet 一个家族；看过没选的几个和理由）、
  只改用户和 AI 看得见的那一层、bundle id 和代码名沿用 SrtFlow、MCP 服务器名改 `skycut`、新工程用 `.skycut` 老的照开、AI 的子文件夹改名但已有的
  SrtFlow 子文件夹接着用、只有用户自己装着所以不写迁移代码；分两个 PR，外加本机收拾的顺序（装新包删旧包、重新注册 MCP、GitHub 仓库改名、
  代码目录挪到 `SkyStudio_APP_Master/SkyCut/`、Claude Code 的记忆目录跟着改名）。
- [收费：体验版、导出水印、MCP 门槛，生成改用 Sky Studio 的 key](docs/plans/2026-10-27-paid-plans-and-sky-studio-key.md) — 2026-10-26 / 27 用户拍的 20 条板：
  软件授权和 Sky Studio 积分都卖、B 端学电商 ERP（席位 + 积分 + 开通服务、年付、前几个客户手动开通）、仓库先公开省 CI、不限分辨率、没付费的导出带 Sky Studio logo 水印
  （四角 + 正中随机跳）、MCP 是付费核心、服务器下发 `mcp` / `watermark` 开关、体验默认 7 天且改默认不影响已在体验的人、一把 Sky Studio 的 `sk-` key 管授权和积分、
  接口放 Sky Studio 网站仓库的 `api/skycut/v1`（用户另开窗口做）、Sky Studio 接好后删掉自带 fal Key 那条路、upscale 和 Sky Studio 网页同一套上限（一次最长 30 秒、
  两头的余料算在里面，最高 30 fps，服务器在 `/models` 里报、SkyCut 不写死）、先做 B 端（C 端先只写开通的邮箱 support@skystudioai.com、不开网页，导出面板那一行不拦导出）、
  体验每台 Mac 一次、每个账号一次；两边的分工和七刀（第 5 刀拆成 5a 账号 / 5b 照开关拦，5b 合进去先关着、10-28 接口上线后打开），以及 Sky Studio 定稿之后 SkyCut 要跟着改的（没有长轮询、只能取消排队中的、
  成品永久进作品库、同时最多 3 个任务、`/quote` 每种都报、克隆一次送多句再在本机切开、旁白的时间是字符级）；2026-11-05 / 06 加「自助购买 Pro」（第 21–38 条）：
  **2026-11-06 已上线**：Sky Studio PR #238 已合并并发布至 6 个正式域名，官网 PR #325 已合并发布价格与购买入口；SkyCut 客户端 #319、#321–#323 已随 0.18.59 于 2026-11-06 发布，本机 App 同日已更新到 0.18.61。
  第 34 条的积分包调整（恢复每档一个按钮，有存卡一键付款，否则到 Dodo 自选付款方式，地址照旧、结账语言跟网站）与第 37、38 条（购买页价格按语言、切换方案自动关闭未付旧结账）已随 Sky Studio PR #239 于 2026-11-06 上线。
  只有一个 Pro、银行卡月付 $19 / ¥129 和年付 $149 / ¥999 订阅、一次性的一年只给微信（Dodo 的微信 / 支付宝香港都不能自动续费）、不退款只能取消续费、不含税、
  微信一次性款超限时的含税例外、扣款失败才有 7 天宽限（单独的 `grace_until`，补交后到期日照 Dodo 的新周期）、不会续费的到期前 7 天在 SkyCut 里提醒、Dodo 后台的设置、软件费和积分分开、月付不送年付每年送 1,000、
  Pro 记在 Sky Studio 账号上（Key 只认人、按登录的账号 id 不按邮箱）、一个 Pro 默认最多 2 台 Mac（按机器号数、和 Key 无关，商务可后台调）、结账语言跟网站、Pro 按微信 / 其他方式分地址入口、没有外部老用户所以不保护不回填、拒付只记账 + 人工复核、商务按 pro_source 写邮箱续约，以及两边要做的事。
- [AI 接口（MCP）第一块实施报告](docs/reports/2026-09-27-mcp-slice1-report.md) — 23 个工具做到了哪、CI 与端到端实测的证据、测试版怎么出（`scripts/build-beta-app.sh`）、过程中修掉的事（撤销分组、提示条位置、文字折断、翻译语言与下载引导、自动存盘与默认位置）、还差什么（第二块起的功能、Claude 桌面版 / Codex 要用户点「连接」）。
- [AI 接口（MCP）第二块实施报告](docs/reports/2026-09-27-mcp-slice2-report.md) — 第二块起手「AI 的手和眼」（方案第 31 条）：`edit_clip` 的画面放法、去黑边、对准主体、`look`、`listen`、总说明里不用外部工具那一句，窗口一轮只摆一次（第 32 条）；然后现有功能铺满（后台模式、读文稿、整理文件、访达选中、剪辑的其余设置、推子关键帧、形状、复制、定格、音乐库、压缩烧录转换，工具 23 → 37 个）；每一刀的 CI、本机自检、测试版冒烟的证据，过程中撞上的事（三个老 bug），还差什么。
- [AI 接口（MCP）第三块实施报告](docs/reports/2026-09-28-mcp-slice3-report.md) — 分析数据 + 智能剪：`transcribe`（词级时间，和生成字幕同一套 `TranscriptHarvester`）、`listen beats=true`（鼓点）、`cut_speech`（按文字剪、删停顿、口头禅、说重了）、`cut_to_beat`（音乐踩点），工具 37 → 40 个（到预算）；CI 与测试版冒烟的证据、撞上的事（切开之后链接成对、new_audio 接在 A1 后面两个老 bug），还差什么（音频库没有鼓点清楚的音乐、转写要 macOS 26）。
- [AI 接口（MCP）第四块实施报告](docs/reports/2026-09-28-mcp-slice4-report.md) — 本机识别画面：`look shots=true` 分镜头（切点学 PySceneDetect、整个文件扫一遍缓存、长视频走任务）、`look files` 一次看 24 个文件、`edit_clip fit=fill` 跟着人走（位置关键帧、换镜头跳过去）；解码速度和切点的探针实测、测试版冒烟（素材A 47 个镜头、14.6 分钟的课 130 个镜头）、跟拍第一版乱晃怎么改的、还差什么。
- [AI 接口（MCP）第五块实施报告（进行中）](docs/reports/2026-09-28-mcp-slice5-report.md) — 剪辑风格 + 配音 + 逐词高亮字幕：第 ① 刀剪辑风格与零件（recipes / save_recipe、实心形状 v24、set_text 补参数）、第 ② 刀 macOS 配音（add_voiceover，词的标记只从代理方法来、语速按实测表换）、第 ③ 刀 Kokoro 与 Qwen3-TTS 的 CoreML 探针（M1 上 Kokoro 实时 10 倍、Qwen3 实时 0.2 倍、段尾逗号让 Kokoro 冒杂音）、用户选 Kokoro 之后接进 App（模块、R2、八个角色、按字 / 词的时间）、用户试用撞上的爆音、**⑤ 验收实剪第一轮**（AI 剪了两条，撞出的十几件事逐条怎么处理的、哪些等用户听、哪些功能等拍板），还差什么（第 ④ 刀起的顺序见方案第 54–56 条）。
- [Sky Studio 生成与配音真实验收](docs/reports/2026-10-29-sky-studio-generation-and-voice.md) — 6b 五类、6c 旁白 / 合批克隆 / 排队退款、累计积分账、固定签名 Beta 与检查证据。
- [视频 upscale 实测：六个 fal 模型、八个档位、19 条真素材](docs/reports/2026-10-02-upscale-smoke-test.md) — 2026-10-02 南极工程上真跑：每条的帧数 / 耗时 / 估价 / 实收 / 账单 units，
  三家的计费规律（字节按秒精确、FLUX 按像素·秒线性、Topaz 按 unit 且台阶没公开）、只有 FLUX 原样保留声音、FLUX ±1 帧、上传要 `fal-cdn-v3`、画质印象。
- [AI 接口（MCP）第六块实施报告](docs/reports/2026-09-29-mcp-slice6-report.md) — fal.ai 生成：用户定「视频只用 minimax/h3-max/、加音乐音效、只用最新的模型」之后的模型表、Key（钥匙串）、每日上限与提示条上先问、`generate_media`、清单按 Key 列不列、配旁白的 fal 档与克隆；证据（373 + 1132 项、反向验证、端到端冒烟）、撞上的事（取消发不出去、钥匙串授权框、冒烟把文件放进了下载文件夹）、没对真 fal 验过的、等用户拍板的（钥匙串授权框取舍、默认模型）。
- [第三批 AI 反馈的测试版冒烟（0.18.35）](docs/reports/2026-10-16-ai-feedback-batch3-smoke.md) — `listen cuts=true` 在 L30 口播上的五个剪辑点怎么报、照建议改完撞出的
  quiet_spot bug；字幕行距 1 → 1.3 预览第一行上移 21 px、成片和预览两行上下沿差 ≤ 2 px；这台 Mac 的圆体进不了烧录字体清单。
- [字幕默认单行 + 行数开关的测试版冒烟（0.18.37）](docs/reports/2026-10-16-subtitle-line-count-smoke.md) — PR #222 合并后真机过一遍：`max_lines=3` 报错、默认 59 条全单行、`max_lines=2` 39 条 / 19 条两行且框报 `lines: 2`、撤销两步各退一层；面板拨到「2 行」生成和 AI 那一路一样、工程文件写进 `subtitleMaxLines: 2`；面板下拉两套自动化都点不了、是用户点的。
- [AI 多开第 ① 刀的冒烟（0.18.38）](docs/reports/2026-10-17-open-projects-slice1-smoke.md) — 拆单例 + 工程窗口合进 main 之后：两个工程窗口按键 / 撤销 / 开关 / 关窗各管各的
  （进程内驱动；第一次跑撞出「先放内容后挂 delegate、撤销撤不到工程」并修好），装好的测试版上 AI 单工程的老流程（建、放、加字、撤销、看、导出、存）全通；
  Rosetta 终端里打包要用 `/bin/bash`；还没验到的留给第 ② 刀。
- [AI 多开第 ② 刀的冒烟（0.18.39）](docs/reports/2026-10-17-ai-project-routing-slice2-smoke.md) — 一个会话开两个工程：不带 project 的落在最后打开的、
  两个文件夹里同名的 C0001.MP4 各进各的工程、导出中关工程被拒、撤销这一轮只退一个工程；另一个会话碰不到 / 开不了 / 取消不了别人的；撞出 open_folder 报旧
  output_folder（#232 已修）；点不了横幅上的停止（自动化工具没授权），留人工回归。
- [AI 多开第 ③ 刀的冒烟（0.18.41）](docs/reports/2026-10-17-ai-headless-slice3-smoke.md) — 后台工程（0 个窗口）开 / 建、放素材、看、导出、挂上窗口后撤得到
  后台时的那一步、摘回后台、关掉都对；fal 确认码用假 fal 跑（17 过 1 没验到）；锁屏时 CG 的屏幕上窗口列表不更新、别拿它判断窗口关没关；侧边栏和用户操作
  那几样屏幕锁着没验到，留人工回归。
- [AI 多开第 ④ 刀的冒烟（0.18.42）](docs/reports/2026-10-17-ai-queue-version-slice4-smoke.md) — 一个文件夹两个版本：第二个工程不给 `version` 被拒、
  给了叫「Trip cut - vertical」；连着四个导出一个接一个（`queue_position` 1 / 2 / 3）、排着的取消不写文件、版本名不叠、撞名加编号；生成字幕也排队；
  没撞出新问题，方案四刀到这里做完；面板导出和 AI 排着的交替留人工回归。
- [AI 多开补测：屏幕亮着把界面那几项走一遍（0.18.42 → 0.18.45）](docs/reports/2026-10-18-ai-multi-project-ui-smoke.md) — 四刀冒烟时屏幕锁着留下的界面项
  补测：两个窗口各自 ⌘Z / 空格 / ⌫、编辑菜单跟着键窗口、横幅停止只停一个、撤销这一轮只退一个、关窗转后台 / 安静 5 分钟后真关、新建 / 打开开到新窗口、
  面板和 AI 排队、翻译排队、后台模式不开窗口；撞出三个问题并修掉（#241 侧边栏的行出不来、#242 导出进度显示在每个窗口还能停别人的、#243 侧边栏一行截字 /
  排队写成导出中）；怎么在用户用着电脑时测（常驻会话、辅助功能、按键只发给测试版、切前台等空闲）；用户离开后用真鼠标补完右键菜单、悬停提示、
  真录屏落进工程、⌘O 开到新窗口（中文输入法下改系统打开面板的「前往」框会让面板服务崩，要先切 US 布局）。
- [第四批 AI 反馈的测试版冒烟（0.18.46）](docs/reports/2026-10-18-ai-feedback-batch4-smoke.md) — #246、#248 合进 main 之后在 L16 测试工程上真跑（后台模式、不开窗口）：max_width 0.6 下五句全断在词组边界、预览和成片抽帧一模一样；77.417 报 on_speech / available. / 77.75，照改再查 in_pause；另外两个入点也切在上一句的尾音上；cut_speech 剪同一刀挪到 71.75 / 77.75，完整转写下检查的建议和它一字不差（只转写几段时入点差一帧：转写窗口切进半个词）。
- [改名 SkyCut 之后的冒烟（0.18.47）](docs/reports/2026-10-18-skycut-rename-smoke.md) — 装好的正式版和测试版：TCC 里录屏和下载文件夹的记录新包全部核得过（不用再授权）、双击 `.skycut` / `.srtflowproj` 都交给 SkyCut.app、Claude Code 连得上 `skycut`、设置和数据文件夹都在；测试版后台真跑：新文件夹存 `SkyCut/…/*.skycut`、老文件夹接着用 `SrtFlow/`、老工程原名存回去、报错是新措辞；**菜单栏的 App 名取可执行文件名**（不是 CFBundleName），没发现 App 的问题。
- [真 Codex 连 SkyCut 的冒烟（0.18.47）](docs/reports/2026-10-26-codex-client-smoke.md) — 第一次用真的 Codex（命令行 0.147、最便宜的 GPT-5.6-Luna、低推理）：设置里「连接」写对配置、
  断开后逐字节还原，12 步（开工程、后台、看、听、读字幕、加字、导出、看成片）约 60 秒全通，Codex 看得到 `look` 的图（问只有图里才有的东西才分得清）；
  每次调用约 2.7 万输入 token（整份清单每轮都发），免费版撑不完一次完整剪辑；撞出两个问题：工具悄悄丢掉不认识的参数（`set_text` 的 `end`）、连接时留的配置备份权限变宽。
- [测试版 0.18.48：导出水印和 Claude 桌面版「连接」的冒烟](docs/reports/2026-10-27-beta-watermark-and-claude-desktop-smoke.md) — 装好的测试版导出就带水印
  （16:9 每 4 秒一段逐帧和原片比、落点和大小对表；9:16 看图）；Claude 桌面版连接 → 重启 → `Connected to skycut (48 tools)` → 断开还原，备份和原配置同为 600；
  View → Reload 不重读配置要真重启、它自己会改这份配置、「断开」内容一样字节不一样；聊天里真调工具留给用户。
- [原生录屏实施报告](docs/reports/2026-08-06-native-screen-recording-implementation-report.md) —
  Phase 0–5 的真实进度、实测证据、偏差和未完成项。

## 架构与长期约束索引

- [MCP 说明书（skycut_guide）](docs/architecture/mcp-guide.md) — 按需读的工具说明：App 照 recipes 的路子答、没开通也照答、清单里第一个且只有它预先加载（`anthropic/alwaysLoad`）；每个工具一个同名主题（概要 = 现在的说明原文、`fields` 从参数定义现算）、目录 ≤ 5,000、一次 ≤ 6,000 且长的分节、写错的回目录 + 猜的；迁移七个 PR 做到哪、守卫、反向验证、人工回归。

- [SkyCut 官网](docs/architecture/skycut-website.md) — `website/`、C 版四语言与三端排版、Three.js 首屏与三个 AI 流程、首屏的质感与渐进增强（烤好的静图是默认画面、实时场景什么时候接手和让位、帧预算、出血、重烤与指纹、浏览器级手动检查）、样式表的先后（构建按共用关系分块、不保留挂的顺序，每份样式表自带自己的媒体查询）、小字读得清（手机上 ≥ 12 px、演示区对比度 ≥ 4.5:1、标题不跳级、行高写死）、南极视频和七种字幕、Sky Lu / Sky Studio 身份与 SEO / sitemap、GEO（robots 对 AI 爬虫全放开、生成的 `llms.txt`、`lastmod` 只写真改过的那天且改了页面要跑 `npm run stamp:pages`）、文章栏目 Guides（文章是 `content/guides/<slug>/` 里的文件，多繁中、日文两种只给文章用的语言；没写发布日就是草稿、发布日用 `npm run publish:guides` 盖；价格不许手写、只链自己的页面、**对外不提 GitHub**；部署后跑 `npm run indexnow`）、本地预览与合并后部署、Free / Pro 功能对比、模型快照、角色系统与积分标记、年付折合和真实标价、Google 表格邮箱登记、Apps Script 合同与本地假服务验收、Zoho 品牌邮件。

- [MCP 功能发现与升级后的重连](docs/architecture/mcp-discovery.md)：分别核对 App、helper 与客户端实际 schema；需求对应工具、最小示例、重连与真实客户端验收。

- [写代码的规范](docs/architecture/coding-standards.md) — 模块化的六条（一个文件一件事、抽有名字的顶层类型、
  别开只有 extension 的文件、纯计算和副作用分开、同一规则只有一处实现、函数别太长），单文件目标 400 / 上限 600
  行与老文件只许降的基线、审查清单。
- [开着的工程（OpenProjects）](docs/architecture/open-projects.md) — 2026-10-17 起工程不再是单例：注册表持有开着的全部工程（主窗口那个 `primary`、
  工程窗口里或后台（没有窗口、不建预览，第 ③a 刀）的 `others`、菜单作用的 `focused`、退出要问的 `all`、最多 8 个、同一个文件只开一份）、只许它建工程；短 id 一次运行不重用；工程代号全 App 一个计数
  （跨对象当身份比较，各自从 0 数会撞号）；撤销：工程窗口由 AppKit 建、delegate 交出工程自己的（先挂 delegate 再放内容），主窗口是 SwiftUI 的、改不了（探针），
  不许退到键窗口的；工程窗口里按键、时间线几何、录屏框、upscale 面板只认自己的，开关和「优化 / 原片」全 App 一份；关工程的收拾、换 / 关一个工程只停它自己的活；
  后台工程不建预览、关 AI 在剪的工程窗口转后台、侧边栏「AI 在剪的工程」（停止 / 打开窗口 / 关掉）、用户在 AI 正剪着的工程上新建 / 打开开到新窗口；
  谁该找哪一个工程的表；守卫、探针、冒烟与人工回归。
- [签名与系统权限](docs/architecture/code-signing-and-permissions.md) — 2026-10-03 起发布版和测试版用一把固定的自签名证书「SrtFlow Signing」签：
  系统权限（录屏、麦克风、下载文件夹、钥匙串）按签名记账，ad-hoc 的每个新版本都是「另一个 App」，录屏那条拨开关都救不回来（TCC 只改开关、不换钉着的签名）；
  私钥在仓库外 `~/.config/srtflow/signing/`、仓库钉证书的 SHA-1、永不重建；签名只经 `sign-app.sh`（签名那几秒把专用钥匙串挂上搜索列表）；
  App 每个构建最多删一次自己的录屏记录再请求；第一次换签每台机器再授权一次；**钥匙串例外**：没有 Team ID，分区名单按代码哈希记，每个新构建第一次读 Key 仍要输一次密码（2026-11-07 更正）；守卫与人工回归。
- [产品名与代码名](docs/architecture/product-name.md) — 2026-10-18 起看得见的叫 SkyCut（App、可执行文件、DMG、界面和权限弹框的文案、给 AI 的话、
  MCP 服务器 `skycut`、小程序 `skycut-mcp`），身份沿用 SrtFlow 且永远不改（bundle id、UTType、签名证书、钥匙串、UserDefaults、数据文件夹、AI 通道、
  环境变量）、代码名沿用 SrtFlow；为什么（授权按 bundle id + 证书认、数据在老文件夹里、老会话的小程序要连得上）、规矩、守卫与人工回归。
- [AI 接口（MCP）](docs/architecture/ai-control-mcp.md) — 三段结构（客户端 → `skycut-mcp` → App，活只在 App 里做）、工具清单只有一份且小程序给、不按个数卡守三条（不许两个长得像、只读和写文件不混、说明总长度有上限）、选项词表抄一份就要对账、两代协议（老的 initialize / 新的 `_meta` + `server/discover`）、通道（按 bundle id 分 socket、一次调用一条连接、不抢别人的 socket、阻塞收发只在自己的线程上）、工具在 App 里的十三条规矩（一个工具 = 一步撤销、复用手动操作的规则、排队、看得见但不抢键盘且一轮只摆一次窗口、不许弹模态框、只有删文件才问（读别处的文件问一次、记住文件夹；撞名加编号）、长任务回任务号、AI 看不见就替它量、短 id 与 V1/A1 轨道名、做出来的文件放哪、画面怎么放（铺满 = 窗映满画布）、look 看、listen 听，第 4 块的分镜头、一次看几个文件、铺满跟拍，第 5 块的剪辑风格（AI 自己挑、内置卡在资源里不用 Bundle.module、用户的存 Application Support、卡里的名字必须存在）与配方卡要用的零件、配旁白（按角色挑声音、词的标记只从代理方法来、语速按实测表换、字幕走生成字幕那一套），SrtFlow 自己的声音（本机的 Kokoro：模块从 speech-swift 搬来改过、模型从我们的 R2 下载并核校验值、按字切 token 拿到每个字的时刻、在第一段安静处切掉尾巴杂音））、总说明里「只用 SrtFlow 的工具」、这一轮 / 停止 / 撤销这一轮、「连接 AI」三个客户端各用什么办法（连上顺带放行工具）、人工回归清单。
- [视频 upscale](docs/architecture/video-upscale.md) — 轨道上的片段送 Sky Studio 放大（2026-10-02 起送 fal，2026-10-28 起送 Sky Studio、花积分）：模型和上限从 `/models` 读（`topaz-starlight` / `bytedance-upscaler-pro`，一次最长 30 秒含余料、最高 30 fps），价问 `/quote`；范围三选一带余料按原片算、放不下先少留余料、裁出来的只有画面（`MediaReadQueue.export`）、送上去之前探那个文件当 `params.source`、上传 / 排队 / 下载、成品的声音一律不要（ffmpeg 把原片那一段封回去，HEVC 点名 hvc1）、`<原名>_<宽x高>_<模型>.mp4` 放原片旁边撞名加编号、做完不替换（对比窗口里点替换才换源）、面板上的报价就是确认、AI 起的过每日积分上限、做完按实收改账、没花出去的退回、中间文件不留；回归与人工清单。
- [优化媒体](docs/architecture/optimized-media.md) — 预览画面的代理（2026-10-01 V1 + V2）：关键帧间隔进 `MediaInfo`（老工程缺键 = 不知道，打开时补探不标脏）、解码速度按机型记、只转长 GOP 且一个 GOP 要解超过两帧时间的、原分辨率 4K 减半、H.264 0.5 秒一个关键帧无 B 帧只有画面、**经视频合成读、块的轨从块头盖到块尾**（变帧率的录屏静止期一帧撑住）、源时间 10 秒一块、缓存按路径找按身份认（改参数 +1 版本、10 GB LRU、30 天过期）、读和编只在 `MediaReadQueue`、10-bit / HDR 第一版不转；**换源只换画面不动时间账**（`CompositionClipInsert`：格子相加正好、差一块 / 插不进去退回原片、几何按插进去的源轨算）、**只在停着时换、某段的块齐了才换、最多 3 秒一次、先转播放头附近的**、切工程作废、一个源转不了就用原片（只在菜单里标，不进提示条）、「优化媒体 / 原片」记 UserDefaults、性能台架量原片、协调者只有菜单订阅、成片 / 预渲染 / AI 看永远原片；**V3（设置里的「优化媒体」一节）**：上限十进制几档、键只经 Store、改小当场 enforce；启动时 proxy 队列上过期 30 天没用的；清空 = proxy 队列上删 → 协调者 `reset()` → `scheduleRebuild()`（不然表上写着「齐了」就不再排转码）、`removeAll` 只许那一处调、不弹框；设置那一节只订阅自己的小对象；还没做的；人工回归。
- [音频引擎](docs/architecture/audio-engine.md) — 时间线的声音只有这一份：预览实时播、成片离线渲（`Sources/SrtFlow/AudioEngine/`；2026-10-01 PR3b 起 AVPlayer 那条声音路删了，播放器的合成里只有画面）：配置是从时间线算出来的纯值（自己排序、展开转场；增益表 `AudioGainTable.swift`）、播放头只是几个数（锚点）、渲染块实时安全、喂样在普通线程、一段一条流、不缓存、离线和实时同一张图；声音是主时钟、视频 `setRate` 钉到引擎；配乐比画面长时 builder 垫黑底铺到总长；电平表是无锁槽；引擎的时钟只从渲染块的时间戳来（声卡 44.1 kHz 的采样时间不能拿来算 48 kHz 的位置）；自检对着纯 Swift 的 oracle 混音器比。**2026-11-11 起图不是一直开着的**（第二节第 11 条：占着声卡 = Mac 不睡、App Nap 不生效）：没有声音不开、停着 2 分钟没人用就停、用户回到 SkyCut（变成活动的、窗口变成主 / 键窗口、鼠标移进窗口、按键）就在后台先起好、离开 2 分钟以上回来第一下就是播放时当场起并从原处开播；量出来的数（回来先有动作的和一直开着一样，冷着按画面和声音一起晚 0.15–0.3 秒、开头不少）、为什么是 2 分钟、睡眠断言和 App Nap 的前后对比、为什么不能让播放头先走（起声卡拖住整个进程）。
- [fal.ai 生成](docs/architecture/fal-generation.md) — Key（钥匙串：只读属性不弹框、读密钥每个新签名弹一次、`.silent` / `.interactive` 两档、`FalKeyCache` 一次运行最多弹一次、别改成 `LAContext`）、每日上限（只设每天的、额度内不问、超了 / 价格不明先在提示条上问、决定和记账同一步、没做出来的退回）、模型表（2026-09-29 用户定：视频只用 `minimax/h3-max/`、其余各类当前最新的；挑法、价格、更新办法）、请求体对着接口定义快照验、队列接口（照 fal 给的地址、取消要在 detached Task 里发）、`generate_media`（任务、成品放哪、不改工程；2026-10-28 起走 Sky Studio，这一节成了历史）、历史上清单跟着 Key 走（2026-10-30 已替代：始终列全，执行时核对授权；现行合同见 Sky Studio 的任务）、配旁白三档与克隆、已知不足（真 Key 第一次要对的六条）、回归与人工清单。
- [合成音效](docs/architecture/sound-effect-synth.md) — SrtFlow 自己合成的 16 个剪辑动效音（AI 用 `add_clips` 的 `sound_effect`）：落点 `hit_at` 是合同（自检钉 ±25 ms）、混响按干声峰值比例混、峰值 −1 dBFS + K 加权 ≤ −9 LUFS、同参数同种子同文件（改声音要 +1 version 并再给用户听）、默认都短、写文件只经 `AIAudioFileWriter`、渲染在 `MediaReadQueue.analysis`；riser / downlifter 照 ElevenLabs 参照量出来的形状做。
- [声音库：克隆的参考录音、声音库的工具和界面、变声](docs/architecture/voice-library.md) — 2026-11-10 起（声音 PR 2）：参考录音是 44.1 kHz 单声道 16-bit WAV、至少 10 秒有效人声、最长 3 分钟（终点在 3:00 前后 1 秒、不到 181 秒），用途 `voice_reference`；有效人声 = 20 ms 一格、均方根 ≥ 0.0056 的整格（≈ −45.04 dBFS；和服务器的合同，服务器放宽到 0.0055，常量单独写死、不借 `AIVoiceLevel`）；超过 3 分钟挑人声最多的一段（一样多比前 15 秒、再比早），切在 ≥ 0.2 秒的停顿里离两头 40 ms，一直有声才退到最安静的格子边；先整段量响度再只截那一段、按 PTS 落格、立体声取平均、读只在 `MediaReadQueue.analysis`；旧的 `clone_from` 用它但过渡期走不通、声音 PR 3 删了（生产入口等声音 PR 6）；声音库本身和变声做到时补进来。 **第九节（声音 PR 8）：设置里的声音库、声音选择器、新建 / 设计声音的对话框**——和 AI 的工具同一条路（建 / 加 / 删 / 设计各只有一份）、授权是对话框里的一勾、设计的按钮就是确认并先过每日硬预算、语言本机检测预选（检测不出来留空）、现在录到 3 分钟自己停、声音库用不了时预设照常；守卫、反向验证、人工回归（麦克风授权、真 Sky Studio）。 **第十节（2026-11-11 审查之后）：收费单只下一次、账只记一次**——会花钱的按钮按下去就锁、一份报价一个 key（不从内容算）、同一件事只开一单（过闸之前先看在建的）、费用的问题受理后才清、没做成的单把原因和新价带进 get_job、预算规矩只有一份、授权那句升版本刷新目录再问、临时文件夹只在一处起名并在启动时清。 **第十一节（声音 PR 9）：变声**——`change_voice` 和片段右键的面板同一条路；传单声道 WAV、截声音在收费之前；只判每日硬预算；落地是一步撤销（原段静音、两条新音频轨、三段链接），这一段没了 / 工程换了只留文件；守卫、反向验证、人工回归（真 Sky Studio 要花积分）。
- [联动：压在主轨块上的东西跟着它的画面走](docs/architecture/timeline-linkage.md) — 2026-10-02 起「联动」开关（原「链接」，默认开）：十条规矩（跟着画面走、完全在一段里的才跟、
  跨段的全部挪同一个量才跟、真删才删、这次操作碰过的不再碰、撞上让开、规则只在 `TimelineLinkage.follow` 一处且钩在 `perform` / `liveApply` 收尾、拖动中压着的东西是没有障碍的成员并按宿主的实际落点再平、
  哪些算「任何东西」、关着只剩显式链接组）、场景表、给 AI 的那一面（`get_timeline` 的 `linkage`、结果里的 `linkage`）、已知不足、守卫、人工回归。
- [剪辑页上记住的开关](docs/architecture/editor-remembered-toggles.md) — 2026-10-01 用户拍板：播放跟随是开关、默认关（关着播放头走出视口、停下不滚回；开着翻页式，`PlayheadFollow` 纯值、只碰横向；Return 回到开头照旧滚回最左）；磁吸 / 吸附 / 联动（2026-10-02 起默认开）/ 播放跟随四个工具栏开关和剪辑页字幕列表的跟随按钮都记在 UserDefaults，键、默认值、读写只有 `EditorToggles` 一份（默认值的字面量就是产品口径）；冒烟 / 性能场景起手永远默认值、拨了不落盘；加一个记住的开关怎么做；人工回归。
- [时间线缩放](docs/architecture/timeline-pinch-zoom.md) — local NSEvent monitor 与失败方案、**锚点**（捏合钉指针底下那一刻、工具栏钉播放头，滚动视图只从 `TimelineScrollGeometry` 拿、`keepAnchored` 同一拍挪 + 下一轮补挪）、**纵向缩放**（⌥ 捏合 / ⌥ + Ctrl + 滚轮 / ⌘↓ ⌘↑，视频和音频轨统一成一个高度、细行不变、按行认锚点）、人工回归清单。
- [时间线上的复制 / 剪切 / 粘贴](docs/architecture/timeline-clipboard.md) — 能拷什么（标记、转场跟着段走）、入口（编辑菜单在响应链末端、右键菜单是函数不是视图）、系统剪贴板一套自己的类型且不写纯文本（滤镜那套并进来了）、落点鼠标优先否则播放头（右键菜单用右键按下的那一处）、换新身份走编码往返、各类落到哪（剪辑整组同轨、撞上往上抬、画面组上下关系不变；文字 / 滤镜往上找空的；字幕句按指着的轨）、粘完选中且一步撤销、剪切 = 拷贝 + ⌫、人工回归清单。
- [工程文件与素材重链接](docs/architecture/video-edit-project-file.md) — 格式（版本表到 v34）、定位、脏标记与自动保存、换成 upscale 文件的段（四之五：原片配书签不进 mediaURLs、换源 = 源时间整体平移、分割要抄记录）。
- [时间线拖动手势](docs/architecture/timeline-drag-gestures.md) — 坐标系、刷新、吸附、唯一落点算法，
  **对齐线**（§4：对齐点含字幕 cue / 标记 / 藏起来的段、多选只看整组外沿、磁吸也亮线、裁切也吸按 FCP、吸附关了线也不亮），
  **拖动 / 拉框的会话不进时间线的 `@State`**（§0b：`TimelineDragBox` 持有不订阅、块只 `onReceive`
  自己那份、覆盖层唯一订阅者），
  框选（相交即选中、混选与「预览最多一套框」、整组一起移动），以及命中区必须盖在填满视口
  之后、点非素材处移播放头、扫帧 peek 的唯一所有者、**整条时间线只许一个拖放落点**（§5e-2），
  插入缝（停 0.2 秒拉开、行的位置一份纯值、纵向按指针判，§5h）、整条轨换位（§5i）、文字块上下换行（§5j）、
  框选框滤镜 / ⌘A 全选 / ⌘⇧A 取消（§3.5b）与多段一起裁（§3.6）。
- [预览自由变换](docs/architecture/preview-free-transform.md) — `ClipPlacement` 与预览/导出同账。
- [关键帧动画](docs/architecture/keyframe-animation.md) — 源时间锚定、切片与 fill + matte。
- [工程帧率](docs/architecture/project-frame-rate.md) — 唯一事实来源、容差空间与回归矩阵。
- [声音：音量与渐入渐出](docs/architecture/audio-fades.md) — 唯一夹紧点、转场仲裁、dB 换算、只换增益的快路径（引擎 `updateGains`）、每段增益表从段起点起就有确定的值。
- [声音场景](docs/architecture/sound-scenes.md) — 九个场景的模型与 v20、效果跑在引擎的渲染块里（预览和成片同一份；效果在段增益之后、推子之前）、每段一条效果链各自散余音（段尾之后喂零，不用载体）、加 / 去掉场景重开流、seek 复位、不载入出厂预设、喇叭类先削波后限带、响度补偿用同一串处理量（渲染前记输入）、回归与人工清单。
- [成片的声音](docs/architecture/export-audio-mixdown.md) — 成片的声音就是预览那份混音，2026-10-01 起由同一个音频引擎离线渲出来（之前是 AVFoundation 读合成；导出图里不许有声音滤镜）、读用户那一份状态（展开只许一次）、正好画面那么长、f32 中间文件、`MediaReadQueue.export`、和以前的成片比变了什么（单声道响 3 dB、变速换成预览的算法）。
- [音量曲线](docs/architecture/audio-volume-curve.md) — 曲线属于段（dB、锚源时间、有点时取代 `volume`）、编辑动作本身不改声音、两条管线同一张折线表、导出 `aeval` 平衡树的六条实测约束（放在 `adelay` 之前并减掉首帧定格、最右叶子必须是常数、全精度数字、超大图走文件）。
- [波形与深度缩放](docs/architecture/audio-waveform.md) — 一个文件读一次的三层精度（多级峰值 / 按需原始采样块 / 顶替）、粗级是 min/max 不是平均、画「听到的声音」且爆音涂红、**Canvas 只画 `clipBoundingRect`**（超宽内容的实测地基）。
- [推子与电平表](docs/architecture/audio-mixer.md) — 三级增益一条账（段 × 渐变 × 轨道推子 × 总推子，配置里分开记、渲染块按同一个顺序乘）、只动推子走快路径；电平表：峰值从渲染块来（无锁槽）、总表从混音器出口来、槽按键登记、界面每拍取走、读播放头不问播放器；tap 那条路的七条约束 2026-10-01 PR3b 起退役（案例还在）。
- [画面渐入渐出](docs/architecture/video-fades.md) — 渐变露出的是下一层、alpha 斜坡两条管线同账、与声音共用的夹紧规则。
- [主轨转场：借余料与定格补足](docs/architecture/transition-handles.md) — 不挪用户片段、三种几何与容量、余料不够用首尾帧定格补足（2026-09-23 拍板）、定格字段只在渲染副本里且只许展开函数写、两条管线怎么做定格。
- [画面段的入场 / 出场动画](docs/architecture/clip-animation.md) — 五种效果都落在三种斜坡上、效果与画面渐变共用一个槽（老工程零迁移）、铺满画布不露边的补偿、逐帧效果走预渲染的代价。
- [视频轨对等化](docs/architecture/video-tracks.md) — 取消画中画、一轨一色、⌥ 点击穿透、轨道头这一列的动作（按住拖 = 整条轨换位置、拖下边缘 = 调行高），以及尚未对齐的两项。
- [用户文本文件的编码](docs/architecture/text-file-encoding.md) — 字幕、讲稿这类用户给的文本文件，编码识别只有 SrtFlowCore 的 `TextDecoding` 一处：BOM → 严格 UTF-8 → 像 UTF-16 才 UTF-16 → GBK；为什么 UTF-16 不能无条件排在 GBK 前面。
- [画面文字](docs/architecture/text-overlays.md) — 唯一的绘制入口、1080p 基准、版面框即定位框、包络位图、把手的三种数学、九种动画与「只逐帧渲动画段」、数字元件（等宽自己排，苹方没实现字体特性）、数字的等待、**老虎机位数不同的两头**（不存在的那一位滚成空白收掉、居中和右对齐右边不动、正在收的那一位原地滚走）、**时间线上的行**（行号进模型、行序 = 叠放序、新字开新行、换行往上找空行、老工程迁移）。
- [滤镜](docs/architecture/filters.md) — 时间轴上的调色段、层号进模型（LUT 不可交换）、强度=表的线性插值、预览挂图层滤镜的实测地基（backgroundFilters 会污染整个窗口）、两条管线的四条对齐约束。
- [画面上的形状](docs/architecture/shapes.md) — 线条 / 长方形 / 正方形 / 圆 / 圆弧（2026-10-03 加了圆和圆弧、入场 / 出场动画）：种类和几何（`keepsSquare`、`defaultSize`、`drawsFilled`、`strokeWidth(in:)`）、所有种类画什么只有 `ShapeOutline.drawing` 一份（预览、导出、AI 的「看」同一条路径，各自上色；y 向下顺时针；线头在长度以内；什么都没露出来时给空路径）、入场 / 出场动画（淡入淡出 / 弹性缩放 / 擦除 / 画出来，和文字同名同曲线、出场倒放、时刻钉到帧上、导出只逐帧渲那两截、和文字共用 `OverlayExportFile`）、拍过的板、`set_shape`、v30 / v31、守卫与人工回归。
- [盖一块：模糊 / 马赛克](docs/architecture/cover-blur-mosaic.md) — 形状的一种、时间线上的一段（`ShapeKind.blur` / `.mosaic`，不画东西、不算总长、不进 `renderedShapes`、格式 v26）、**不跟着片段走**（为什么：预览没有片段级的钩子、「从旧段构造新段」漏字段的教训）；盖谁：合成 + 调色之后、形状之前；三条管线按构造一致（预览第二层播放器 + 区域容器 + 边缘外延、导出 `split → crop → gblur / pixelize → overlay`、AI 的「看」CoreImage）；八条硬约束（层序、蒙版与滤镜别同层、边缘外延、格子从左上角起算、框取偶数、高斯半径是标准差、力度按画面高、没有盖一块时不建第二层）；AI（`set_shape` 的 blur / mosaic + `strength`、`text_scan` 给的 `cover`）；实测地基、已知不足、回归与人工清单。
- [录屏生命周期](docs/architecture/screen-recording-lifecycle.md) — 状态机、journal、恢复、退出与快照，AI 起的会话（2026-10-03：同一条流程、差别只在 `ScreenRecordingSession`）。
- [Inspector 数值框](docs/architecture/inspector-scrub-number-field.md) — 写入、取消、焦点与光标合同。
- [检查器的排版](docs/architecture/inspector-layout.md) — 固定的窄栏（约 220pt）：一行的最小宽度不许超过它，否则整列被撑宽、右边被裁；菜单 Picker 不许锁宽度；长名字的下拉标题单独一行。
- [定格](docs/architecture/freeze-frame.md) — 一次性提交、PNG 归属、波纹范围与静帧管线。
- [字幕语言流](docs/architecture/subtitle-language-flow.md) — 目标语言可见性、预检与自动检测。
- [字幕轨可见性与布局](docs/architecture/subtitle-track-visibility-and-layout.md) — 一语言一轨、**两条轨独立**（2026-09-26 起：各自的 ID 和时间、来源表现算过期 / 缺译文、两个翻译按钮各动哪些句子）、画面上的布局（译文叠在原文下面或各摆各的、预览和烧录读同一份按时间切好的块）、**工程自己的样式与逐词高亮**（2026-09-28：样式两层只问 `subtitleStyle(appWide:)`、词的时间记在句子上并跟着编辑走、按词切段、ASS 标签与预览同一份位置）、选择模型（点选互斥 / 框选混选），以及三个编辑入口共用的合同。
- [轨道块标记](docs/architecture/clip-markers.md) — 源时间锚定、标记对所有选择互斥、命中区分层。
- [即时提示](docs/architecture/instant-tooltips.md) — 不许用系统 `.help`、快捷键单一来源、面板四条硬约束。
- [本地化](docs/architecture/localization.md) — 写死的文案必须每张表都有（一张原文表 + 每种语言一张译文表，有几张不写死）、L10n 与 Text 的分工、lproj 小写坑、**sheet / popover 不继承应用内语言**与已知盲区、**加一种界面语言只做两件事**。
- [阻塞的媒体读取](docs/architecture/blocking-media-reads.md) — `copyNextSampleBuffer` 这类会卡住线程的读取不许进 Swift 并发的线程池（同一档 QoS 上卡满核数就整档死锁）、`MediaReadQueue` 的两种用法与宽度、唯一的例外（字幕生成逐窗口读）、什么样的阻塞会死锁。
- [挂起主线程抓栈](docs/architecture/main-thread-stack-capture.md) — 看门狗挂起主线程走栈的那几十微秒里只做系统调用和裸读写：不分配也不释放内存（主线程可能正握着分配器的锁，挂起方再要就永远等下去、主线程永远恢复不了）、不拿锁、不碰要现场取类型元数据的导入 C 结构 / 没特化的泛型；挂起和恢复只在 `walkWhileSuspended`；为什么只靠压力撞的测试抓不住（分配器快路径无锁，原写法 10 轮只撞上 5 轮）、确定性的守卫怎么数（`malloc_logger` 钩子问挂起计数）。
- [预览性能 ratchet](docs/architecture/preview-perf-ratchet.md) — 量的是活不是 CPU、**每个视图 body
  第一行计数**（守卫钉着，`--fix` 自动补）、时钟连跳走真播放的入口、合成负载当 GPU 代理数字、要有两遍
  一模一样、计数逐项相等（进步必须登记）、基线只许降（抬基线的 PR 不许动产品代码）、**已知的偶发误报**
  （检查器数值框和时间线缩放桥接多一轮 → 重跑）、盲区、**时间线上的块不读工程、按值比较**（守卫钉着）、**只有一个小视图关心的状态不放在工程上发**（第十节，「正在重建」的转圈）、**点一下选中一段的时间花在哪**（第十一节：release 和 debug 一样慢、活在框架里；换 Observation 之前块的选中高亮只在根视图那一遍更新）、**播放头的每一跳只叫醒跟着它动的东西**（第十二节：订阅时钟按类型名单、大视图持有不订阅、只关心变没变的 `onReceive` 自己那份、停着才有意义的读 `PacedPlayhead`，守卫钉着）、**工程是 `@Observable`**（第十三节：body 读了什么就只被什么叫醒、按属性不按值、不驱动界面的存储 `@ObservationIgnored`、读撤销栈 / 最近列表这类不可观察的东西要自己找叫醒的来源、冒烟看 `event:project.changed.<属性>`、剩下的一半是命中测试）。
- [导出设置](docs/architecture/export-settings.md) — 分辨率档位封的是**短边**（竖屏 1080×1920 的 1080p 就是它本身）、只降不升、各管线在哪一步缩；**面板上只放这条管线真消费的设置**（按管线声明，不按控件加开关）；标题→文件名只有一个函数、导出位置的记忆链、视频和字幕文件同一条撞名规则、记住与恢复默认，以及人工回归清单。
- [导出水印](docs/architecture/export-watermark.md) — 只加在剪辑导出的成片上（`VideoEditExporter`：面板和 AI 的 export_video），预览、look、生成 / upscale 的成品、压缩 / 烧录、录屏都不加；加不加只有 `WatermarkPolicy` 说了算（授权说要加 —— 照授权拦生效时听服务器的 `watermark` —— 或测试开关 `export.testWatermark`；照授权拦 2026-10-28 起打开，没开通正式版的导出都带）、`plan()` 的 `watermark` 没有默认值；落点在烧字幕之后、缩小之前；Sky Studio 的 logo（`Resources/watermark-logo.svg` 读成矢量路径现画）带阴影、70%，每 4 秒在四角 + 正中随机跳、不连续同一处，四角宽 = 短边 25%、正中 15%；整段只两个 overlay、位置是平衡的分段 if 树；要加却读不出 logo 就不导；导出面板「会带水印」那一行不拦导出；已知能绕过去的；守卫与人工回归。
- [Sky Studio 账号](docs/architecture/sky-studio-account.md) — 2026-10-27 / 28 收费方案第 5 刀（5a 只读授权；5b 照授权拦，**2026-10-28 打开**）：用户粘一把 `sk-` Key（钥匙串 `<bundle id>.skystudio`，和 fal 的 Key 共用 `KeychainSecret` 的两档读法）、存的时候马上问 `/me`、Sky Studio 不认就不留；每个请求带机器号（硬件 UUID 加盐的 SHA-256，原始编号不出本机，盐永远不改）；只有 `SkyStudioAPI` 碰 `https://skystudioai.com/api/skycut/v1`（自检用回环地址的假服务器）；此刻的授权是纯函数 `SkyCutLicense`：开关、天数全照服务器的，没有 Key / 没问到过 / 过了 `valid_until` 按免费版，服务器的钟换成本机的、往回拨不作数；启动 / 回到 SkyCut / 每小时看一眼，后台从不弹钥匙串框；设置里「Sky Studio」一节（账号、套餐、积分、问不成时为什么、开通优先服务器购买地址、台数满了只给管理 Mac / 客服邮箱和「复制邮箱」，Pro 快到期 / 续费失败宽限共用提醒，商务续约只给邮箱、说明字段不改功能）；照授权拦（`SkyCutGates`：AI 的门在核对参数名之后、建调用排队之前，`get_status` 照常回并报 `skycut_plan`；还没问完先问一次再判；导出水印听服务器的；导出面板「会带水印」那一行不拦导出；告诉 AI 带了水印；`enforcedByDefault` 自 2026-10-28 起打开，接口已上线并完成真服务器验收）；能绕过去的；守卫与人工回归。接口合同在 Sky Studio 仓库的 `docs/agents/skycut-api.md`。
- [Sky Studio 的任务](docs/architecture/sky-studio-jobs.md) — 2026-10-28 收费方案第 6 刀起：生成、upscale、克隆走 Sky Studio 的 `/models`、`/quote`、`/uploads`、`/jobs`（合同从 Sky Studio main 5c8d6a0d 起冻结）。模型、价、上限 SkyCut 不写死；扣多少一律问 `/quote`、交任务时当 `max_credits`；每件活一个 idempotency_key，满了（每个账号同时 3 个）在本机等 15 秒用同一个 key 再交、提交断网保留原 key 并核查原单，不重放收费 POST；交的请求不跟着取消、等 120 秒；没有长轮询，照 `poll_after_seconds`（2–60 秒）问，断网 10 次才算失败、最多等 5 小时；只有排着队的能取消（退钱），开始了的照实说取消不了、积分花了、成品照样进作品库；成品永久在作品库（克隆留 60 天），宽高帧率是 null 的从文件读；Key 只发给 Sky Studio（上传签名地址、成品地址都不带）；Sky Studio 真服务器实测的细节（PUT 原样带头、upscale 的 source 从导出的文件探、图生视频带 aspect_ratio、克隆冷启动 4 分钟）；谁在用（upscale；generate_media 2026-10-28 起：`SkyStudioGeneration` 换参数、按种类挑 `/models` 里的模型、规矩在服务器上、图生视频的首帧走 `/uploads`）；停不下来的那单接着查到底；第 6 刀后面几个 PR 还没做的；守卫。
- [生成的字幕长什么样](docs/architecture/subtitle-generation-style.md) — 先断句、后去标点、最后在整条轨上排时间；去标点的规则（句中换一个半角空格、行尾删，问号叹号引号书名号省略号列举顿号留着，数字缩写撇号不动，只在生成和机器翻译落字时去）；断句（逗号拆小句、太短的并、放不下的用动态规划挑切法、每一刀的代价表、中文按系统分词且按整句判语言）；一行多长（全角 1 半角 0.5 的字数 + 按字号和画面宽度的「放得下」，竖屏更短）；几行（2026-10-16 用户定默认单行，生成面板 / AI 的 `max_lines` 跟着工程走；两行时折行点两行差不多宽 + 断在好断的地方 + 中文不切词、一样好时下面那行长）；显示时间（5/6 秒、7 秒、2 帧、不到半秒接上、说完多停半秒、不越过素材结尾）；几段素材同时有字只留一条（零碎杂音、谁清楚留谁、同一段素材不算撞）；转写哪些声音（藏起来的不转、只用选中的片段）；已知不足、回归与人工清单。

- [按旁白段落同步时间线](docs/architecture/voiceover-timeline-sync.md) — 显式映射、实测音频与原稿对齐，共用批量事务，一次撤销且不重复联动。

- [官方原创短片](docs/architecture/official-film.md) — 公开镜头 / context / 声音合同、真实引用报价、不透明 pin、两侧预检与输出验收的边界；私有配方不进客户端。

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
- [2026-09-23 从 Finder 拖文件进时间线标尺以下没反应](docs/bugfixes/2026-09-23-timeline-file-drop-claimed-by-inner-drop-region.md) — 拖入由最里面的落点区独占认领（「两套路由」的结论已更正，见下一条）。
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
