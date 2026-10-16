# 2026-10-16 字幕默认单行 + 行数开关的测试版冒烟（0.18.37）

[PR #222](https://github.com/skysf/SrtFlow/pull/222)（main 51a0868）合并后出的测试版，真机过一遍用户当天定的规矩：
**字幕默认都是单行，除非用户在软件里调成两行、或者通过 AI 说要两行**（[生成的字幕长什么样](../architecture/subtitle-generation-style.md) 第四节）。

## 环境

- 测试版 0.18.37（`VERSION=0.18.37 scripts/build-app.sh && scripts/build-beta-app.sh`，签名证书 76d27565…、`codesign --verify --deep --strict` 过、
  三张文案表都带新字串、小程序能答 initialize），原地替换装进「应用程序」。
- 素材 L30.mp4（101 秒英文口播，拷在 scratchpad 里）；工程 smoke-lines 由 `new_project` 建在素材旁边的 `SrtFlow/Projects/`。
- 驱动：`scripts/gui-smoke/mcp-client/client.py`（[GUI 冒烟流程](../testing/gui-smoke-testing.md) 四之七），三张调用表分三段跑。

## 结果

| 步骤 | 结果 |
| --- | --- |
| `generate_subtitles max_lines=3` | 报错 `max_lines is how many lines one subtitle may take: 1 (default) or 2.`，没起任务 |
| `generate_subtitles`（不给 max_lines） | 59 条，全部单行；`get_subtitles` 回 `max_lines: 1` |
| `generate_subtitles max_lines=2` | 39 条，其中 19 条占两行；每条两行的 `box` 报 `lines: 2`、和文字的行数一致；没有三行的。折行点都在词组边界：「You now know the manual / way to make a movie」「can be done by a digital robot / while you sleep?」「What if I told you that everything / you just learned」（避开「that」收尾）、「we are going to move / from being directors to being engineers」（底重） |
| `undo` 一步 | 退回单行那 59 条，`max_lines` 仍是 2（行数的改动是前一步） |
| 再 `undo` 一步 | `max_lines` 回到 1 |
| 面板（用户亲手）：字幕列表表头的麦克风 → 「从音频生成」→「每条字幕的行数」拨到「2 行」→ 生成 | `get_subtitles` 回 `max_lines: 2`，39 条 / 19 条两行，和 AI 那一路一模一样；自动保存后工程文件里 `timeline.subtitleMaxLines = 2`，`formatVersion` 仍是 32 |

## 没验到的、另案的

- 面板上的下拉两套自动化都点不了（进程内驱动点 AppKit 控件会卡死，[四之六](../testing/gui-smoke-testing.md) 第 12 条；AX 自动化的 cmux 这台机器还没初始化完），所以那一步是用户点的，
  排版是用户看的（没报问题）。关掉再开工程行数还在没有单独试 —— 文件里已经写进去了、缺键 = 1 的读法有第 46 组钉着。
- 译文、导入的 SRT、手改变长的句子，渲染时放不下仍自动折行、不重切（[AI 接口](../architecture/ai-control-mcp.md) 第 36 条「不自动重新断句」），这次没碰。
