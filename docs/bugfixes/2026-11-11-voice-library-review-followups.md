# 2026-11-11 声音库审查的后续：重复预留、丢掉的费用问题、借用的读取器、授权文案升版本

声音 PR 6（#362）、PR 8（#367）合并后的深度审查（只读代码，没有用户撞上）列了 8 条和一批测试盲区。第 1 条单独成篇：
[设计声音连按下了好几单](2026-11-11-design-voice-ordered-twice.md)。第 5 条（全部权限下删声音没有提示条）声音 PR 7（#370）已经做了。
这里是其余几条。

## 症状

1. **MiniMax 版还在建时又调 `add_voiceover`，本机的每日账记两笔**（#362）。建要几十秒；AI 没等它、再调一次，报价还说要建，
   SkyCut 再问一遍（用过的令牌作废、另发一张），用户再点头就再预留 377.6、再起一个任务。Sky Studio 对同一个声音 + 语言开着的建单
   只回原来那一单、只扣一次，可本机两个任务各 `settle` 一次，一笔 377.6 记成 755.2。#370 之后更糟：全部权限 + 长期授权时不问，
   每调一次就直接多记一笔。
2. **旁白中途那笔一次性费用的问题，建的那一单还没被受理就清掉了**（#362）。`resume` + 令牌 → 记上账就把恢复记录里的 `fallbackFee`
   清了，然后才交 `voice_enroll`。交的时候改了价（`price_changed`）、断网、等不到槽：预留退了，问题也没了，普通 `resume` 找不到它，
   只剩 `generate_missing` —— 默认模型又失败、又回 `fallback_needs_one_time`。`price_changed` 带的新价也没进 `get_job`。
3. **新建声音时检测录音的语言，借用了只给字幕生成的读取器**（#367）。`AudioWindowReader.extract` 的 `copyNextSampleBuffer` 循环写在
   async 函数里，是 `checks/blocking-media-reads.sh` 白名单上唯一的例外，理由（严格一个窗口读完再读下一个）只对字幕生成成立。
   查的时候发现配旁白回来的音频要转写时（`SkyStudioVoiceAudio.transcribe`，2026-10-29）也在借。
4. **Sky Studio 把授权那句升了版本，SkyCut 要等 10 分钟的目录缓存过期才用得上**：这期间每次建声音都带旧版本、都回 `consent_outdated`。
5. **点「新建」时主线程整份读录音**（≤ 16 MB，再算 SHA-256）；**崩溃后录音留在临时目录**（三种文件夹只在正常收尾时删）。
6. **每日预算的规矩抄了一份**：`DesignVoiceModel.overLimit` 把 `DailySpendPolicy.decide` 连 0.0005 的余量一起抄了。
7. （残留）**转写得了的 Mac 上，合成一批的几句每次都对不回原文，`resume` 永远 `local_split`**。

## 根因

- 1、2 和第 1 条是同一个：**本机没有「同一件事只开一单」**，也没有把「问题答完了」和「服务器受理了」分开。记账那一刻就当作事情成了。
- 3：守卫只看 `copyNextSampleBuffer` 写在哪个函数里，**看不见谁在调那个例外**；例外的理由写在文档里，没变成检查。
- 4：`voice_consent.per_recording` 从 `SkyStudioCatalogCache` 读，没有任何一条路在服务器说「版本旧了」时去刷新它。
- 7：只给「这台 Mac 转写不了」留了按字数估的出路（重试多少次都一样）；「转写得了、但这段音频就是对不上」同样重试多少次都一样，没算进去。
- 测试：假协议 `VoiceLibraryHTTP` 每一单 `/jobs` 当场回 `done`、实扣等于 `max_credits`。去重、改价、失败退款、排队都照不到，
  `settle` 什么都不做也全绿。

## 修复

| 条 | 改了什么 |
| --- | --- |
| 1 | `SkyStudioVoiceOneTimeStep.decide`、`SkyStudioVoiceFallbackFee.settle` 在过闸（问 / 记账）之前先看 `SkyStudioVoiceLibraryJob.running(这个账户的声音 + 语言)`，读长期授权（await）之后再看一次；在建就回那一单的任务号（`already_building: true`），不问、不预留、不交。任务自己起手也看（最后一道）。 |
| 2 | 那笔费用的问题挂在任务的 `onAccepted` 上清（服务器回了任务号那一刻）；没做成走 `onFailure`：问题放回 / 留着，`price_changed` 把新价记进恢复记录，下一次按新价问；`minimax_voice_exists` 算答完。改记录只经 `SkyStudioVoiceRecovery.updateFee`（现读现改现写，不拿旧的整份去盖）。没做成的单 `get_job` 带 `failure`、`code`，改价的带 `credits_now` / `credits_approved` 和下一步。 |
| 3 | 新读取器 `QueuedAudioWindow`：同一份格式和落盘（`AudioWindowReader` 拆出来的三样零件），读取是单独的同步函数、交给 `MediaReadQueue`。检测语言走 `.analysis`，配旁白的转写走 `.voice`。`AudioWindowReader.extract` 只剩字幕生成在调。 |
| 4 | AI 的 `manage_voices`：收到 `consent_outdated`（这一次的 `consent: true`）就 `SkyStudioCatalogCache.forget()`、读新的那一句，用新版本、新文案再问一次（旧令牌绑着旧版本，不认），结果带 `consent_statement_updated`。对话框：忘掉目录、Store 再取一遍、**那一勾拿掉**（用户同意的是旧的那句）。 |
| 5 | `SkyStudioVoiceRecordingSubmission.make`：整份读录音、算哈希在 `MediaReadQueue.analysis` 上。三种临时文件夹只在 `VoiceLibraryTemp` 起名，启动时后台清**一天以前**留下的（临时目录是几个 SkyCut 共用的，另一个正开着对话框时不能删它手里的）。转写开头那一处的清理不加这几个前缀。 |
| 6 | `overLimit` 改成问 `spend.decide(credits:)`。 |
| 7 | 恢复记录的每一批记 `splitFailures`；转写得了的 Mac 上第一次切不开照旧报错、能恢复，这一批**第二次**还切不开就按字数估（`SkyStudioVoiceSplitEstimate`），结果照旧报 `estimated_split_line_indices`，`voice.note` 说试了两次。 |
| 假协议 | `VoiceLibraryHTTP`：设计 / 建单能先排队（`holdPolls` / `holding`，`GET /jobs/{id}`）、同一个 key 回原来那一单、同一个声音 + 语言开着的建单回那一单、`price_changed`、失败退款、MiniMax 设计上限 760 实扣 751.4、授权那句能升版本。`VoiceRecoveryHTTP`：建单能改价。 |

## 验证

`scripts/check-voice-recovery.sh`：`LibraryOrderChecks`（账按实收 / 改价 / 失败退款 / 排队、MiniMax 版在建时跟着那一单（请求批准和
全部权限 + 长期授权）、授权那句升版本、临时文件夹、`QueuedAudioWindow`）、`FallbackFeeChecks.repricedChecks`、
`LibraryUIChecks.outdatedStatementChecks`、`PaidAudioChecks.neverMatchesChecks`。扫描：`checks/sky-studio-wiring/voice-library-orders.sh`、
`checks/blocking-media-reads.sh`（借用那个例外的调用方）。

反向验证（2026-11-11，每一处临时改回去、跑、再恢复）：

| 临时改成 | 红了什么 |
| --- | --- |
| 建 MiniMax 版之前不看在建的那一单（两处 + 任务自己） | 扫描 3 条；运行：第二次调用又问了一遍、用过的令牌也再问、全部权限下预留 755.2（应为 377.6）、建了两单 |
| 记上账就清费用的问题、没有 `onFailure` | 扫描 2 条；运行 5 条：恢复记录里问题没了、普通 `resume` 不再问、`get_job` 没有下一步、新价建不成 |
| 没做成的单不带原因 | 扫描 1 条；运行：`price_changed` 没有 `credits_now`、退款的设计没有 `billing` |
| `settle` 什么都不做 | 当天的账停在 760（应为 751.4） |
| 没做成不退预留 | 改价 / 退款之后账上还留着那一笔 |
| 两个入口不认 `consent_outdated` | 扫描 1 条；运行：AI 那一路直接报错、对话框还显示 v1 且那一勾还在 |
| 清残留不看多久以前 | 把正开着的三个也删了（删了 6 个） |
| `QueuedAudioWindow` 不看停止标记 | 取消了照样回文件 |
| 检测语言改回借 `AudioWindowReader.extract` | `blocking-media-reads` 红 |
| 对话框自己抄预算规矩 / 自己起临时文件夹 / 主线程建 Submission / 转写的清理带上对话框的前缀 / 启动时不清 | 扫描各红 1–3 条 |
| 第二次切不开也不估 | `neverMatchesChecks` 3 条 |

全部恢复后转绿。

## 教训 / 防回归

- **记上账 ≠ 事情成了**。问题答没答完、要不要再问，以服务器受理为准；受理之前的失败要把局面原样留给下一次。
- **例外要连调用方一起钉**。白名单只管定义的话，第二个调用方出现时没有任何东西会红。
- **缓存的东西被服务器说「旧了」，就得有一条路去刷新**；不然只能等它自己过期。
- **假服务器别太「整齐」**（和 2026-11-10 那一轮同一个教训）：每单当场做完、实扣等于报价，等于没测结算。
- **「重试多少次都一样」的失败要有出路**，不管原因是这台 Mac 转写不了，还是这段音频对不上。
- 没验到的：真 Sky Studio 上的去重 / 改价 / `consent_outdated`（不发付费请求，照接口合同写的）；SkyCut 重启后本机不记得在建的那一单，
  用户再点头会再记一笔（服务器仍只扣一次），当天的账会多出一笔，第二天清零。
- 长期约束：[声音库](../architecture/voice-library.md)第十节、[阻塞的媒体读取](../architecture/blocking-media-reads.md)「例外」、
  [Sky Studio 的任务](../architecture/sky-studio-jobs.md)第五节。
