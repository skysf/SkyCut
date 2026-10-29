# 2026-10-29 提交返回时取消会丢掉服务器任务号

## 症状

POST 已建单，用户恰好在等待返回时停止；服务器已开始而回 409，调用方拿不到这单的服务器 ID，无法准确报告与核账。

## 根因

`SkyStudioJobRun.submit` 先检查取消并抛 `stopped`，`run` 返回后才 `onUpdate(.status)`。取消路径永远走不到报告 ID 那一步。

## 修复

成功 POST 的回答先报告状态与 ID，再处理取消；正常路径去掉重复报告。取消仍在不继承取消的任务中按 ID 执行，409 / 未知继续 followToEnd。

## 验证

`JobRunChecks` 在假 POST 回答前取消外层 Task，分别模拟退款与 409，确认 ID 恰好报告一次。临时恢复旧顺序，689 条检查中两条 ID 断言明确失败（reverse log：`/private/tmp/skycut-voice-cancel-reverse.log`），恢复后通过。未调用付费接口。

## 教训 / 防回归

付费提交的身份必须先交给调用方，随后才能抛停止；长期约束在 [Sky Studio 的任务](../architecture/sky-studio-jobs.md)“交任务”。
