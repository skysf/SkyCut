# 2026-11-10 add_voiceover 会回 needs_confirmation，点过头再调却被参数核对挡掉

## 症状

请求批准模式下，AI 调 `add_voiceover`：
- `resume=<recovery_file>` 指向点名文件夹以外的恢复文件（或记录里的音频不在读过的文件夹里），
- 或者（2026-11-10 以前）`clone_from` 指向点名文件夹以外的录音，

工具照规矩回 `needs_confirmation` + `confirm_token`，`next_step` 叫 AI 问过用户、带着 `confirm_token` 再调一次。AI 照做，回来的却是
「add_voiceover has no parameter "confirm_token", so nothing was done. Its parameters: …」—— 这件事永远做不成：不带令牌就再问一次，带了就被挡。
声音 PR 3 写说明书主题时逐个核对「名片说会回 needs_confirmation 的工具收不收 confirm_token」才发现；用户没撞上过（恢复文件和音频在
任务结束时都记进了读过的文件夹，正常流程不会问；`clone_from` 那条路过渡期本来就走不通）。

## 根因

- 问的那一处是共用的 `AIWorkspace.confirmReading`：从 `args` 里读 `confirm_token`、对得上就放行。它不管工具的说明上有没有这个参数。
- 2026-10-27 起路由在排队之前按工具说明核对参数名（`MCPArgumentCheck`，[案例](2026-10-27-unknown-tool-arguments-silently-ignored.md)）：说明上没有的名字整个调用不做。
- 别的会问的工具（`look`、`listen`、`transcribe`、`add_clips`、`generate_media`……共 15 个）说明里都写了 `confirm_token`；只有 `add_voiceover` 漏了 ——
  它的两处 `confirmReading`（`clone_from` 的录音、恢复文件和记录里的音频）是后加的，加的时候没人回头看说明。
- 没有守卫把「会问」和「收不收答复」对上：`MCPArgumentCheck` 的检查只核对说明上**有的**名字都认，不知道哪些工具会问。

## 修复

- `add_voiceover` 的说明加上 `confirm_token`（`MCPSchema.confirmToken`，和别的工具同一份；`SkyStudioVoiceRecovery.resumeIfAsked` 本来就收它）。
- 名片写明「Ask mode may return needs_confirmation」（SkyCut 声音方案 4.10 的样稿；一次性费用的确认是声音 PR 6，到时同一个参数）。
- `clone_from` 同一个 PR 里去掉了（决定第七节第 8 条），会问的只剩读别处的恢复文件那一处。

## 验证

- `scripts/check-mcp.sh`：`SkyStudioVoiceChecks` 拿 `resume` + `confirm_token` 过参数核对；`ArgumentCheckChecks`：
  名片里写着 `needs_confirmation` 的工具，带着 `confirm_token` 再调都过参数核对（反过来那一半 —— 收 `confirm_token` 的名片要写
  `needs_confirmation` —— 在 `GuidePilotChecks`）。
- 反向验证（2026-11-10）：把 `confirm_token` 从 `add_voiceover` 的说明里拿掉，`check-mcp` 变红（参数核对挡掉带令牌的恢复、名片说会问却不收），
  恢复后转绿。守卫 2026-11-10 随说明书试点合进来时从 `GuideWrittenChecks` 挪到 `ArgumentCheckChecks`，挪完重做了一遍；记录在 PR #355 正文。

## 教训 / 防回归

- **会问就要能收答复**：往一个工具里加 `confirmReading` / `AIConfirmations` 的那一刻，说明里同时加 `confirm_token`。参数核对是严的，
  「代码里读了这个参数」不等于「AI 传得进来」。
- 守卫按名片的字查（写着 `needs_confirmation` 就要收 `confirm_token`）：名片的固定说法本来就要求会问的工具写 `needs_confirmation`
  （[MCP 按需说明方案](../plans/2026-11-09-mcp-guide.md) 2.2 第 4 条），两样对上，以后漏了任一样都会红。
- 长期约束写在 [AI 接口（MCP）](../architecture/ai-control-mcp.md) 第四节第 52 条（参数名按说明核对）。
