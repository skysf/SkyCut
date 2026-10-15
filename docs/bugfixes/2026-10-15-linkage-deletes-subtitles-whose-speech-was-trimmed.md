# 2026-10-15 裁切后说的话剩不到一半的字幕「留在原地」，和前移过来的下一句叠在一起

## 症状

测试版 0.18.30 上扮成 AI 客户端复测（联动开）：L30 全片一段 + 生成的 59 句字幕，`edit_clip source_in=1.0 ripple=true`：

- 第一句「Congratulations on finishing the course」留在 [0, 1.777]，下一句前移到 [0.86, 2.157]，两句叠了约 0.9 秒；结果里
  `linkage.left_subtitles` 列着第一句。
- 手动拖裁切把手一样（`liveTrim` → `liveApply`，`deletesContent: false`）。
- 不能变的：`source_in=0.5` 时这句说的话还剩七成，正常收短到 [0, 1.277]，其余整体前移 0.5。

## 根因

[联动规矩 12](../architecture/timeline-linkage.md)（2026-10-15 早上的 [案例](2026-10-15-linkage-moves-subtitles-as-a-block.md)）：
`LinkageCueFollow.outcome` 在字幕底下的画面全没了、或说话的那几秒剩不到一半时返回 `deletesContent ? .delete : .leftBehind` —— 裁切不算真删，
走「留在原地」。那是照搬规矩 4（「裁切是边拖边看的探索动作，拖过去一句字幕就没了太吓人」），那条是给文字、音效这类**摆上去**的东西定的。
字幕是说出来的话，话都裁掉了还留着，只会压在前移过来的下一句上；而且拖把手时 `liveApply` 每拍都从手势开始时的快照重放，拖回来字幕就回来，
「太吓人」的顾虑对字幕本来就不成立。

## 修复

用户定：**裁切让一句字幕说的话剩不到一半时也删，不再留在原地。**

- `LinkageCueFollow.gone`：说的话（大半）没了时，真删删；不是真删但底下的段都还在（同 id：只是裁切 / 变速 / 滑动让这截画面不在它的
  窗口里了）也删；只有底下有段整个没了、又不是真删（少见：转静帧失败收回占位块那一类）才留在原地、报出来（`leftBehind` 只剩这一种）。
  原文、译文两条轨和配音的字幕（规矩 11，`CaptionSourceFollow` 走同一个 `outcome`）都是这样。
- 动手前先验了交接里点出的风险：upscale 换源 / 换文件是同 id 换了素材，账按源时间对不上，「parts 为空就删」会让换源一次字幕全没 ——
  自检一跑，发现现状比那还糟（压在上面的东西全被挪了一个偏移），先在 [换源案例](2026-10-15-linkage-follows-source-shift-after-swap.md)
  修掉（同 id 换素材按改之前的素材和入点记账），这条规矩才敢按「底下的段都还在」判。
- 给 AI 的结果（`AILinkageReport`）多一样 `deleted_subtitles`（跟着没了几句）：只报一个 `deleted`，AI 会以为删了段；`left_subtitles`
  的说明改成「底下的段没了、又不是删掉的」。
- `VideoEditProject.liveApply` 的注释「连续编辑从不真删」改成「不传真删；说的话被裁掉的字幕照样删，每拍从快照重放、拖回来就回来」。
- 长期约束：[联动](../architecture/timeline-linkage.md) 规矩 4 / 12、场景表、AI 那一节、人工回归；[方案](../plans/2026-10-02-timeline-linkage.md)
  补了这次拍的板。

## 验证

- `scripts/check-timeline-snap.sh` 第 1h 组（`checks/TimelineSnap/LinkageCues.swift`）：改入点 +0.5 时整句在被裁掉那截上的、说的话大半被裁掉的
  两句都删（以前留在原地）、报 `deletedCues: 2`、没有留在原地的；用户 L30 的样子（`source_in=1.0` 第一句删、下一句到 [0.86,2.157)；
  `source_in=0.5` 第一句收短到 [0,1.277)、下一句前移 0.5）；段整个没了又不是真删的仍留在原地并报 `leftCues`。第 1f 组：被裁掉那 2 秒上的字幕
  没了（文字照旧留在原地）、删 B 的报告带 `deletedCues: 1`。第 1g 组：配音段裁掉头 1.5 秒，第一句说的话只剩两成 → 删、第二句原地。共 670 项全绿。
- `scripts/check-mcp.sh` 的 `LinkageReportChecks`：`deleted_subtitles` 只在真有字幕没了时报、note 说为什么；删的不是字幕时不带。
- 反向验证（不合并的草稿 PR，CI）：见文末。
- 测试版复测：待 0.18.31 装上后按症状里的步骤重走（见文末）。

## 教训 / 防回归

- **一条规矩的理由只对一类东西成立时，别把它照搬给另一类。** 「裁切不删、留在原地」的理由是摆上去的东西拖过去就没了太吓人；字幕是说出来的话、
  又每拍从快照重放，两个前提都不在，规矩就该不一样。
- **动一条规矩之前，先把它旁边的地雷用自检踩一遍。** 交接里写的换源风险，先写自检再动手，当天撞出另一个更大的 bug，单独修掉。
