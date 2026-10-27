# 2026-10-27 测试版 0.18.48：导出水印和 Claude 桌面版「连接」的冒烟

对应：[收费方案](../plans/2026-10-27-paid-plans-and-sky-studio-key.md)第 4 刀（[导出水印](../architecture/export-watermark.md)）和第 12 条；
补上 [真 Codex 冒烟](2026-10-26-codex-client-smoke.md)第七节没测到的第一条（Claude 桌面版的「连接」）。用户说「可以」之后做的。

结论：**都通。** 装好的测试版导出就带水印，位置、大小和跳的表一致；Claude 桌面版连上、重启后握手、列出 48 个工具，断开后配置还原。
第 3 刀（#256）在真机上看到了：原配置 600，SkyCut 留的备份也是 600。

## 环境

- 测试版 SkyCut 0.18.48（main 904312f，含 #255–#257），固定证书签名、装进「应用程序」；`export.testWatermark` 打开（留着给用户自己试）。
- 素材：L16 的成片（1920×1080、24 fps）拷进 scratchpad；用 `scripts/gui-smoke/mcp-client/client.py` 那一套扮 AI 客户端驱动测试版，全程后台模式。
- Claude 桌面版 3.6556.2，已经开了三天，里面有三个 Code 会话（南极工程，转写最后写入是前一天，都闲着）；用户另一个窗口在终端里，不受影响。

## 一、水印

- **16:9**：新工程放 L16 的 0–20 秒，`export_video` 1080p，11 秒导完（1920×1080、24 fps）。每个 4 秒段取中间一帧，和原片同一帧比
  （都缩到 480×270、差超过 24 的像素取外接框）：

  | 时刻 | 落在 | 框宽 / 短边 |
  | --- | --- | --- |
  | 2 秒 | 右下 | 25% |
  | 6 秒 | 右上 | 25% |
  | 10 秒 | 左下 | 25% |
  | 14 秒 | 右上 | 25% |
  | 18 秒 | 右下 | 25% |

  每一段只改了一处、离边约 4%、不连续两次同一处；别处都和原片一样。L16 自己左下角就有一个小的 Sky Studio 标（素材里的），不是水印，比对里也没有它。
- **9:16**：`set_canvas` 9:16 + `edit_clip fit=fill`，0 到 20 秒 = 原片的 20–40 秒，导出 1080×1920。看图：正中（小）、左上、左下、右上、左下，
  四角大、正中小，亮的网页和暗的画面上都看得清。
- 没测到：导出面板那一路（和 `export_video` 是同一个 `VideoEditExporter`，`checks/export-watermark-wiring.sh` 钉着），留给用户在测试版里点。

## 二、Claude 桌面版的「连接」

- 设置 → AI →「Claude Desktop」那一行点「Connect」（辅助功能 `AXPress`，不抢前台）：配置里多了 `skycut`（`command` = 测试版里的 `skycut-mcp`），
  `skysheet` 和别的键解析出来一样；`claude_desktop_config.json.skycut-backup` 和点之前的配置逐字节一致，**权限 600，和原文件一样**（#256 之前是 644）。
- 测的过程中 Claude 桌面版**自己改了一次这份配置**（存偏好，6583 → 6580 字节）：备份要在点「连接」前那一刻拷，开头拷的那份已经旧了。
- **View → Reload 不重读配置**：它只把已经加载的服务器重启一遍（日志里 skysheet 关了又起），`skycut` 没起来。要真退出再开：AppleScript `quit`
  4 秒退干净、没弹框；`open -g -b com.anthropic.claudefordesktop` 照样跳到最前面，开完把前台还给用户原来的 App。退出会结束它里面的 Code 会话，
  所以先看那几个会话闲着没（进程状态、转写的最后写入时间）。
- 重开 6 秒后日志：`Connected to skycut (48 tools)`、协商的协议 2025-11-25（`Era probe verdict: legacy`，走老一代握手），initialize / tools/list 都有回话，
  没有报错（「Extension skycut not found in installed extensions」每个写在配置里的服务器都有，skysheet 一样）。
- 点「Disconnect」：那一行回到「Not connected」，配置解析出来和连接前一样，但**字节不一样**（6580 → 6848）：SkyCut 按 JSON 重写（键排序、自己的缩进）。
  不算问题（Claude 桌面版存偏好时也按它自己的格式整份重写），核对时比解析后的内容；这次在内容一致之后把备份拷回去，字节也一致了，再删掉 `.skycut-backup`。
- 没测到：在 Claude 桌面版的聊天里真调一次工具（要往它的输入框里打字、点「允许」；用户正在用这台电脑、输入法是拼音，留给用户）。
  正在跑的 Claude 桌面版里 `skycut`（指向测试版）还加载着，下次重启就没了。
