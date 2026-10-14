# 2026-10-14 挪了配音段，它的字幕留在原地

## 症状

2026-10-06 审美盲测的南极片，AI 用 `add_voiceover subtitles=true` 配了旁白，之后按画面调整节奏，用 `edit_clip` 把几段配音往后挪了一两秒。
配音挪了，字幕还在原来的时刻 —— 字幕比声音早出来一两秒。AI 只好一句句再用 `edit_subtitles` 挪（联动开关是开着的）。

## 根因

- 联动（[联动](../architecture/timeline-linkage.md)）的规矩是「压在主轨块上的东西跟着它的**画面**走」：只有主轨的画面变了才有东西跟。
  配音在音频轨上，挪它主轨一点没变，`TimelineLinkage.follow` 第一行就返回了。
- 字幕本来有「从哪一段生成的」记录（`CueMeta.provenance.clipID`，转写的字幕一直记着），可配音那条路加字幕走的是 `insertCue` ——
  它把每句记成「人工」、不带来源；就算想跟，也不知道该跟谁。

## 修复

- 配音的字幕每句记下是哪段配音生成的（`AIVoiceoverSubtitles.add`：分段结果里本来就有来源，`insertCue` 之后补上，`origin` 记成生成的）。
- 联动加一条（规矩 11，`CaptionSourceFollow`）：原文字幕的来源段**不在主轨上**时，段挪了 / 裁了头 / 变了速，字幕按它在素材里的那一刻跟着挪
  （裁头时那一刻没动就不挪）；段被真删（`deletesContent`）字幕一起删，别的操作让它没了字幕留着。来源在主轨上的照旧只跟画面，两条不叠；
  这次操作碰过的句子不碰；译文轨不跟（两条轨独立）。`TimelineLinkage.follow` 在主轨画面没变时也调它（钩子的位置不变：`perform` / `liveApply` 收尾），
  所以手动拖配音段、AI 的 `edit_clip`、删掉配音段都一样；联动关着时不跟。
- 长期约束写进 [联动](../architecture/timeline-linkage.md) 规矩 11 和已知不足（分割后右半段的字幕记的还是左半段）、[AI 接口（MCP）](../architecture/ai-control-mcp.md) 配旁白那一节。

## 验证

- `scripts/check-timeline-snap.sh` 第 1g 组（`checks/TimelineSnap/LinkageCaptions.swift`）：配音段挪 +3 秒两句跟着 +3、长度不变、报告里算两样；
  主轨来源的句子和手打的不动；裁头字幕留在原地；2 倍速按素材那一刻换算；真删一起删、不是真删留着；这次自己挪过的句子不再挪、没碰的照跟。
- `scripts/check-mcp.sh` 的 `VoiceChecks`：配音的每句字幕记着它的配音段。
- 联动原有的第 1f 组照旧（主轨画面那条没动）。
- 反向验证（不合并的草稿 PR #190，CI）：`TimelineLinkage.follow` 里的 `CaptionSourceFollow.plan` 换成空计划 —— 第 2 组 check-timeline-snap
  红 7 条：配音段挪 3 秒两句字幕都留在原地（10.2 / 12.0，应 13.2 / 15.0）、报告里跟着挪的是 0 句（应 2）、长度没保住、变速后没按源时间换算
  （12.0，应 11.0）、删配音段字幕没跟着删、没被碰过的那句也不跟（12.0，应 15.0）。

## 教训 / 防回归

- **「跟着走」的规矩要问清跟的是什么**：画面跟画面走，字幕是声音说出来的，就该跟声音走；只有主轨一条线的话，音频轨上生成的东西永远没人管。
- **数据里本来有的关系，新入口要照样记**：转写的字幕一直记着来源，配音那条路换了个插入函数就丢了。
