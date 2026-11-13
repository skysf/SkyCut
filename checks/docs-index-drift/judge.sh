#!/usr/bin/env bash
# checks/docs-index-drift.sh 的一节：拿两份索引里的链接对着磁盘上的文档核一遍。
#
# **不单独跑**：由 docs-index-drift.sh 用 `source` 装进来，只定义 JUDGE_AWK（带引号的 heredoc，正文只用 ASCII）。
#
# 管什么（链接都是 lines.sh 认出来的那一种，先把路径规范成从仓库根目录算起的写法再比）：
#   · 死链：链接指向的不是一份真实存在的普通文件（大小写也要一字不差）；指到仓库外面去的也红。
#   · 漏索引：docs/bugfixes/ 下的每一份（INDEX.md 自己除外）要在 INDEX.md 里**当条目**列着；docs/ 下其余每一份、
#     连同 INDEX.md，要能从 AGENTS.md 的链接找到。
#   · 案例的条目只进 INDEX.md：AGENTS.md 的索引小节和「Bug 修复案例索引」一节里，任何指向 docs/bugfixes/ 下的链接
#     都红（INDEX.md 和 TEMPLATE.md 除外），不管前面是什么记号；INDEX.md 的说明里也不许链案例（只当条目列，才进顺序和重复检查）。
#   · 重复：同一份文档在 INDEX.md 里、在 AGENTS.md 的索引小节里各只许当一次条目。
#   · 顺序：INDEX.md 的模板那一行在最上面，其余按文件名去掉开头「YYYY-MM-DD-」之后的那一段从小到大（字节序），
#     这一段相同的再按日期。放错了说出是哪一条、该排在谁上面。
# 不管什么：链接和条目的写法（lines.sh）。
#
# 输入（标准输入，字段用 \037 隔开；K 行要排在最前面）：
#   K  路径                                       磁盘上一份普通的 .md 文件（docs/ 下的全部 + 仓库根目录的）
#   A|B  行号  free|index|pointer  entry|text  路径    lines.sh 认出来的链接（A = AGENTS.md，B = INDEX.md）
#   别的行（lines.sh 的 E 行）不看。
# 输入变量：bug_dir（docs/bugfixes）。
# 输出：
#   E  A|B  行号  代号  值 1  值 2  值 3            一个问题（代号的意思见 messages.sh；没有行号的写 0）
#   X  A|B  行号  规范后的路径  链接里写的路径        指向 docs/ 和根目录以外的链接：在不在交给主文件逐段核对
#   J  文档数  AGENTS.md 的链接数  INDEX.md 的链接数   最后一行：主文件靠它认「真的核过了」（扫空 = 假绿）

read -r -d '' JUDGE_AWK <<'AWK' || true
function out(tg, n, code, d1, d2, d3) {
  print "E" S tg S n S code S (d1 == "" ? "-" : d1) S (d2 == "" ? "-" : d2) S (d3 == "" ? "-" : d3)
}
function resolve(base, p,   n, parts, i, m, stack, r) {
  m = 0
  if (base != "") m = split(base, stack, "/")
  n = split(p, parts, "/")
  for (i = 1; i <= n; i++) {
    if (parts[i] == "..") { if (m == 0) return ""; m-- }
    else stack[++m] = parts[i]
  }
  r = stack[1]
  for (i = 2; i <= m; i++) r = r "/" stack[i]
  return r
}
function less(i, j) {
  if (bslug[i] != bslug[j]) return ((bslug[i] "") < (bslug[j] ""))
  return ((bdate[i] "") < (bdate[j] ""))
}
function place(c,   j) {
  for (j = 1; j <= bn; j++) if (j != c && less(c, j)) { out("B", bline[c], "order", bname[c], bline[j], bname[j]); return }
  out("B", bline[c], "order_last", bname[c])
}
BEGIN {
  FS = "\037"; S = "\037"
  bug_prefix = bug_dir "/"; bug_index = bug_dir "/INDEX.md"; bug_template = bug_dir "/TEMPLATE.md"
}
$1 == "K" { if ($2 != "" && !($2 in known)) { known[$2] = 1; korder[++kn] = $2 } next }
$1 == "A" || $1 == "B" {
  seen[$1]++
  r = resolve(($1 == "A" ? "" : bug_dir), $5)
  if (r == "") { out($1, $2, "escape", $5); next }
  if (!(r in known)) {
    if (index(r, "docs/") == 1 || index(r, "/") == 0) { out($1, $2, "dead", $5); next }
    print "X" S $1 S $2 S r S $5
  }
  if ($1 == "A") {
    a_linked[r] = 1
    if ($3 != "free" && index(r, bug_prefix) == 1 && r != bug_index && r != bug_template) out("A", $2, "stray_case", $5)
    if ($3 == "index" && $4 == "entry") {
      if (r in a_entry) out("A", $2, "dup_agents", $5, a_entry[r])
      else a_entry[r] = $2
    }
    next
  }
  if ($4 != "entry") { if (index(r, bug_prefix) == 1) out("B", $2, "intro_case", $5); next }
  if (r in b_entry) { out("B", $2, "dup", $5, b_entry[r]); next }
  b_entry[r] = $2
  if (r == bug_template) { if (bn > 0) out("B", $2, "template_first", $5); next }
  bn++; bname[bn] = $5; bline[bn] = $2; bdate[bn] = substr($5, 1, 10); bslug[bn] = substr($5, 12)
  next
}
END {
  for (i = 1; i <= kn; i++) {
    p = korder[i]
    if (index(p, "docs/") != 1) continue
    if (index(p, bug_prefix) == 1 && p != bug_index) {
      if (!(p in b_entry)) out("B", 0, "unindexed_case", p, substr(p, length(bug_prefix) + 1))
    } else if (!(p in a_linked)) out("A", 0, (p == bug_index ? "no_index_link" : "unindexed"), p)
  }
  last = 0; last2 = 0
  for (i = 1; i <= bn; i++) {
    if (last == 0 || !less(i, last)) { last2 = last; last = i; continue }
    drop_prev = (last2 == 0 || !less(i, last2))
    drop_cur = (i == bn || !less(i + 1, last))
    if (drop_prev && !drop_cur) { c = last; last = i }
    else c = i
    place(c)
  }
  print "J" S (kn + 0) S (seen["A"] + 0) S (seen["B"] + 0)
}
AWK
