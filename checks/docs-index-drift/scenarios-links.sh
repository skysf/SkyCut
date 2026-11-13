#!/usr/bin/env bash
# checks/docs-index-drift.sh 自测的场景（一）：链接怎么认 —— 两份索引里只有「[字](相对路径.md)」算链接，
# 别的写法（看着像索引其实点不开的、守卫查不了死链的）一律红；docs/ 下的每一份都要有这样一个链接。
#
# **不单独跑**：由 self-test.sh 用 `source` 装进来，用它的 scenario / edit / fill_to 和 A（AGENTS.md）、B（INDEX.md）、
# E_ALPHA / E_BETA …（最小副本里的那几行）。一行 scenario 一个场景：该绿还是该红、红在哪个代号上、名字、怎么改副本。
# 标着 D6R-04 / 08 的是 Codex 2026-11-13 审查时实跑出来的输入（改之前的守卫全都退出 0 或报错了对象）；
# 标着 D6R-12 / 14 的是同一天收口核查时又跑出来的（白名单那一版照样退出 0）。
# shellcheck disable=SC2016,SC2154  # 单引号里的反引号和 $ 是要原样写进副本的字；A、B、E_* 在 self-test.sh 里

GROUP="links"
RULE="规则二"   # 不设上限的小节「唯一入口约定」里的一行，往它后面加东西
hide_beta() { edit drop "${A}" "${E_BETA}" && edit after "${A}" "${RULE}" "$1"; }   # 把 beta 唯一的索引换成别的写法
new_doc() { printf '# x\n' > "$1"; }

scenario green - "基线：最小副本原样" keep
RUN_LOCALE=en_US.UTF-8 scenario green - "基线，在 en_US.UTF-8 下跑" keep

# ── 死链藏在守卫不认的写法里（D6R-04）──
scenario red dead "带 #锚点 的死链（D6R-04）" edit after "${A}" "${RULE}" '- 见 [broken](docs/architecture/missing.md#topic)。'
scenario red bracket "引用式链接和它的定义（D6R-04）" edit after "${A}" "${RULE}" '- 见 [broken][missing]。
[missing]: docs/architecture/missing.md'
scenario red bracket "拿引用的定义当注释藏路径（[//]: # (…)）" edit after "${A}" "${RULE}" '
[//]: # (docs/architecture/beta.md)'
scenario red bracket "只有引用的定义一行" edit after "${A}" "${RULE}" '
[missing]: docs/architecture/missing.md'
scenario red html "a 标签里的死链（D6R-04）" edit after "${A}" "${RULE}" '- 见 <a href="docs/architecture/missing.md">broken</a>。'
scenario red html "自动链接 <https://…>" edit after "${A}" "${RULE}" '- 见 <https://example.com/a.md>。'
scenario red dead "普通的死链" edit after "${A}" "${RULE}" '- 见 [gone](docs/architecture/missing.md)。'
scenario red dead "INDEX.md 的说明里的死链" edit after "${B}" "怎么排见" '另见[没有的](../architecture/missing.md)。'
s_link_to_dir() { mkdir docs/fake.md && edit after "${A}" "${RULE}" '- 见 [目录](docs/fake.md)。'; }
scenario red dead "链接指向一个叫 fake.md 的目录" s_link_to_dir
scenario red dead "路径大小写不对（Mac 的文件系统不分大小写，守卫要分）" edit swap "${A}" "${E_BETA}" '- [Beta](docs/Architecture/beta.md) — 管 beta。'

# ── 唯一的索引被藏起来：看着还在，其实点不开（D6R-04）──
scenario red html "唯一的索引整行包进 HTML 注释（D6R-04）" edit swap "${A}" "${E_BETA}" "<!-- ${E_BETA} -->"
scenario red html "唯一的索引包进跨行的 HTML 注释" edit swap "${A}" "${E_BETA}" "<!--
${E_BETA}
-->"
scenario red html "唯一的索引包进 details 标签" hide_beta '<details>[Beta](docs/architecture/beta.md)</details>'
scenario red fence "唯一的索引只留在代码围栏里（D6R-04）" edit swap "${A}" "${E_BETA}" '```
'"${E_BETA}"'
```'
scenario red fence "唯一的索引挪进不设上限的小节的代码围栏" hide_beta '
```
[Beta](docs/architecture/beta.md)
```'
scenario red fence "波浪线围栏" hide_beta '
~~~
[Beta](docs/architecture/beta.md)
~~~'
scenario red fence "两对反引号的行内代码里藏链接" hide_beta '- 见 ``[Beta](docs/architecture/beta.md)``。'
# 一份新文档唯一的索引放进套在引用 / 列表里的波浪线围栏：围栏只认行首的时候守卫退出 0，那个路径还算索引（D6R-12）
s_probe() { new_doc docs/architecture/probe.md && edit after "${A}" "两份索引是全的" "$1"; }
scenario red fence "唯一的索引在引用里的波浪线围栏里（D6R-12）" s_probe '
> ~~~
> [Probe](docs/architecture/probe.md)
> ~~~'
scenario red fence "唯一的索引在列表项里的波浪线围栏里、围栏不闭合（D6R-12）" s_probe '- ~~~
  [Probe](docs/architecture/probe.md)'
scenario green - "对照：同一个路径写成普通的链接（上面两个红在围栏上）" s_probe '- 见 [Probe](docs/architecture/probe.md)。'
scenario red unindexed "唯一的索引写成行内代码" hide_beta '- 见 `[Beta](docs/architecture/beta.md)`。'
scenario red unindexed "唯一的索引只剩括号里的路径（老正则当它是索引）" hide_beta '- beta 的文档 (docs/architecture/beta.md) 在这里。'
scenario red codeblock "唯一的索引挪进缩进的代码块（空行后面缩进四格）" hide_beta '
    [Beta](docs/architecture/beta.md)'
scenario red codeblock "缩进的行接在普通段落后面" edit after "${A}" "这里只有两类内容" '  [Alpha](docs/architecture/alpha.md)'
scenario red codeblock "缩进的行接在标题后面" edit after "${A}" "## 开始任务前" '    [Alpha](docs/architecture/alpha.md)'
scenario red backslash "反斜杠转义的方括号（看着像链接，其实不是）" hide_beta '- 见 \[Beta](docs/architecture/beta.md)。'
scenario red image "图片写法" hide_beta '- 见 ![Beta](docs/architecture/beta.md)。'
scenario red link_text "链接的文字是空的" hide_beta '- 见 [](docs/architecture/beta.md)。'
scenario red link_text "链接的文字只有空格" hide_beta '- 见 [ ](docs/architecture/beta.md)。'
scenario red invisible "链接的文字是零宽空格" hide_beta "- 见 [$(printf '\342\200\213')](docs/architecture/beta.md)。"
# 链接的文字正着认：至少一个字母、数字或汉字（行内代码里的也算），不再往黑名单里补空白（D6R-14）
scenario red link_text "链接的文字是细空格 U+2009（D6R-14）" hide_beta "- 见 [$(printf '\342\200\211')](docs/architecture/beta.md)。"
scenario red link_text "链接的文字是 EN 空格 U+2002（D6R-14）" hide_beta "- 见 [$(printf '\342\200\202')](docs/architecture/beta.md)。"
scenario red link_text "链接的文字是窄的不换行空格 U+202F（D6R-14）" hide_beta "- 见 [$(printf '\342\200\257')](docs/architecture/beta.md)。"
scenario red link_text "链接的文字是盲文空白 U+2800（D6R-14）" hide_beta "- 见 [$(printf '\342\240\200')](docs/architecture/beta.md)。"
scenario red link_text "链接的文字是只有细空格的行内代码" hide_beta "- 见 [\`$(printf '\342\200\211')\`](docs/architecture/beta.md)。"
scenario red link_text "链接的文字只有标点" hide_beta '- 见 [——](docs/architecture/beta.md)。'
scenario green - "链接的文字只有汉字" hide_beta '- 见 [贝塔](docs/architecture/beta.md)。'
scenario green - "链接的文字只有行内代码" hide_beta '- 见 [`Beta`](docs/architecture/beta.md)。'
scenario green - "链接的文字里字和字之间夹着细空格" hide_beta "- 见 [Beta$(printf '\342\200\211')文档](docs/architecture/beta.md)。"
scenario red invisible "不换行空格" edit after "${A}" "${RULE}" "- 规则三：$(printf '\302\240')看不见的空格。"
scenario red invisible "全角空格" edit after "${A}" "${RULE}" "- 规则三：$(printf '\343\200\200')全角空格。"
scenario red invisible "文字方向控制符（U+202E）" edit after "${A}" "${RULE}" "- 规则三：$(printf '\342\200\256')反着写。"
scenario red blank_code "链接的文字是一段空的行内代码" hide_beta '- 见 [` `](docs/architecture/beta.md)。'
scenario red entity "链接的文字是 HTML 实体写的零宽空格" hide_beta '- 见 [&#8203;](docs/architecture/beta.md)。'
scenario red entity "HTML 实体写的不换行空格" edit after "${A}" "${RULE}" '- 规则三：&nbsp;。'
scenario red math "唯一的索引夹在两个 \$\$ 之间（当公式渲染）" hide_beta '
$$
[Beta](docs/architecture/beta.md)
$$'
scenario red codeblock "列表记号后面空五格（内容成了代码块）" hide_beta '-     [Beta](docs/architecture/beta.md)'
scenario red codeblock "列表项、空行、再缩进（列表项里的代码块）" hide_beta '- 规则三

      [Beta](docs/architecture/beta.md)'
s_front_matter() { { printf '%s\n' '---' 'see: "[Beta](docs/architecture/beta.md)"' '---'; cat "${A}"; } > "${A}.fm" && mv "${A}.fm" "${A}" && edit drop "${A}" "${E_BETA}"; }
scenario red title "唯一的索引挪进文件开头的 front matter" s_front_matter
s_bom() { { printf '\357\273\277'; cat "${A}"; } > "${A}.bom" && mv "${A}.bom" "${A}"; }
scenario red invisible "文件开头加 BOM" s_bom
scenario red bracket "套在链接里的链接" hide_beta '- 见 [[a](docs/architecture/alpha.md)](docs/architecture/beta.md)。'

# ── 只认一种链接：别的写法说出来，不悄悄跳过 ──
scenario green - "唯一的索引带 #锚点、文件在（D6R-04：以前说它没索引）" edit swap "${A}" "${E_BETA}" '- [Beta](docs/architecture/beta.md#第一节) — 管 beta。'
scenario green - "链接的文字里有行内代码" edit after "${A}" "${RULE}" '- 见 [`AlphaThing` 的 `[x]`](docs/architecture/alpha.md)。'
scenario green - "不设上限的小节里标题带链接" edit after "${A}" "### Bug 修复、守卫与文档" '
### 另见 [Alpha](docs/architecture/alpha.md)
'
scenario red target "链接带标题" edit swap "${A}" "${E_BETA}" '- [Beta](docs/architecture/beta.md "标题") — 管 beta。'
scenario red target "链接带 ./" edit swap "${A}" "${E_BETA}" '- [Beta](./docs/architecture/beta.md) — 管 beta。'
scenario red target "链接以 / 开头" edit swap "${A}" "${E_BETA}" '- [Beta](/docs/architecture/beta.md) — 管 beta。'
scenario red target "路径中间有 ../" edit swap "${A}" "${E_BETA}" '- [Beta](docs/build/../architecture/beta.md) — 管 beta。'
scenario red target "路径里连着两个 /" edit swap "${A}" "${E_BETA}" '- [Beta](docs//architecture/beta.md) — 管 beta。'
scenario red target "链到网址" edit after "${A}" "${RULE}" '- 见 [站点](https://example.com/a.md)。'
scenario red target "链到不是 .md 的文件" edit after "${A}" "${RULE}" '- 见 [脚本](checks/docs-index-drift.sh)。'
scenario red target "锚点里有空格" edit swap "${A}" "${E_BETA}" '- [Beta](docs/architecture/beta.md#第 一节) — 管 beta。'
scenario red bracket "链接和括号之间有空格" edit swap "${A}" "${E_BETA}" '- [Beta] (docs/architecture/beta.md) — 管 beta。'
scenario red bracket "脚注" edit after "${A}" "${RULE}" '- 规则三[^1]。'
scenario red bracket "任务框" edit after "${A}" "${RULE}" '- [ ] 待办：把摘要写在这里。'
scenario red bracket "正文里的方括号" edit after "${A}" "${RULE}" '- 用法：run.sh [工程拷贝]。'
scenario red tick "反引号不成对" edit after "${A}" "${RULE}" '- 规则三：`没关上。'
scenario red ctrl "制表符" edit after "${A}" "${RULE}" "- 规则三：$(printf '\t')制表符。"
s_crlf() { LC_ALL=C awk '{ printf "%s\r\n", $0 }' "${A}" > "${A}.crlf" && mv "${A}.crlf" "${A}"; }
scenario red ctrl "整份 AGENTS.md 换成 CRLF 行尾" s_crlf
s_nul() { printf 'x\000y\n' >> "${B}"; }
scenario red nul "INDEX.md 里有 NUL 字节" s_nul
scenario red escape "AGENTS.md 里的链接指到仓库外面" edit after "${A}" "${RULE}" '- 见 [外面](../outside.md)。'
scenario red escape "INDEX.md 里的链接指到仓库外面" edit after "${B}" "怎么排见" '另见[外面](../../../outside.md)。'
scenario green - "INDEX.md 的说明链到根目录的文件" edit after "${B}" "怎么排见" '另见[介绍](../../README.md)。'

# ── docs/ 和根目录以外的链接：在不在照样查，大小写一字不差 ──
s_tools() { mkdir -p tools && new_doc tools/notes.md && edit after "${A}" "${RULE}" "- 见 [笔记]($1)。"; }
scenario green - "链到 docs/ 以外真实存在的文件" s_tools tools/notes.md
scenario red dead "链到 docs/ 以外、大小写不对" s_tools Tools/notes.md
scenario red dead "链到 docs/ 以外不存在的文件" s_tools tools/none.md

# ── 磁盘上的文档（D6R-04 的文件名、D6R-08 的目录）──
s_named() { new_doc "$1" && edit after "${A}" "${E_BETA}" "- [x]($2) — 名字不合规的文档。"; }
scenario red name "文件名带括号（D6R-04：不去支持这种链接，文件名先红）" s_named 'docs/a(b).md' 'docs/a(b).md'
scenario red name "文件名带空格、链接用尖括号（D6R-04）" s_named 'docs/a b.md' '<docs/a b.md>'
scenario red name "中文文件名" s_named 'docs/architecture/中文.md' 'docs/architecture/中文.md'
scenario green - "docs/ 下一个叫 fake.md 的目录不是文档（D6R-08：以前说它没索引）" mkdir docs/fake.md
s_dir_inner() { mkdir docs/fake.md && new_doc docs/fake.md/inner.md; }
scenario red unindexed "叫 fake.md 的目录里的文档照样要索引" s_dir_inner
s_symlink() { ln -s beta.md docs/architecture/alias.md && edit after "${A}" "${E_BETA}" '- [Alias](docs/architecture/alias.md) — 符号链接。'; }
scenario red symlink "符号链接当文档" s_symlink
scenario red ext "后缀写成 .MD 的文档（不进索引也不红的话就是漏网的）" new_doc docs/architecture/LOUD.MD
scenario red ext "后缀写成 .markdown 的文档" new_doc docs/architecture/notes.markdown

# ── 漏索引 ──
scenario red unindexed "新的架构文档没进 AGENTS.md" new_doc docs/architecture/delta.md
s_only_in_bug_index() { new_doc docs/architecture/delta.md && edit after "${B}" "怎么排见" '另见[Delta](../architecture/delta.md)。'; }
scenario red unindexed "新的架构文档只在 INDEX.md 里提了一句" s_only_in_bug_index
scenario red unindexed_case "新案例没进 INDEX.md" new_doc docs/bugfixes/2026-04-01-lemon-case.md
s_cut_index_links() {
  edit sub "${A}" '[Bug 修复案例索引](docs/bugfixes/INDEX.md)' 'Bug 修复案例索引' \
    && edit sub "${A}" '[docs/bugfixes/INDEX.md](docs/bugfixes/INDEX.md)' '`docs/bugfixes/INDEX.md`'
}
scenario red no_index_link "AGENTS.md 不再链到 INDEX.md" s_cut_index_links
scenario red missing "INDEX.md 没了" rm "${B}"
scenario red empty "INDEX.md 是空文件" cp /dev/null "${B}"
