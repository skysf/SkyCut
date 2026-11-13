#!/usr/bin/env bash
# checks/docs-index-drift.sh 自测的场景（三）：INDEX.md 的顺序和重复、docs/bugfixes/ 下的文件、AGENTS.md 整份的大小。
#
# **不单独跑**：由 self-test.sh 用 `source` 装进来（见 scenarios-links.sh 开头）。最小副本里四份案例按规矩排是
# apple-case（01-09）、kiwi-case（03-01）、mango-case（01-05）、zebra-case（02-01）。
# 这一组只对新顺序有意义：--against 拿老守卫跑时跳过（老守卫要的是文件名从大到小）。
# 标着 D6R-05 的是 Codex 2026-11-13 审查时实跑出来的输入。
# shellcheck disable=SC2016,SC2154

GROUP="order"
E_LEMON='- [2026-04-01 柠檬案例](2026-04-01-lemon-case.md) — 教训五。'
new_case() { printf '# case\n' > "docs/bugfixes/$1.md"; }
# s_add <文件名（不带 .md）> <after|before> <锚> <条目>：新写一份案例，把它的条目加到那一行后面 / 前面。
s_add() { new_case "$1" && edit "$2" "${B}" "$3" "$4"; }
s_rewrite() {  # 整份条目换一个顺序：参数是模板以外的条目，按给的顺序写
  local head
  head="$(sed -n '1,/TEMPLATE.md/p' "${B}")"
  { printf '%s\n' "${head}"; printf '%s\n' "$@"; } > "${B}"
}

# ── 顺序：按文件名里日期后面那一段，不看日期 ──
scenario green - "新案例按规矩插（lemon 在 kiwi 和 mango 之间）" s_add 2026-04-01-lemon-case after "${E_KIWI}" "${E_LEMON}"
RUN_LOCALE=zh_CN.UTF-8 scenario green - "按规矩插，在 zh_CN.UTF-8 下跑" s_add 2026-04-01-lemon-case after "${E_KIWI}" "${E_LEMON}"
scenario red order "新案例照老习惯加在模板下面" s_add 2026-04-01-lemon-case after "TEMPLATE.md" "${E_LEMON}"
scenario red order "新案例照上一版规矩插（文件名从大到小：日期最新的在最上面）" s_add 2026-04-01-lemon-case before "${E_APPLE}" "${E_LEMON}"
scenario red order "新案例加在最后" s_add 2026-04-01-lemon-case after "${E_ZEBRA}" "${E_LEMON}"
s_swap() { edit drop "${B}" "${E_MANGO}" && edit before "${B}" "${E_KIWI}" "${E_MANGO}"; }
scenario red order "两条对调" s_swap
scenario red order "整份换回文件名从大到小（上一版的顺序）" s_rewrite "${E_KIWI}" "${E_ZEBRA}" "${E_APPLE}" "${E_MANGO}"
scenario red order "整份按日期从旧到新" s_rewrite "${E_MANGO}" "${E_APPLE}" "${E_ZEBRA}" "${E_KIWI}"
scenario red order_last "最该排在最后的一条放在最上面" s_rewrite "${E_ZEBRA}" "${E_APPLE}" "${E_KIWI}" "${E_MANGO}"
s_template_down() { edit drop "${B}" "TEMPLATE.md" && edit after "${B}" "${E_APPLE}" '- [Bugfix 模板](TEMPLATE.md) — 新案例必须使用的结构。'; }
scenario red template_first "模板那一行挪到案例中间" s_template_down
# 键带着 .md、按字节比：「-」(0x2D) 排在「.」(0x2E) 前面，大写字母排在小写前面。
E_APPLE_SHORT='- [2026-04-01 苹果](2026-04-01-apple.md) — 教训。'
scenario green - "apple.md 排在 apple-case.md 后面（按字节：- 在 . 前面）" s_add 2026-04-01-apple after "${E_APPLE}" "${E_APPLE_SHORT}"
scenario red order "apple.md 排在 apple-case.md 前面" s_add 2026-04-01-apple before "${E_APPLE}" "${E_APPLE_SHORT}"
E_UPPER='- [2026-04-01 大写](2026-04-01-Zulu-case.md) — 教训。'
scenario green - "大写开头的排在小写前面（按字节，不按字典）" s_add 2026-04-01-Zulu-case before "${E_APPLE}" "${E_UPPER}"
RUN_LOCALE=en_US.UTF-8 scenario green - "大写在前，在 en_US.UTF-8 下跑也一样" s_add 2026-04-01-Zulu-case before "${E_APPLE}" "${E_UPPER}"
RUN_LOCALE=en_US.UTF-8 scenario red order "大写开头的排在最后，在 en_US.UTF-8 下跑也红" s_add 2026-04-01-Zulu-case after "${E_ZEBRA}" "${E_UPPER}"
E_APPLE_LATER='- [2026-05-01 苹果案例又一次](2026-05-01-apple-case.md) — 教训。'
scenario green - "日期后面那一段相同：按日期，旧的在前" s_add 2026-05-01-apple-case after "${E_APPLE}" "${E_APPLE_LATER}"
scenario red order "日期后面那一段相同：新的排在了旧的前面" s_add 2026-05-01-apple-case before "${E_APPLE}" "${E_APPLE_LATER}"

# ── 重复：同一份案例只列一次，换一种路径写法也不行（D6R-05）──
scenario red dup "同一份紧挨着又列一次、改过一句话" edit after "${B}" "${E_MANGO}" '- [2026-01-05 芒果案例（改过）](2026-01-05-mango-case.md) — 改过的一句。'
scenario red dup "同一份隔着别的条目又列一次" edit after "${B}" "${E_ZEBRA}" "${E_MANGO}"
scenario red target "同一份用 ./ 又列一次（D6R-05）" edit after "${B}" "${E_ZEBRA}" '- [2026-02-01 斑马案例](./2026-02-01-zebra-case.md) — 又列一次。'
scenario red case_entry "同一份用 ../bugfixes/ 又列一次" edit after "${B}" "${E_ZEBRA}" '- [2026-02-01 斑马案例](../bugfixes/2026-02-01-zebra-case.md) — 又列一次。'
scenario red unindexed_case "唯一的一条写成 ./（不算列了）" edit swap "${B}" "${E_ZEBRA}" '- [2026-02-01 斑马案例](./2026-02-01-zebra-case.md) — 教训四。'
scenario red table "案例在末尾的表格里又列一次（D6R-05）" edit after "${B}" "${E_ZEBRA}" '
| 案例 | 教训 |
| --- | --- |
| [2026-02-01 斑马案例](2026-02-01-zebra-case.md) | 又列一次。 |'
scenario red table "模板在末尾的表格里又列一次（D6R-05）" edit after "${B}" "${E_ZEBRA}" '
| 案例 | 教训 |
| --- | --- |
| [Bugfix 模板](TEMPLATE.md) | 又列一次。 |'
s_all_table() {  # D6R-05 的最小副本：全部条目改成倒序的表格
  local head
  head="$(sed -n '1,/怎么排见/p' "${B}")"
  printf '%s\n' "${head}" '' '| 案例 | 教训 |' '| --- | --- |' \
    '| [2026-02-01 斑马案例](2026-02-01-zebra-case.md) | 四。 |' '| [2026-01-05 芒果案例](2026-01-05-mango-case.md) | 三。 |' \
    '| [2026-03-01 奇异果案例](2026-03-01-kiwi-case.md) | 二。 |' '| [2026-01-09 苹果案例](2026-01-09-apple-case.md) | 一。 |' \
    '| [Bugfix 模板](TEMPLATE.md) | 结构。 |' > "${B}"
}
scenario red table "全部条目改成倒序的表格（D6R-05）" s_all_table

# ── INDEX.md 的条目只列同文件夹的案例 ──
scenario red case_entry "条目带 #锚点" edit swap "${B}" "${E_ZEBRA}" '- [2026-02-01 斑马案例](2026-02-01-zebra-case.md#根因) — 教训四。'
scenario red case_entry "条目指向别的文件夹" edit after "${B}" "${E_ZEBRA}" '- [2026-01-01 Alpha](../architecture/alpha.md) — 不是案例。'
scenario red entry_date "条目的文字不带日期" edit swap "${B}" "${E_ZEBRA}" '- [斑马案例](2026-02-01-zebra-case.md) — 教训四。'
scenario red entry_date "条目文字里的日期和文件名对不上" edit swap "${B}" "${E_ZEBRA}" '- [2026-02-02 斑马案例](2026-02-01-zebra-case.md) — 教训四。'
scenario red intro_case "案例只在说明里提了一句、没当条目" edit after "${B}" "怎么排见" '另见[芒果](2026-01-05-mango-case.md)。'
s_case_gone() { rm docs/bugfixes/2026-02-01-zebra-case.md; }
scenario red dead "条目指向的案例文件没了" s_case_gone
scenario red marker "INDEX.md 里 + 开头的条目（F4）" edit swap "${B}" "${E_ZEBRA}" '+ [2026-02-01 斑马案例](2026-02-01-zebra-case.md) — 教训四。'
scenario red after "INDEX.md 的条目后面接一段话" edit after "${B}" "${E_ZEBRA}" '
教训四的一大段摘要。'

# ── docs/bugfixes/ 下只放带日期的案例 ──
s_sub_case() { mkdir docs/bugfixes/sub && printf '# case\n' > docs/bugfixes/sub/2026-04-01-lemon-case.md; }
scenario red case_name "案例放进子文件夹" s_sub_case
scenario red case_name "案例的文件名不带日期" new_case notes
scenario red case_name "案例的日期写得不全" new_case 2026-4-1-lemon-case

# ── AGENTS.md 整份的大小：只数 docs/bugfixes/ 以外的普通文件（D6R-08）──
DOCS_IN_BASE=4   # alpha、beta、gamma、some-plan
s_size() { pad_agents "$1"; }
scenario green - "AGENTS.md 正好等于上限" s_size "$(size_limit "${DOCS_IN_BASE}")"
scenario red size "AGENTS.md 比上限多 1 字节" s_size $(($(size_limit "${DOCS_IN_BASE}") + 1))
s_size_new_doc() {  # 多一份进了索引的文档，上限多 SIZE_PER_DOC_BYTES
  printf '# delta\n' > docs/architecture/delta.md \
    && edit after "${A}" "${E_BETA}" '- [Delta](docs/architecture/delta.md) — 管 delta。' && pad_agents "$1"
}
scenario green - "多一份文档，上限跟着多 ${SIZE_PER_DOC_BYTES}" s_size_new_doc "$(size_limit $((DOCS_IN_BASE + 1)))"
scenario red size "多一份文档，比新上限多 1 字节" s_size_new_doc $(($(size_limit $((DOCS_IN_BASE + 1))) + 1))
s_size_new_case() { new_case 2026-04-01-lemon-case && edit after "${B}" "${E_KIWI}" "${E_LEMON}" && pad_agents "$1"; }
scenario red size "多一份案例，上限不跟着涨" s_size_new_case $(($(size_limit "${DOCS_IN_BASE}") + 1))
s_size_dir() { mkdir docs/fake.md && pad_agents "$1"; }
scenario green - "叫 fake.md 的目录：不算文档、不红，正好等于上限（D6R-08）" s_size_dir "$(size_limit "${DOCS_IN_BASE}")"
scenario red size "叫 fake.md 的目录不让上限涨" s_size_dir $(($(size_limit "${DOCS_IN_BASE}") + 1))
