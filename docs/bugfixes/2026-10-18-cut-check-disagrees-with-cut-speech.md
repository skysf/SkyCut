# 2026-10-18 listen cuts=true 说「可以不改」，cut_speech 却说同一刀切在字上

## 症状

测试员转来（测试版 0.18.45，测试工程是 L16 课程目录下的 `SrtFlow/Projects/SrtFlow_测试_L16.srtflowproj`）：一段英文口播用 cut_speech 的 `keep`
剪成 4 段，第 3 段的出点在源 77.417 秒（「…the smartest model currently available.」说完）。

- cut_speech（snap 默认开）说这一刀在声音上，`moved` 里挪到 77.75。
- `listen cuts=true` 查剪完的同一刀：`status: "quiet_spot"`（why 写着「cut_speech would cut here too」，note 写着「fine as it is」），
  **同时**又给了 `suggested_source_out: 77.717`。
- 测试员拿 listen 量：−40 dB 下静音 77.508 才开始，77.417 时「available.」的尾音还在。

检查一边说可以不改、一边建议改；说 cut_speech 也会切在这，cut_speech 却挪走了。AI 照 quiet_spot 留着这一刀，成片会把尾音截掉一截。

## 根因

用 ffmpeg 把原片的声音解出来，照 `AIAudioLevels.windows` 的切法（44.1 kHz 下 2048 帧一窗、从文件开头对齐）复算，测试员看到的两个数都精确对上：

| 窗（秒） | dB | 是什么 |
| --- | --- | --- |
| 77.369–77.415 | −34.3 | 「available」的尾巴 |
| 77.415–77.462 | **−48.2** | 尾音里一格 46 ms 的低谷 —— 77.417 正落在这儿 |
| 77.462–77.601 | −37.6 / −41.0 / −44.3 | 尾音还在 |
| 77.601–77.880 | −60 … −52 | 真停顿 |
| 77.880– | −24.9 | 「The」开口 |

1. **quiet_spot 没看附近有没有真停顿。** `AICutCheck.side` 只要切口落在任何一个低于门限的电平窗里（贴边 0.05 秒也算）就判 quiet_spot；
   「真停顿够不够得着」只拿来决定给不给建议。2026-10-16 加 quiet_spot 时的本意是「附近没有真停顿、cut_speech 自己也只能停在最安静的那一格」
   （[那次的案例](2026-10-16-listen-cuts-suggested-spot-reported-on-speech.md)），可那次的守卫把「安静窗旁边够得着真停顿：照旧 quiet_spot、但建议挪进
   停顿」写成了期望值 —— 正是这次自相矛盾的输出，被守卫钉成了对的。cut_speech 判同一刻：不在停顿里（离停顿开头远过 0.05 秒）、旁边够得着真停顿
   → 挪进去。尾音里的低谷不是两个词之间的空隙。
2. **判法只有 `AISpeechCutPoints` 一份，输入却各量各的。**
   - 门限：cut_speech 量调用时那段片段（这次是整段原片：−48.5，夹到 −45），检查量剪完那一小段前后各 1 秒（−43.9）。−45 下停顿从 77.601 起、
     中间 77.7405、对齐到帧是 77.75；−43.9 下从 77.555 起、中间 77.717 —— 就是那两个数。
   - 词：cut_speech 用估过开口的词（transcribe 读出来的那份，「The」从 77.56 起），检查用识别器原样的词（「The」77.22–77.94，正好盖住 77.417）——
     它要是报切到的词，会报成「The」。
   - 轴：cut_speech 在时间线秒上判、检查在源秒上判，「0.1 秒算停顿、最多挪 0.3 秒」在变速的片段上两边差一个倍速。
   - 建议没对齐到帧，cut_speech 落刀是对齐到帧的。

## 修复

- `AICutCheck.side`：结论就是 cut_speech 在这一刻会怎么做。**quiet_spot 只给 cut_speech 不会挪进真停顿的切口**（附近够不着真停顿、正落在最安静的
  一格里）；cut_speech 会挪进停顿的报 on_speech，建议就是它落刀的地方（`AISpeechCuts.onFrame` 对齐到帧，挪不到半帧的不给）。
- 新的纯值 `AISpeechHearing`（`Sources/SrtFlow/AISpeechHearing.swift`）：两个工具判切口的输入只从这里来 —— 整个素材文件的电平窗、
  **按整个文件量的门限**（AI 给了 silence_db 就用它；不随片段剪成多长变）、整个文件估过开口的词（`SpeechTranscript`，同 transcribe）。
  读法只有 `AISpeechCutTool.wholeFile`（波形要读完整个文件）/ `transcript`（只读缓存）一份，listen cuts=true 也调它们。删停顿（remove_pauses）
  照旧量调用时那段片段，行为不变。
- `AISpeechCutPoints` 的数据都是声音的源秒，多一个 `clip`：cut_speech 问的、拿回去的是时间线秒，进出各换一次；写给 AI 的停顿也换回问的那条轴。
  0.1 秒算不算停顿、最多挪 0.3 秒都按声音自己的秒，变速的片段上两个工具也判得一样。
- 切到的词（`AICutCheck.word`）：cut_speech 会挪进停顿时，只在停顿这一边的词里找 —— 停顿在后面：词尾不过停顿开头的；在前面：词尾过了停顿结尾的 ——
  再取盖着的、或 0.3 秒内最近的。
- `AIListenCuts`：一个素材文件只听一遍（几段共用）；结果的 `silence_db` 写「measured over each media file」，note 补一句 cut_speech 判法一样。
- 长期约束写进 [AI 接口（MCP）](../architecture/ai-control-mcp.md) 第四节第 13 条（cuts=true）和第 27 条（cut_speech）。

## 验证

- 守卫（`scripts/check-mcp.sh`）：
  - `checks/MCP/CutCheckChecks.swift` 新加 `checkCutDipInWordTail`：照 L16 的形状造（尾音里一格低谷、0.14 秒后真停顿、「The」估的开口已在尾音里），
    出点切在低谷上 → on_speech、词是「available.」、建议 = cut_speech 落刀处（对齐到帧）、照建议改完再查是 in_pause。`checkCutQuietSpot` 最后一条
    改成「够得着真停顿的安静窗：on_speech，建议就是 cut_speech 的落点」（原来钉的是矛盾的输出）。
  - 新的 `checks/MCP/SpeechHearingChecks.swift`：L16 原片真量出来的 87 个窗（74.95–79 秒）+ 转写缓存里那一句的原样 —— cut_speech 在整段上
    keep 71.458–77.417，77.417 挪到 77.75；剪辑点检查判剪完的那一段：on_speech、「available.」、建议 77.75。另有：门限按整个文件量、词和 transcribe
    读出来的一样；1.5 倍速的片段上按时间线秒问和按源秒问每一刻都落在同一处，写给 AI 的停顿是时间线秒。
  - 接线扫描（`checks/MCP/listen-wiring.sh`，listen 的两节扫描从 check-mcp.sh 搬出来 —— 它加了这一节到 610 行、超过上限）：判切口的点只在
    `AISpeechHearing` 里建；剪辑点检查只经 `AISpeechCutTool.wholeFile` / `transcript` 读、不起转写；建议对齐到帧。
- 反向验证（本机只编判切口那几组：check-mcp 的源文件清单 + 一个只调这四组的 main，151 项）：
  1. 判定改回旧写法 → 红 3 条（够得着真停顿的安静窗、尾音里的低谷、L16 真电平）；
  2. 切到的词改回只按远近找 → 红 2 条（报成「The」）；
  3. 建议不对齐到帧 → 红 2 条（77.72 / 77.7404，cut_speech 是 77.7083 / 77.75）；
  4. 接线扫描（CI 同款 /bin/bash 3.2）：在 AIListenCuts 里另建判点、自己读波形、去掉 `frame` → 各红一次。
  恢复后 151 项全绿、扫描绿；`swift build --product SrtFlow` 通过，check-mcp 的全部源文件 `swiftc -typecheck` 通过。
- PR #246 首跑 CI 第 4 组红：10-14 那条「cut_speech 的切口要经量出来的停顿」的扫描（`checks/MCP/tool-result-wiring.sh`）按字面钉着
  `AISpeechCutTool` 旧的三行，判点改从 `AISpeechHearing` 建之后它找不到了。它在 check-mcp.sh source 进来的一节里，`scripts/check-guards.sh`
  只跑 `checks/*.sh` 顶层，本地跑不到 —— 和 PR #71、#84、#132 同一类坑。扫描照新接法改（读整个文件的波形、`AISpeechHearing` 建判点、按片段的
  时间线秒问、四种剪法都经判点、结果报 `moved`），撤掉 `clip: speech` 反向验证红一次；check-mcp.sh 编译之前的全部扫描本地用 /bin/bash 跑一遍全绿。
  让 check-guards 也跑这些扫描另开一个 PR。

## 教训 / 防回归

- **检查类工具说「X 会怎么做」，就用 X 的输入、读 X 的决定**，不要另起一个近似的条件 ——「落在一个安静窗上」不等于「cut_speech 不挪」。
- **「同一条规则只有一处实现」要连输入一起算**：判法一份、门限按两段不同的声音量，就是两份规则。读输入的地方也只留一份。
- **守卫的期望值要从意图来**：10-16 的守卫把「quiet_spot + 建议」写成期望值，把自相矛盾的输出钉成了对的（同
  [出场动画先快后慢](2026-10-14-exit-animations-front-loaded.md) 那条：期望值不能照实现抄）。
- 尾音里也有几十毫秒的低谷：「最安静的一格」只有在附近没有真停顿时才是好切口。
