# 改名 SkyCut：只改看得见的，身份和代码名沿用 SrtFlow

> 2026-10-18 用户拍板。长期约束（哪些名字永远不改、新东西怎么起名）写在
> [产品名与代码名](../architecture/product-name.md)，这里记为什么这么定、分几步做、本机怎么收拾。

## 背景

用户做了一族 Sky 开头的 App（SkyDict、SkySheet、SkyMusic……），想把这个也统一进来。SrtFlow 这个名字来自最早的
字幕格式转换，现在它是一个完整的剪辑软件（多轨、录屏、AI 剪辑），名字已经说不清它是什么。
改名同时把代码目录从 `SkyStudio_APP_Master/srt_vtt/app_files/` 挪到 `SkyStudio_APP_Master/SkyCut/`（和 SkySheet 的摆法一样），
GitHub 仓库从 `skysf/SrtFlow` 改成 `skysf/SkyCut`。

## 拍过的板

| # | 问题 | 定了什么 | 为什么 |
| --- | --- | --- | --- |
| 1 | 叫什么 | **SkyCut**（用户定） | cut 就是剪，一看就知道是剪视频的（Final Cut、CapCut 都这么用）；和 Dict、Sheet 一样是一个音节的品类词；`mcp__skycut__` 和 `mcp__skysheet__` 放在一起整齐。看过没选的：SkyEdit（没说编辑什么，以后做图片 / 音频编辑器时会占错位置）、SkyVideo（平淡，最像英国 Sky 电视台的产品名）、SkyFlow（和 SrtFlow 一脉相承，但已有一家叫 Skyflow 的软件公司）、SkyReel（昆仑万维的 AI 视频生成模型叫 SkyReels，正好撞在 AI 视频这个圈子里）、SkyClip（偏小，像剪短视频的小工具） |
| 2 | 改多深 | **只改用户和 AI 看得见的那一层**（用户：按建议来） | 「SrtFlow」在仓库里有 770 个文件、5,331 处，真正要改的只是界面、给 AI 的话、包名、仓库名；其余是身份和代码 |
| 3 | bundle id 动不动 | **不动**，留着 `com.srtflow.SrtFlow`（用户：按建议来） | 系统授权和钥匙串按「bundle id + 证书」认，UserDefaults 按 bundle id 分域：一动就是 10-03 签名事故的翻版（授权全部重给、设置清零）。用户几个 App 的 bundle id 本来就不统一（`com.skydict.SkyDict`、`ai.skylu.skysheet`、`com.skystudio.skymusic`），没有要对齐的 |
| 4 | 代码里的模块名 | **沿用 SrtFlow 当代码名** | 改模块名是几百个文件的机械改动，对用户零价值，`docs/` 里历史案例写的路径全部对不上；在 AGENTS.md 开头写一句就够（Chrome / Chromium 也是这样） |
| 5 | MCP 服务器名 | **`srtflow` → `skycut`**，小程序 `srtflow-mcp` → `skycut-mcp` | `.app` 改名之后客户端配置里写的小程序路径反正要重写一次，顺手换名字几乎不多花成本；和 SkySheet 的 `skysheet` 一致 |
| 6 | 工程文件后缀 | **新存的用 `.skycut`，老的 `.srtflowproj` 照样能开**（用户：按建议来） | 每个工程在 Finder 里都看得见它；UTType 标识不变、只多认一个后缀，老工程不受影响。第二步做 |
| 7 | AI 在用户文件夹里建的子文件夹（`<文件夹>/SrtFlow/` 下面的导出、工程、配音……） | **新文件夹叫 SkyCut；已经有 SrtFlow 子文件夹的接着用它**，两个名字都认（我定的） | 同一个文件夹里同一批工程的成片分在两个子文件夹里最乱；接着用老的，新文件夹用新的。第二步做 |
| 8 | 给别人的迁移 | **不做**（用户：只有自己装着） | 不写「自动改 AI 客户端配置里的旧条目」「提示删旧 App」这类代码，本机手动收拾一次（下一节） |
| 9 | 图标 | **不换** | 图里只有播放键、波形和时间线，没有字 |
| 10 | 签名证书「SrtFlow Signing」 | **不重建、不改名** | AGENTS.md「打包与签名」：换证书 = 所有授权再给一次；证书名用户看不见 |
| 11 | 历史文档 | **不改** | `docs/bugfixes`、`docs/reports`、老的 `docs/plans` 记的是当时的事，当时就叫 SrtFlow；现行的说明（架构、构建、测试流程、README、AGENTS.md）跟着改 |

名字撞车的提醒（用户知道，没影响决定）：印象里有个叫 SKYCUT 的刻字机品牌，品类不同；英国 Sky 电视台对「Sky」商标维权很积极
（当年逼微软把 SkyDrive 改成 OneDrive），视频正是它的本行 —— 自己发在 GitHub 上问题不大，哪天上 App Store 或收费先查商标。

## 分步

1. **PR：改名**（看得见的一层）—— Info.plist 的名字和用途说明、三张文案表、给 AI 的说明和结果、MCP 服务器名和小程序名、
   打包脚本（`SkyCut.app`、`SkyCut Beta.app`、DMG 和里面的「首次打开必读」）、随包的授权声明、风格卡、README、现行文档；
   新守卫 `checks/product-name.sh` 钉住身份不改。
2. **PR：新存的工程用 `.skycut`、AI 的子文件夹叫 SkyCut**（第 6、7 条），老的都认。
3. **本机收拾**（下一节）。

## 本机收拾（用户只有这一台）

按顺序：

1. 打包装上 `SkyCut.app` 和 `SkyCut Beta.app`，旧的 `SrtFlow.app` / `SrtFlow Beta.app` 挪进废纸篓（同一个 bundle id 不能并存，见架构文档第五节）。
2. Claude Code：去掉指向旧包的 `srtflow`、注册 `skycut`（`claude mcp add --scope user skycut -- "/Applications/SkyCut.app/Contents/Helpers/skycut-mcp"`），
   `~/.claude/settings.json` 的 `mcp__srtflow` 换成 `mcp__skycut`。旧的会话要新开（工具名变了）。
3. GitHub 仓库改名 `skysf/SkyCut`（旧地址自动跳转；以后别再建一个叫 SrtFlow 的仓库，不然跳转失效），本地 `origin` 改成新地址。
4. 代码目录挪到 `SkyStudio_APP_Master/SkyCut/`（`srt_vtt/` 里只有 `app_files` 和一个 `.DS_Store`，一步 `mv`），`.build` 清掉重编
   （编译缓存里记着绝对路径）。
5. Claude Code 的记忆和会话按目录路径存：`~/.claude/projects/-Users-sky-…-srt-vtt-app-files/` 改名成新路径对应的
   `-Users-sky-Downloads-Sky-Studio-All-SkyStudio-APP-Master-SkyCut/`，不然新会话读不到记忆、`/resume` 找不到老会话。
   第一次在新目录开 Claude Code 会问一次信任这个文件夹。
