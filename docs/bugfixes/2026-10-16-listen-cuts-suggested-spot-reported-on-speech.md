# 2026-10-16 listen cuts=true 建议把切口挪到两个词之间最安静的一格，照做之后它又把那一格报成切到字

## 症状

PR #219 合并后在测试版 0.18.35 上冒烟（L30 课程、英文口播）：在「custom AI」中间（源 38.9 秒）切一刀，`listen cuts=true` 报两头都是
`on_speech`、词是「AI」、建议 `suggested_source_in` / `suggested_source_out` = 38.464（「moved to the quiet spot between the words」）。
照建议用 `edit_clip` 把两段的出点 / 入点都改到 38.464 再查一遍：这个剪辑点两头还是 `on_speech`，词变成「custom」，而且**没有建议**了 ——
它自己推荐的位置，它又说不行，还给不出更好的地方。AI 照这个结果会以为剪辑点仍有问题，却无处可改。

## 根因

`AISpeechCutPoints.point` 找切口的顺序是：在真的停顿（≥ 0.1 秒的安静）里就不动；不在就先按转写挪，挪到的地方有停顿用停顿，
没有够长的停顿就退到**最近的一个安静窗**（一格约 43 毫秒：一口气说下去时词和词之间那一点点）。cut_speech 就切在那一格里，
这是它找不到停顿时的既定做法。

`AICutCheck.side` 把 `point.why == nil` 当「在停顿里」，别的一律当 `on_speech`。切口正落在那个安静窗里时：它不在 `pauses`
里（不够 0.1 秒）→ `why` 非空 → 报 on_speech；转写那边「custom」收得晚、把 38.464 盖住了 → 报切到「custom」；`point.time`
算出来还是这一格 → 和切口一样 → 没有建议。判法本身是对的（那一格确实不是停顿），错的是**把算法自己的最佳选择当成了问题**：
一个会被自己的建议打脸的检查没法用。

## 修复

- `AICutCheck.Verdict` 加一种 `quietSpot`：切口落在量出来的安静窗里（贴边算在内，同 `AISpeechCutPoints.edgeTolerance`）、又不在
  停顿里时报它，不叫词（转写的词边在这儿不可信），结果里 `status: "quiet_spot"` 带一句解释。只有附近**真的停顿**够得着
  （`point.time` 落在 `pauses` 里）才给建议 —— 挪到另一个安静窗没有意义，挪过去再查还是这一句。
- `on_speech` 的统计不算它；`listen` 结果的 `note` 里多一句 quiet_spot 是什么。
- 守卫：`checks/MCP/CutCheckChecks.swift` 的 `checkCutQuietSpot`：两个词连着说、中间只有一格安静，切在词上 → on_speech 带建议；
  **照建议再查 → quiet_spot、不再建议**（没修时这条红：报 on_speech、词「custom」）；安静窗旁边够得着真停顿时照旧建议挪进停顿。
  `scripts/check-mcp.sh` 跑它。

## 验证

- 守卫反向验证：把 `side` 里安静窗那一支改成永远不走（`if false`），`check-mcp` 红在「cut where it suggested, the head checks back as
  quiet_spot」；恢复后绿。
- 测试版装上这版后再跑同一段冒烟：把切口放到 38.464 之后两头报 `quiet_spot`、没有建议（见记忆 / 本案例的后续）。

## 教训 / 防回归

- **检查类的工具要和它自己的建议闭环**：建议 X、照 X 改完再查必须是「好了」，写守卫时就把「照建议改完再查」这一步写进去。
- 「不在停顿里」和「切到字」不是一回事：声音连着说的两个词之间，算法自己也只能退到最安静的一格，那一格就是这段声音里最好的切口。
- 转写的词边在停顿两侧会偏（docs/bugfixes/2026-10-14-cut-speech-trusts-word-times.md），声音说安静的地方不要再拿转写去定罪。

**后续（2026-10-18）**：这次的修法只拿「真停顿够不够得着」决定给不给建议，没拿它决定判定；守卫还把「安静窗旁边够得着真停顿：照旧 quiet_spot、
但建议挪进停顿」写成了期望值 —— 那是自相矛盾的输出（quiet_spot 说 cut_speech 也会切在这，cut_speech 却挪进了停顿）。L16 上撞出来：切在
「available.」尾音里的一格低谷上，报 quiet_spot 又建议挪。现在 quiet_spot 只给 cut_speech 不挪的切口，见
[2026-10-18 案例](2026-10-18-cut-check-disagrees-with-cut-speech.md)。
