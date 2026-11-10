# 2026-11-10 声音功能的免费冒烟补跑（声音 PR 3–6）

> 用户 2026-11-10「开更多会话把测试做完」：声音 PR 3–6 合进 main 之后，`voice.py` 按合批改过没跑过，声音库、几批同时交还没有免费冒烟。
> 这一轮全部在本机假 Sky Studio 上跑：不花钱、不调真服务商，不碰正式版、测试版、用户的工程和用户的钥匙串。方案：
> [SkyCut 声音方案](../plans/2026-11-09-voice-features.md) 9.2；脚本和起法：[GUI 冒烟流程](../testing/gui-smoke-testing.md) 四之八（第 2、3a、3b 条）。

## 环境

- main `d50b1db`（#365 合并之后；先在 `cd1980a` 上跑通一遍，合进 #365 重编之后全部再跑一遍）；macOS 26.5.2、M1，`swift build --arch arm64`。
- 独立测试身份 `com.srtflow.SrtFlow.<名字>.skystudiosmoke`、回环端口 18781（这一轮起 `run.sh` 能换身份和端口，见四之八），ffmpeg 拷进测试目录。
- 英文转写模型：这台 Mac 已经装好（`SpeechTranscriber.installedLocales` 里有 `en_US`）。
- 机器上同时有别的会话在编译：load average 在 11 到 28 之间，结果和它有关（见「看见的问题」第 1 条）。

## 结果

| 项 | 跑没跑到 | 结果 |
| --- | --- | --- |
| 1. `voice.py`（声音 PR 5 合批之后第一次跑） | 跑了（两轮，合 #365 之后那轮 12 秒） | **过**。默认 `gemini:Charon`；两句合成一批（`skystudio_job_ids` 一个）；`subtitle_timing: aligned`、两句字幕；一步撤销；`clone_from` 被参数核对拒；排队中取消退款、重复取消不重复退；报价时服务出错当场退本机（Kokoro `am_fenrir`，带 `voice.note`）；下载 / PUT 不带 Key |
| 1 的一部分：转写模型没装时「交第一批之前装」 | **没跑到**（模型已经装好，`local_step` 没出现） | 不算通过；要找一台没装英文模型的 macOS 26 走一遍 |
| 2. 声音库 `voice_library.py`（新） | 跑了（三轮；最后一轮 25 秒） | **过**，见下面「声音库」 |
| 3. 几批同时交 `voice_concurrency.py`（新） | 跑了（三轮；最后一轮 65 秒） | **过**，见下面「几批同时交」 |
| 方案 9.2 的中途换备用 `voice_fallback.py`（新） | 跑了（两轮；最后一轮 18 秒） | **过**，见下面「中途换备用」 |
| 回归：`zero.py`、`permissions.py`（假服务改了之后） | 跑了 | **过** |
| 回归：`media.py`、`model_expansion.py` | 跑了 | **红，旧账**：2026-11-01 的 AI 权限模式（`2fa04cb`）之后请求批准模式下 `quality=highest` 先问，这两个脚本（10-30 / 10-31 写的）还按直接开始核对。和声音无关，这次没改 |
| 界面上任务浮层那一行「n/5 batches · x running · y waiting」 | **没看** | 进程内驱动打不开工具栏的任务浮层；`get_job` 的 `batches_done / batches_running / batches_waiting / batch_count` 和那一行读的是同一个 `SkyStudioVoiceBatchBoard`。要人看一眼 |
| 全部权限下「不问、带 `standing_grant`」 | **没跑到** | 声音 PR 7 还没合；假服务已经有 `/voices/consent-grant`，脚本在假服务记着有效授权时改核对这一条 |
| 变声 `change_voice` | 没跑 | 声音 PR 9 还没做 |

### 声音库（`voice_library.py`）

- 列：中文、英文两份预设，各自标出默认的 `gemini:Charon`；日语没有自己的名单，回英文那份并写 `list_language: en`；我的声音一开始是空的。
- 用录音新建（请求批准模式）：问句带 `voice-consent-v1` 的原文和「用了哪一段、14 秒清楚的人声」；问之前没有 `/uploads`、没有 `POST /voices`；
  拿这张令牌换个名字再调被拒（`confirm_token_refused`、另发一张）；点头之后传一次 `voice_reference`（假服务核对是 44.1 kHz 单声道 16-bit WAV）、
  `POST /voices` 一次，带 `consent: true` + 版本、`source`（文件名、起止、`auto_selected: false`）、`idempotency_key`。
  6 秒的录音（4.9 秒人声）当场拒：`too_little_speech`、还差 5.1 秒，什么都没传。
- 加一种语言（中文）：问授权 → 加上；同一种语言再加：服务器回 `reference_exists`，话说清楚（但见「看见的问题」第 2 条）。改名：列表里跟着变。
- `voice=voice_…` 读稿：问一次性费用（375 积分建英文的 MiniMax 版，`rule: default_needs_one_time`），问的时候没有 `/jobs`；`skip_one_time=true`
  照 IndexTTS2 读、对齐的字幕、两段两句一步撤销；再问一次拿到的是同一张令牌；点头起 `voice_enroll`、做完英文 `minimax: true`，再读就是
  `minimax-speech-2.8-hd`、不再问。
- 设计：问「约 20.2（最多 22.5）积分」、`qwen3-voice-design`，问的时候没有 `/jobs`；点头起任务、做完有新声音和 `sample_url`。额度只剩 10 积分时
  再设计：`daily_budget_exceeded`、没有令牌、没有 `/jobs`。
- 删除：请求批准模式问一句（写名字）、点头才删；全部权限直接删，存储一时不可用（503）自动再发一次（两次 DELETE）。
- 全部权限下建声音的授权、读稿的一次性费用照样问（PR 6 的规矩：还没有长期授权）。
- 声音库用不了（503 `not_configured`）：`list_voices` 照回预设、`mine` 写 `unavailable`；改名、`voice_…` 读稿都报「暂时用不了、一分没花」，
  没有 `/jobs`、没有退本机。
- `manage_voices` 不登记时间线撤销：放一段 → 改名 → 撤一步 = 撤掉的是那一段，再撤说没有可撤的。
- 一轮花假积分 400.5（建 MiniMax 版 375 + 设计 22.5 + 两次读稿各 1.5）。

### 几批同时交（`voice_concurrency.py`）

起法：声音池 2、共用池 1、每批 80 字（十句同样的话分成 5 批）。

- 声音池：两批交上去、三批在本机等（`get_job`：0/5 好了、2 在跑、3 在等），等了 3 秒没有第三个 POST。
- 共用池不被声音池挡：声音池满着时图片 A 照交；图片 B 在本机等，A 做完才交；共用池回一次 429，等 15 秒用同一个 `idempotency_key` 再交、做完。
  图片一直没占声音池的槽。
- 放行一批：做完、还槽、下一批交上去（1/5 好了、2 在跑、2 在等）。
- 中途停（一批在 Sky Studio 已经开始、一批排着队、两批在本机等）：发了两次取消，排队的那批取消并退钱、开始了的那批照实说并接着查到底，
  在等的两批没交；任务 `cancelled`、给 `recovery_file`。
- 普通恢复：拿回已有的（第 1、2 批，四句写成文件），没有新的 POST、没落地，结束时叫用 `generate_missing=true`。
- `generate_missing=true`：照记录的选择再报一次价，只交没做的三批（声音池回一次 429 的那批用同一个 key 再交，一共 4 个 POST），已经交过的 key 一个没再用；
  十句十条字幕一次落地，一步撤销全回去。

### 中途换备用（`voice_fallback.py`）

- `fallback_used`：先做完的那批说换了备用 → 还没交的第三批带 `eleven-v4` 的 plan；结果 `line_models` 写清 4 句 `eleven-v4`、2 句 Gemini，
  `voice.note` 提醒前后可能听得出差别。
- `fallback_needs_one_time`（声音库的声音、照 IndexTTS2 读）：出错的那批没扣钱、另一批收好，任务以可恢复的 `failed` 结束；结束码不带价，
  SkyCut 自己 `/quote` 了一次 `voice_enroll`，`get_job` 问「375 积分建 MiniMax 版」并给令牌；`resume` + 令牌起建的任务，建好之后
  `resume` + `generate_missing` 只补那一批（新 key、原来的 IndexTTS2），四句一次落地。

## 看见的问题（交给调度，这里没修）

1. **（中）SkyCut 不在前台时，AI 起的活跑在 App Nap 的优先级上，机器一忙就慢到超时。** 测试 App 在后台（`open -g`、AI 后台模式没有窗口）时，
   `ps` 的优先级是 4；一次旁白任务里 40 个采样有 37 个是 4、只有 3 个是 46。load 22–28 时：主线程在 `get_job` 拼字典这种小事上一卡 1–5 秒
   （`~/Library/Logs/SrtFlow/main-thread-stalls.log`，栈在 `AIJobs.json`），5 秒的一批本机转写在「finishing」停了 190 秒以上，
   报价失败退本机的 Kokoro 合成超过 90 秒（MCP 调用超时）；同样的脚本 load 11–14 时 11–25 秒跑完。SkyCut 只在录屏时拿
   `ProcessInfo.beginActivity`（`ScreenRecordingCoordinator.swift`，注释写着「否则 App Nap 拖垮时长」），AI 的任务（转写、本机读稿、等云端、导出）都没有。
   用户在别的 App 里干活、让 AI 在后台剪的时候就是这个情形。没有验证改法（比如跑任务时拿活动断言）。
2. **（低）给声音加一种已经有的语言：先问授权、把录音传上去，服务器才回 `reference_exists`。** 用户白确认一次授权，一段人声录音白传到 Sky Studio。
   删除之前已经会 `GET /voices/{id}`，加语言之前也能先看一眼这种语言在不在。
3. **（低）加一种语言的授权问句里写的是声音 id**（「add a Chinese recording to voice_be4d…」），新建、删除的问句写的是名字；AI 要把它转述给用户。
4. **（低）停下几批的旁白时，`message` 只说了已经开始的那一批**（「Sky Studio had already started it, so it could not be cancelled…」）：
   没说一批做好了、一批排着队退了钱、两批没交。结构化的字段里都有，但一句话里的「it」指不清是哪一批。
5. **（低）结果不明的那一批的句子不在任何一个句子列表里**：停的时候那批已经在 Sky Studio 开始了，`unknown_batch_indices` 有它的批号，
   可 `completed_line_indices`、`pending_recovery_line_indices`、`not_generated_line_indices` 都没有那两句；按句子读的 AI 会以为它们不存在。
6. 旧账（不是声音）：`media.py`、`model_expansion.py` 从 2026-11-01 起在请求批准模式下红（见上表）。

另外：测试身份的主线程卡顿日志写进和正式版共用的 `~/Library/Logs/SrtFlow/main-thread-stalls.log`，本机 Kokoro 读的也是共用的
`~/Library/Application Support/SrtFlow/Voices/`（只读）。和以前一样，这一轮没有改。

## 冒烟脚本这一轮改了什么

- `run.sh`：`SKYSTUDIO_SMOKE_BUNDLE`（必须以 `.skystudiosmoke` 结尾）/ `SKYSTUDIO_SMOKE_PORT` 换身份和端口，`SKYSTUDIO_SMOKE_CONTROL` 给假服务起手的控制项；
  这一节的 Python 脚本都按 `SKYSTUDIO_SMOKE_PORT` 找服务。
- 假服务（`server.py` + 新的 `voice_library_fixtures.py`）：`/voices` 的增删改查和长期授权、设计 / 建 MiniMax 版的报价和成品、声音库读稿的整段报价
  （一次性费用、备用）；`/me` 报两个池；`/models` 带全部声音模型、能压小读稿每批的字数；按种类 hold 和 `POST /__release`；`pool_full` 让某个池回一次 429；
  `voice_job_outcomes` 让某一批中途换备用 / 备用要先建 MiniMax 版；`GET /__jobs`、`/__voices` 给脚本核对。
- 新脚本：`voice_library.py`、`voice_concurrency.py`、`voice_fallback.py`，共用 `voice_smoke_support.py`。
