# 构建与打包

## 架构坑（重要）

这台机器的终端会话可能跑在 **Rosetta** 下，此时裸 `swift build` 默认编译
**x86_64**，产物落在 `.build/x86_64-apple-macosx/`，而
`.build/arm64-apple-macosx/debug/` 里躺着的还是上一次的旧二进制。

后果（真实发生过）：编译输出的警告行号都对得上新代码，但拷去测试的 arm64
二进制是旧的——"修复"在真机上毫无变化，浪费一整轮验证。

**规则：**

1. 一律显式 `swift build --arch arm64`（Release 同理：`-c release --arch arm64`）。
2. 测试/交付前用本次新增的字符串验明产物：
   `strings <二进制> | grep <新增字符串>`，配合 `lipo -archs` 确认 arm64。
   **挑长度 ≥16 字节的标记串**：Swift 的小字符串优化会把 ≤15 字节的字面量内联进
   代码、不落数据段，`strings` 在 Release 里根本查不到（`timeline-zoom` 这种 13
   字节的就查不到，`SRTFLOW_SMOKE_VIDEO` 能查到）——否则会误判成"新代码没进包"。

## 常用命令

```bash
swift build --arch arm64                      # 调试构建
swift run --arch arm64 SrtFlowCoreChecks      # 核心自检（184 项断言，CLT 无 XCTest）
scripts/check-local.sh timeline-snap          # 推之前：全部扫描守卫 + 点名的检查（原生 arm64）
./scripts/build-app.sh                        # Release + 组装 .app + 签名 + DMG
```

## 本地怎么跑检查（2026-11-04 起）

**本地只跑扫描守卫和这次改动直接相关的几项，完整的一遍交给 CI**（2026-11-04 用户定）：`scripts/check-local.sh <名字…>`
先跑 `scripts/check-guards.sh`，再一项一项跑点名的检查（名字先找 `scripts/check-<名字>.sh`，再找 `checks/<名字>.sh`；
也可以写路径；`core` 是 `swift run SrtFlowCoreChecks`）。CI 在每个 PR 上 5 台 runner 全跑 `scripts/check-all.sh`，绿了才合，
所以每一项照样会在合并之前跑到；本地全跑一遍要满载十几到三十分钟，笔记本烫，还和 CI 重复。想在本地全跑也可以。

**一律用原生 arm64、`/bin/bash` 跑**。在用户的 M1 上量的（2026-11-04）：

| 跑法 | 守卫 hover-pointer-style | 全部扫描守卫 |
| --- | ---: | ---: |
| Rosetta 下（x86_64） | 33.3 秒 | 6–7 分钟 |
| 原生 arm64 + `/bin/bash` | 6.1 秒 | 89 秒 |
| 原生 + 后台优先级（`taskpolicy -b`，只用能效核） | 18.0 秒 | — |
| 原生，换成 Apple 芯片版 Homebrew 之后（2026-11-05，`check-local.sh` 只跑扫描守卫） | — | 62 秒 |

Rosetta 下的进程起子进程也优先挑 x86_64 那一半，检查里几千个 grep / awk / perl、编译器都跟着走翻译，又慢又烫。2026-11-04 这台机器上
的根子是 PATH 最前面的 `/usr/local/bin/bash`：`/usr/local` 里的 Intel 版 Homebrew 装的、只有 x86_64。它从两条路钻进检查：

- **`#!/usr/bin/env bash` 和 `bash x.sh` 直接找到它**：在原生的终端里也照样走翻译。
- **Claude Code 给命令起的 shell 也被它带进 Rosetta**：cmux 的 `claude` 外壳脚本是 `#!/usr/bin/env bash`，翻译的 bash 再 exec 只有
  arm64 的 `claude` —— `claude` 本身跑原生，可「优先 x86_64」跟着传了下来（进程标志 `P_AFFINITY`），它再起的通用二进制（`/bin/zsh`、
  `python3`……）全走翻译（`sysctl -n sysctl.proc_translated` 是 1）。同样的进程链实测：Intel 的 bash 起出来是 1，原生的 bash 起出来是 0。

2026-11-05 换成了 Apple 芯片版 Homebrew（`/opt/homebrew`，PATH 里排在 `/usr/local/bin` 前面），Intel 版删了：新开的终端、新起的
Claude Code 里 PATH 上的 bash 是原生的 5.x，命令 shell 也是原生的。换之前就开着的会话照旧带着 Rosetta，重开才好；别的机器、
勾了「使用 Rosetta 打开」的终端也照样可能在 Rosetta 下起检查 —— 所以下面这套照旧留着。

所以三个入口（`check-local.sh`、`check-guards.sh`、`check-all.sh`）在 `cd` 之前 source `scripts/native-arch.sh`：在 Rosetta 下就
`exec arch -arm64 /bin/bash "$0" "$@"` 重跑自己（CI 的 runner 本来就是原生、Intel 的 Mac 没有这个 sysctl，都什么也不做）；
起检查一律写 `/bin/bash`，和 CI、check-all 的 `run_check` 同一个 3.2（以前 check-guards 用 PATH 上的 bash，本机跑的是 5.x，
和 CI 不是一个解析器，[陷阱 5、6](../bugfixes/2026-08-06-build-version-and-shell-traps.md) 那一类「本机绿、CI 红」它也挡不住）。`checks/native-local-checks.sh` 钉着；装了 Rosetta 的机器上
它还真起一个 x86_64 的探针，看 source 之后是不是换成了原生。单独跑某一个检查时也照样写 `scripts/check-local.sh <名字>`，
别直接 `scripts/check-x.sh`（那样走的是 PATH 上的 bash）。

## 打包流程（scripts/build-app.sh）

The notary profile is checked first (`scripts/signing/notarize.sh --check`: one notarytool cannot use stops the build
before the compile) → Release 构建 → 手写 Info.plist 组装 `dist/SkyCut.app`（SwiftPM 的可执行产品 `SrtFlow` 拷成 `Contents/MacOS/SkyCut`，产品名与代码名见 [产品名与代码名](../architecture/product-name.md)） → 拷入 SwiftPM 资源包、
vendor/ffmpeg 和 AI 客户端启动的 MCP 小程序 `skycut-mcp`（都在 `Contents/Helpers/`，
见 [AI 接口（MCP）](../architecture/ai-control-mcp.md)）, and the web-motion renderer `skycut-web-motion` (also in
`Contents/Helpers/`, [web-motion renderer](../architecture/web-motion-renderer.md)) → 生成图标 → 签名（只经 `scripts/signing/sign-app.sh`：
**先签嵌套二进制再签外层**，顺序反了外层签名立即失效，`scripts/check-mcp.sh` 钉着 skycut-mcp 这一条，`checks/web-motion-wiring.sh` 钉着 skycut-web-motion；
the Developer ID with the hardened runtime, see the signing section below) → the app notarized and its ticket stapled
(`notarize.sh`) → `scripts/build-dmg.sh` 生成 Retina 引导背景、复制 Finder 布局模板，
再由 `hdiutil` 生成 DMG（HFS+、卷名仍是 `SkyCut`）→ the DMG signed (`sign-dmg.sh`), notarized and stapled (`notarize.sh`).

产物：`dist/SkyCut.app`（0.18.66 约 68 MB）、`dist/SkyCut-<版本>-arm64.dmg`（2026-10-18 改名之前叫 `SrtFlow.app`、`SrtFlow-<版本>-arm64.dmg`）。

版本号：**正式发版必须显式传** `VERSION=x.y.z ./scripts/build-app.sh`。不传时
脚本兜底取最近的 git tag，并在 HEAD 领先该 tag 时警告「这是开发版产物」——
以前这里是写死的默认值，发到 0.4.1 了还停在 0.3.0，打出过贴错版本号的包，
见 [bugfixes/2026-08-06-build-version-and-shell-traps.md](../bugfixes/2026-08-06-build-version-and-shell-traps.md)。

## DMG 安装窗口（2026-11-06 起）

根目录只显示 `SkyCut.app` 和指向 `/Applications` 的 `Applications` 软链。首次打开说明直接在
Finder 背景中展示，不再放「首次打开必读 - Read Me First.txt」。Step 1 teaches dragging SkyCut to Applications. Since
2026-11-26 builds are notarized and open directly ([签名与系统权限](../architecture/code-signing-and-permissions.md)), so
the old step 2, «Blocked on first open? System Settings › Privacy & Security › Open Anyway», is gone in every language
(user, 2026-11-25: 「装机的那个页面……提示可以简化了」). Since 2026-11-20 (the user's call) step 1 is in six languages,
English first: English, 简体中文, 繁體中文, Español, 日本語, Русский. Step 2 gives one guide link for everyone,
`www.skycut.app/docs`: the website sends `/docs` to the docs page in the visitor's language
([SkyCut 官网](../architecture/skycut-website.md)), and the videos go on those pages.
终端 `xattr` 兜底由 App 需要时自己显示，不放在安装图上。

- 图稿唯一来源：`scripts/dmg/make-background.swift`，只用系统 AppKit / Core Text / Core Graphics 和系统字体。
  Its one input is SkyCut's icon for the drag hint: `build-dmg.sh` makes it with the app icon's own generator,
  `scripts/make-icon.swift` (from `packaging/icon-source-1024.png`), so the hint follows a new icon.
  配色是暖白 `#f3f0e8`、森林绿 `#123f32`、深色正文；所有像素使用自己的不透明底色，不跟随系统深浅色变色。
  每次打包现生成 760×510（72 dpi）和 1520×1020（144 dpi）的 PNG，再用
  `tiffutil -cathidpicheck` 合成 `/.background/background.tiff` 的两种分辨率。
- The copy (2026-11-20; step 2 removed 2026-11-26): every line is 14 pt regular, English in the dark ink `#19221d`, the
  other five languages in one muted ink `#505b4a`; there is no header. The Applications folder's name is the system's own
  string in each language, read from its localization tables on macOS 26.5.2. Traditional Chinese follows Taiwan
  (`zh_TW`); Spanish follows Spain (`es`, like SkyCut's `es.lproj`; Latin America's `es_419` name is the same).
  - Every text run carries its language (`kCTLanguageAttributeName`). Untagged, Core Text draws Traditional Chinese and
    Japanese with Simplified Chinese faces and punctuation (PingFang SC instead of PingFang TC and Hiragino).
  - A line that would cross x 724 or come within 24 pt of the canvas bottom stops the build. Grow the canvas, the window
    frame and both checks together, keep the hidden `.background` folder's position below the window (`check-layout.py`
    asserts its icon's top is), and keep the window fitting the 13-inch MacBook Air (below).
- The icon band (2026-11-26, the user's pick): nothing behind the icons, a still drag hint between them. Finder shows a
  selected icon on a 144 pt grey square, its label in a pill of the accent colour, and the light circles that sat behind
  both icons until then showed through it (user: 「这样叠在一起很难看」). A Finder background is a still image (a GIF
  shows its first frame, nothing runs), so the hint is a still: SkyCut's icon three times like strobe frames, its 44 pt
  rounded square fading in (12 / 25 / 45 %) towards Applications, a black pointer with a white edge on the last copy,
  then the arrowhead on a short shaft, all within x 284–458. The pointer is a fixed outline, traced once from macOS 26's
  arrow cursor, so the build needs no cursor image or window server.
  - Both icons' selection areas (x 128–272 and 488–632, y 92–258) stay plain paper: `check-background.swift` asserts it.
    It probes the hint only on its own ink (the arrow's shaft, the pointer's black), never on the icon copies, so a new
    app icon needs no check edit.
- 布局源：`packaging/dmg/DS_Store`，打包时拷成卷根的 `.DS_Store`。窗口框固定
  `{{120, 120}, {760, 598}}`（为标题栏及用户开启的路径 / 状态栏留出空间，图稿 760×510），图标 128 point，App / Applications
  中心为 `(200, 164)` / `(560, 164)`, the drag hint between them；隐藏工具栏和侧栏。The hidden `.background` folder sits at `(380, 800)`, below
  the window: a Finder that shows hidden files would otherwise put its icon on the first free spot, over the steps
  ([case](../bugfixes/2026-11-26-dmg-hidden-background-icon-over-steps.md)), and Finder hides it by default either way.
  模板同时声明关闭状态栏 / 路径栏；Finder 可能沿用用户的这两项全局偏好，窗口高度仍能容下完整引导。
  背景 alias 使用卷内 `.background/background.tiff`，不携带开发机路径、卷 UUID 或 inode。
  `scripts/build-dmg.sh` **不控制 Finder、不调用 Apple Events**，正常打包不会申请「控制访达」权限。
  - Where the window lands (seen 2026-11-20, macOS 26.5.2): Finder counts the frame's y from the bottom of the screen
    and moves a window that would reach under the menu bar down to just below it (on a 1440×900 pt screen it opened
    31 pt from the top, at 776 pt tall). On a 13-inch MacBook Air's default 1470×956 pt screen the 598 pt window spans
    120–718 pt from the bottom, leaving 238 pt for the menu bar and 120 pt for a bottom Dock. The title bar is 32 pt and the
    path and status bars take 56 pt together, so with the user's bars on, the content area is exactly the 510 pt canvas.
- 模板可重复生成：只在主动改窗口布局时，临时安装 `ds-store==1.3.3`、`mac-alias==2.2.3`
  到 `/private/tmp/skycut-dmg-template-tools`，再执行
  `PYTHONPATH=/private/tmp/skycut-dmg-template-tools python3 scripts/dmg/make-layout.py`。
  这两个一次性工具不进正式依赖，打包和 CI 都不 import 它们。提交新模板前必须真挂载验收，
  图标坐标改动时同步图稿和 `scripts/dmg/check-layout.py` 的布局合同。
- 扫描守卫：`checks/dmg-packaging.sh` 钉正常打包接线、命名和不带旧 txt / Finder 自动化，
  用标准库解析模板的实际叶记录检查窗口、背景 alias 和图标位置。
- 产物检查：`scripts/check-dmg.sh` 不带参数时用小型 App 夹具真走生产组装器并挂载只读 DMG，
  检查背景、布局、软链、无 txt，并解码 TIFF 验两种像素尺寸 / DPI 和完整图稿 (with the hint's own ink, and plain paper
  under both icons' selection areas)。带 DMG 路径时验完整包。
  两条都在 `scripts/check-all.sh`，本地运行 `arch -arm64 /bin/bash scripts/check-local.sh dmg`。

**路径栏 / 状态栏的已知限制（2026-11-06 实测与验收决定）**：macOS 26.5.2 上，模板的
`bwsp.ShowPathbar` / `bwsp.ShowStatusBar` 都已经是 `false`；用户原有偏好为开时，重开只读 DMG
仍会显示两栏。在一次性可写映像中由 Finder 亲自隐藏、保存再压成只读映像，以及补上
`fwi0` / `fwvh` / `fwsw` / `vstl` 兼容字段，都复现同样结果。用户验收决定保留当前布局并记录限制。
这里只保证模板声明关闭，不能把这两项字段的扫描通过报告成「实机已隐藏」。打包过程不改用户的
`com.apple.finder` 全局偏好；人工排查若临时切换了偏好，结束必须恢复原值。该次排查已恢复为开。

Finder 的真实渲染属于人工回归，每次改图稿 / 模板后以及发版前要检查：

1. 用开发版本号（例如 `VERSION=0.18.60-dmgtest arch -arm64 /bin/bash scripts/build-app.sh`）
   打测试包，再运行 `arch -arm64 /bin/bash scripts/check-dmg.sh dist/SkyCut-0.18.60-dmgtest-arm64.dmg`。
2. 挂载到独立临时目录，保留用户已打开的安装盘和 Finder 窗口；在 Finder 新窗口中打开测试卷。
   确认背景自动显示、the drag hint between the two icons、第 1 步六种语言和第 2 步的教程链接完整，Retina 屏上字体清楚、图标标签能读。
   Select SkyCut (click it, or reveal it with `open -R <mount>/SkyCut.app`): Finder's grey square and label pill sit on
   plain paper, with nothing of the art under them.
   深浅色下背景本身底色不变；不要为了验收打断用户工作、切换全系统外观。
   路径栏 / 状态栏必须按用户原有偏好重开检查；只在当前窗口手动隐藏后的截图不能证明模板生效。
   Look once with hidden files shown (Finder's ⇧⌘.): no item of the volume over the steps. With hidden files off, the status
   bar says 2 items.
   If another volume named SkyCut is mounted (the user's installer disk, say), the test window shows that volume's
   background: the template's alias names only the volume, a fixed date and a relative path (seen 2026-11-20; a user
   with an older SkyCut disk still mounted sees the same). Leave the user's disk mounted and check a scratch copy of the
   test image with its own volume name instead: the alias regenerated for that name with the template tools, the same
   app, background and window records.
3. 截图只存 `/private/tmp` 并在交接写路径，不入库；关闭本次开的窗口，卸载本次测试卷。
4. 删除测试 DMG 和同版 `dist/SkyCut.app`，避免未发布版本留在 `dist/`；不安装、不上传、不发版。

## Signing and notarization: the Developer ID (since 2026-11-26)

macOS keys its permissions (screen recording, microphone, Downloads, Automation, the keychain) to the signature: an
ad-hoc build is another app every time. Release and Beta builds are therefore signed with the Developer ID
`Developer ID Application: TIANYU LU (26TVX3S9FR)` (from 2026-10-03 to 11-26: the self-signed «SrtFlow Signing»), whose
designated requirement names the team, so new builds and a renewed certificate keep every permission; the hardened
runtime is on and Apple notarizes them, so a download opens directly. The rules, the entitlements and their proof:
[签名与系统权限](../architecture/code-signing-and-permissions.md).

- **The identity** is in the login keychain; `packaging/signing-identity.sha1` pins its SHA-1 and `sign-app.sh` signs with
  nothing else (an expired pin or another certificate of the team: it refuses). Renew before 2027-12-25 and update the
  pin; the team keeps every permission.
- **The notary profile** `notary-26TVX3S9FR` (one for all of the user's apps) is in the login keychain too. The user creates
  it once, in Terminal: `xcrun notarytool store-credentials notary-26TVX3S9FR --apple-id <Apple ID> --team-id 26TVX3S9FR`
  (it asks for an app-specific password from appleid.apple.com). Scripts never ask for, read or print the password; a
  build without a usable profile stops before the compile and prints this command.
- `build-app.sh` notarizes twice: the app (zipped), stapled before the DMG is made, then the signed DMG, stapled too.
- A Mac with no Developer ID of the team, or a shell whose `security` cannot reach the keychain, stops the build before
  the compile. Someone building SkyCut for themselves from source runs `SKYCUT_ALLOW_ADHOC=1 scripts/build-app.sh`: ad-hoc,
  not notarized, with ⚠️ warnings, and **such a build never goes to a user or a release**.
- A build that fails after it began writing `dist/` deletes the app and DMG it wrote (`build-beta-app.sh` its Beta).

## 测试版（SkyCut Beta）

没合并的功能要给用户在自己机器上实测时：`VERSION=x.y.z scripts/build-app.sh && scripts/build-beta-app.sh`，得到 `dist/SkyCut Beta.app`（re-signed with the same Developer ID and notarized on its own）。换了名字和 bundle id（`com.srtflow.SrtFlow.beta`：bundle id 沿用旧名），设置、AI 的通道都和正式版分开；每种文档类型都只做「备选」，双击工程文件仍由正式版打开。`build-app.sh` 会顺手打一个同版本号的 DMG、覆盖 `dist/SkyCut.app` —— 只出测试版时记得把它们删掉 / 换回去，别让 `dist/` 里留着贴了未发布版本号的包。

## Installed copies on the developer Mac

The user, 2026-11-19: 「本机就保留一个正式版，一个beta 就够了，不要那么多版本都安装在本机」 (one official copy and one beta are
enough; don't install so many versions on this Mac). So the Mac keeps exactly two installed copies, `/Applications/SkyCut.app`
(official) and `/Applications/SkyCut Beta.app` (beta), and no other SkyCut bundle outlives the run that built it.

- **Unregister, then delete.** A SkyCut bundle that goes away is unregistered first, so it leaves no dead registration:
  `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <path>`,
  then deleted outright: no backup copy, nothing left in the Trash.
- **A local install** happens only when the user asks for one, and the beta is replaced only when the user asks for a beta.
  - Build with `VERSION=x.y.z scripts/build-app.sh` (official), then `scripts/build-beta-app.sh` for the beta, signed with
    the Developer ID and notarized: a build that fell back to ad-hoc is never installed (signing section above).
  - Only while the copy being replaced isn't running. Never quit the user's SkyCut or SkyCut Beta: wait, and ask.
  - Move the old bundle aside, put the new one at the same path and verify it (version, `codesign --verify --deep --strict`,
    the team and notarization: acceptance checklist below); if it fails, put the old one back and stop. Then unregister
    and delete the old bundle and the build's `dist/*.app`. `dist/` keeps only the newest DMG; after a beta-only build
    its DMG goes too (previous section).
- **Test, smoke and probe bundles** (`SrtFlowDev.app`, harness and check bundles, `.skystudiosmoke` and measurement apps,
  repro apps) are built under a temporary or scratch folder, never installed into `/Applications`, and unregistered and
  deleted when the run ends. Install the cleanup trap before staging the bundle. Use `scripts/test-app-cleanup.sh`
  for the unregister and removal, including on errors. Keep any needed logs or project fixtures outside the bundle.
  For a multi-command smoke session, a failed start cleans up immediately and `stop` ends a successful session and
  removes its bundle. The measurement harness can stage a new bundle from its prepared template on the next start.
  `checks/test-app-cleanup.sh` scans this wiring and exercises cleanup in both exit paths.
- **No preferences in the login home.** A check never leaves a domain in `~/Library/Preferences`: removing a domain
  (`removePersistentDomain`, `defaults delete`) leaves its plist, and cfprefsd rewrites a plist deleted within about 10 s
  of the domain's last change. A Swift check's own suite is a `ScratchDefaults` (`checks/Shared/ScratchDefaults.swift`):
  named by a path in a temporary folder, so cfprefsd stores it there. A staged check or render app is
  `com.srtflow.SrtFlow.<name>check` or `<name>render` (`.run<pid>` when parallel runs need their own), and
  `remove_test_app` deletes that domain 15 s after the app exits (`scripts/test-defaults-cleanup.sh`); `check-all.sh` and
  `check-local.sh` collect them and wait once. On CI, `check-all.sh` fails if new SkyCut-looking preferences are left.
  `checks/test-defaults-cleanup.sh` scans this and exercises the removal.
- **Never reset the LaunchServices database** (`lsregister -kill`, `-delete`, `-seed` and the like): it holds every app
  on the Mac, not only SkyCut.

Why: on 2026-11-19 macOS still knew 17 extra SkyCut-type bundles (build outputs, smoke and probe apps) and 100 dead
registrations. They show up in Spotlight and "Open With", and a project file can open in a test build. Later that day,
24 `MotionPlacementCheck.app` fixtures kept by failed check runs (2026-11-17 to 11-19) were still on disk and registered.
`~/Library/Preferences` held 2,353 plists from checks ([case](../bugfixes/2026-11-19-check-defaults-leftovers.md)).
The release records below that moved old bundles to the Trash or kept a backup predate this rule.

## 产物验收清单

- `lipo -archs dist/SkyCut.app/Contents/MacOS/SkyCut` → `arm64`
- `dist/SkyCut.app/Contents/Helpers/skycut-mcp` 在、能跑：往它的 stdin 喂一行 `initialize`，
  stdout 回一行带 `"serverInfo":{"name":"skycut"` 的 JSON
- `dist/SkyCut.app/Contents/Helpers/skycut-web-motion` is there, arm64 and signed like the app; fed `{}` on stdin it prints
  one result line saying the request could not be read and exits with code 2
- `strings ... | grep <新增字符串>` → 命中
- The build log says «Signature verified (developer-id, hardened runtime)» and, for the app and the DMG, «notarized, ticket
  stapled, Gatekeeper accepts it»; a «⚠️ No Developer ID on this Mac» anywhere means ad-hoc: don't ship it
- `codesign -dvvv` on the app and each helper → `TeamIdentifier=26TVX3S9FR`, `flags=0x10000(runtime)`, a `Timestamp=`;
  `codesign -d -r- dist/SkyCut.app` names `certificate leaf[subject.OU] = "26TVX3S9FR"`, not `cdhash H"…"`
- `spctl --assess --type execute -vv dist/SkyCut.app` and `spctl --assess --type open --context context:primary-signature
  -vv dist/SkyCut-<版本>-arm64.dmg` → `source=Notarized Developer ID`; `xcrun stapler validate` passes on both
- `swift run --arch arm64 SrtFlowCoreChecks` → "All 184 checks passed."
  （断言数会随功能增长，以当次输出为准）
- DMG：`/bin/bash scripts/check-dmg.sh dist/SkyCut-<版本>-arm64.dmg` 通过；按上节真开 Finder 验背景、图标位置和 Retina。
- 涉及 UI 改动时按 `docs/testing/gui-smoke-testing.md` 做真实窗口验证

## 公开下载发布

官网按钮和软件包分开管理。`skycut.app` 使用固定入口 `https://skylu.ai/download/skycut`，
由个人站仓库 `skysf/skystudio` 的 `_redirects` 将有 / 无尾斜杠两个入口 302 到
`https://downloads.skylu.ai/skycut/SkyCut-<版本>-<内容标识>-arm64.dmg`。因此单独更新软件包不需要
重建 Vercel 官网，也不要在官网里写死版本 URL。

「已通过 CI 的 main」= 这个提交上 main 那一轮（push）的 `check-all` 绿了就算（用户 2026-11-13 定）。那一轮是短轮时
（树已经在 PR 那一轮原样验过，见「CI」一节「合并之后 main 上那一轮」），每组的摘要里写着是哪一轮 PR 的 CI 验的这棵树；
不另要求发版前再完整跑一轮。
Since 2026-11-17 a new merge cancels the older main runs (「CI」), so an older commit's run is usually cancelled: release
the newest, or re-run that commit's run (a re-run cancels nothing) and wait for green. Docs-only main merges now run
the full checks too, so their own green `check-all` is sufficient. For commits using the earlier scan-only main
workflow, a docs-only release commit also needs its newest code ancestor's green main run; re-run it if cancelled.

流程：从已通过 CI 的干净 main 显式指定 `VERSION` 打包（since 2026-11-26 signed with the Developer ID and notarized: verify
the team and Gatekeeper's «Notarized Developer ID» per the acceptance checklist）；核对包内版本、
arm64、MCP 初始化与 ffmpeg 可运行，挂载 DMG 核对实际携带的 App。再复用 `scripts/r2.py`
上传新版本对象（凭证位置见该文件开头），从公开地址完整读回，比对大小与 SHA-256 后，
才在个人站隔离分支修改两条重定向，检查、PR 合并并等待 Cloudflare Pages 发布。
最后从固定入口实际下载核对新包。版本文件给 immutable 缓存，不能用新内容覆盖旧版本名。
上传前不要用公开正式 URL 探测“文件还不存在”：当前 CDN 会把 404 缓存 4 小时，HEAD
也会踩中；需要探测时用存储 API。发布对象带 DMG 内容哈希前缀，先上传、再访问公开 URL。
遇到已缓存的 404 时使用未被探测过的内容寻址版本对象，不扩大令牌权限或清空整个站点缓存。

**Tool vocabulary for Sky Studio** (since 2026-11-19, MCP-62): from the same commit and with the same VERSION as the package,
`VERSION=x.y.z scripts/export-tool-vocabulary.sh skycut-x.y.z.json` writes the file Sky Studio's content gate checks
published editing styles and craft cards against. Hand it to ops for the content root's `vocab/` folder, so new content is
checked against the build users have. Rules: [AI interface (MCP)](../architecture/ai-control-mcp.md) section 4 item 32.

发布守卫 `python3 scripts/check-release-download.py <本地已验证的.dmg> --url <候选直链>`
核对实际 HTTP 200、下载域名、大小和全文件 SHA-256；切换入口后不带 `--url` 再跑一次，
会经正式入口验证 302 后拿到的完整内容。任一不符非零退出，不把 206 局部下载算完整验证。
它不进每个 PR 的 check-all：CI 没有本地签名包，且未发布的候选不能要求线上已存在。
CDN 缓存属于外部状态，每次发布都要执行这条真实网络检查；反向验证见
[新下载地址的 404 缓存](../bugfixes/2026-11-05-release-download-cached-404.md)。

2026-11-05，用户明确授权替换旧下载包，发布 **0.18.57**：

- 构建源码：已通过 CI 的 main `6aa24d2de7479504edeb044e9748c2cefb105be2`。
- 产物：`SkyCut-0.18.57-arm64.dmg`，33,105,257 字节；原来的本地测试包保留，不将
  `0.18.56-local.*.officialfilm` 当成正式版本上传。
- SHA-256：`32b9118d79e509d6e02b937c50b7baa85c439a60feb1a60d00a0f807471bfd68`。
- 公开对象：`skycut/SkyCut-0.18.57-32b9118d79e5-arm64.dmg`，上传后完整下载回读一致。
- 本地包和 DMG 内 App 的深度签名校验通过，均钉在仓库原签名证书
  `76d275650223bc09efe7708900458dbdb0ab90ef`；未重建证书，未退回 ad-hoc。
- `hdiutil verify` 通过，挂载包与本地 App 主程序字节一致；包内 MCP 初始化报告
  `skycut` / `0.18.57`，ffmpeg 可运行，架构为 arm64。

2026-11-05，用户授权本机安装并更新下载入口，随森林主题发布 **0.18.58**：

- 构建源码：完整 CI 通过的 main `f9d5d63f71c3017af6a64bd19e148daca5e93488`，包含
  [主题 PR #315](https://github.com/skysf/SkyCut/pull/315)。
- 产物：`SkyCut-0.18.58-arm64.dmg`，33,122,665 字节；SHA-256：
  `a0e7ea78f9e5236c389db6bf455da05fc98c49aea4d4a26dc09d4a87aa3df141`。
- 公开对象：`skycut/SkyCut-0.18.58-a0e7ea78f9e5-arm64.dmg`，使用 immutable 缓存。
  先上传再从公开直链完整回读，大小、全文件 SHA-256 与本地 DMG 一致。
- `hdiutil verify`、本地 App 与挂载包内 App 的深度签名均通过；原固定证书不变。
  两份主程序字节一致，均含主题偏好标记；MCP 初始化报告 `skycut` / `0.18.58`，
  ffmpeg 可运行，架构为 arm64，包内授权声明为当前 AGPL-3.0。
- 本机 `/Applications/SkyCut.app` 已替换为同一构建并重新打开原工程；工程文件字节
  不变、录屏权限仍为 granted，原 App 保留在本机临时备份目录。原生窗口确认森林色
  和新图标，`get_settings` 报告当前与默认主题均为 `forest`。
- 个人站的两条固定下载入口由
  [skystudio PR #13](https://github.com/skysf/skystudio/pull/13) 更新，网站页面与 Vercel
  官网构建未改变。每次发布仍须执行上述固定入口的完整下载守卫。

2026-11-06，用户拍板发版，发布 **0.18.59**（发版与验收事实由 Claude 提供）：

- 构建源码：已通过 CI 的 main `81b6ca887c00663f7e7d9de5dfb4f4b1a76e2a37`，包含
  #319、#321–#323 的客户端改动；用 `VERSION=0.18.59 arch -arm64 /bin/bash scripts/build-app.sh` 打包。
- 产物：`SkyCut-0.18.59-arm64.dmg`，33,154,366 字节；SHA-256：
  `6b510389d6681154c76f1a8874a03e56383a0d348964a04d63f2d5e471d58b30`。
- App 为 arm64，Info.plist 版本为 `0.18.59`。签名仍钉在原固定证书
  `76d275650223bc09efe7708900458dbdb0ab90ef`，没有退回 ad-hoc；本地 App 与挂载 DMG 内
  App 的深度签名校验均通过。`hdiutil verify` 通过，挂载包内主程序与本地构建字节一致。
- MCP 初始化报告 `skycut` / `0.18.59`；ffmpeg 能运行，ffmpeg 与 `skycut-mcp` 均为 arm64，
  包内授权声明为当前 AGPL-3.0。新增字符串 `machine_limit_reached`、
  `Open Sky Studio to update your payment method`、`Open Sky Studio to renew SkyCut Pro` 均在包内。
- 公开对象：`skycut/SkyCut-0.18.59-6b510389d668-arm64.dmg`，使用 immutable 缓存。
  先上传，再用 `scripts/check-release-download.py --url` 从公开直链完整读回，大小与 SHA-256 一致。
- 个人站 [skystudio PR #14](https://github.com/skysf/skystudio/pull/14)（合并提交 `6cd9103`）
  将 `/download/skycut` 两条重定向改到新对象，Cloudflare Pages 部署成功。之后不带 `--url`
  再跑 `scripts/check-release-download.py`，经固定入口 302 拿到的完整内容与本地 DMG 一致。
- 发版时 SkyCut 正在运行，本机 `/Applications/SkyCut.app` 没有替换，仍为 `0.18.58`。
  没有打 git tag，也没有创建 GitHub release，与 0.18.57 / 0.18.58 的做法一致。

2026-11-06，随 DMG 安装引导背景发布 **0.18.60**（发版与验收事实由 Claude 提供）：

- 构建源码：已通过 CI 的 main `83e02b0`（[PR #327](https://github.com/skysf/SkyCut/pull/327)：DMG 用双语 Retina
  安装引导背景和固定 Finder 布局取代旧 txt）；App 本身只有版本号变化。
- 产物：`SkyCut-0.18.60-arm64.dmg`，33,404,452 字节；SHA-256：
  `5a2cfd505e53f659d5f86730bf9956bf3cb6e1315ecddaa20b704988727edf53`。签名仍钉在原固定证书。
- 公开对象：`skycut/SkyCut-0.18.60-5a2cfd505e53-arm64.dmg`，immutable 缓存，先上传、从公开直链完整读回一致；
  个人站 [skystudio PR #15](https://github.com/skysf/skystudio/pull/15)（合并提交 `c4ce149`）切换两条入口，
  之后经固定入口完整下载核对一致。
- 当天录「如何在 Mac 上安装 SkyCut」教程时，本机正式版从 0.18.58 经这个 DMG 装成 0.18.60。

2026-11-06，用户拍板发版，发布 **0.18.61**（发版与验收事实由 Claude 提供）：

- 构建源码：已通过 CI 的 main `b69414c8a5474b477cb20dee3d6b8412e42cfdbb`，包含
  [#328](https://github.com/skysf/SkyCut/pull/328)（录屏账本按 bundle id 分开，正式版和测试版不再互相接管录制）与
  [#330](https://github.com/skysf/SkyCut/pull/330)（录屏结束在界面和 MCP 都说清结果）；
  用 `VERSION=0.18.61 arch -arm64 /bin/bash scripts/build-app.sh` 打包。
- 产物：`SkyCut-0.18.61-arm64.dmg`，33,437,051 字节；SHA-256：
  `caa5f05092b77c07579c56b481188369633071ed8279371cb2b22abc2e142ee1`。
- App、ffmpeg、`skycut-mcp` 均为 arm64，Info.plist 版本为 `0.18.61`；签名钉在原固定证书
  `76d275650223bc09efe7708900458dbdb0ab90ef`，本地 App 与挂载 DMG 内 App 的深度签名校验均通过。
  `hdiutil verify` 通过，挂载包内主程序和 `skycut-mcp` 与本地构建字节一致；`scripts/check-dmg.sh` 通过。
- MCP 初始化报告 `skycut` / `0.18.61`；ffmpeg 8.1 能运行；新增字符串 `Open recorded project` 在包内。
- 公开对象：`skycut/SkyCut-0.18.61-caa5f05092b7-arm64.dmg`，immutable 缓存。先上传，再用
  `scripts/check-release-download.py --url` 从公开直链完整读回，大小与 SHA-256 一致。
- 个人站 [skystudio PR #16](https://github.com/skysf/skystudio/pull/16)（合并提交 `d887716`）把两条入口改到新对象，
  Cloudflare Pages 部署成功；不带 `--url` 再跑一次，经固定入口 302 拿到的完整内容与本地 DMG 一致。
- 本机 `/Applications/SkyCut.app` 和 `/Applications/SkyCut Beta.app`（同一构建经 `build-beta-app.sh`）都换成 0.18.61，
  旧的两份进了废纸篓；两边 `get_status` 都报 `0.18.61`、Pro、录屏授权 granted。
- 实机回归：测试版录屏时打开正式版，录制照常进行到停止（105 秒，修复前约 30 秒就失败）；测试版账本只在
  `Application Support/com.srtflow.SrtFlow.beta/`，共用的 `SrtFlow/` 下没有账本。按时长停止的录制，`get_job`
  报存到哪个文件、入轨到哪个工程哪个 clip、谁停的；之后再调 `record_screen action=stop` 返回 `already_stopped`
  和同一份结果，不再说什么都没录到。
- 没有打 git tag，也没有创建 GitHub release，做法同前。

2026-11-07，随全部图片模型和角色系统发布 **0.18.62**。用户授权「完成剩下的」，发版与验收事实由 Claude 提供。

构建：
- 源码：已通过 CI 的 main `5edfed3e6c3c0999718ccb2bd989f3bcfd4352da`，包含两个 PR：
  - [#334](https://github.com/skysf/SkyCut/pull/334)：图片换角度、放大，以及生成图片按实际字节定扩展名；
  - [#336](https://github.com/skysf/SkyCut/pull/336)：角色的 `list_characters` / `get_character` / `manage_characters`。
- 打包命令：`VERSION=0.18.62 arch -arm64 /bin/bash scripts/build-app.sh`。
- MCP 清单 58 个工具，总长度在用户 2026-11-07 抬到的 110,000 字以内。

产物：
- `SkyCut-0.18.62-arm64.dmg`，33,695,016 字节；SHA-256：`70a81b192e80912c8a00fe4f7c2d68f25943a255e64df3d5ff68aee35c41519e`。

校验：
- 包：
  - `hdiutil verify` 通过；
  - Info.plist 版本 `0.18.62`；
  - App 主程序、ffmpeg、`skycut-mcp` 均为 arm64。
- 签名：
  - 钉在原固定证书 `76d275650223bc09efe7708900458dbdb0ab90ef`；
  - 挂载 DMG 里的 App 深度签名校验通过。
- 字节一致：DMG 里的三份二进制与本机安装的 `/Applications/SkyCut.app` 逐字节相同。
- 运行：
  - MCP 能初始化；
  - ffmpeg 8.1 能运行；
  - `scripts/check-dmg.sh` 通过。

发布：
- 公开对象：`skycut/SkyCut-0.18.62-70a81b192e80-arm64.dmg`，immutable 缓存。
- 先上传，再用 `scripts/check-release-download.py --url` 从公开直链完整读回，大小与 SHA-256 一致。
- 个人站 [skystudio PR #17](https://github.com/skysf/skystudio/pull/17)（合并提交 `645c73e`）把两条入口改到新对象，约 30 秒后 Cloudflare Pages 生效。
- 不带 `--url` 再跑一次，经固定入口 302 拿到的完整内容与本地 DMG 一致；带尾斜杠的入口 302 到同一个对象。

安装：
- 本机 `/Applications/SkyCut.app` 和 `/Applications/SkyCut Beta.app` 都是 0.18.62。测试版用 `build-beta-app.sh` 打包，同一把证书。

真积分验收：
- 见[全部图片模型与角色系统的真积分验收](../reports/2026-11-07-image-models-and-characters-smoke.md)。
- 新图片模型、换角度和角色全部成功，共 208 积分。
- 图片放大坏在 Sky Studio 的服务商（Google 下线了 Imagen 放大），已退款。当天 Sky Studio PR #243 换成 fal SeedVR2 并受控发布，补测 x2 / x3 通过。

升级时的钥匙串：
- 装上新版后第一次读 Sky Studio Key 会弹钥匙串框要登录密码，原因是没有 Team ID，钥匙串分区名单按构建的代码哈希记。
- 这次 AI 调用一直等在框后面，详见同一份报告。
- 要点「始终允许」，否则每次启动都会再问。

没有打 git tag，也没有创建 GitHub release，做法同前。

2026-11-08，修完 0.18.62 验收里发现的问题，发布 **0.18.63**。用户 2026-11-07 说「把你发现的问题都优化了，按照你的建议来」，并决定暂不买 Apple 开发者账号。发版与验收事实由 Claude 提供。

构建：
- 源码：已通过 CI 的 main `29d811cf42abca07ea340efca967a9486e7b783a`，包含两个 PR：
  - [#340](https://github.com/skysf/SkyCut/pull/340)：角色精简列表、换角度 / 放大的成品按源图起名、结束的任务不报阶段、角色正常完成的说法、图片宽高从文件读；
  - [#341](https://github.com/skysf/SkyCut/pull/341)：新构建启动不弹钥匙串框、AI 调用不等框、每个构建提示一次。
- 打包命令：`VERSION=0.18.63 arch -arm64 /bin/bash scripts/build-app.sh`。

产物：
- `SkyCut-0.18.63-arm64.dmg`，33,703,436 字节；SHA-256：`d70e816f5e47319d827be05da5f3fc52a24b151863df89b346044e624f4b917b`；App 的 CDHash `6d5415ca…`。

校验：
- 包：
  - `hdiutil verify` 通过；
  - Info.plist 版本 `0.18.63`；
  - 主程序、ffmpeg、`skycut-mcp` 均为 arm64，挂载包里的三份与 `dist/SkyCut.app` 逐字节相同。
- 签名：
  - 钉在原固定证书 `76d2…90ef`，深度签名校验通过；
  - `TeamIdentifier=not set`，和以前一样。
- 运行：
  - MCP 初始化报告 `skycut` / `0.18.63`；
  - ffmpeg 8.1 能运行；
  - 新提示条的文案在包内；
  - `scripts/check-dmg.sh` 通过。

发布：
- 公开对象：`skycut/SkyCut-0.18.63-d70e816f5e47-arm64.dmg`，immutable 缓存。
- 先上传，再用 `--url` 完整读回一致。
- 个人站 [skystudio PR #18](https://github.com/skysf/skystudio/pull/18)（合并提交 `cb05b01`）切换两条入口；不带 `--url` 经固定入口完整下载一致，带尾斜杠的入口 302 到同一个对象。

安装：
- 本机正式版和测试版都换成 0.18.63，测试版的 identifier 是 `com.srtflow.SrtFlow.beta`，同一把证书；旧的两份进了废纸篓。

升级时的钥匙串（实测）：
- 启动没有系统框，`get_status` 报 `keychain_permission: "required"`，AI 的付费工具立刻回恢复步骤。
- 用户点提示条的「允许…」、输登录密码、选「始终允许」之后，分区名单加上了这一构建。
- 重开同一构建不再问。
- 详见 [钥匙串的 bugfix](../bugfixes/2026-11-07-keychain-prompt-blocks-ai-calls.md)「实机验证」。

真积分验证 #340（28 积分）：角色列表 28 条 10,786 字（原来 79,969 字），换角度成品叫 `<源图名> angle.png`，图片宽高从文件读，结束的任务不报阶段。

没有打 git tag，也没有创建 GitHub release，做法同前。

2026-11-10，发布声音功能的中间版 **0.18.64**。Sky Studio 的声音服务当晚上线后，装着的 0.18.63 用不了 Sky Studio 的克隆和云端旁白。用户选了「中间版」并批准发版：声音 PR 6（声音库的 MCP 工具）和 PR 3–5 的审查修正一合进 main 就打包，先把 AI 旁白和用自己的声音克隆恢复；声音库界面（PR 8）、全部权限的长期授权（PR 7）、右键换声音（PR 9）下一版再发。发版与验收事实由 Claude 提供。

构建：
- 源码：main `d50b1db31aad8aa34b4baadf64de97a788910bf6`，等这个提交 push 那一轮 CI（5 组 + `check-all`）全绿才打包。0.18.63 之后合进来的客户端改动：
  - 声音：#345、#349、#353（声音目录合同，对齐 Sky Studio）；#346、#350（克隆的参考录音）；#355（PR 3：先整段报价再回任务号，预设声音按名字）；#364（PR 4：按池领槽，几批同时交）；#361（PR 5：旁白的字幕时间）；#362（PR 6：`list_voices` / `manage_voices`，用声音库的声音读稿）；#365（PR 3–5 的审查修正：付过钱的旁白不再卡住）；
  - 说明书 `skycut_guide`：#344、#348、#351、#354、#358；
  - #352：视频模型目录跟 Sky Studio（Omni 1.2，撤下 Veo 3.1 Pro）。
- 在单独的 worktree 里打包：`VERSION=0.18.64 arch -arm64 /bin/bash scripts/build-app.sh`，冷编 Release 约 10 分钟。
- worktree 里没有 `vendor/ffmpeg`：先用 `FFMPEG_LOCAL=<主 checkout>/vendor/ffmpeg scripts/vendor-ffmpeg.sh` 拷进来并校验，和以前各版是同一个 ffmpeg 8.1。

产物：
- `SkyCut-0.18.64-arm64.dmg`，34,202,304 字节；SHA-256：`42a6bdac2af15ffa182b7a06b45efb19eceb98bc1bd7512f4b1474a3f317c771`；App 的 CDHash `13fd8329…`。

校验：
- 包：
  - `hdiutil verify` 通过；
  - Info.plist 版本 `0.18.64`；
  - 主程序、ffmpeg、`skycut-mcp` 均为 arm64；挂载包里的整个 App 与 `dist/SkyCut.app` 逐字节相同（`diff -r`）。
- 签名：
  - App 和两个 Helpers 都钉在原固定证书 `76d2…90ef`，本地和挂载包内的深度签名校验都通过；
  - `TeamIdentifier=not set`，和以前一样。
- 运行：
  - 挂载包里的 `skycut-mcp` 初始化报告 `skycut` / `0.18.64`。socket 指到不存在的路径，碰不到正在运行的 0.18.63；
  - 清单 61 个工具，`skycut_guide` 排第一，`list_voices`、`manage_voices` 都在；
  - ffmpeg 8.1 能运行；
  - `voice_library_unavailable`、`estimated_split_line_indices` 等新字符串在包内；
  - `scripts/check-dmg.sh` 通过。

发布：
- 公开对象：`skycut/SkyCut-0.18.64-42a6bdac2af1-arm64.dmg`，immutable 缓存。
- 先上传，再用 `--url` 从公开直链完整读回一致。
- 个人站 [skystudio PR #19](https://github.com/skysf/skystudio/pull/19)（合并提交 `38ad76c`）切换两条入口，Cloudflare Pages 部署成功。
- 不带 `--url` 经固定入口完整下载一致；带尾斜杠的入口 302 到同一个对象。

安装：
- 发版时正式版在运行，`/Applications/SkyCut.app` 没有替换，仍是 0.18.63。
- 测试版换成 0.18.64：
  - `build-beta-app.sh` 从同一构建打包，同一把证书；
  - 去掉签名后，三份二进制与正式版逐字节相同；
  - 旧的进了废纸篓；只装好，没有启动。

升级时的钥匙串：
- 新构建第一次读 Sky Studio Key 时，要用户点提示条的「允许…」、输登录密码、选「始终允许」。和 0.18.63 一样，见[钥匙串的 bugfix](../bugfixes/2026-11-07-keychain-prompt-blocks-ai-calls.md)。
- 写这份记录时，这一步还没做。

没有打 git tag，也没有创建 GitHub release，做法同前。

2026-11-11，声音功能的 SkyCut 这一半全部合完，发布 **0.18.65**。用户睡前授权完成全部任务（含发版），2026-11-11 早上说「release skycut 0.18.65」。发版与验收事实由 Claude 提供。

构建：
- 源码：main `dfe6f7c42c72943dc69f14b3bcc069d47dfaad24`，这个提交 push 那一轮 CI（5 组 + `check-all`）全绿。0.18.64 之后合进来的客户端改动：
  - 声音：#367（PR 8：设置里的声音库、声音选择器、新建 / 设计声音）；#370（PR 7：全部权限下记长期授权，声音那几件事不再问）；#374（PR 9：`change_voice` 和片段右键「换成我的声音…」）；#372（`manage_voices` 的 `language` 可选，不给就本机识别）；#375（声音库审查的修正：收费单只下一次、账只记一次）；#379（设计声音的报价写出用的模型）；#371（AI 干活时不被 App Nap 降速，停下的旁白逐批说清）；
  - 说明书 `skycut_guide`：#359、#360（两批工具换成短名片 + 说明书主题）；#376（全清单收回 100,000）；
  - #373（花积分之前，用户原话没点名规格就照常先问）；#377（连接 Codex 时写进它的参数定义字节上限）；#380（进程内冒烟驱动的 `voice` 一步，声音库和变声的几个对话框挂上驱动的钩子）。
- 在单独的 worktree 里打包：`VERSION=0.18.65 arch -arm64 /bin/bash scripts/build-app.sh`，冷编 Release 288 秒。
- worktree 里没有 `vendor/ffmpeg`：先用 `FFMPEG_LOCAL=<主 checkout>/vendor/ffmpeg scripts/vendor-ffmpeg.sh` 拷进来并校验，SHA-256 与主 checkout 那份相同，还是同一个 ffmpeg 8.1。

产物：
- `SkyCut-0.18.65-arm64.dmg`，34,739,523 字节；SHA-256：`4e959bb1007c90511b9b23d801d0590e1dfe2bd13bdc50496431f2dd98ed35da`；App 的 CDHash `6a307aac…`。

校验：
- 包：
  - `hdiutil verify` 通过；
  - Info.plist 版本 `0.18.65`，麦克风的用途说明是 #367 改的那一版（录屏的解说、新建声音时录样音）；
  - 主程序、ffmpeg、`skycut-mcp` 均为 arm64；挂载包里的整个 App 与 `dist/SkyCut.app` 逐字节相同（`diff -r`）。
- 签名：
  - App 和两个 Helpers 都钉在原固定证书 `76d2…90ef`，本地和挂载包内的深度签名校验都通过，打包日志里没有退回 ad-hoc 的警告；
  - `TeamIdentifier=not set`，和以前一样。
- 运行：
  - 挂载包里的 `skycut-mcp` 初始化报告 `skycut` / `0.18.65`。socket 指到不存在的路径、不许拉起 App，碰不到正在运行的正式版；
  - 清单 62 个工具，`skycut_guide` 排第一，`change_voice`、`list_voices`、`manage_voices` 都在；全清单按 `CatalogBudget` 的量法（带外壳的 UTF-16）是 98,443，在 100,000 以内；
  - ffmpeg 8.1 能运行；
  - `voice_convert_source`、`voices/consent-grant`、`language_undetected`、`overrides_not_applied`、`unknown_line_indices` 和 App Nap 那句活动说明都在包内；
  - `scripts/check-dmg.sh` 通过。DMG 的图稿和 Finder 模板自 0.18.60 起没改。

发布：
- 公开对象：`skycut/SkyCut-0.18.65-4e959bb1007c-arm64.dmg`，immutable 缓存。
- 先上传，再用 `--url` 从公开直链完整读回一致。
- 个人站 [skystudio PR #20](https://github.com/skysf/skystudio/pull/20)（合并提交 `5d91143`）切换两条入口，Cloudflare Pages 部署成功。
- 不带 `--url` 经固定入口完整下载一致；带尾斜杠的入口 302 到同一个对象。

安装：
- 发版时正式版在运行（0.18.64，2026-11-10 晚上换上的），先没有替换。用户退出之后，同一天从这个 DMG 换成 0.18.65，和 DMG 里的 App 逐字节相同（`diff -r`），旧的进了废纸篓。
- 换的时候两个 Codex 会话的 `skycut-mcp` 还是旧包里的，照常跑着、没有停：它们下一次调用时从 App 拿新清单（`MCPCatalogSync`）。
- 测试版换成 0.18.65：
  - `build-beta-app.sh` 从同一构建打包，同一把证书；
  - 去掉签名后，三份二进制与正式版逐字节相同；
  - 旧的进了废纸篓；只装好，没有启动。

升级时的钥匙串：
- 新构建第一次读 Sky Studio Key 时，要用户点提示条的「允许…」、输登录密码、选「始终允许」。和 0.18.63 一样，见[钥匙串的 bugfix](../bugfixes/2026-11-07-keychain-prompt-blocks-ai-calls.md)。
- 写这份记录时，这一步还没做。

没有打 git tag，也没有创建 GitHub release，做法同前。

2026-11-11，修完 0.18.65 之后发现的问题，发布 **0.18.66**。用户上午说「0.18.66 no rush, go on the public and my Mac when all bug and issues are fixed」，之后又说「修完直接合，然后发 0.18.66」。发版与验收事实由 Claude 提供。

构建：
- 源码：main `d74aacf402a743a763e2511865b54539827bf69f`，这个提交 push 那一轮 CI（5 组 + `check-all`）全绿。0.18.65 之后合进来的客户端改动：
  - #386（钥匙串只是慢时，AI 收到「过几秒同样的调用再来一次」，不再被叫去让用户点「允许…」）；#387（SkyCut 重启之后接着跟在建的声音库那一单，不再问一遍价、多记一笔）；#383（`set_settings` 的回答里两处长期授权说的是同一件事）；
  - 界面：#388（系统深色 + 森林色时提示是浅底深字）；#389（森林色的提示外面不再套一圈直角方框）；#390（系统深色时森林色切经典色，开着的窗口整个跟着变）；
  - #391（预览的音频引擎停着 2 分钟没人用就停图，Mac 能空闲睡眠、App Nap 生效；用户回到 SkyCut 就在后台先起好）；
  - 其余合进来的只有文档和报告：#382、#385（0.18.65 的发布记录）、#384（声音真实冒烟的 AI 工具那一半）。
- 在单独的 worktree 里打包：`VERSION=0.18.66 arch -arm64 /bin/bash scripts/build-app.sh`，Release 编译 244 秒（整个脚本 260 秒）。
- `vendor/ffmpeg` 还是 0.18.65 时从主 checkout 拷进来的那份，SHA-256 与主 checkout 相同，同一个 ffmpeg 8.1。

产物：
- `SkyCut-0.18.66-arm64.dmg`，34,481,396 字节；SHA-256：`ed755d81d1b766baebf0a2a29903a3042785c7939be0d6fed0c647e14cf5890b`；App 的 CDHash `05d6fc08…`。

校验：
- 包：
  - `hdiutil verify` 通过；
  - Info.plist 版本 `0.18.66`；
  - 主程序、ffmpeg、`skycut-mcp` 均为 arm64；挂载包里的整个 App 与 `dist/SkyCut.app` 逐字节相同（`diff -r`）。
- 签名：
  - App 和两个 Helpers 都钉在原固定证书 `76d2…90ef`，本地和挂载包内的深度签名校验都通过，打包日志里没有退回 ad-hoc 的警告；
  - `TeamIdentifier=not set`，和以前一样。
- 运行：
  - 挂载包里的 `skycut-mcp` 初始化报告 `skycut` / `0.18.66`。socket 指到不存在的路径、不许拉起 App，碰不到正在运行的正式版；
  - 清单 62 个工具，`skycut_guide` 排第一；全清单 98,443（带外壳的 UTF-16），和 0.18.65 一样：这一批没有改工具清单；
  - ffmpeg 8.1 能运行；
  - `scripts/check-dmg.sh` 通过。
- 这一批的改动都在包里（和 0.18.65 的主程序比，新包有、旧包没有）：
  - #386：给 AI 的「The macOS keychain has not answered SkyCut yet…」；#387：在建单的 UserDefaults 键 `SrtFlow.skystudio.voiceLibraryOrders.v1`；
  - #388：提示面板设外观用到的 `setAppearance:`、`appearanceNamed:`（0.18.65 的主程序里一处都没有）；#390：`SystemColorScheme`、KVO 的 `effectiveAppearance`；
  - #391：`srtflow.audio-engine.idle-log`、`srtflow.audio-engine.start`、`running-but-stopped` 和停图 / 起图的日志；
  - #389、#383 不带新字符串，查构建产物：发出去的主程序和 Release 构建产物 `strip -xS` 之后 38 个 section 逐字节相同（只差 `__LINKEDIT` 和签名的大小）。产物的符号里有 #389 的 `TooltipContent.bubble`，提示宿主的类型在 `AppThemeModifier` 外面再套 `_ClipEffect<RoundedRectangle>`（裁切在主题外面）；反汇编 `set_settings` 的 async 片段，`modeChanged` 返回之后才 `snapshot("all")`（#383 的顺序）。
- 没做的：只能用真鼠标过的人工清单（系统深色 + 森林色时鼠标停在按钮上看提示、来回切主题看开着的窗口）这次发版没有实机过：发版时用户在主屏录课，不能动屏幕。

发布：
- 公开对象：`skycut/SkyCut-0.18.66-ed755d81d1b7-arm64.dmg`，immutable 缓存。
- 先上传，再用 `--url` 从公开直链完整读回一致。这次上传很慢（经本机的代理，34 MB 约 13 分钟），没有出错。
- 个人站 [skystudio PR #21](https://github.com/skysf/skystudio/pull/21)（合并提交 `f1c4c04`）切换两条入口，Cloudflare Pages 部署成功。
- 不带 `--url` 经固定入口完整下载一致；带尾斜杠的入口 302 到同一个对象。

安装：
- 发版时本机没换：用户在用正式版 0.18.65 录课（Codex 在操作它，`/Applications/SkyCut.app` 的主程序和三个 `skycut-mcp` 都在跑）。
- 同一构建的测试版已经打好（`build-beta-app.sh`，同一把证书，去掉签名后三份二进制与正式版逐字节相同）。
- 录完课用户同意换之后，等用户自己退出正式版（23:10:51）再换（23:11:15）：没有替用户退出、没有 kill。正式版和测试版都是 0.18.66（build 1），
  两个都过 `codesign --verify --deep --strict`，App、`skycut-mcp`、ffmpeg 都是钉着的那把证书，正式版的 CDHash 就是上面的 `05d6fc08…`；
  旧包在废纸篓（`SkyCut-0.18.65.app`、`SkyCut Beta-0.18.65.app`）。换完两个都没启动，新构建第一次读 Key 的钥匙串授权留给用户。
  换的时候 Codex 的两个 `skycut-mcp` 还在跑旧的那份，下一次调用时在后台拉起的是 `/Applications` 里的 0.18.66。

升级时的钥匙串：
- 换上之后，新构建第一次读 Sky Studio Key 时，要用户点提示条的「允许…」、输登录密码、选「始终允许」。和 0.18.63 一样，见[钥匙串的 bugfix](../bugfixes/2026-11-07-keychain-prompt-blocks-ai-calls.md)。

没有打 git tag，也没有创建 GitHub release，做法同前。

2026-11-20, nine days and 143 merges after 0.18.66, publish **0.18.67**. The user's OK that evening: 「发布 0.18.67 (Recommended)」
(the public link still served 0.18.66 from 11-11). Release and verification facts by Claude.

Build:
- Source: main `ea1beed540cf6b8674957c392345291ed845133a` (#546). That commit's own main run (all five shards and
  `check-all`, full checks) was green. Client changes since 0.18.66, PRs #392–#546, in short:
  - sound: joins across a cut with `set_transition` `sound` (#435, #439); ducking under speech with `set_track`
    `duck_others_db` (#475, #486); a clip's voice-band cut, `edit_clip` `voice_band_db` and its inspector slider (#479,
    #491, #537); `listen` per layer, voice masking and source-sound words (#431, #433, #456, #458); music accents and
    `hit_at` (#477); saved sound roles (#515, #524); true peaks (#448);
  - the web-motion renderer, helper `skycut-web-motion`, and stored motion clips (#443, #460, #465, #470, #472, #489,
    #494); motion presets (#434); canvas shape changes keep clips, texts and shapes (#445, #451, #463, #466);
  - saved project versions around AI rounds (#440); `inspect_video` delivery checks and stray frames (#438, #459, #481,
    #540); Sky Studio's editing styles and craft cards (#519, #538);
  - files: project writes, export folders and every open / save window off the main thread, and nothing replaced or
    deleted without confirmation (#478, #482, #484, #485, #488, #490, #495–#497, #500, #504, #507, #508, #512, #516);
  - playback: picture and sound start together after a pause, a hover, an edit and the idle stop (#499, #521, #531,
    #539);
  - the DMG install window in six languages with one guide link (#545).
- Packaged in its own worktree: `VERSION=0.18.67 arch -arm64 /bin/bash scripts/build-app.sh`. The Release compile took
  403 s, the whole script about 7.5 minutes; free disk went from 7.8 GiB to 6.8 GiB.
- `vendor/ffmpeg` came from the main checkout through `FFMPEG_LOCAL=… scripts/vendor-ffmpeg.sh`. Its SHA-256 matches the
  main checkout's: the same ffmpeg 8.1.

Product:
- `SkyCut-0.18.67-arm64.dmg`, 42,359,249 bytes; SHA-256
  `2fac9551c5ec3e59f2cc66ad78d007693c6b2fbdd6f0097f4cfad786bc4acdc9`; the App's CDHash `ce7941d5…`.

Checks:
- Package:
  - `hdiutil verify` passes;
  - Info.plist version `0.18.67` (build 1);
  - the main binary, ffmpeg, `skycut-mcp` and `skycut-web-motion` are all arm64;
  - the App in the mounted DMG is byte for byte the same as `dist/SkyCut.app` (`diff -r`).
- Signing:
  - the App and its three helpers are signed with the pinned certificate `76d2…90ef`;
  - the deep, strict signature check passes locally and in the mounted DMG; the build log has no ad-hoc warning;
  - `TeamIdentifier=not set`, as before.
- Running:
  - the mounted `skycut-mcp` initializes as `skycut` / `0.18.67`. Its socket pointed at a missing path and it was not
    allowed to launch the App, so it never reached the SkyCut that was running;
  - the catalog has 64 tools, `skycut_guide` first;
  - ffmpeg 8.1 runs;
  - names from this batch are in the new main binary and absent from 0.18.66's: `duck_others_db`, `voice_band_db`,
    `craft_cards`, `sound_role`, `set_motion`, `ProjectVersionStore`.
- DMG: `scripts/check-dmg.sh <dmg>` passes. The background TIFF, read out of the mounted DMG, shows all six languages
  and `www.skycut.app/docs`.
- Not done: the manual checklists that need a real mouse were not run for this release.

Publish:
- Public object: `skycut/SkyCut-0.18.67-2fac9551c5ec-arm64.dmg`, immutable cache.
- Uploaded first (10 s), then read back in full from the public direct link with `--url`: the same size and SHA-256.
- Personal site [skystudio PR #22](https://github.com/skysf/skystudio/pull/22) (merge commit `3283885`) switched both
  entries; Cloudflare Pages deployed it about 30 s after the merge.
- Without `--url`, the full download through the stable entry matches; the trailing-slash entry 302s to the same object.

Tool vocabulary for Sky Studio:
- `VERSION=0.18.67 scripts/export-tool-vocabulary.sh skycut-0.18.67.json` from the same commit: 64 tools, 69 guide
  topics, 788 known names, sources not dirty.
- The file is in the content root's `vocab/` folder; that folder was new, and it holds only this file.

Install:
- `/Applications/SkyCut.app` was not replaced: it was running (a local build, `0.18.66-local.20261120.81bb330e`, started
  23:09), and SkyCut is never quit for the user. The Beta stays 0.18.66; this release did not ask for it.
- `mdfind` for `com.srtflow.SrtFlow` listed nothing. Spotlight on this Mac was dropping apps that day; the packaging
  is not the cause.

升级时的钥匙串：
- When 0.18.67 replaces the installed copy, its first read of the Sky Studio Key needs the user to click the banner's
  「允许…」, enter the login password and choose 「始终允许」, as for 0.18.63 (see the
  [keychain bugfix](../bugfixes/2026-11-07-keychain-prompt-blocks-ai-calls.md)).

No git tag and no GitHub release, as before.

## CI（.github/workflows/checks.yml）

CI 跑的就是 `scripts/check-all.sh`，只是拆成几组、分到几台 runner 上并行跑。
**仓库是公开的，GitHub 托管的 macOS runner 免费**，免费档同时最多 5 台 macOS，所以拆成 5 组。

- **分组写在 check-all.sh 里**：`shard N` 一行，下面的 `run_check` 都归第 N 组。CI 用 matrix
  跑 `scripts/check-all.sh --shard N --of 5`；本地不带参数，照旧一口气全跑。
- **组数两边必须一致**：check-all.sh 读自己文件里的 `shard N` 声明，和 CI 传进来的 `--of`
  （`strategy.job-total`）对不上就直接红；分到的那组一项都没跑也红。不然多声明的那一组在
  CI 上永远不跑，而且是绿的。
- **`checks/` 顶层的每一条扫描守卫都要在 check-all.sh 里**（某一行 `run_check` 点名它）。`scripts/check-guards.sh`
  按通配符跑 `checks/*.sh`，推之前本地看到的是全绿，可 CI 只跑 check-all.sh 列着的：2026-11-04 查出四条守卫从加上
  那天起 CI 一次都没跑过（[案例](../bugfixes/2026-11-04-scan-guards-never-ran-in-ci.md)）。`checks/check-all-shards.sh` 钉着。
  要故意不进 CI 的检查（要图形会话、要真钥匙串）写成 `scripts/check-*.sh`，文件头写明为什么，别放 `checks/` 顶层。
- **汇总 job 叫 `check-all`**（ubuntu，几秒）：ruleset `protect-main` 要求的必需检查就是
  这个名字，所以改 CI 不用动 ruleset。它 `needs` 全部分组，而且必须带
  `if: ${{ !cancelled() }}`：不写的话，分组一红它就被跳过，**被跳过的必需检查会被 GitHub
  当成通过**，红的 PR 也能合进去。不用 `always()`，是免得被取消的那一轮再报一个假的失败。
- **Full-App checks run in shards 1–3, and every shard restores one full-App build cache** (since 2026-11-20,
  [measurements](../reports/2026-11-20-ci-rebalance.md)).
  - Shard 1 builds the complete App in its own step, "Build app": compile errors show in full there. check-all.sh also
    lists the plain build as a check ("build（完整 App 编得过）"). On main the step's result is saved as the cache that
    every shard of the next run restores (the cache item below).
  - A check that links the App's object files (`@"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList"`: video-inspection,
    motion-placement, voice-recovery and others) builds `--product SrtFlow` itself. In shards 2 and 3 the first such check
    compiles what changed since main's cache, one to four minutes. Shards 4 and 5 hold none: there a single one would add
    that build for one check. The other scripts build only the libraries they need (`swift build --target SrtFlowCore`).
  - Shard 1 is the graphical shard. The playback start benchmark runs before its checks and the preview perf ratchet
    after them, both on the App that "Build app" just built (in another shard the benchmark would compile inside its
    six-minute limit). It holds the lightest share of check-all, about 13 minutes in all, so re-running a timing flake
    costs that rather than the longest shard.
  - Until 2026-11-20 every full-App check had to sit in shard 1. Shard 1 grew from 8–10 minutes (through 11-17) to
    27–28 (11-19) while shards 2–5 took 8–11, and a flaky benchmark re-ran all of it.
  - `checks/check-all-shards.sh` pins the full-App shards, that every command runs exactly once and no check script
    drops out of CI, and that the graphical steps run after the App build in its shard.
- **自检二进制用 `-wmo` 编**（整模块一次编完）。同一份 40 个文件，默认的逐文件编译要
  12.5 秒，`-wmo` 只要 4.9 秒（本机 arm64、模块缓存已热）：逐文件模式下每个文件都要把
  其余文件重新解析一遍。CI 上拆分前，各项检查里编译占了约 300 秒、运行约 160 秒。
  `-enable-batch-mode` 实测编不过，别换成它。
- **同一个 PR 又推了新提交，旧的一轮直接取消**（`concurrency`），不白占 runner。
  **A new merge cancels the older main runs too** (since 2026-11-17, user's call): pushes to main share one group
  (`github.ref`), so a merge cancels the main runs that are still queued or running. On 2026-11-16 GitHub ran only about
  three macOS jobs at a time: main runs waited up to three hours, four of them queued at once, each needing five runner
  slots, while only the newest one matters.
  - Why that's safe: the newest main tree contains every earlier merge. Its run either checks it, or skips the checks
    because its pull request's green run checked exactly that tree (「合并之后 main 上那一轮」 below); the cancelled
    merges get checked as part of it.
  - Docs-only main merges always run the full checks, even if their tree matches a green PR marker: that PR only
    ran scans and cannot verify inherited code. Both `ci-docs-only.sh` and `ci-verified-tree.sh` return false for
    these pushes. This deliberately spends a full main run on docs merges instead of tracking ancestor runs and
    their cancellations through the API. Docs-only PRs keep the scan-only fast path; code merges keep exact-tree
    reuse. The earlier rule could cancel the only run checking a code merge's actual tree and replace it with scans:
    replaying 141 main runs from 2026-11-04 to 11-17 found two cases (#359 and #395, followed by docs-only merges).
    Regression and reverse-verification evidence: [docs-only cancellation gap](../bugfixes/2026-11-17-docs-only-main-cancels-unverified-code.md).
  - A re-run (`run_attempt` > 1) keeps a per-commit group. In the shared group, re-running an older main run cancels the
    newest one: tried on a throwaway branch on 2026-11-17 (ubuntu only), the re-run cancelled the newer run ("Canceling
    since a higher priority waiting request for … exists"); with the per-commit group both finished. So re-running a
    cancelled main run, or 「关掉开关再重跑」 below, cancels nothing, and the next merge doesn't cancel it.
  - A superseded run ends cancelled; the summary job `check-all` is skipped (`!cancelled()`), not red. It saves no
    `.build` cache, so the next pull request restores the newest one saved and compiles the difference.
  - `checks/ci-verified-tree.sh` pins the block word for word (PR runs by number, pushes by `github.ref`, re-runs by
    commit, `cancel-in-progress: true`, no job-level block).
- **Docs-only PRs take a fast path** (since 2026-11-04): each shard first runs `scripts/ci-docs-only.sh`. When true,
  compilation and self-checks are skipped; shard 1 runs `scripts/check-guards.sh` (including docs-index-drift), the
  others finish, and `check-all` still reports the result. Since 2026-11-17 main pushes always return false here,
  including docs-only merges, to cover cancelled ancestors; since 2026-11-20 so does the merge slot's dispatch on
  main. The slot's test runs on `merge-slot/pr-<N>` check out GitHub's test merge (first parent main) and classify
  like a pull request. Standard-input mode (`-`) only classifies the supplied paths, regardless of event, so
  `ci-verified-tree.sh` can reuse the same whitelist.
  - **白名单是严格的**：`docs/` 下的文件，根目录的 `AGENTS.md`、`README.md`、`SrtFlow-Requirements.md`。查过
    （2026-11-04），自检里读这几样内容的只有扫描守卫 docs-index-drift，编译、跑二进制的一样都不读。白名单外的任何一个
    文件、一个文件都没改、git 算不出来、路径被 git 加了引号，都按「不是」照常全跑；改名按「删旧的 + 加新的」算
    （`--no-renames`），把代码挪进 `docs/` 不算只改文档。往白名单里加东西之前，先查有没有检查读它。
  - **不能用 `on:` 里的 `paths` / `paths-ignore`**：那样整个 workflow 被跳过，必需的检查 `check-all` 永远等不到结论，
    PR 合不进去。所以是每一步各自看判断的结论，每一步都写成 `docs_only != 'true'`：判断那一步出了岔子（没输出、
    输出不是 true）就照常全跑。
  - `checks/ci-docs-only.sh` 钉着：判断本身（含在临时仓库里真提交的改名、合并提交、根提交）、每一步重活的条件、
    快速通道只在第 1 组、触发条件里没有 paths、汇总 job 照旧。
  - Its cases set every GitHub variable the classifier reads (`GITHUB_EVENT_NAME`, `GITHUB_REF`) themselves, and never
    inherit them from the run executing the check. The check runs its cases again as main's push and the merge slot's
    dispatch on main see them. Until 2026-11-20 a case inherited `GITHUB_REF=refs/heads/main`, and main's run after a
    docs-only merge went red ([case](../bugfixes/2026-11-20-ci-docs-only-check-red-on-main.md)).
- **合并之后 main 上那一轮：树已经验过就不再跑检查**（2026-11-13 起，用户定；量了什么、几种做法比下来怎样见
  [合并后 main 上那一轮的实测](../reports/2026-11-13-main-ci-verified-tree.md)）。
  - Since 2026-11-17 this reuse applies only to code merges. A docs-only merge always runs the full checks; a green
    scan-only PR marker does not prove that code inherited from a cancelled main run was tested.
  - Since 2026-11-20 the merge slot (below) dispatches this run on main, and `ci-verified-tree.sh` treats that
    dispatch like a push. A marker also counts when the slot's test run left it: a `workflow_dispatch` on
    `merge-slot/pr-<N>` whose head commit has exactly the merge's two parents, so the same tree by construction.
    `checks/ci-verified-tree.sh` pins both (30 cases).
  - 为什么：改代码的 PR 合进来，main 上要再跑一轮完整的，占满 5 台约 7.5 分钟。合出来的树和这个 PR 最后一次绿的那一轮测的树
    （GitHub 替它合的 `refs/pull/N/merge`）一模一样时，这一轮没有新东西可验：2026-08-16 到 11-13 能查到的 358 次合并里 308 次是这样，
    几件事并行的 11-04 到 11-13 是 104 次里 77 次。树不一样（ruleset 没开「合并前必须跟上 main」，PR 可以没跟上就合）照旧完整跑。
  - 记号：PR 那一轮全绿，汇总 job `check-all` 最后上传一个叫 `verified-tree-<这一轮检出的树>` 的 artifact（只留 1 天；两步都
    `continue-on-error`：留不下只是 main 上多跑一轮，不许让必需的检查变红）。main 上的那一轮不留。
  - 判断：每组在「只改了文档？」之后跑 `scripts/ci-verified-tree.sh`。它拿合并提交的树去找同名的 artifact，但认的是 GitHub 对上传它的
    那一轮的记录：本仓库 `.github/workflows/checks.yml`、`pull_request`、completed + success（重跑过的看最后一次）、头提交 = 合并提交的
    第二个父提交、不是 fork、建出来不到 24 小时（用户定）；合并提交要正好两个父提交（`gh pr merge --merge`，squash / rebase 合的不认）。
    查不到、接口出错、`gh` 不在、记号过期，一律打印 false、照常全跑。原因写进每组的摘要（`ci-verified-tree: …` 那一行）。
  - 短轮做什么：第 1 组取 `.build` 缓存、编 App、存缓存（约 1 分钟，下一个 PR 照样取到新的缓存）；其余四组十几秒就结束；
    跑检查、性能 ratchet、快速通道的扫描守卫都不跑。汇总 job 照样跑官网检查、照样给结论。
  - 写法：每一步都写成 `steps.verified.outputs.verified != 'true'`（和快速通道同一个写法：判断出岔子就照常全跑）；备缓存的几步是
    「没验过，或者第 1 组」；编 App 那一步不看它。顶层 `permissions` 给 `contents: read`、`actions: read`（读 artifact 和运行记录要它）。
    `checks/ci-verified-tree.sh` 钉着：判断本身的用例（临时仓库里真的合并提交 + 假的 `gh`，每个用例只改一个事实）、
    workflow 每一步的条件、记号只在 PR 的那一轮最后留。
  - 丢掉的是同一棵树的第二遍。到 11-13，main 上红过的 24 轮里 0 次是「PR 没跟上 main、合出来才坏」：12 次是检查自己不稳定（其中
    11 次是同一棵树的第二遍，以后要等下一个 PR 撞上），12 次是没分到 runner。PR 绿了之后到合并之间 runner 的镜像换了，也要等下一个 PR 才测到，
    所以记号只认 24 小时（历史上从那一轮建出来到合并最长 8.8 小时）。
  - **关掉**：`gh variable set CI_VERIFIED_TREE --body off`（仓库变量），下一轮起全部照常全跑，不用改代码；
    `gh variable delete CI_VERIFIED_TREE` 恢复。要把某个 main 提交完整跑一遍：关掉开关再重跑那一轮（重跑检出的还是原来那个提交，变量读的是
    重跑那一刻的值：2026-11-13 在只跑 ubuntu 的测试分支上实测），或者等记号过期（1 天）再重跑。
  - **上线之后看这几个数**：
    - main 上短轮占多少（摘要里 `was verified by run`）：应该和「树一模一样」的比例差不多（并行的日子一半多，顺着做的日子接近全部）。
      一直是 0 是查记号坏了：没漏验，只是没省。
    - **对账**（漏验只会出在这里）：挑短轮，摘要里写着 `verified by run R`；`gh run view R --log | grep -m1 'HEAD is now at'` 读出
      `Merge <头> into <当时的 main>`，`git merge-tree --write-tree <当时的 main> <头>` 的第一行要等于 `git rev-parse <main 的提交>^{tree}`。
      有一次不等，马上关掉开关。
    - PR 第 1 组「Build app」的中位数（11-04 到 11-13 是 40 秒）不该涨：涨了是第 1 组的缓存没存上。
    - PR 第 2–5 组「Run checks」的中位数（同期 307 秒）涨 30 秒以内：短轮不刷新这几组的缓存（用户定），涨得多再给短轮加一步刷新。
      Moot since 2026-11-20: every shard restores the one cache that shard 1 saves in short runs too.
    - PR 第一次红、原样重跑就绿的次数：明显变多，说明有不稳定的检查没人发现，单独去修。
- **Uploads are diagnostics, never gates** (since 2026-11-20, [case](../bugfixes/2026-11-20-ci-artifact-upload-fails-green-shard.md)):
  every `actions/upload-artifact` step has `continue-on-error: true`, so an artifact service timeout shows on that step
  and leaves the run's result to its checks. The measuring steps stay gates. `checks/check-all-shards.sh` pins it.
- **GitHub's own failures are re-run automatically, at most twice; a check's never** (since 2026-11-20,
  `.github/workflows/rerun-infra.yml` + `scripts/ci-infra-rerun.py`). On 11-19 GitHub gave up on queued macOS jobs
  after 48–76 minutes ("The job was not acquired by Runner of type hosted even after multiple attempts": the job ends
  cancelled, with no runner and no steps; runs 44557659527 and 44561816873), people re-ran them by hand, and the
  merge slot sent such PRs back.
  - When a checks run ends red, rerun-infra re-runs its failed jobs (check-all with them) only if every job that failed
    or was cancelled carries one of GitHub's own messages for a job that never got a runner or lost it ("was not
    acquired by Runner", "lost communication with the server", "runner has received a shutdown signal") and none
    that a step failed, a timeout, a newer push or a person cancelled; and if it started no step but the setup steps
    before the first check (`SETUP_STEPS` in the script: checkout, toolchain, the docs-only and verified-tree
    classifiers, file times, the two caches, fetching ffmpeg), at most one of them unfinished: the last, cut off.
    check-all may fail at "All shards passed" alone, since it only reports the shards.
  - Never re-run: a check that failed or timed out, a setup step that failed by itself, a runner lost during a check
    (the check may have starved it), a run a newer push or a person cancelled, a fork's run, a run whose branch has
    moved on or that isn't its branch's newest run (re-running a superseded PR run would cancel the newer one: same
    concurrency group). A run ends at attempt 3; after that it stays red for a person.
  - Replayed over every red or cancelled attempt from 11-19 00:00 to 20:48 UTC (89 attempts, 365 failed jobs): exactly
    the two not-acquired attempts qualify; every superseded, cancelled, timed-out and failed one doesn't.
  - The merge slot uses the same verdict and re-runs the runs it waits on itself ("Merge slot" below). When both try,
    GitHub takes the first re-run and the other finds it in progress.
  - `workflow_run` runs main's copy of rerun-infra with a write token for every checks run, pull requests from forks
    included, so the job skips forks' runs, checks out main and passes only the run's id and attempt to the script.
  - `checks/MergeSlot/InfraRerunCases.py` (run by `MergeSlotChecks.py`) tests the verdict on jobs built from this
    workflow's own step names and GitHub's own messages, and pins `SETUP_STEPS` to checks.yml (each a step of its job
    whose commands run no check) and rerun-infra's wiring. Rename a setup step in both files together.
- **Step failure rates** (a signal, never a gate): `scripts/ci-step-failure-rates.py [--days N | --since … --until …]
  [--exclude-branch B]` counts, per step of the shard jobs, how often it failed in pull request and main runs. It is
  read-only and needs any collaborator's `gh` login. The coordinator runs it daily. When the playback start benchmark fails
  in more than 5% of pull-request executions on branches that don't touch playback, recalibrate it
  ([playback start](../architecture/playback-start.md)). On the CI analysis' snapshot of 11-19 (to 15:10 UTC) it gives
  that analysis' count: the benchmark failed in 20 of 30 executions on other pull requests' branches
  ([measurements](../reports/2026-11-20-ci-rebalance.md)).
- **第 1 组多一步「预览性能 ratchet」**（`scripts/check-preview-perf.sh`，不在 check-all.sh 里：
  要图形会话）。它起第 1 组已经编好的 App，按固定场景数「做了多少件活」，和
  `checks/PreviewPerf/baseline.json` 比，只许降不许涨；结果和 App 日志作为附件 `preview-perf`
  上传，逐项对比写在汇总页。为了比「这个 PR 之前」的基线，checkout 带 `fetch-depth: 2`
  （PR 合并提交的第一个父提交）。规则见 [预览性能 ratchet](../architecture/preview-perf-ratchet.md)。
- **`.build` 缓存要真省下编译**（2026-11-04 起，[案例](../bugfixes/2026-11-04-ci-build-cache-never-saved-a-compile.md)）。
  以前的缓存从来没省下过一次编译：SwiftPM 判断要不要重编看的是修改时间「和上次记下的一不一样」，checkout 出来的时间每次都是
  新的，恢复回来的 `.build` 全当过期；五组又共用一个只看 `Package.swift` 的 key，谁先跑完谁存、命中了就再也不存。现在：
  - 编译之前先跑 `scripts/ci-stable-mtimes.py`：入库文件的修改时间按内容（git 的 blob id）算。内容没变的文件每次 checkout
    都是同一个时间；变了的换一个时间、照样重编 —— 哪怕新时间比上次编译还早，因为 SwiftPM 比的是「一不一样」不是「新不新」
    （`scripts/check-ci-build-cache.sh` 在小包上每次真验一遍，哪天 SwiftPM 改了它就红，不会拿旧的目标文件测新代码）。
  - Restored with `actions/cache/restore`, saved with `actions/cache/save`. Since 2026-11-20 there is **one cache for
    all shards**: the complete App build (every product) of shard 1's "Build app" step, key
    `swiftpm-<os>-<checkout>-<toolchain fingerprint>-app-<commit>`. restore-keys drop the commit, so a run restores the
    newest App build for the same checkout and toolchain. A second restore key, the old shard-1 cache (`…-shard1-`),
    covers the switch and stops matching once those entries expire. Before, each shard kept its own cache, keyed with
    its shard number, and only shard 1's held the App.
  - Saved on main only, by shard 1, right after "Build app" succeeds. A PR restores main's newest one: GitHub scopes
    caches by branch, so a PR's cache serves that PR alone, and the run after a merge prepares the next PR's cache.
    - Not at the end of the job, as before 2026-11-20: since 11-17 a newer merge cancels older main runs, and on busy
      days few lasted long enough to save. On 11-19, 5 of 12 sampled PR runs restored a cache 23–42 source files behind.
    - Only shard 1 saves, so the shared cache is always a complete App build. The 2026-11-04 bug was a shard that had
      built only the core library winning a shared key.
    - The verified main short runs (「合并之后 main 上那一轮」 above) restore, build and save in shard 1 as before, and that
      now refreshes the cache for every shard.
    - A cache entry is per commit and can't change; GitHub drops entries unused for seven days.
  - `checks/ci-build-cache-key.sh` pins all of this.
- **`.build` 缓存的 key 和 restore-keys 都带检出目录（`github.workspace`）**：`.build` 里的模块缓存记着编它时的绝对路径，
  换了目录恢复回来就编不过。2026-10-18 仓库改名 SkyCut、检出目录从 `…/SrtFlow/SrtFlow` 变成 `…/SkyCut/SkyCut`，旧缓存被恢复、
  五组齐红（[案例](../bugfixes/2026-10-18-ci-build-cache-breaks-after-repo-rename.md)）。`checks/ci-build-cache-key.sh` 钉着。

**How to group** (since 2026-11-20): pack by each check's time in the CI logs (`✓ 名字（N s）`), slowest first, each
into the emptiest shard it may go to. Full-App checks go to shards 1–3, everything else to shards 2–5. Count shard 1's
App build and its graphical steps (about six minutes together) and keep it the lightest, and count one App build
(about one to two minutes) in shards 2 and 3. Scan guards are seconds and compile nothing: they run first in a shard.
Add a new check to the emptiest shard it may go to, then look at the shard times on CI. Docs never say which shard a
check is in: only check-all.sh does, and a shard number written elsewhere goes stale at the next rebalance.

**实测**：

- 拆分前一轮约 10 分钟（check-all 508 秒 + 冷编 81 秒 + 其余步骤 17 秒；最慢的几项是
  export-frame-rate 84 秒、audio-fade 54 秒、clip-animation 40 秒）。
- 拆成 5 组、加上 `-wmo` 之后（2026-09-24，PR #65 首跑）**整轮 2 分 18 秒**。5 台几乎同时
  开跑（间隔不到 10 秒），各组 1 分 24 秒到 2 分 4 秒。第 1 组冷编完整 App 用了 52 秒。
  另外 4 组各有一笔固定开销：第一项检查要先编核心库（13–20 秒），编译器的模块缓存也是冷的。
  export-frame-rate 从 84 秒降到 44 秒。
- 第一次分组第 4、5 组偏重（纯检查耗时 81、86 秒，第 2、3 组 57、61 秒），把 media-import、
  text-render 挪去第 2、3 组，按上面的数字估算四组约为 69 / 74 / 68 / 74 秒。
- 挪完之后的第二轮**整轮 2 分 55 秒**，各组 1 分 11 秒到 2 分 42 秒。同样的检查换一台 runner
  能差 1.5–2 倍：player-clock 21 → 42 秒、export-frame-rate 44 → 63 秒，screen-recording-writer
  反而 27 → 18 秒。runner 都是 3 核（`hw.ncpu` = 3）、同一个镜像，差别在宿主机当时的忙闲。
  **所以分组只求大致均衡，别拿一轮的数字精调**。一轮大约 2–3 分钟，拆分前是 10 分钟。
- 2026-11-04（PR #302）**整轮又涨到 10 分 55 秒**，全卡在第 1 组：10 分 46 秒 = 冷编 App 2 分 43 秒 + 检查 4 分 39 秒
  + 性能 ratchet 3 分钟；另外四组 3 分 25 秒到 5 分 35 秒。第 1 组的检查里，6 项链接完整 App 的（约 130 秒）只能
  留在这里；另外约 141 秒是扫描守卫和纯值检查（光 check-script-source-lists 就 55 秒），按旧规矩放进来的。
  把这 141 秒挪进第 4、5 组之后，第 1 组估计约 8 分 25 秒，其余几组 5 分钟上下。
- 挪完的实测（PR #304 首跑）：**第 1 组 8 分 45 秒**（10 分 46 秒 → 省下 2 分钟），其余四组 4 分 8 秒到 5 分 2 秒。
  现在整轮就是第 1 组：冷编 App 和 3 分钟的性能 ratchet 占了它一大半，再往下降要靠 `.build` 缓存真省下编译。
- `.build` 缓存修好之后（PR #307，合并后 main 那一轮原样重跑）：五组都恢复了自己那份、重编 0 个文件，第 1 组编 App
  **2 分 12 秒 → 15 秒**，第 1 组 5 分 52 秒，**整轮约 6 分钟**（PR #302 是 10 分 55 秒）。这是「什么都没改」的下限，真 PR 只多编改了的那些。
  一个 PR 从本地到能合的整笔账见 [2026-11-04 一个 PR 要多久](../reports/2026-11-04-ci-speedup.md)。

**几个 PR 同时跑（2026-11-13 量的）**：CI 一次能并行几轮，排任务时按这里算。

- **macOS runner 同时最多 5 台**：GitHub 文档写 Free / Pro / Team 都是 5（Enterprise 50）。11-04 到 11-13 的 1,432 个 macOS job
  （去掉重跑时 GitHub 复制过来的那些）同一时刻最多正好 5 台在跑；有 job 在跑的时间里，一半是 5 台全满。
- **完整的一轮就要 5 台**，所以改代码的 PR 实际是一轮一轮排着跑的。按这一轮建出来时别的轮占着、排着多少个 macOS job 分，从建出来到最后一组跑完
  （中位数，括号里是 p90；汇总的 `check-all` 再加十几秒）：没有别的 7.5 分钟（10.7，110 轮）；约 1 轮 11.3 分钟（16.6，57 轮）；约 2 轮 17.6 分钟（22.7，29 轮）；
  3 轮以上 25.1 分钟（48.3，21 轮）。两个同时开着，后一个多等约 4 分钟；三个，最后一个约 18 分钟出结果。
- **合进 main 也跑一轮完整的**（给下一个 PR 备 `.build` 缓存、验真正合出来的那份）：同一时期跑完的 217 轮完整 CI 里 85 轮是 main 上的。
  合一个改代码的 PR 一共占两轮，合并之后约 7 分钟里新建的轮都得等它让出 runner。（后续：2026-11-13 起，树已经在 PR 那一轮原样验过时，
  这一轮只占第 1 组约 1 分钟，见上面「合并之后 main 上那一轮」。Since 2026-11-17 a new merge also cancels the older main runs
  still queued or running, see the `concurrency` item above.）
- **只改文档的快速通道也占名额**：一样起 5 个 macOS job，第 1 组跑扫描守卫约 2.4 分钟，其余四组各十几秒；没别的在跑时 2.5 分钟出结果，
  排在完整的轮后面时中位 5.7 分钟。占得少、可以多开，但不是不占。
- 变 DIRTY 就要再合 main、再跑一轮：哪些文件最常撞、为什么不用 `merge=union`（GitHub 不认），见[文档索引怎么写](../architecture/doc-indexes.md)第五节。

## Merge slot (.github/workflows/merge-slot.yml, since 2026-11-20)

The user's call on 2026-11-20 ("改成排队合并"): pull requests are merged one at a time, each only after a green
`checks.yml` run on the exact tree that lands. GitHub's merge queue isn't available to a personal-account repository.

- **Why.** Merge-when-green let two PRs land minutes apart, neither tested on top of the other: on 11-18 #476 and #481
  left main uncompilable for about 1.5 hours. Staying current cost even more. In the week to 11-19, authors merged main
  into their branches 85 times; 57 of those merges had no conflict, and each cancelled the run in progress.
- **Author procedure** (AGENTS.md 「合并与分支」): add the label `merge-slot` when the PR is ready to merge: as you
  open it if no review is pending, otherwise once the review (Codex, or the coordinator's read under
  [Code review rounds](../testing/code-review.md)) clears it. From then on, don't push or merge main unless the slot
  sends the PR back; it removes the label and comments why. Red: fix, push, label again.
  Known flake: re-run the failed jobs of the run it names, label again once green. Conflict: merge `origin/main`,
  push, label again. Done when the PR is MERGED. `scripts/merge-slot-wait.sh N [max minutes]` waits: exit 0 merged,
  1 sent back (it prints the slot's comment), 2 closed, 3 still queued at the time limit (run it again).
- **What the slot does** (`scripts/merge-slot.py`), oldest label first:
  1. It waits until `check-all` on the PR's head is green; red sends the PR back, unless GitHub's infrastructure failed
     the run before any check started: then the slot re-runs it, at most twice ("GitHub's own failures" in "CI"
     above), and waits; after two re-runs it sends the PR back with the by-hand re-run.
  2. It builds the test merge X itself: `merge-slot/pr-<N>` is pointed at the current main and the head is merged into
     it with the Merges API, so X's parents are (main, head). A 409 (conflict) sends the PR back. X is built once per
     main and head. It never uses GitHub's own test merge (`merge_commit_sha`): GitHub recomputes that for new commits
     on the PR, not when main moves ([case](../bugfixes/2026-11-20-merge-slot-waits-for-stale-test-merge.md)).
  3. If a green run already tested X's tree, it merges at once. The proof is a `verified-tree-<tree>` marker: from the
     PR's own run when main hasn't moved since, or from an earlier slot test.
  4. Otherwise it dispatches `checks.yml` on `merge-slot/pr-<N>`, which holds X. That is the same
     workflow file on the same tree as a pull_request run on main + head, docs-only fast path included. Nothing else
     is tested or merges while it runs ("One at a time" below). A red or cancelled run sends the PR back with its link;
     the branch stays, so re-running the run's failed jobs can still prove the tree. A run GitHub's infrastructure
     failed is re-run in place first, as in 1., and holds the slot meanwhile.
  5. It merges with `--merge`, the head pinned, only while main is still X's first parent. Then it dispatches
     `checks.yml` on main and deletes the PR's branch and `merge-slot/pr-<N>`.
- **PRs that change `.github/workflows/` can't use the slot.** GitHub doesn't let the workflow token create or update
  workflow files, so the slot can neither build their test merge nor merge them. It reads each PR's files and sends
  such a PR back at once with the by-hand path: merge origin/main into the branch, push, and once `check-all` is green
  run `gh pr merge N --merge` at once; merge main again first if main moved in between
  ([case](../bugfixes/2026-11-20-merge-slot-cannot-write-workflow-files.md)). These are rare (CI changes). The window
  between their green run and the hand merge is the one place two merges can still race.
- **The workflow token.** The slot merges with `GITHUB_TOKEN`, and a merge made with it starts no push run. So the slot
  dispatches `checks.yml` on main itself. `scripts/ci-docs-only.sh` and `scripts/ci-verified-tree.sh` treat that run
  like a push: never docs-only, and the usual verified short run when a marker proves the tree. The cache is saved on
  `github.ref == 'refs/heads/main'`. `checks.yml` takes dispatches on main and on `merge-slot/pr-<N>` only. On any other
  ref every shard is skipped, so `check-all` fails: a skipped required check would count as passed.
- **One at a time.** The job has `concurrency: merge-slot` with `cancel-in-progress: false`, so a run that finds the
  slot busy waits. Every run reads the whole queue from GitHub (labels, runs, markers), so nothing is lost when a newer
  waiting run replaces an older one. The script stops after 320 minutes; a new label or the half-hourly cron starts it
  again.
  - **One PR is under test at a time.** A PR holds the slot while a `merge-slot/pr-<N>` run of it is queued or in
    progress, for ten minutes after that run ends (a green test merges next, a red one sends the PR back), and for ten
    minutes after the job dispatched it (GitHub lists a dispatched run a little later). Only the holder moves, even
    when a PR with an older label turns green meanwhile. Of several holders, the earliest test holds.
  - `holder()` reads the runs from GitHub every pass, so the workflow's next job keeps the same holder. Until 2026-11-20
    each pass started again from the oldest label, and on 11-19 #531's test was dispatched while #532's ran
    ([case](../bugfixes/2026-11-20-merge-slot-tested-two-prs-at-once.md)).
- **Safety.** It merges only a tree that a green run tested, with the head pinned and main read just before merging. A
  manual merge in the second between those two calls could still land an untested tree, so nobody merges by hand. It
  never runs a pull request's code: `pull_request_target` runs main's copy of the workflow, and the job checks out main.
  The ruleset still requires `check-all` on the head.
- **Cost.** One ubuntu job while the queue isn't empty, polling every 90 seconds. That is about six API calls a pass,
  under the token's 1,000 an hour. A PR whose own run tested the current main gets no second run; otherwise it gets one
  slot test, which costs what a pull_request run does.
- `checks/MergeSlot/MergeSlotChecks.py` runs the slot against an in-memory GitHub (`FakeGitHub.py`) and pins both
  workflows. The fake copies GitHub's quirk that broke the first version: the test merge isn't recomputed when main
  moves, and its token can't write workflow files. Reverse verification on 2026-11-20: 24 mutations of the script each
  turned it red. Among them: merging without proof, skipping the last main check, reusing a test merge for another main
  or head, rebuilding it every pass, not detecting a workflow PR, an unpinned head, FIFO by number, not holding the
  slot during a test, and squash. It also runs `InfraRerunCases.py` (the automatic re-runs in "CI" above). Since
  2026-11-20 its slot tests can last 12 polls and be listed late, like GitHub's, so overlapping tests show.
