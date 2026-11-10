# 2026-11-10 停下几批的旁白：结果只说最先出事的那一批，结果不明那批的句子哪个列表都没有

## 症状

声音功能的免费冒烟（[报告](../reports/2026-11-10-voice-free-smoke.md)，随 PR #368 合进来；看见的问题第 4、5 条）：五批的旁白、声音池 2 个，停的时候一批做完、
一批在 Sky Studio 已经开始了、一批排着队、两批在等空位。停下之后 `get_job`：

1. `message` 只有一句「Sky Studio had already started it, so it could not be cancelled. Keep querying the original job's billing; …」——
   「it」是哪一批说不清，另外四批（一批做完了、一批退了钱、两批没交）一个字都没有；
2. 已经开始的那一批结果不明（交了、没成品、也不算没生成），它的两句在 `completed_line_indices`、`pending_recovery_line_indices`、
   `not_generated_line_indices` 里都没有，只有 `unknown_batch_indices` 里有它的批号。按句子读的 AI 会以为这两句不存在。

## 根因

1. 几批同时交（声音 PR 4）之后，`SkyStudioVoiceBatchQueue` 只记**第一件**出事的批（`failure`），`SkyStudioVoiceoverRun.fail` 拿它的话当整件的结果。
   用户一停，几批各自抛：已经开始的抛「开始了、取消不了」，排着的抛「开始之前停下、没花钱」，等槽的离队 —— 谁先记上看调度。冒烟那一次先记上的是
   「已经开始了」；在 `StopChecks` 里撤掉修复复现时先记上的是排队那批的「Stopped before Sky Studio started it; no credits were spent.」：话本身都没错，
   放在五批的旁白上就错了 —— 后一句让人以为一分没花、什么都没做，其实第 0 批做完了、第 1 批的积分可能花了。一批一单的时候没有这个问题（就那一批）。
2. `SkyStudioVoiceCheckpoint.detail` 的句子列表只分「做完」「有成品待切」「没生成」三种，结果不明是第四种，只给了批号的列表，句子落在三张表的缝里。

## 修复

1. 新的纯值 `SkyStudioVoiceStopSummary`：照恢复记录给每一批定停在哪 —— 做完了（有成品或句子都切好了）、在 Sky Studio 已经开始了取消不了
   （交了、有任务号、没退）、开始之前停下（退了钱，`retryable`）、还没交、交了没拿到任务号（结果不明）—— 按 `batch_index`（从 0 起）逐批写成一句：
   「Stopped. By batch_index (from 0): 0 finished (…); 1 had already started on Sky Studio and could not be cancelled (…); 2 stopped before Sky Studio
   started (credits returned); 3, 4 never sent (nothing charged). Nothing was added to the timeline.」`SkyStudioVoiceoverRun.fail` 在用户停、
   而且不止一批时用它（结果的 `message` 和恢复记录的 `recovery_issue` 同一句）；只有一批的照旧用那一批自己的话。
2. `detail` 加 `unknown_line_indices`：结果不明那几批的句子（去掉本机已经切好的）；没起任务的那一支也给空表。说明书 `add_voiceover` 的
   batches_recovery 一节提到它、说停下之后 `message` 逐批说清（`checks/MCP/CatalogNames.swift` 认这个字段名）。
3. 长期约束写进 [Sky Studio 的任务](../architecture/sky-studio-jobs.md)第五节「几批同时交」和结果字段那一条。

## 验证

- `scripts/check-sky-studio.sh` 的 `VoiceStopChecks`（纯值）：六批停在五种地方（做完、开始了、退了、两批没交、交了没拿到任务号），每一批的状态、
  那句话一字不差、`unknown_batch_indices` [1, 5] 和 `unknown_line_indices` [2, 3, 10, 11]、本机已经切好的那句不算结果不明、只有一批时不另写。
- `scripts/check-voice-recovery.sh` 的 `StopChecks`（真 App 对象 + 假协议：第 1 批取消回 409、第 2 批取消回 200 之后问回 cancelled + 全退）：
  停之前 1 批好了 / 2 批在跑 / 2 批等空位；停下之后 `cancelled`、那句话逐批说到、`recovery_issue` 同一句、`unknown_line_indices` [1]、
  `pending_recovery_line_indices` [0]、`not_generated_line_indices` [2, 3, 4]、等槽的两批没交；放开之后普通恢复只 GET 那一单、两句都切好、不交新的。
  真跑出来的那句：「Stopped. By batch_index (from 0): 0 finished (resume uses the audio without paying again); 1 had already started on Sky Studio
  and could not be cancelled (credits may be spent; resume only fetches the result); 2 stopped before Sky Studio started (credits returned);
  3, 4 never sent (nothing charged). Nothing was added to the timeline.」
- 反向验证（临时改回去、跑、再恢复）：`fail` 照旧用第一件事的话 → `StopChecks`「逐批说清」红（拿到的是「Stopped before Sky Studio started it;
  no credits were spent.」）；`detail` 不报 `unknown_line_indices` → `VoiceStopChecks` 两条红、`StopChecks` 两条红。
- 回归面：`check-voice-recovery` 原有的「切句时用户停了」那一场（三批都做完）现在的话是「0, 1, 2 finished … Nothing was added to the timeline.」，
  照实；`check-mcp` 6801 项绿（说明书的字数、提到的字段名）。

## 教训 / 防回归

- 几件事同时出的时候「只报第一件」就是随机报一件：用户按停止时，结果要把每一件都说到。以后再有「几样同时跑、用户一停各自抛」的活，照这个写。
- 按句子报状态的那几张表要盖住每一句：加一种批的状态（这次是结果不明），就给它一张句子的表；测的时候断言每一句都在某一张表里。
