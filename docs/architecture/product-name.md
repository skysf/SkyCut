# 产品名与代码名：看得见的叫 SkyCut，身份沿用 SrtFlow

> 2026-10-18 起产品改名 SkyCut（原名 SrtFlow，和 SkyDict、SkySheet 一个家族）。给用户、给 AI 看的名字是 SkyCut；
> bundle id、数据文件夹、钥匙串、通道这些身份，以及代码里的模块名，沿用 SrtFlow。
> 新加界面文案、给 AI 的话、新的文件夹 / 设置键 / 环境变量之前必读。拍板和理由见 [改名方案](../plans/2026-10-18-rename-to-skycut.md)。

## 一、三层名字

| 层 | 叫什么 | 包括 |
| --- | --- | --- |
| 看得见的（用户、AI） | **SkyCut** | App 名（`CFBundleName` / `CFBundleDisplayName`）、`SkyCut.app` 和里面的可执行文件 `SkyCut`、DMG（`SkyCut-<版本>-arm64.dmg`）、主窗口标题、三张文案表、系统权限弹框里的用途说明（`InfoPlist.strings`）、Finder 里的类型名（「SkyCut Video Project」）、随包的授权声明、测试版「SkyCut Beta」；新存的工程后缀 `.skycut`、AI 在用户文件夹里新建的子文件夹 `SkyCut/`；给 AI 的总说明、工具说明、工具结果和报错、风格卡；MCP 服务器名 `skycut`（工具在客户端里叫 `mcp__skycut__…`）、小程序 `skycut-mcp`、「连接 AI」写进客户端配置的那一项（`mcp__skycut`、`[mcp_servers.skycut]`）和备份后缀 `.skycut-backup`、`get_status` 的 `skycut_voices` |
| 身份（**永远不改**） | 沿用 SrtFlow / srtflow | bundle id `com.srtflow.SrtFlow`（测试版 `com.srtflow.SrtFlow.beta`）；UTType 标识（`com.srtflow.project`、`com.srtflow.srt` 等）；签名证书「SrtFlow Signing」和 `~/.config/srtflow/`；钥匙串里 fal Key 的 service（`<bundle id>.fal`）；UserDefaults 的域（就是 bundle id）和带名字的键（`SrtFlow.fal.settings.v1` 等）；`~/Library/Application Support/SrtFlow`、`~/Library/Caches/SrtFlow`、`~/Library/Logs/SrtFlow`；AI 通道的 socket（按 bundle id 算，太长时兜底 `/tmp/srtflow-mcp-…`）和小程序 ↔ App 的内部工具名（`_srtflow_probe` / `_srtflow_catalog`）；环境变量 `SRTFLOW_*`；日志 subsystem、队列名、临时文件前缀；烧录用的 ASS 里的样式名 |
| 代码（不改） | SrtFlow | SwiftPM 的包、目标和产品（`SrtFlow`、`SrtFlowCore`、`SrtFlowMCPKit`、`SrtFlowKokoro`、`SrtFlowMCP`、`SrtFlowCoreChecks`）、资源包 `SrtFlow_SrtFlow.bundle`、源码目录、类型名、注释、`docs/` 里的历史记录 |

打包脚本把 SwiftPM 的可执行产品 `SrtFlow` 拷成 `SkyCut.app/Contents/MacOS/SkyCut`（`APP_NAME` 和 `PRODUCT` 两个变量，`scripts/build-app.sh`）。
小程序的 SwiftPM 产品直接叫 `skycut-mcp`：客户端配置里写的就是这个路径，`ps` 里看到的也是它。

用户在 Finder 里看得见、又早就散在用户文件夹里的两样，新的叫 SkyCut、老的照认：

- **工程文件**：新存的用 `.skycut`，改名之前的 `.srtflowproj` 照样能开、原地存回去不改后缀。认不认得一个文件是工程只问
  `VideoEditProjectFile.isProjectFile`（打开、双击、最近打开、AI 的 `open_project`、列文件夹都走它）；UTType 标识不变，
  Info.plist 里后缀先写 `skycut`（新文件用第一个）再写 `srtflowproj`。内容和格式版本不变（[工程文件](video-edit-project-file.md) 第三节）。
- **AI 在用户文件夹里建的子文件夹**：新建的叫 `SkyCut/`（下面是导出、工程、配音……）；起点下面已经有改名之前的 `SrtFlow/` 就接着用它
  （同一个文件夹里的成片不分成两处），工程的家、列文件夹时跳过的输出文件夹两个名字都认（`DefaultFolder.aiFolder` / `aiFolderNames`，
  [AI 接口](ai-control-mcp.md) 第四节第 10 条）。

## 二、为什么身份不改

1. **系统授权按「bundle id + 签名证书」认**（[签名与系统权限](code-signing-and-permissions.md)）。bundle id 一改，macOS 当成另一个 App：
   录屏、麦克风、下载文件夹、钥匙串里的 fal Key 全部重给。UserDefaults 按 bundle id 分域，记住的设置（工具栏开关、导出设置、
   字幕样式、fal 的额度……）全部清零。
2. **数据文件夹里有用户的东西**：存的剪辑风格、下载的配音模型（约 333 MB）、音频库缓存、录屏的恢复账本、优化媒体缓存。
   换文件夹名就要搬家，搬漏一样就丢，换来的只是一个用户看不见的名字。
3. **老会话里的小程序还在跑**：AI 会话开始时起的是升级之前的小程序，它按 bundle id 算 socket、用 `_srtflow_*` 跟 App 说话。
   这几样不变，老会话照样连得上新 App、照样换上新清单（[小程序清单过期](../bugfixes/2026-10-14-stale-helper-tool-list.md)）。
4. **UTType 标识**认老工程、老字幕和拖放的载荷，改了老工程双击就打不开、拖放静默失败（[自定义类型没声明](../bugfixes/2026-09-23-custom-drag-types-not-declared.md)）。
5. 这些名字用户看不见。别人家也这样做：Slack 的 bundle id 到今天还是 `com.tinyspeck.slackmacgap`。

代码名不改：改模块名是几百个文件的机械改动，对用户没有任何好处，`docs/` 里几百处路径（历史案例、守卫的说明）会全部对不上。

**仓库改名、挪目录时，记着绝对路径的编译产物都要作废**：本机删 `.build`；CI 的 `.build` 缓存 key 带检出目录，改名后自己换一份
（[仓库改名后 CI 五组全红](../bugfixes/2026-10-18-ci-build-cache-breaks-after-repo-rename.md)）。

## 三、规矩

1. **给用户、给 AI 看的文字写 SkyCut**：`L10n` / `Text` / `instantHelp` 的文案（三张表一起改，[本地化](localization.md)）、
   工具说明、工具结果和报错、风格卡、权限弹框的用途说明。
2. **身份类的名字永远不改**，新加的同类东西照旧用老前缀（`SrtFlow.<模块>.<键>`、`com.srtflow.…`、`SRTFLOW_…`、
   `Application Support/SrtFlow/<子目录>`），不要一半新一半旧。哪天真要改，先写搬家（读旧的、写新的、搬完再删）并在发版说明里写清。
3. **MCP 服务器名和「连接 AI」写的名字是同一个**：`MCPServerCore.serverName` 和 `AIClientConfigFiles.serverName` 都是 `skycut`；
   Claude Code 的放行规则 `mcp__skycut` 由它拼出来。
4. **主窗口标题 `SkyCut` 在本地化守卫的豁免清单里**（App 名在任何语言下都一样，`checks/LocalizationCoverage/main.swift`）。
5. **给 AI 的文字只用英文**这条不变（[AI 接口](ai-control-mcp.md) 第一节第 3 条）；名字短了一个字母，说明的长度上限更宽松，不用另外量。

## 四、守卫

| 检查 | 钉什么 |
| --- | --- |
| `checks/product-name.sh`（第 1 组） | 第 5 节：Info.plist 里工程的后缀先 `skycut` 再 `srtflowproj`、两个后缀常量、两个子文件夹名、AI 的输出位置经 `aiFolder`、列文件夹跳过两个名字、没有别处拿后缀直接比（只许问 `isProjectFile`）、没有别处直接拼 `aiFolderName`。其余几节 —— 身份：bundle id、测试版 bundle id、八个 UTType 标识、钥匙串 service、签名证书和目录；数据：七个数据文件夹、卡顿日志位置、fal 的两个键；通道：两个内部工具名、`/tmp` 兜底前缀；看得见的：`CFBundleName` / `CFBundleDisplayName` / `CFBundleExecutable` 是 SkyCut、打包的 `APP_NAME`、小程序产品名、两处服务器名是 `skycut` |
| `checks/MCP/ProtocolChecks.swift` | 小程序握手和 `server/discover` 报的 `serverInfo.name` 是 `skycut` |
| `checks/MCP/ConfigChecks.swift` | 「连接 AI」往 Claude / Codex 配置里写、删的是 `skycut` 那一项，放行规则是 `mcp__skycut` |
| `scripts/check-mcp.sh` 开头 | 打包脚本把 `skycut-mcp` 拷进 Helpers，`sign-app.sh` 先签它再签外层 |

`scripts/check-project-file.sh` 第 47 组：`.skycut` / `.srtflowproj` 都认作工程（不分大小写），别的后缀不认；两种后缀存了都读得回来、格式版本一样。
`scripts/check-mcp.sh` 的 `FolderChecks`：`X/SkyCut/工程` 和 `X/SrtFlow/工程` 里的工程家都是 X；已有 `SrtFlow/` 的文件夹接着用它，没有的建 `SkyCut/`。

**反向验证（2026-10-18，第二步）**：最近打开改回拿后缀直接比、Info.plist 里两个后缀对调、AI 的输出位置绕开 `aiFolder` —— 第 5 节三条各自红；恢复后转绿。

**反向验证（2026-10-18）**：把 Info.plist 的 bundle id 改成 `com.skycut.SkyCut`、剪辑风格的文件夹改成 `SkyCut/Recipes`、
`_srtflow_probe` 改成 `_skycut_probe`、服务器名改回 `srtflow` —— `checks/product-name.sh` 四条各自红、退出码 1；恢复后转绿。

## 五、人工回归（改名之后第一次装）

1. Dock、启动台、「关于」、菜单栏的 App 菜单（「隐藏 SkyCut」「退出 SkyCut」）、Finder 里工程文件的「种类」都是 SkyCut。
2. 录一次自定义区域、读一次下载文件夹、用一次 fal 的 Key：都**不**再问授权（bundle id 和证书都没变）。
3. 工具栏开关、导出设置、字幕样式、存的剪辑风格、已下载的配音都还在。
4. 设置 → 连接 AI → Claude Code「连接」之后，`~/.claude.json` 里是 `skycut` 指向 `SkyCut.app/Contents/Helpers/skycut-mcp`，
   `~/.claude/settings.json` 的 `permissions.allow` 里是 `mcp__skycut`；新开的会话里工具叫 `mcp__skycut__…`。
5. 新建工程存成 `.skycut`，Finder 里种类是「SkyCut Video Project」、双击回到 SkyCut；老的 `.srtflowproj` 双击照样打开、改完存回原文件；
   最近打开里两种都列出来。AI 在一个新文件夹里导出建的是 `SkyCut/导出`；在一个已经有 `SrtFlow/` 的文件夹里接着放进 `SrtFlow/导出`。
6. 「应用程序」里不能同时留着旧的 `SrtFlow.app`：两个包同一个 bundle id，双击工程时系统可能挑中旧的；老会话里的小程序
   按自己所在的包拉起 App（`open -g -a`），App 没开时会把旧的那个拉起来。装好 SkyCut 之后把旧包挪进废纸篓。
