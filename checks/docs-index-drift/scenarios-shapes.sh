#!/usr/bin/env bash
# checks/docs-index-drift.sh 自测的场景（二）：条目和小节的形状 —— 索引小节里一条索引只有一种写法
# （AGENTS.md 另许成形的表格），摘要不能换一种写法塞回来；「Bug 修复案例索引」一节只留指路的话。
#
# **不单独跑**：由 self-test.sh 用 `source` 装进来（见 scenarios-links.sh 开头）。
# 标着 D6R-06 的是 Codex 2026-11-13 审查时实跑出来的输入；标着 F4 的是同一天上一轮复审绕过去的写法。
# shellcheck disable=SC2016,SC2154

GROUP="shapes"
ARCH_INTRO="每份一行：链接 + 这份文档管什么。"
POINTER_LINE="- 修 bug 之前先在那份索引里搜一遍。"
MANGO="docs/bugfixes/2026-01-05-mango-case.md"
LONG="$(fill_to 390 '摘要')"

# ── 每行的字节数、说明的行数 ──
s_entry_bytes() { edit swap "${A}" "${E_BETA}" "$(fill_to "$1" '- [Beta](docs/architecture/beta.md) — ')"; }
scenario green - "AGENTS.md 的条目正好 ${ENTRY_MAX_BYTES} 字节（含汉字）" s_entry_bytes "${ENTRY_MAX_BYTES}"
scenario red long "AGENTS.md 的条目多 1 字节" s_entry_bytes $((ENTRY_MAX_BYTES + 1))
RUN_LOCALE=en_US.UTF-8 scenario green - "正好 ${ENTRY_MAX_BYTES} 字节，在 en_US.UTF-8 下跑（数的是字节不是字）" s_entry_bytes "${ENTRY_MAX_BYTES}"
RUN_LOCALE=en_US.UTF-8 scenario red long "多 1 字节，在 en_US.UTF-8 下跑" s_entry_bytes $((ENTRY_MAX_BYTES + 1))
s_case_bytes() { edit swap "${B}" "${E_MANGO}" "$(fill_to "$1" '- [2026-01-05 芒果案例](2026-01-05-mango-case.md) — ')"; }
scenario green - "INDEX.md 的条目正好 ${ENTRY_MAX_BYTES} 字节" s_case_bytes "${ENTRY_MAX_BYTES}"
scenario red long "INDEX.md 的条目多 1 字节" s_case_bytes $((ENTRY_MAX_BYTES + 1))
s_intro() {  # 架构索引原来 1 行说明，再加 $1 行
  local i=0 lines=""
  while [ "${i}" -lt "$1" ]; do lines="${lines}说明第 ${i} 行。
"; i=$((i + 1)); done
  edit after "${A}" "${ARCH_INTRO}" "${lines%
}"
}
scenario green - "说明正好 ${INTRO_MAX_LINES} 行" s_intro $((INTRO_MAX_LINES - 1))
scenario red intro "说明多 1 行" s_intro "${INTRO_MAX_LINES}"
scenario red long "说明里一行 $((ENTRY_MAX_BYTES + 1)) 字节" edit swap "${A}" "${ARCH_INTRO}" "$(fill_to $((ENTRY_MAX_BYTES + 1)) '说明')"
scenario green - "不设上限的小节里的表格行 1,800 字节（必读表有意只受整份上限）" edit after "${A}" "| alpha 那一块" "$(fill_to 1798 '| 很长的一行 | ') |"
s_new_section() { printf '\n## 新加的小节\n\n%s\n' "$(fill_to $((ENTRY_MAX_BYTES + 1)) '新小节里的摘要')" >> "${A}"; }
scenario red long "新加的「## 」小节照索引小节管" s_new_section

# ── 摘要换一种写法塞回来（F4、D6R-06）──
scenario red marker "+ 开头的列表条目（F4）" edit swap "${A}" "${E_BETA}" '+ [Beta](docs/architecture/beta.md) — 管 beta。'
scenario red marker "* 开头的列表条目" edit swap "${A}" "${E_BETA}" '* [Beta](docs/architecture/beta.md) — 管 beta。'
scenario red marker "1. 开头的列表条目" edit swap "${A}" "${E_BETA}" '1. [Beta](docs/architecture/beta.md) — 管 beta。'
scenario red marker "不以链接开头的「- 」" edit after "${A}" "${E_BETA}" '- 见 beta 的摘要。'
scenario red indent "缩进的「- [」条目（F4）" edit swap "${A}" "${E_BETA}" '  - [Beta](docs/architecture/beta.md) — 管 beta。'
scenario red indent "条目后面接缩进的续段（F4）" edit after "${A}" "${E_BETA}" "  ${LONG}
  ${LONG}
  ${LONG}"
scenario red after "条目后面接不缩进的续行" edit after "${A}" "${E_BETA}" "${LONG}"
scenario red after "条目中间隔着空行夹一段话" edit after "${A}" "${E_BETA}" "
${LONG}
"
s_pipe_paragraph() {
  edit swap "${A}" "${E_ALPHA}" "| ${E_ALPHA}
$(fill_to 380 '| ')
$(fill_to 380 '| ')
$(fill_to 380 '| ')"
}
scenario red table_head "行首一个竖线的多行摘要，没有表头和分隔行（D6R-06）" s_pipe_paragraph
scenario red table_head "条目后面空一行接竖线开头的摘要" edit after "${A}" "${E_BETA}" "
| ${LONG}
| ${LONG}
"
scenario red quote "索引小节开头用 > 引用写条目（D6R-06）" edit after "${A}" "${ARCH_INTRO}" '> [Beta](docs/architecture/beta.md) — 管 beta 的一大段摘要。'
scenario red html "索引小节开头用 HTML 写条目（D6R-06）" edit after "${A}" "${ARCH_INTRO}" '<p>[Beta](docs/architecture/beta.md) — 管 beta 的一大段摘要。</p>'
scenario red bare_entry "说明里以链接开头的一行（少了「- 」的条目）" edit after "${A}" "${ARCH_INTRO}" '[Beta](docs/architecture/beta.md) — 管 beta 的一大段摘要。'
scenario red rule "条目前面的说明下面划一道（把说明变成标题）" edit after "${A}" "${ARCH_INTRO}" '---'
scenario red rule "不带竖线开头的表格（a | b 加 --- | ---）" edit after "${A}" "${ARCH_INTRO}" '文档 | 摘要
--- | ---
x | 很长的摘要'
scenario red bracket "任务框冒充条目" edit after "${A}" "${E_BETA}" '- [x] beta 的摘要第一段。'

# ── 条目只有一种写法 ──
scenario red entry_form "条目没有那句话" edit swap "${A}" "${E_BETA}" '- [Beta](docs/architecture/beta.md)'
scenario red entry_form "破折号写成连字符" edit swap "${A}" "${E_BETA}" '- [Beta](docs/architecture/beta.md) - 管 beta。'
scenario red entry_form "破折号后面是空的" edit swap "${A}" "${E_BETA}" '- [Beta](docs/architecture/beta.md) — '
scenario red entry_links "一条里两个链接" edit swap "${A}" "${E_BETA}" '- [Beta](docs/architecture/beta.md) — 管 beta，另见 [Alpha](docs/architecture/alpha.md)。'
scenario red dup_agents "同一份文档在同一节里列两次" edit after "${A}" "${E_BETA}" '- [Beta 又一次](docs/architecture/beta.md) — 摘要的第二段。'
scenario red dup_agents "同一份文档在另一节里又列一次" edit after "${A}" "- [README.md](README.md)" '- [Beta 又一次](docs/architecture/beta.md#别的锚点) — 摘要的第二段。'

# ── AGENTS.md 索引小节里的表格：表头 + 分隔行 + 每行正好一个链接 ──
# s_table <表头> <分隔行> <alpha 那一行> [更多行…]：把架构索引的三条换成一张表。
s_table() {
  local body="$1
$2
$3"
  shift 3
  while [ $# -gt 0 ]; do body="${body}
$1"; shift; done
  edit drop "${A}" "${E_ALPHA}" && edit drop "${A}" "- [Gamma](docs/build/gamma.md) — 管 gamma。" && edit swap "${A}" "${E_BETA}" "${body}"
}
T_HEAD='| 文档 | 管什么 |'
T_SEP='| --- | --- |'
T_ALPHA='| [Alpha](docs/architecture/alpha.md) | 管 alpha。 |'
T_BETA='| [Beta](docs/architecture/beta.md) | 管 beta。 |'
T_GAMMA='| [Gamma](docs/build/gamma.md) | 管 `a` 和 `b`。 |'
scenario green - "成形的表格：表头、分隔行、每行一个链接" s_table "${T_HEAD}" "${T_SEP}" "${T_ALPHA}" "${T_BETA}" "${T_GAMMA}"
scenario green - "分隔行带对齐的冒号" s_table "${T_HEAD}" '| :--- | ---: |' "${T_ALPHA}" "${T_BETA}" "${T_GAMMA}"
scenario red table_head "表头下面不是分隔行" s_table "${T_HEAD}" "${T_ALPHA}" "${T_BETA}" "${T_GAMMA}"
scenario red table_head "分隔行的列数和表头对不上" s_table "${T_HEAD}" '| --- |' "${T_ALPHA}" "${T_BETA}" "${T_GAMMA}"
scenario red table_head "表头行尾没有竖线" s_table '| 文档 | 管什么' "${T_SEP}" "${T_ALPHA}" "${T_BETA}" "${T_GAMMA}"
scenario red row_links "表格里没有链接的行（上一行摘要的续行）" s_table "${T_HEAD}" "${T_SEP}" "${T_ALPHA}" "| | ${LONG} |" "${T_BETA}" "${T_GAMMA}"
scenario red row_links "表格的一行两个链接" s_table "${T_HEAD}" "${T_SEP}" "${T_ALPHA}" '| [Beta](docs/architecture/beta.md) | 见 [Gamma](docs/build/gamma.md) |'
scenario red table_row "表格行的列数和表头对不上" s_table "${T_HEAD}" "${T_SEP}" "${T_ALPHA}" '| [Beta](docs/architecture/beta.md) | 管 beta | 多一列 |' "${T_GAMMA}"
scenario red table_row "表格行的行内代码里有竖线" s_table "${T_HEAD}" "${T_SEP}" "${T_ALPHA}" '| [Beta](docs/architecture/beta.md) | 管 `a | b`。 |' "${T_GAMMA}"
scenario red dup_agents "表格里同一份文档列两次（D6R-05：表格也查重复）" s_table "${T_HEAD}" "${T_SEP}" "${T_ALPHA}" "${T_BETA}" "${T_BETA}" "${T_GAMMA}"
scenario red long "表格行多 1 字节" s_table "${T_HEAD}" "${T_SEP}" "${T_ALPHA}" "${T_GAMMA}" "$(fill_to $((ENTRY_MAX_BYTES - 1)) '| [Beta](docs/architecture/beta.md) | ') |"
scenario green - "表格行正好 ${ENTRY_MAX_BYTES} 字节" s_table "${T_HEAD}" "${T_SEP}" "${T_ALPHA}" "${T_GAMMA}" "$(fill_to $((ENTRY_MAX_BYTES - 2)) '| [Beta](docs/architecture/beta.md) | ') |"
scenario red after "表格后面不空行就接一段话" s_table "${T_HEAD}" "${T_SEP}" "${T_ALPHA}" "${T_BETA}" "${T_GAMMA}" "${LONG}"
s_table_glued() { edit after "${A}" "${E_BETA}" "${T_HEAD}
${T_SEP}
| [Readme](README.md) | 紧跟在条目后面的表格。 |"; }
scenario red glued "表头紧跟在一条「- [」索引后面（F4）" s_table_glued
scenario red table "INDEX.md 里写表格（D6R-05：那里是纯列表）" edit after "${B}" "${E_ZEBRA}" "
${T_HEAD}
${T_SEP}
| [2026-02-01 斑马案例](2026-02-01-zebra-case.md) | 又列一次。 |"

# ── 「Bug 修复案例索引」一节：只留指路的话，案例的条目只进 INDEX.md ──
scenario red stray_case "指路小节里用 > 引用写案例条目（D6R-06）" edit after "${A}" "${POINTER_LINE}" "> [芒果案例](${MANGO})"
scenario red stray_case "指路小节里「- [」案例条目" edit after "${A}" "${POINTER_LINE}" "- [2026-01-05 芒果案例](${MANGO}) — 教训三。"
scenario red stray_case "指路小节里「+ [」案例条目（F4）" edit after "${A}" "${POINTER_LINE}" "+ [2026-01-05 芒果案例](${MANGO}) — 教训三。"
scenario red stray_case "指路小节的一句话里链案例" edit swap "${A}" "${POINTER_LINE}" "- 修 bug 之前先读[芒果案例](${MANGO})。"
scenario red stray_case "案例条目写进别的索引小节" edit after "${A}" "- [README.md](README.md)" "- [2026-01-05 芒果案例](${MANGO}) — 教训三。"
scenario red stray_case "索引小节的说明里链案例" edit swap "${A}" "${ARCH_INTRO}" "每份一行，例如[芒果案例](${MANGO})。"
scenario red pointer_shape "指路小节里写表格" edit after "${A}" "${POINTER_LINE}" "
${T_HEAD}
${T_SEP}
| [Readme](README.md) | 表格。 |"
scenario red pointer_shape "指路小节里加小标题" edit after "${A}" "${POINTER_LINE}" '
### 最近的案例'
scenario red pointer_shape "指路小节里缩进的续行" edit after "${A}" "${POINTER_LINE}" '  续行里的摘要。'
scenario red intro "指路的话加到 $((INTRO_MAX_LINES + 1)) 行" edit after "${A}" "${POINTER_LINE}" '- 第四行。
- 第五行。
- 第六行。'

# ── 索引条目挪进不设单条上限的小节（那里只受整份上限）──
s_move_entry() { edit drop "${A}" "${E_BETA}" && edit after "${A}" "- 构建与打包" "$1"; }
scenario red entry_in_free "索引条目原样挪进不设上限的小节" s_move_entry "- [Beta](docs/architecture/beta.md) — ${LONG}${LONG}"
scenario red entry_in_free "挪进去、换成编号列表" s_move_entry "1. [Beta](docs/architecture/beta.md)：${LONG}${LONG}"
scenario red entry_in_free "挪进去、写成嵌套的列表项" s_move_entry "  - [Beta](docs/architecture/beta.md)：${LONG}${LONG}"
s_swallow() {  # 把不设上限的小节的标题挪到架构索引的条目上面：名单里每个标题都还正好出现一次
  edit drop "${A}" "## 构建与检查入口" && edit before "${A}" "${E_ALPHA}" '## 构建与检查入口
'
}
scenario red entry_in_free "把不设上限的小节的标题挪到索引条目上面（条目被它收走）" s_swallow
scenario green - "不设上限的小节里，链接写在句子中间的列表项" edit after "${A}" "- 构建与打包" '- 另见 [Beta](docs/architecture/beta.md)（只能这样做）。'

# ── 小节的名单 ──
scenario red free_missing "改了不设上限的小节的标题" edit swap "${A}" "## 按修改范围选必读文档" '## 必读文档'
scenario red free_missing "不设上限的小节的标题出现两次" edit before "${A}" "## 规划与实施报告索引" '## 构建与检查入口
'
scenario red pointer_missing "改了指路小节的标题" edit swap "${A}" "## Bug 修复案例索引" '## 案例索引'
s_drop_heading() { edit drop "${A}" "## 架构与长期约束索引" && edit drop "${A}" "${ARCH_INTRO}"; }
scenario red index_missing "去掉索引小节的标题（条目并进上一节）" s_drop_heading
