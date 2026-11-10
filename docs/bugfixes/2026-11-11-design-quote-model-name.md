# 2026-11-11 设计声音的报价写「用 Sky Studio 设计」，说不出是 Qwen3 还是 MiniMax

## 症状

2026-11-11 用真的 Sky Studio 跑声音库的界面冒烟（实测报告 `docs/reports/2026-11-11-voice-real-smoke.md`）：设置 → 剪辑与声音 → 设计声音，填一段英文描述，
报价那一行写的是「Designed with Sky Studio · 22.5 credits」，不是「Designed with Qwen3 · 22.5 credits」。同一处 AI 的 `manage_voices design`
问用户时结果里没有 `model`，设计任务在云端任务浮层那一行的标题也是「Sky Studio」。

用哪家要紧：中文描述服务器用 MiniMax（约 750 积分），别的语言用 Qwen3（22.5 积分）。对话框自己的说明就写着「中文描述用 MiniMax、别的用 Qwen3」，
方案（声音方案 5.4）定的也是「将用 MiniMax / Qwen3 设计 · 约 X 积分」，可真服务器上一次都没写出来过。

## 根因

- `SkyStudioQuote` 只读顶层的 `model`。Sky Studio 声音的报价（读稿、克隆、设计、建 MiniMax 版、变声）**顶层没有 `model`**，用哪个模型只在
  `voice_plan.selection.model`（合同 `docs/agents/skycut-api.md` 的「`/quote` answers」，真的回答见下）：
  `{"credits": 22.5, "credits_expected": 22.5, "settlement": "exact", "voice_plan": {"selection": {"model": "qwen3-voice-design"}, …}, "one_time": [{"kind": "voice_design", "model": "qwen3-voice-design", …}]}`。
  所以 `quote.model` 永远是 nil，`VoiceLibraryText.designModel(nil)` 退成「Sky Studio」。
- **两份假服务都替它补了一个顶层 `model`**：回归用的 `checks/VoiceRecovery/LibraryFixture.swift` 和免费冒烟的 `voice_library_fixtures.py`，设计的报价都写着
  `"model": "qwen3-voice-design"`。于是 `LibraryUIChecks` 里「中文描述的报价写 MiniMax」这一条一直是绿的，离屏渲染的图（PR 8）也写着 MiniMax —— 测的是假服务
  自己编的形状，不是合同的形状。

## 修复

- `SkyStudioQuote.init?(json:)`：顶层没有 `model` 时读 `voice_plan.selection.model`（顶层有就还用顶层的，图片、视频那些报价不变）。设计面板、AI 的问句、
  任务的标题都从这一处拿。
- 设计任务在浮层里的标题改成和面板同一个叫法（`VoiceLibraryText.designModel`：MiniMax / Qwen3），不写原始的模型 id。
- 两份假服务的设计报价改成和真的一样：没有顶层 `model`，`voice_plan.selection.model` + `one_time`。

## 验证

- `scripts/check-sky-studio.sh`：`VoiceLibraryChecks` 的 `runDesignQuoteChecks` 拿真服务那一份回答（去掉说明文字）读，`model` 是 `qwen3-voice-design`；
  顶层有 `model` 时还是顶层的。
- `scripts/check-voice-recovery.sh`：`LibraryUIChecks` 的英文描述报价写出 Qwen3、不写 Sky Studio；中文描述写 MiniMax 和两个数；`LibraryChecks` 里 AI 的设计问句带
  `model: qwen3-voice-design`。
- **反向验证**：只撤掉 `SkyStudioJob.swift` 那一行，Sky Studio 检查红 1 条（`got nil`），声音恢复检查红 3 条，其中一条打出来的正是真冒烟截图上那一句
  「Designed with Sky Studio · 22.5 credits」；放回去都绿。

## 教训 / 防回归

- 假服务的回答要照合同的形状写，最好从真服务的回答抄（去掉签名链接和说明文字）；假服务替客户端「补」一个字段，就把客户端的毛病一起藏起来了。
  声音的报价用哪个模型只在 `voice_plan.selection.model`，写进了[声音库](../architecture/voice-library.md)第九节第 7 条。
- 「离屏渲染的图对了」不等于真服务上对：数据来自假服务时，图只证明排版。
