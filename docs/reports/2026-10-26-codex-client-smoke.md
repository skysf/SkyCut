# 2026-10-26 真 Codex 连 SkyCut 的冒烟（0.18.47）

对应：[收费方案](../plans/2026-10-27-paid-plans-and-sky-studio-key.md)第 12 条（要买的客户用 Codex）。在这之前 Codex 只被脚本扮过
（[第三块报告](2026-09-28-mcp-slice3-report.md)把「Codex 的连接」列为没测到；[AI 多开的冒烟](2026-10-18-ai-multi-project-ui-smoke.md)里的 Codex 是 `client.py` 改了名字），
这是第一次用真的 Codex 从连接到导出走一遍。

结论：**能用。** 连接、工具调用、看图、导出都通；撞出两个小问题，作为收费方案的第 2、3 刀修。

## 环境

- Codex 命令行 0.147（和本机的 Codex.app 共用 `~/.codex/config.toml` 和账号）。用户的 Codex 是免费版，按用户的话**用最便宜的模型只测能不能用**：
  `codex debug models` 里列出来的是 GPT-5.6-Terra（较老的均衡档）和 **GPT-5.6-Luna**（较老的快速档），选 Luna，`model_reasoning_effort = "low"`。剪得好不好用户自己测。
- 测试版 SkyCut 0.18.47（代码 = main 6452634），在后台起；工程是 L16 测试工程用 `copy-project.sh` 连素材拷进 scratchpad 的那份；全程后台模式。
- `codex exec --sandbox read-only --json`，用 `-c mcp_servers.<名字>.enabled=false` 关掉用户配置里别的 MCP 服务器；提示里写明只用 skycut 的工具、
  不碰 `generate_media` / `upscale_clip` / `add_voiceover` / `record_screen`（测试版里存着一把 fal Key）。
- 测之前把 `~/.codex/config.toml` 和 Claude 桌面版的配置拷了一份。

## 一、连接

- 设置 → AI → Codex 点「Connect」（用辅助功能 `AXPress` 点，不动鼠标）：`config.toml` 末尾多了
  `[mcp_servers.skycut]`（`command` = 测试版里的 `skycut-mcp`、`default_tools_approval_mode = "approve"`），旁边留了 `config.toml.skycut-backup`；
  设置页那一行变成「Connected」，`codex mcp list` 里 `skycut` 是 enabled。
- 测完点「Disconnect」：配置和连接前**逐字节一致**。
- **问题**：备份文件的权限是 644（谁都能读），原文件是 600。这次没泄露什么（这份配置里的令牌走环境变量），但别的客户端配置里可能直接写着密钥 → 第 3 刀修。

## 二、一次跑 12 步

| 步 | 工具 | 结果 |
| --- | --- | --- |
| 1 | `get_status` | 通 |
| 2 | `open_folder`（scratchpad 里的拷贝） | 通，列出视频、图、字幕、工程 |
| 3 | `open_project` | 通，`project: "p1"`、4 段、29.125 秒 |
| 4 | `set_view` background | 通 |
| 5 | `get_timeline` | 通 |
| 6 | `look` 第 5 秒（带图） | 通，见第三节 |
| 7 | `listen` 前 10 秒 | 通 |
| 8 | `get_subtitles` | 通，6 句 |
| 9 | `set_text`「Codex test」0–3 秒 | 通，但见第四节 |
| 10 | `export_video` 最小分辨率 + `get_job wait_seconds=30` | 通，854×480，5 秒导完，第一次 `get_job` 就是 done |
| 11 | `look` 成片第 1 秒 | 通，认出了「Codex test」 |
| 12 | `close_project` | 通，存回工程 |

- 全程约 60 秒；「工具不用每次问」生效，没有一次卡在确认上。
- Codex 自己列的「看着别扭的地方」：开工程前 `get_status` 报着一个空的未命名工程（测试版刚起，正常）；`set_text` 收了一个说明里没有的 `end`（第四节）；
  `look` 回的图很大；`open_folder` 把 `/private/tmp/…` 报成 `/tmp/…`（同一个地方，不改）。

## 三、Codex 看得到 `look` 的图

- 第一轮它把第 5 秒说成「画面很暗、一个人在操作光学设备」。实际画面是白墙、满墙彩色颜料、前面一位戴眼镜穿黑色高领毛衣的男士 ——
  它的话对得上的是 `look` 文字部分里 Vision 的标签（`optical equipment`），不是图。
- 第二轮只让它看这一帧，问两件文字里没有、只有图里才有的事：上衣什么颜色、背后墙上是什么。答「黑色」「抽象的彩色颜料」，都对。
- 结论：**Codex 会把 MCP 工具结果里的图交给模型**；第一轮是低推理的便宜模型照着文字标签编。判断「看没看到图」要问只有图里才有的东西。

## 四、`set_text` 悄悄丢掉了 `end`

`set_text` 的时间参数是 `start` + `duration`，没有 `end`。Codex 照「0 到 3 秒」传了 `start: 0, end: 3`，SkyCut 没报错、把 `end` 扔了，
用默认时长 3 秒 —— 这次碰巧对了；要是 AI 说「0 到 5 秒」，结果会悄悄变成 3 秒。所有工具都是这样：不认识的参数直接丢掉。Claude 一样会撞上 → 第 2 刀修。

## 五、用量

| 轮 | 工具调用 | 输入 token（其中走缓存） | 输出 token |
| --- | --- | --- | --- |
| 第一轮（12 步） | 12 | 345,850（256,896） | 1,474 |
| 第二轮（只看一帧） | 6 | 221,777（161,280） | 637 |

每次调用约 2.7–3.7 万输入 token：Codex 不按需加载工具，整份工具清单（接近 10 万字符）每轮都发一遍（[AI 接口（MCP）](../architecture/ai-control-mcp.md)第一节第 6 条）。
真剪一条片子要几十到上百次调用，**免费版 Codex 多半撑不完一次完整剪辑**；客户要真用，得是 ChatGPT 的付费账号。以后可以给 Codex 精简清单（它的配置能只开一部分工具）。

## 六、测试工具自己出的错

第一次点「Connect」时，自己写的辅助功能小工具按「含有 Codex 这段文字的容器里第一个按钮」找，点到了**第一行 Claude 桌面版**的「Connect」：
它的配置里多了一条指向测试版的 `skycut`（别的设置语义上没变，只是键的顺序和缩进被重写了）。一分钟内按测试前的拷贝逐字节恢复、删掉 SkyCut 留的备份；
Claude 桌面版一直开着没重启，那一条从没生效。不是 App 的问题，教训写进了 [GUI 冒烟流程](../testing/gui-smoke-testing.md)「四之五」：设置页一行里的名字、状态、按钮是兄弟，
要找到那一行的文字再往后找按钮。

## 七、没测到的

- Claude 桌面版的「连接」：它开着（用户可能正在用），要重启才认新配置，留到之后。（2026-10-27 测了：[测试版 0.18.48 的冒烟](2026-10-27-beta-watermark-and-claude-desktop-smoke.md)第二节。）
- Codex.app 的图形界面里用：只测了命令行（配置和账号是同一份）。
- 剪得好不好：用户自己用好一点的模型测。
