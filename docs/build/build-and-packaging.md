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

Release 构建 → 手写 Info.plist 组装 `dist/SkyCut.app`（SwiftPM 的可执行产品 `SrtFlow` 拷成 `Contents/MacOS/SkyCut`，产品名与代码名见 [产品名与代码名](../architecture/product-name.md)） → 拷入 SwiftPM 资源包、
vendor/ffmpeg 和 AI 客户端启动的 MCP 小程序 `skycut-mcp`（都在 `Contents/Helpers/`，
见 [AI 接口（MCP）](../architecture/ai-control-mcp.md)）→ 生成图标 → 签名（只经 `scripts/signing/sign-app.sh`：
**先签嵌套二进制再签外层**，顺序反了外层签名立即失效，`scripts/check-mcp.sh` 钉着 skycut-mcp 这一条；
用固定的签名身份签，见下方签名一节）→ `scripts/build-dmg.sh` 生成 Retina 引导背景、复制 Finder 布局模板，
再由 `hdiutil` 生成 DMG（HFS+、卷名仍是 `SkyCut`）。

产物：`dist/SkyCut.app`（约 52 MB）、`dist/SkyCut-<版本>-arm64.dmg`（2026-10-18 改名之前叫 `SrtFlow.app`、`SrtFlow-<版本>-arm64.dmg`）。

版本号：**正式发版必须显式传** `VERSION=x.y.z ./scripts/build-app.sh`。不传时
脚本兜底取最近的 git tag，并在 HEAD 领先该 tag 时警告「这是开发版产物」——
以前这里是写死的默认值，发到 0.4.1 了还停在 0.3.0，打出过贴错版本号的包，
见 [bugfixes/2026-08-06-build-version-and-shell-traps.md](../bugfixes/2026-08-06-build-version-and-shell-traps.md)。

## DMG 安装窗口（2026-11-06 起）

根目录只显示 `SkyCut.app` 和指向 `/Applications` 的 `Applications` 软链。首次打开说明直接在
Finder 背景中展示，不再放「首次打开必读 - Read Me First.txt」。App 仍用原自签名证书、暂不做
Apple 公证：背景教用户拖入应用程序，以及第一次被拦下时到「系统设置 › 隐私与安全性 › 仍要打开」。
中英文在同一张图上，教程地址为 `skycut.app/zh/docs` 和 `skycut.app/en/docs`，视频以后补到这些页面。
终端 `xattr` 兜底由 App 需要时自己显示，不放在安装图上。

- 图稿唯一来源：`scripts/dmg/make-background.swift`，只用系统 AppKit / Core Graphics 和系统字体。
  配色是暖白 `#f3f0e8`、森林绿 `#123f32`、深色正文；所有像素使用自己的不透明底色，不跟随系统深浅色变色。
  每次打包现生成 760×560（72 dpi）和 1520×1120（144 dpi）的 PNG，再用
  `tiffutil -cathidpicheck` 合成 `/.background/background.tiff` 的两种分辨率。
- 布局源：`packaging/dmg/DS_Store`，打包时拷成卷根的 `.DS_Store`。窗口框固定
  `{{120, 120}, {760, 648}}`（为标题栏及用户开启的路径 / 状态栏留出空间，图稿 760×560），图标 128 point，App / Applications
  中心为 `(200, 164)` / `(560, 164)`，分别在箭头两头；隐藏工具栏和侧栏。
  模板同时声明关闭状态栏 / 路径栏；Finder 可能沿用用户的这两项全局偏好，窗口高度仍能容下完整引导。
  背景 alias 使用卷内 `.background/background.tiff`，不携带开发机路径、卷 UUID 或 inode。
  `scripts/build-dmg.sh` **不控制 Finder、不调用 Apple Events**，正常打包不会申请「控制访达」权限。
- 模板可重复生成：只在主动改窗口布局时，临时安装 `ds-store==1.3.3`、`mac-alias==2.2.3`
  到 `/private/tmp/skycut-dmg-template-tools`，再执行
  `PYTHONPATH=/private/tmp/skycut-dmg-template-tools python3 scripts/dmg/make-layout.py`。
  这两个一次性工具不进正式依赖，打包和 CI 都不 import 它们。提交新模板前必须真挂载验收，
  图标坐标改动时同步图稿和 `scripts/dmg/check-layout.py` 的布局合同。
- 扫描守卫：`checks/dmg-packaging.sh` 钉正常打包接线、命名和不带旧 txt / Finder 自动化，
  用标准库解析模板的实际叶记录检查窗口、背景 alias 和图标位置。
- 产物检查：`scripts/check-dmg.sh` 不带参数时用小型 App 夹具真走生产组装器并挂载只读 DMG，
  检查背景、布局、软链、无 txt，并解码 TIFF 验两种像素尺寸 / DPI 和完整图稿。带 DMG 路径时验完整包。
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
   确认背景自动显示、两图标在箭头两头、三步中英文完整，Retina 屏上字体清楚、图标标签能读。
   深浅色下背景本身底色不变；不要为了验收打断用户工作、切换全系统外观。
   路径栏 / 状态栏必须按用户原有偏好重开检查；只在当前窗口手动隐藏后的截图不能证明模板生效。
3. 截图只存 `/private/tmp` 并在交接写路径，不入库；关闭本次开的窗口，卸载本次测试卷。
4. 删除测试 DMG 和同版 `dist/SkyCut.app`，避免未发布版本留在 `dist/`；不安装、不上传、不发版。

## 签名：一把固定的自签名证书（2026-10-03 起）

macOS 的录屏、麦克风、下载文件夹、钥匙串权限按签名认。ad-hoc 签名每出一个新版本就是「另一个 App」，用户给过的
权限全部作废，录屏那条在系统设置里拨开关都救不回来。所以发布版和测试版都用同一把自签名证书「SrtFlow Signing」签，
designated requirement 是「bundle id + 这把证书」，换版本不变。来龙去脉和规矩见
[签名与系统权限](../architecture/code-signing-and-permissions.md)。

- **私钥在仓库外** `~/.config/srtflow/signing/`（专用钥匙串 + 密码文件）；仓库里只钉证书的 SHA-1
  （`packaging/signing-identity.sha1`）。**备份这个目录；换机器把它整个拷过去，别重新建**：换证书 = 每个用户
  再授权一次，`sign-app.sh` 发现证书和钉着的不是一把会拒签。
- 第一次（以后不用再跑）：`scripts/signing/create-identity.sh`，已经有了就拒绝。
- 没有签名身份的机器（CI、自己编着用的人）退回 ad-hoc 并打一段 ⚠️ 警告：**这样的包别拿去发版**。
- 签名那几秒 `sign-app.sh` 会把专用钥匙串挂上钥匙串搜索列表、签完原样放回（codesign 只在列表里找身份）。

## 测试版（SkyCut Beta）

没合并的功能要给用户在自己机器上实测时：`VERSION=x.y.z scripts/build-app.sh && scripts/build-beta-app.sh`，得到 `dist/SkyCut Beta.app`。换了名字和 bundle id（`com.srtflow.SrtFlow.beta`：bundle id 沿用旧名），设置、AI 的通道都和正式版分开；每种文档类型都只做「备选」，双击工程文件仍由正式版打开。`build-app.sh` 会顺手打一个同版本号的 DMG、覆盖 `dist/SkyCut.app` —— 只出测试版时记得把它们删掉 / 换回去，别让 `dist/` 里留着贴了未发布版本号的包。

## 产物验收清单

- `lipo -archs dist/SkyCut.app/Contents/MacOS/SkyCut` → `arm64`
- `dist/SkyCut.app/Contents/Helpers/skycut-mcp` 在、能跑：往它的 stdin 喂一行 `initialize`，
  stdout 回一行带 `"serverInfo":{"name":"skycut"` 的 JSON
- `strings ... | grep <新增字符串>` → 命中
- 脚本自带 `codesign --verify --deep --strict` → "签名校验通过"
- `codesign -d -r- dist/SkyCut.app` → `certificate leaf = H"<packaging/signing-identity.sha1 里那一行>"`，
  不是 `cdhash H"…"`（是的话就是退回了 ad-hoc，别发）
- `swift run --arch arm64 SrtFlowCoreChecks` → "All 184 checks passed."
  （断言数会随功能增长，以当次输出为准）
- DMG：`/bin/bash scripts/check-dmg.sh dist/SkyCut-<版本>-arm64.dmg` 通过；按上节真开 Finder 验背景、图标位置和 Retina。
- 涉及 UI 改动时按 `docs/testing/gui-smoke-testing.md` 做真实窗口验证

## 公开下载发布

官网按钮和软件包分开管理。`skycut.app` 使用固定入口 `https://skylu.ai/download/skycut`，
由个人站仓库 `skysf/skystudio` 的 `_redirects` 将有 / 无尾斜杠两个入口 302 到
`https://downloads.skylu.ai/skycut/SkyCut-<版本>-<内容标识>-arm64.dmg`。因此单独更新软件包不需要
重建 Vercel 官网，也不要在官网里写死版本 URL。

流程：从已通过 CI 的干净 main 显式指定 `VERSION` 打包，用原固定身份验签；核对包内版本、
arm64、MCP 初始化与 ffmpeg 可运行，挂载 DMG 核对实际携带的 App。再复用 `scripts/r2.py`
上传新版本对象（凭证位置见该文件开头），从公开地址完整读回，比对大小与 SHA-256 后，
才在个人站隔离分支修改两条重定向，检查、PR 合并并等待 Cloudflare Pages 发布。
最后从固定入口实际下载核对新包。版本文件给 immutable 缓存，不能用新内容覆盖旧版本名。
上传前不要用公开正式 URL 探测“文件还不存在”：当前 CDN 会把 404 缓存 4 小时，HEAD
也会踩中；需要探测时用存储 API。发布对象带 DMG 内容哈希前缀，先上传、再访问公开 URL。
遇到已缓存的 404 时使用未被探测过的内容寻址版本对象，不扩大令牌权限或清空整个站点缓存。

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
- **只有第 1 组编完整 App**（单独一步，编译错误在自己的步骤里看得清；2026-11 冷编要 2 分 10 秒到
  2 分 45 秒，2026-09 才 50–80 秒；check-all.sh 第 1 组也明写了一项「build（完整 App 编得过）」）。
  别的组的子脚本只 `swift build --target SrtFlowCore`：它们要的只是核心库的模块和目标文件。
  **要链接完整 App 目标文件的检查**（脚本里 `@"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList"`，
  video-inspection、voice-recovery 这几项）**只能放第 1 组**，放到别的组那台就得为它再冷编一遍整个 App。
  反过来，第 1 组也只放这一摊：它要背冷编和 3 分钟的性能 ratchet，本来就是最慢的一组。
  `checks/check-all-shards.sh` 两头都钉着。
- **自检二进制用 `-wmo` 编**（整模块一次编完）。同一份 40 个文件，默认的逐文件编译要
  12.5 秒，`-wmo` 只要 4.9 秒（本机 arm64、模块缓存已热）：逐文件模式下每个文件都要把
  其余文件重新解析一遍。CI 上拆分前，各项检查里编译占了约 300 秒、运行约 160 秒。
  `-enable-batch-mode` 实测编不过，别换成它。
- **同一个 PR 又推了新提交，旧的一轮直接取消**（`concurrency`），不白占 runner；main 上的
  每一次都跑完。
- **只改了文档的 PR / 合并走快速通道**（2026-11-04 起）：每组第一步跑 `scripts/ci-docs-only.sh` 判一下，是就不编 App、
  不跑自检，第 1 组跑一遍 `scripts/check-guards.sh`（文档索引 docs-index-drift 在里面）就收工，其余四组到这一步就绿了，
  汇总 job `check-all` 照常给结论。原来一个只改文档的 PR 要占满 5 台 runner 两轮（PR 一轮、合并后 main 一轮），
  各约 10 分钟；10 月下旬到 11-04 合的 60 个 PR 里有 10 个是这样的。
  - **白名单是严格的**：`docs/` 下的文件，根目录的 `AGENTS.md`、`README.md`、`SrtFlow-Requirements.md`。查过
    （2026-11-04），自检里读这几样内容的只有扫描守卫 docs-index-drift，编译、跑二进制的一样都不读。白名单外的任何一个
    文件、一个文件都没改、git 算不出来、路径被 git 加了引号，都按「不是」照常全跑；改名按「删旧的 + 加新的」算
    （`--no-renames`），把代码挪进 `docs/` 不算只改文档。往白名单里加东西之前，先查有没有检查读它。
  - **不能用 `on:` 里的 `paths` / `paths-ignore`**：那样整个 workflow 被跳过，必需的检查 `check-all` 永远等不到结论，
    PR 合不进去。所以是每一步各自看判断的结论，每一步都写成 `docs_only != 'true'`：判断那一步出了岔子（没输出、
    输出不是 true）就照常全跑。
  - `checks/ci-docs-only.sh` 钉着：判断本身（含在临时仓库里真提交的改名、合并提交、根提交）、每一步重活的条件、
    快速通道只在第 1 组、触发条件里没有 paths、汇总 job 照旧。
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
  - 取用 `actions/cache/restore`、存用 `actions/cache/save`，每组一份，key 带检出目录、工具链指纹（Xcode / Swift 的版本）、
    组号和这次的提交；restore-keys 去掉提交，恢复同一组、同一工具链最新的那份。
  - 只在 main 上、整组绿了才存。PR 恢复 main 上最新的那份（GitHub 的缓存按分支隔开，PR 上存的只有这个 PR 自己用得上）；
    所以 main 上合并之后那一轮也是在给下一个 PR 备缓存。缓存一份按提交存、存了不能改，旧的 GitHub 七天没人用会自己清掉。
  - `checks/ci-build-cache-key.sh` 钉着上面这些写法。
- **`.build` 缓存的 key 和 restore-keys 都带检出目录（`github.workspace`）**：`.build` 里的模块缓存记着编它时的绝对路径，
  换了目录恢复回来就编不过。2026-10-18 仓库改名 SkyCut、检出目录从 `…/SrtFlow/SrtFlow` 变成 `…/SkyCut/SkyCut`，旧缓存被恢复、
  五组齐红（[案例](../bugfixes/2026-10-18-ci-build-cache-breaks-after-repo-rename.md)）。`checks/ci-build-cache-key.sh` 钉着。

**怎么分组**：第 1 组只放「完整 App」那一摊（上面那条）。其余的按 CI 日志里每项的耗时（`✓ 名字（N s）`）
装箱，最慢的先放，每次放进第 2–5 组里当前最空的那一组；扫描守卫秒级、不编译，放在各组最前。加了新检查就放进
最空的那组，改完看一眼 CI 上各组的时长。文档里提到某条检查时别写它在第几组：分组只以 check-all.sh 为准，
写了组号的地方下次重排就过期。

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
