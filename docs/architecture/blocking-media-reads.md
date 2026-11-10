# 阻塞的媒体读取不进 Swift 并发的线程池

> 2026-09-23 事故后定下的硬约束。写任何 `AVAssetReader` 读取循环之前必读；在 async 函数
> 或 `Task` 里做其他会卡住线程的事（等信号量、同步 IO、等子进程）之前也要读。
> 案例：[打开工程后缩略图和波形全空](../bugfixes/2026-09-23-waveform-decode-deadlocks-thread-pool.md)。

## 约束

循环调 `AVAssetReaderOutput.copyNextSampleBuffer()` 的读取，**不许跑在 Swift 并发的协作
线程池里**。也就是说，不许写在 async 函数里，也不许包进 `Task { }` / `Task.detached`。
要读的话：

1. 在 async 函数里做完异步的准备工作（`loadTracks`、`load(.formatDescriptions)` 等）；
2. 把「建 reader → `startReading` → 循环读」写成**单独的同步函数**；
3. 交给 `MediaReadQueue`（`Sources/SrtFlow/MediaReadQueue.swift`）去跑：
   - 只要一个结果时：`await MediaReadQueue.run(on: MediaReadQueue.detail) { readTile(…) }`；
   - 读的途中要陆续往外交东西时（比如波形总览边读边画）：在
     `MediaReadQueue.overview.addOperation { … }` 里读，每攒出一份就 `feed.yield`，读完
     `feed.finish()`；async 那一边 `for await` 这条 `AsyncStream`。参照
     `WaveformDecoder.decode`。

## 为什么

- `copyNextSampleBuffer()` 会卡住调用它的线程，一直等到 CoreMedia 在自己那边把下一块
  解出来。CoreMedia 做这份活时，沿用的是调用方的 QoS。
- 协作线程池每个 QoS 只有 CPU 核数条线程，**堵住的不补**。同一档上同时卡着的读取一旦
  凑满核数，这一档就再也派不出线程：CoreMedia 的活排不上队，卡着的读取也就永远等不到
  数据。结果是**死锁**：从此整档 QoS 都不再执行任何东西，同一档的 GCD 活也停，CPU 0%。
- 实测（8 核）：用生产的 `WaveformStore` 同时读 7 个文件，0.23 秒读完；读 8 个就永远不
  返回。同样的循环挪到 `OperationQueue` 上之后，宽度从 1 到 64，43 个文件都能全部读完。
- 跟着一起死的不止读取本身，同一档上的所有 task 都会停。2026-09-23 缩略图就是这样没的：
  取图的 task 在 utility 档，它本身并不阻塞，却一直排不上。要是死的是 userInitiated 档，
  打开工程、扫描字体都会挂住。
- 「限流，但还留在池子里读」不算修好：那是在赌同时卡住的读取永远少于核数。可核数随机器
  变，别处也可能在同一档卡线程。

## 几条队列

| 队列 | QoS | 宽度 | 用途 |
| --- | --- | --- | --- |
| `overview` | utility | 2 | 波形总览，整个文件从头读到尾；打开工程时几十个文件一起排队 |
| `detail` | userInitiated | 2 | 深度放大时读原始采样，一秒一块，用户正盯着看 |
| `export` | userInitiated | 1 | 导出时把整条混音离线读成文件（[成片的声音](export-audio-mixdown.md)）；一次只导一个，单独一条不占波形那两条 |
| `shots` | utility | 1 | AI 找镜头切换点（`AIShotScan`）：一个视频从头解到尾，1440p 的课 M1 上约 17 倍速、分段并行也不更快（硬件解码器只有一个），长的要几十秒；单独一条，扫着的时候不占 `analysis` 那两条（[AI 接口](ai-control-mcp.md)） |
| `voice` | userInitiated | 1 | 本机配音（`KokoroVoiceSpeech`）：CoreML 的一次推理同样卡线程（一句约 0.4 秒，第一次要等神经网络引擎编译约 10 秒），模型不同时跑两次、加载也在这条上（[AI 接口](ai-control-mcp.md) 第四节第 35 条） |
| `proxy` | utility | 1 | 优化媒体的转码（`OptimizedMediaTranscoder`）：读一块、硬编一块，解码器和编码器各只有一个，并行也不更快；在后台转，不和播放抢（[优化媒体](optimized-media.md)）。关键帧间隔和解码速度的探测（`MediaKeyframeProbe` / `DecodeSpeedProbe`）走 `detail` |
| `analysis` | userInitiated | 2 | AI 看画面、读文稿：Vision 的 `VNImageRequestHandler.perform`（认人脸、标签、字）同样卡住线程、等 Vision 自己队列上的活；PDFKit 抽大 PDF 的字也要一两秒。AI 的节拍与文件显式短窗也在这里用原生 `AVAssetReader.timeRange` 读采样（[AI 接口](ai-control-mcp.md)）；克隆参考录音的整段量响度和截取（`VoiceReferenceReader`，[声音库](voice-library.md)）也在这里 |

宽度只关系到性能（和播放抢 CPU、内存），和死锁无关。43 个短素材：宽度 1 用 0.92 秒，
宽度 2 用 0.77 秒，3 以上约 0.7 秒。宽度取 2，这样一条被长录屏占住时，另一条照样往下走。

## 读取中的取消与释放

`AVAssetReader.cancelReading()` **不能与输出的 `copyNextSampleBuffer()` 并发**。
本机 Apple SDK 的 `AVFoundation.framework/Headers/AVAssetReader.h:222` 明确写着：
“This method should not be called concurrently with any calls to -[AVAssetReaderOutput copyNextSampleBuffer].”
[API 说明](https://developer.apple.com/documentation/avfoundation/avassetreader/cancelreading%28%29)
中的停止后台预读，不等于允许另一个线程拆掉正在交样本的 reader。

`listen` 的规则是同一个 `analysis` 同步读取体拥有 reader：建立、启动、每次 copy、
唯一的 `defer cancelReading` 和最后释放都在那里。调用方、截止时间 timer 和
`onCancel` 只记停止原因，不持有 reader，也不调用其原生取消。读取体在每次 copy
前后检查停止信号；收尾和 autorelease pool 释放完成后，才恢复等待结果的 continuation。
取消或超时绝不发布半份统计。

metadata 加载阶段仍可立即 `asset.cancelLoading()`；向读取 operation 移交时，在同一锁内
结束这一阶段。取消先发生就留下 failure、不开 reader；移交先发生，之后不能再对读取中的
asset 调 `cancelLoading`。还在队列中的 operation 直接取消、立即回失败，不必等队列空位。

**截止时间的边界**：活动读取在当前一次 native copy 返回后停止，不能把任意卡死的原生
调用硬中断。不得为了让超时看起来准点而跨线程调用 `cancelReading`，也不得提前报告
“已经结束”却把仍在读的对象留在后台。遇到系统解码器不返回时应保留真实的等待状态；
这是原生调用的限制，需要实机核对，不能算作已证明有界的墙钟完成时间。
案例：[取消 listen 时跨线程拆掉正在读的 reader](../bugfixes/2026-11-04-listen-reader-cancel-during-copy.md)。

## 例外

- `SubtitleGen/AudioWindowReader.extract`：字幕生成按窗口抽音频，`TranscriptionTask` 里
  严格一个窗口读完再读下一个，同一时刻最多卡住一条线程，凑不满。**哪天要并行抽，先把它
  挪到 `MediaReadQueue`。** 守卫的白名单里写着同样的理由。
- **这个例外只给字幕生成**：`extract` 的调用方只许在 `SubtitleGen/` 里（守卫钉着）。别处要同样的 16 kHz CAF，走
  `QueuedAudioWindow.extract(…, on: 队列)`：格式、建文件、一块采样怎么落盘用的是 `AudioWindowReader` 的同一份零件，读取是单独的
  同步函数、在点名的 `MediaReadQueue` 上跑，取消只置停止标记。现在两处：配旁白回到本机的音频要转写（`.voice`）、新建声音时检测
  录音的语言（`.analysis`）。2026-11-11 之前这两处都借了 `extract`，白名单只看定义、看不见调用方
  （[案例](../bugfixes/2026-11-11-voice-library-review-followups.md)）。

## 同类的别的阻塞

问题不限于 `AVAssetReader`。在 async 函数里等信号量、`waitUntilExit()`、
`readDataToEndOfFile()`，都会占住池子里的线程。要不要死锁，看的是**等的东西需不需要同一档
的线程**：

- 等外部进程（比如 `MediaProbe` 退回 ffmpeg 解析的那条路）不会死锁，只是占着线程；
- 等本进程里别的活（信号量、CoreMedia 解码）会死锁。

拿不准的，一律按「会死锁」处理，挪出池子。

钥匙串也属于此类：`SecItemCopyMatching` 可能等系统授权，不能直接放在缓存 actor 内，
也不能用 `Task.detached` 承接。`KeychainSecretExecutor` 用独立串行 `OperationQueue`
执行存在 / 读 / 存 / 删，互斥保护进程级交互开关；`KeychainSecretCache` 只管理等待和结果。
静默等待最多 3 秒，其他调用快回需要授权；原生调用迟到成功仍可缓存，存换删后的旧结果作废。
不能在超时线程恢复交互开关，原生调用未返回时也不能声称已经中断。见[钥匙串阻塞案例](../bugfixes/2026-11-07-keychain-prompt-blocks-ai-calls.md)。

## 子进程的异步退出

`FFmpegProcess` 的退出要在启动前注册 `Process.terminationHandler`，和 stdout / stderr 的排空一起汇合后才返回。
启动失败时解除退出回调、归还计数并关闭写端，让读线程收到 EOF。成功、失败和取消都走这一份生产实现。

这里不用另一个 worker 的 `waitUntilExit()` 当退出屏障：它轮询调用线程的 RunLoop，退出通知依赖启动线程，
本机短进程回归和 CI 原生栈已观察到这种跨线程接法不收尾。
[Apple 的等待说明](https://developer.apple.com/documentation/foundation/process/waituntilexit%28%29)与
[退出通知说明](https://developer.apple.com/documentation/foundation/process/didterminatenotification)分别写明了这两个上下文。
读管道仍在普通 GCD worker 上阻塞读取，退出回调本身不占一条等待线程。
案例：[短导出卡在退出等待](../bugfixes/2026-11-03-ffmpeg-exit-wait-runloop.md)。

## 引擎启动探测

`FFmpegRuntime` 的版本和滤镜查询是短命令。每个候选的两次查询共用 5 秒单调时钟预算，
每条命令 stdout / stderr 合流后的输出最多 256 KiB；任一命令启动失败、超时、超量、
异常终止或非零退出都不能把这个候选发布为可用引擎。正常滤镜清单没有 libass 时仍如实发布能力缺失。
候选按标准化路径去重，保留第一次出现的来源优先级，失败的同一路径也不能再耗一轮探测预算。

探测使用窄用途原生 `posix_spawn`；标准输入接 `/dev/null`，`POSIX_SPAWN_CLOEXEC_DEFAULT`
阻止继承无关文件描述符，并显式重置子进程信号屏蔽和默认处理。管道读端非阻塞，进程退出与
EOF 必须同时成立才能接受输出；后代继承写端时到期拒绝，不能无限排空或假定输出完整。

父进程独占该 PID 的 `waitpid(WNOHANG)` 回收权。失败只向本次探测发送 TERM / KILL，
各轮最多轮询 0.2 秒；未回收的 PID 不会被复用，不按名称或进程组停止引擎。OS 尚未在 KILL
宽限期交付退出时，把回收权交给同一串行 DispatchSource 的注册 / 退出回调，既处理注册前
已经退出的子进程，也处理后来退出的子进程；不再发信号，不占永久阻塞的等待线程。
其他代码不得用 `waitpid(-1)` 回收不属于自己的孩子，也不得全局忽略 SIGCHLD 而破坏此所有权。

这些上限约束应用层的读取、轮询和输出。原生启动、文件系统调用、内核调度和退出交付本身
可能不可中断；不得宣称能硬性保证任何受 OS 阻塞的程序都在 5 秒内完成启动或终止。

定位的阻塞工作走 `MediaReadQueue.analysis`。`MediaToolchain` 继续只由 MainActor 使用，
在首次 await 前同步登记正在进行的任务；后台生成、工程打开和视图出现同时请求时，只启动一轮定位。
定位结果返回前不会把 `isResolving` 写成完成，完成后重复入口不会又开一轮。

`scripts/check-engine-probe.sh` 使用真实生产类和合成命令检查退出结果、双流总量、挂起、
忽略 TERM、文件描述符、回收窗口、继承写端、候选去重、共享预算和并发入口。批量检查的
30 秒独立看门狗只管理自己创建的合成进程树，不替代每条命令的截止时间；失败保留阶段
耗时和可取得的原生栈。故意损坏合成前置检查后不再进入定位兜底，防止反向验证误探测真实候选。
案例：[后台引擎短探测无限等待且重复启动](../bugfixes/2026-11-04-engine-probe-hangs.md)。

## 回归

| 检查 | 守什么 |
| --- | --- |
| `scripts/check-waveform.sh` 第 7 节 | 同时读 `min(40, max(16, 2 × 核数))` 个文件，总览和原始采样块各一轮，必须全部读完；看门狗跑在普通线程上，30 秒没读完就判红（死锁时 await 永远不回来，没有看门狗的话守卫只会挂住，不会变红） |
| `checks/blocking-media-reads.sh` | `copyNextSampleBuffer` 写在 async 函数里就红（白名单只有 `AudioWindowReader`，理由见上）；`AudioWindowReader.extract` 在 `SubtitleGen/` 以外被调就红；`QueuedAudioWindow` 的读取要交给 `MediaReadQueue`。已知盲区：同步函数里再包一层 `Task { }`，这条看不出来 |
| `scripts/check-export-profile.sh` | 生产 `FFmpegProcess` 的立即退出、双管道 / 最后进度、错误和取消；独立线程的 30 秒看门狗在旧等待实现上实际变红 |
| `scripts/check-engine-probe.sh` | 短探测的截止时间 / 双输出上限 / 退出码，父进程唯一回收、信号与描述符隔离、注册前后退出窗口、候选去重与单次定位任务 |
| `scripts/check-mcp.sh` 的 `ListenRangeChecks` / `ListenReaderLifecycleChecks` | 显式文件范围在 `analysis` 上有界读取；队列中超时/取消直接结束，已开读时等本次 copy 返回再由读取体单点取消与释放；原生探针固定线程交错，失败不发布半份统计 |

**人工回归**（自动化够不着的真实工程，发版前实机验证）：

- [ ] 打开一份素材数多于 CPU 核数的工程（比如 `AI_Video_SouthPole` 那份，43 个素材）：
      几秒之内，所有视频块都出缩略图，所有音频块都出波形。
- [ ] 放大到按帧显示，在叠着好几条音频轨的位置来回滚动：波形逐渐变清楚，界面不卡，
      不留空块。
- [ ] 对真实长文件的显式 `listen` 区间，在读取中取消并触发截止时间：无崩溃、无半份统计，
      收尾后同队列还能读取。若底层 copy 长时间不返回，不得声称硬超时已完成；记录素材、
      系统版本和原生等待栈，确认 UI 仍保持真实的等待状态。
- [ ] 在自己的后台 MCP 验收工程中确认引擎可用；可中断的受阻引擎应在有限探测后返回不可用，
      官方请求在实际提交前失败，不产生 `/jobs` 或收费回执。真实 OS/TCC 原因须另以证据确认，
      不能从一次超时推断为授权问题。
