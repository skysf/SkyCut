# 2026-10-16 edit_clip 改入点：开头不动、结尾动，这条有意的差别只写在注释里

## 症状

测试员（AI 会话）反馈：「文档没写清楚改 source_in 时，片段的开始位置是固定不动还是跟着变。这次是我先在最后一段上试了
一下才确认的：开始位置固定，结束位置移动。」

它只能挑一段不碍事的试：`edit_clip` 的说明里关于裁切只有一句「trim it (source_in/source_out are seconds in the source
file)」，参数说明也只有「New start inside the source file, seconds」。

## 根因

行为本身是**故意的**：`AIClipEdit.swift` 开头的注释写着「语义和拖把手不同，是有意的：AI 说的是绝对值（『入点改成 2.0 秒』），
所以改入出点时片段的起点不动（除非同时给了 start）；拖左把手则是连起点一起挪」。但这条差别从 2026-09-27 第二块起只在代码注释里，
没进工具说明 —— 给人看的注释 AI 读不到，而剪辑软件里「裁头」的惯例恰恰是开头跟着挪，AI 按惯例猜就会猜反。

第四节第 42 条 ③ 说「意图用参数说而不是靠拖拽的惯例」，这里是它的反面：参数在、意图在，就是没说出来。

## 修复

- `Sources/SrtFlowMCPKit/MCPTimelineTools.swift`：说明里那句改成「… (source_in/source_out are seconds in the source file: the
  clip's timeline start stays where it is and its end moves; pass start too to keep the end in place)」；`source_in` 的参数说明补
  「The clip's timeline start stays; its end moves」，`source_out` 补「the clip's end moves」。ripple=true 推后面的 V1 那句原来就有，
  紧跟在后面。
- 守卫：`checks/MCP/ProtocolChecks.swift` 对小程序真给出来的 `edit_clip` 说明查「timeline start stays」（和 export_video 的
  music_credits、recipes 的那两条同一处）—— 说明以后为了省清单预算被收短时，这句不许收掉。
- 规矩写进 [AI 接口（MCP）](../architecture/ai-control-mcp.md) 第四节第 42 条 ③。

## 验证

- 守卫的判断就是「小程序 tools/list 给出来的 edit_clip 说明含不含这几个字」。反向验证用同一条判断对两份小程序跑：装着的
  0.18.34（main f51cd20，没有这句）→ 不含，红；本地新编的 → 含，绿。
- edit_clip 的说明 1,430 → 1,534 字（上限 2,048，`CatalogTextChecks`）；全清单 83,914 → 约 84,100 字（上限 90,000）。
- CI 的 `scripts/check-mcp.sh` 跑完整的 `ProtocolChecks`。

## 教训 / 防回归

- **给 AI 的接口里，「和界面上的惯例不一样」本身就是要写进说明的事实**。注释写给改代码的人，说明写给调工具的 AI，两边各要一份；
  只有一边等于没写。
- 这种「我知道、它不知道」的差别，最省字的写法是写在参数旁边（一句话），不要只放在工具说明的长段落里。
