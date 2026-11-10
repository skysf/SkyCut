# 2026-11-11 设计声音的对话框连按，同一份报价下了好几单

## 症状

深度审查（声音 PR 8，#367）读代码发现，没有用户撞上：设置 → 声音库 →「设计声音」，报价出来以后**双击**「设计（最多 Y 积分）」，
或者按住回车（按钮是 `.defaultAction`）不放，`DesignVoiceModel.design()` 就跑好几次。每跑一次：

- 本机的每日积分账再记一笔（`SkyStudioJobGate.reserveWithoutAsking`）；
- 再起一个本机任务（`SkyStudioVoiceLibraryJob`）、再向 Sky Studio 交一次 `voice_design`；
- 设置里「正在设计…」多一行，云端任务浮层里多一条。

修复前在假 Sky Studio 上按三下量到的：`POST /jobs` 三次、本机账 +67.5（一份 22.5）、「正在设计」三行、三个任务在跑。

## 根因

1. `design()` 没有「已经下过单」的标记：按下去之后 `offer` 还是 `.ready`、`quoted` 还留着，`DesignVoiceSheet` 的按钮只看
   `model.quote == nil || overLimit`，要等第一次 `design()` 返回才 `dismiss()`。同一个对话框里的 `NewVoiceModel.submitting`、
   `VoiceRenameSheet.saving` 都有这个闩，设计这一个漏了。
2. 本机没有「同一件事只开一单」这一层：`SkyStudioVoiceLibraryJob` 拿到什么就起什么，同一份请求起两次就是两个任务、两笔账，
   做完各自 `settle` 一次。

**和审查报告不一样的一处（照实测写）**：报告说两次请求的 `idempotency_key` 不一样、Sky Studio 会扣两次钱。实测是**同一个 key**：
key 在问价时就随 `draft` 定下了（`SkyStudioVoiceDesignOrder.draft` → `SkyStudioVoiceRequests.design`），`design()` 每次交的都是
`quoted` 那一份；反向验证里三次 `POST /jobs` 的 key 一模一样。照接口合同（Sky Studio `docs/agents/skycut-api.md`：
「`idempotency_key` is unique per account: a repeat returns the original job and charges nothing」）服务器只认一单、只扣一次。
所以真正坏的是**本机**：同一单在每日账上记了 N 笔（Qwen3 的 22.5 × N；MiniMax 的 751.4 第二笔会被默认 1,000 的每日上限挡住，
上限调高过就记成双份），当天的额度白白少掉、之后的活被「每日额度用完」挡住，界面上多出几条重复的任务。
服务器那一半没有用真服务器验证（这次不发付费请求），以合同为准。

## 修复

- **一份报价只下一单**（`DesignVoiceModel`）：`ordered` 一按下去就置上（在起任务之前），`design()` 开头 `guard !ordered`；
  按钮 `.disabled(… || model.ordered)`。改了字是另一份报价（`fieldsChanged` 里放开），那才能再下一单。
- **同一件事只开一单**（`SkyStudioVoiceLibraryJob`）：任务按 `identity` 登记（设计 = 这一份订单的 key，建 MiniMax 版 = 账户 + 声音 + 语言）；
  `start()` 先看 `running(identity)`，还开着就回那一单、把这一笔预留退回，不起第二个任务。`design()` 在预留之前也先问
  `SkyStudioVoiceDesignOrder.running(draft)`。
- **key 的规矩写明**（`SkyStudioVoiceDesignOrder` 开头）：一份报价一个 key，问价时定、交的时候不另起。审查建议「key 由内容决定」
  **没有照做**：Sky Studio 的 key 永远绑着它那一单（做完的、失败的都是，只有扣钱之前被拒的才放开），按内容算的话，同一份描述
  失败过一次、或者想再设计一个，就再也交不出去。一份报价一个 key 已经保证「同一份怎么重入，服务器认的都是同一单」。

同一次审查的其余几条在 [声音库审查的后续](2026-11-11-voice-library-review-followups.md)。

## 验证

- `scripts/check-voice-recovery.sh` 的 `LibraryOrderChecks.designOnceChecks`（真 App 对象 + 假协议，单先排着队）：连按三下只预留一次、
  「正在设计」一行、一个任务、一次 `POST`；绕过对话框把同一份直接起两次，第二次回开着的那一单、预留退回；那一单做完之后手里的报价
  也不能再下；改了字是另一个 key。`LibraryUIChecks.designChecks` 另有一条「第二下什么都不做」。
- `checks/sky-studio-wiring/voice-library-orders.sh`（扫描）：`guard !ordered` 在 `ordered = true` 之前、后者在起任务之前；
  按钮带 `model.ordered`；订单里不另起 key；任务 `start()` 先看 `Self.running(identity)`。
- 反向验证（2026-11-11，每一处临时撤掉、跑、再恢复）：

| 临时改成 | 红了什么 |
| --- | --- |
| 去掉闩和两处「开着的那一单」（= 修复前） | 扫描 2 条；运行 13 条：第二、三下都下了单、预留 67.5、「正在设计」三行、三次 `POST` 同一个 key、同一份直接起两次得到两个任务、当天的账 112.5（应为 45） |
| 只去掉闩 | 扫描 1 条；运行 3 条：那一单做完之后同一份报价又下了一单、账多一笔 |
| 去掉任务的 `running(identity)`（和建 MiniMax 版那两处一起撤的那一轮） | 扫描 1 条；运行：同一份直接起两次得到两个任务、第二笔预留没退（账 45，应为 22.5） |
| 订单交的时候另起一个 key | 扫描 1 条 |

全部恢复后转绿。

## 教训 / 防回归

- **会花钱的按钮，按下去那一刻就要锁**：等异步的结果、等对话框收起来再锁都晚了。同一个界面里别的按钮有闩、这一个没有，
  说明闩是各写各的：加收费按钮时对着 `submitting` / `saving` / `ordered` 过一遍。
- **本机的账和服务器的账是两本**：服务器按 key 去重只保住它那一本；本机每起一个任务就记一笔，要自己有「同一件事只开一单」。
- **审查说的后果先量一遍**：这次「扣两次钱」实测是「本机记两笔」，修法一样，写给用户的话不一样。
- 假服务器原来每一单当场做完、实扣等于报价，这类问题照不到：见后续那一篇的「假协议」。
- 长期约束在 [声音库](../architecture/voice-library.md)第十节。
