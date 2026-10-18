# 2026-10-18 改名 SkyCut 之后的冒烟（0.18.47）

对应：PR #250（改名）、#251（新工程存 `.skycut`、AI 的子文件夹叫 SkyCut）；拍板见 [改名方案](../plans/2026-10-18-rename-to-skycut.md)，
规矩见 [产品名与代码名](../architecture/product-name.md)。装的是 main c0e39c6 的代码打的 0.18.47：`/Applications/SkyCut.app` 和
`/Applications/SkyCut Beta.app`（arm64、`codesign --verify --deep --strict` 过、证书 leaf 76d27565… 和 `packaging/signing-identity.sha1` 一致、
小程序答 initialize 报 `skycut` 且不拉起 App）；旧的 `SrtFlow.app` / `SrtFlow Beta.app` 在废纸篓。

结论：**没发现 App 的问题。** 授权、设置、数据、双击打开、Claude Code 的连接都沿用下来了；新旧两种工程文件、新旧两种子文件夹都按规矩走。

## 一、系统层面（不开 App）

| 查什么 | 怎么查 | 结果 |
| --- | --- | --- |
| 授权有没有跟过来 | 读系统和用户的 TCC.db 里 `com.srtflow.SrtFlow` / `.beta` 的每条记录，解出 `csreq`，拿新装的包 `codesign --verify -R` | 两个 App 的录屏（`kTCCServiceScreenCapture`）和下载文件夹（`kTCCServiceSystemPolicyDownloadsFolder`）都是 auth=2、钉的都是 `certificate leaf` 76d27565…，新包**全部核得过**：不用再授权。麦克风、自动化以前就没给过 |
| 双击交给谁、Finder 里叫什么 | Swift 小脚本问 `NSWorkspace.urlForApplication(toOpen:)` 和 `localizedTypeDescription` | `.skycut` 和 `.srtflowproj` 都是 `com.srtflow.project`、种类「SkyCut Video Project」、交给 `/Applications/SkyCut.app`（不是测试版） |
| Claude Code 连得上吗 | `claude mcp list` | `skycut: /Applications/SkyCut.app/Contents/Helpers/skycut-mcp - ✔ Connected` |
| Dock、登录项里有没有指向旧包的 | `defaults read com.apple.dock persistent-apps`、System Events 的 login items | 都没有 |
| 设置还在吗 | `defaults read com.srtflow.SrtFlow` / `.beta` | 31 / 22 个键，域没变 |
| 数据文件夹 | `~/Library/Application Support/SrtFlow` | 剪辑风格、音频库、配音模型（318 MB）都在原处，新 App 读的就是它 |

## 二、测试版真跑（后台模式，扮成 AI 客户端）

照 [GUI 冒烟流程](../testing/gui-smoke-testing.md)「四之七」：在 scratchpad 里写了个小驱动（`client.py` 的握手 + 等任务 + 逐项 PASS / FAIL），
小程序在后台拉起测试版，`set_view background`，一个工程窗口都没开。素材用 `copy-project.sh` 把 L16 测试工程连素材拷进 scratchpad，摆成两个场景：

- **新文件夹**：只有一段视频和一份中文 `.vtt`。
- **老文件夹**：L16 的拷贝，工程在 `SrtFlow/Projects/Edit.srtflowproj`（和用户真实的工程一样的摆法），根上另有一份老 `.srtflowproj`。

31 项判定，28 项一次过；另外 3 项是驱动自己比错了路径（App 回 `/tmp/…`、驱动拿 `/private/tmp/…` 比），用 realpath 重新核都过。

| 场景 | 调了什么 | 结果 |
| --- | --- | --- |
| 握手 | initialize | `serverInfo` 是 `skycut` / `SkyCut` / 0.18.47，总说明以「SkyCut is a video editor」开头 |
| 状态 | `get_status screen=true` | 窗口列出来了（**录屏授权在运行时有效**）；结果里没有把 App 叫成 SrtFlow 的话，键是 `skycut_voices` |
| 新文件夹 | `open_folder` → `new_project` | `output_folder` 是 `fresh/SkyCut`；工程存成 `fresh/SkyCut/Projects/Rename smoke.skycut` |
| | `add_clips`（视频 + `.vtt`）→ `look` → `export_video 480p` | 画面和字幕都对；22 秒导完 `fresh/SkyCut/Exports/rename-smoke.mp4`，162.2 秒、字幕烧进去了（抽帧看过） |
| | 再 `open_folder` | 结果里说「The SkyCut subfolder (SrtFlow in folders from before the rename: …) is not listed.」，成片不被当素材列出来 |
| | `undo` 一步 → `save_project` | 撤掉的正好是 `add_clips` 那一步（存下来的工程 0 段）；存回去还是 `.skycut` |
| 老文件夹 | `open_folder` | `output_folder` 是 `legacy/SrtFlow`（已有的接着用）；根上的老 `.srtflowproj` 列成工程 |
| | `open_project Edit.srtflowproj` → `get_timeline` → `set_text` | 打得开、4 段读得回来；改完自动保存写回 `Edit.srtflowproj`（formatVersion 32），旁边没有多出 `Edit.skycut` |
| | `export_video 480p` | 成片在 `legacy/SrtFlow/Exports/legacy-export.mp4`，没有另建 `SkyCut/` |
| 报错 | `open_project` 一个 `.mp4` | 「is not an existing SkyCut project (.skycut, or .srtflowproj from before the rename).」 |
| 没点名文件夹时 | `get_status` 报的默认位置 | `~/Downloads/SrtFlow/Exports`：「下载」里本来就有 SrtFlow（以前 AI 建的），接着用它，没新建 `~/Downloads/SkyCut` |
| 名字 | System Events 读进程和菜单栏 | 进程 `SkyCut`；App 菜单「SkyCut」，菜单项「About SkyCut」「Hide SkyCut」「Quit SkyCut」 |

跑完 `quit` 测试版，干净退出。

## 三、正式版

正式版在检查之前就开着（17:30 由 launchd 拉起，不是冒烟拉的），所以只做只读检查、**没有退出它**：经它自己的小程序（就是 Claude Code
注册的那一个）握手报 `skycut`；`get_status screen=true` 列得出窗口（录屏授权在运行时有效）；进程名、App 菜单都是「SkyCut」，第一项「About SkyCut」。

## 四、实测学到的

1. **菜单栏上的 App 名取的是可执行文件名，不是 `CFBundleName`**：测试版的 `CFBundleName` 是「SkyCut Beta」，菜单仍是「SkyCut」（改名之前一直是
   「SrtFlow」，所以不是回归）。正式版要在菜单里叫 SkyCut，可执行文件就得叫 SkyCut —— #250 让打包脚本把 SwiftPM 产品 `SrtFlow` 拷成
   `MacOS/SkyCut`，`checks/product-name.sh` 第 4 节钉着 `CFBundleExecutable`。写进了 [产品名与代码名](../architecture/product-name.md) 第三节。
2. 冒烟驱动比路径要先 realpath：App 回的是 `/tmp/…`，scratchpad 在 `/private/tmp/…`。

## 五、没验到的（留人工）

- 设置 → 连接 AI 那一页的状态显示（这次是用 `claude mcp add` 注册的，没点按钮）。
- 「关于」窗口的样子；在 Finder 里真的双击一个 `.skycut`（LaunchServices 已确认交给 `SkyCut.app`）。
- fal 的 Key（正式版没存过）；真录一段屏幕（运行时授权已由窗口列表确认）。
