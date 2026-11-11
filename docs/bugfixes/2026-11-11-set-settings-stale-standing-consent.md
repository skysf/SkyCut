# 2026-11-11 关掉全部权限的回答里，设置那一处还写着长期授权「已记上」

## 症状

2026-11-11 真实冒烟（AI 工具那一半，`docs/reports/2026-11-11-voice-real-smoke.md` 第八节）里用 `set_settings` 切权限，同一个回答里有两处说长期授权，
说的不是一回事：

| 这一步 | 顶层 `voice_standing_consent` | `sections.ai.voice_standing_consent`（`get_settings` 读的那一处） |
| --- | --- | --- |
| 点过头、打开全部权限 | `recorded`（`voice-standing-consent-v1`） | `unknown`（打开之前的样子） |
| 点过头、切回请求批准 | `revoked` | `recorded`（刚撤掉的那一条） |

Sky Studio 那边是对的（打开后有效授权 0 → 1，切回后 1 → 0）。可 AI 读设置那一处，就会在用户关掉全部权限之后告诉他「长期授权还记着」，
这是授权的事，说反了比不说还糟。

## 根因

`AISettingsTools.update` 先写 Store、**先拍一份设置**（`snapshot`，里面的 `voice_standing_consent` 是 `SkyStudioVoiceStanding.shared.status` 此刻的值），
**再** `await standing.modeChanged(...)` 去 Sky Studio 记 / 撤，把它的结果另放进顶层。拍的那一刻还没记 / 撤，设置里就是改之前的状态。
自检（`StandingChecks.settingsChecks`）只查顶层那一份，所以一直是绿的。

## 修复

`Sources/SrtFlow/AISettingsTools.swift`：先 `modeChanged`、再拍设置，顶层照旧放同一个结果。两处现在都是记 / 撤之后的状态；只改顺序，
问句、令牌、记不上照样打开这些都没动。规矩补进 [声音库](../architecture/voice-library.md) 第八节第 9 条。

## 验证

- `scripts/check-voice-recovery.sh` 的 `StandingChecks.settingsChecks` 加三条：打开之后同一个回答里设置那一处等于顶层（`recorded`）、
  切回之后设置那一处是 `revoked`、记不上时设置那一处是 `not_recorded`。开头先 `accountChanged()`，像刚开的 App 那样从 `unknown` 起。
- **反向验证**：守卫留着、`AISettingsTools.swift` 换回 main 的写法（先拍后记）。第一次只红了两条（切回、记不上）：前面几组检查已经把状态记成了
  `recorded`，打开那一刻拍早了也碰巧写 `recorded`；检查开头加上 `accountChanged()` 再反向，**正好这三条红**（`FAIL: 3 production voice recovery checks`，
  别的一条没红）。换回修复：`scripts/check-local.sh scripts/check-voice-recovery.sh` 全绿（扫描守卫 + 这一项 80 秒）。
- 真机：这次冒烟就是现场，修之前的回答原样记在冒烟的调用记录里；修复只改顺序，没有再花积分重跑。

## 教训 / 防回归

- 一个回答里同一件事出现两次（顶层一份、设置快照里一份），两份必须在同一时刻取：先把会改状态的 await 做完，再拍快照。
- 只查一处的自检挡不住另一处说反；同一件事在回答里有几处，就每处都查。
- 查「改了之后」的守卫，起点要和「改之前」不一样：起点碰巧就是结果时，拍早了也对得上，守卫永远不红（这次反向验证第一遍就是这样）。
