#!/usr/bin/env bash
# checks/docs-index-drift.sh 的一节：逐行读一份索引文件（AGENTS.md 或 docs/bugfixes/INDEX.md），只认规定的几种写法。
#
# **不单独跑**：由 docs-index-drift.sh 用 `source` 装进来，只定义 LINES_AWK（awk 程序放在带引号的 heredoc 里，
# 一个字都不经 shell 展开，shell 陷阱 5；程序正文只用 ASCII，中文的小节标题和破折号从环境变量进来）。
#
# 管什么：两份索引里**许写什么**（白名单）。以前是「认出不许的写法就红」，被绕过三轮：换一种 Markdown 里合法的写法，
# 守卫认不出就当没看见（docs/bugfixes/2026-11-13-index-entry-limit-bypassed.md 和它的「后续」）。现在反过来：
#   整份文件（不设上限的小节也算）——
#     · 链接只有一种：[字](相对路径.md)，可以带 #锚点；路径只用字母、数字、. _ - /，不带 ./、不带标题、不链网址。
#     · 方括号只许用在这种链接里（行内代码里的不算）：引用式链接和它的定义、脚注、任务框、图片都红。
#     · 行内代码只许一对反引号、不跨行、不是空的；代码围栏、行内代码以外的 < 反斜杠 $ 和 HTML 实体、控制字符、
#       看不见的字符都红（它们都能让一个链接看着在、其实点不开或看不见）。
#     · 第一行是「# 标题」（不许 front matter）；缩进的行只许接在列表项后面、列表记号后面只空一格
#       （空行后面缩进的行、记号后面空五格的内容会成代码块，里面的链接点不开）。
#   索引小节和整份 INDEX.md ——
#     · 条目只有一种：顶格的「- [标题](路径.md) — 一句话」，一条正好一个链接；AGENTS.md 的索引小节另许表格
#       （表头 + 分隔行 + 每行正好一个链接），INDEX.md 是纯列表。
#     · 条目以外只许空行、标题和条目前面的说明；每行不超过 max 字节，说明 / 小标题 / 表头每节最多 intro_max 行。
#   「Bug 修复案例索引」一节 —— 只许普通的一行或「- 」开头的一行。
#   不设单条上限的小节 —— 只多一条：列表项不许以链接开头（那是索引条目的写法，条目放进索引小节才有每条的上限）。
# 不管什么：链接指向的文件在不在、漏没漏索引、顺序和重复（judge.sh）；AGENTS.md 整份多大（主文件）。
#
# 输入变量：tag（A = AGENTS.md，B = INDEX.md）、whole（1 = 整份按索引管）、max、intro_max；
#           环境变量 DRIFT_FREE_SECTIONS / DRIFT_INDEX_SECTIONS / DRIFT_POINTER_SECTION / DRIFT_DASH。
# 输出（字段用 \037 隔开 —— TAB 是 IFS 里的空白，空的一栏会被并掉）：
#   E  tag  行号  代号  附带的值  -  -          一个问题（代号的意思见 messages.sh）
#   tag  行号  free|index|pointer  entry|text  路径  一个合规的链接（路径去掉了 #锚点；entry = 这一行是条目、这是它的链接）
#   N  tag  读了几行                              每份文件最后一行：主文件靠它认「真的读过了」（扫空 = 假绿）

read -r -d '' LINES_AWK <<'AWK' || true
function err(code, detail) { print "E" S tag S NR S code S (detail == "" ? "-" : detail) S "-" S "-" }
function err_at(n, code) { print "E" S tag S n S code S "-" S "-" S "-" }
function pipes(s,   t) { t = s; return gsub(/[|]/, "|", t) }
function count_extra() { if (++extra > intro_max) err("intro", extra) }
function close_table() { if (tstate == 1 && !thead_bad) err_at(thead, "table_head"); tstate = 0 }
function emit(role,   i) {
  for (i = 1; i <= nl; i++) print tag S NR S mode S ((i == 1 && role == "entry") ? "entry" : "text") S lpath[i]
}
function kind_of(l) {
  if (l ~ /^ *$/) return "blank"
  if (substr(l, 1, 1) == " ") return "indent"
  if (l ~ /^#+( |$)/) return "heading"
  if (index(l, "- [") == 1) return "entry"
  if (substr(l, 1, 1) == "|") return "table"
  if (substr(l, 1, 1) == ">") return "quote"
  if (l ~ /^[-:|=*_ ]+$/) return "rule"
  if (l ~ /^[-+*]( |$)/ || l ~ /^[0-9]+[.)]( |$)/) return "marker"
  return "prose"
}
function path_ok(p,   n, parts, i, normal) {
  if (p !~ /^[A-Za-z0-9._\/-]+\.md$/) return 0
  n = split(p, parts, "/")
  normal = 0
  for (i = 1; i <= n; i++) {
    if (parts[i] == "" || parts[i] == ".") return 0
    if (parts[i] == "..") { if (normal) return 0 }
    else normal = 1
  }
  return 1
}
BEGIN {
  S = "\037"
  n = split(ENVIRON["DRIFT_FREE_SECTIONS"], parts, "\n")
  for (i = 1; i <= n; i++) if (parts[i] != "") { is_named[parts[i]] = "free"; named[++nnamed] = parts[i] }
  n = split(ENVIRON["DRIFT_INDEX_SECTIONS"], parts, "\n")
  for (i = 1; i <= n; i++) if (parts[i] != "") { is_named[parts[i]] = "index"; named[++nnamed] = parts[i] }
  pointer_title = ENVIRON["DRIFT_POINTER_SECTION"]
  is_named[pointer_title] = "pointer"; named[++nnamed] = pointer_title
  dash = ENVIRON["DRIFT_DASH"]
  # U+00A0 U+00AD U+200B..U+200F U+2028..U+202E U+2060 U+2066..U+2069 U+3000 U+3164 U+FEFF
  inv[++ninv] = "\302\240"; inv[++ninv] = "\302\255"
  inv[++ninv] = "\342\200\213"; inv[++ninv] = "\342\200\214"; inv[++ninv] = "\342\200\215"
  inv[++ninv] = "\342\200\216"; inv[++ninv] = "\342\200\217"
  inv[++ninv] = "\342\200\250"; inv[++ninv] = "\342\200\251"; inv[++ninv] = "\342\200\252"
  inv[++ninv] = "\342\200\253"; inv[++ninv] = "\342\200\254"; inv[++ninv] = "\342\200\255"
  inv[++ninv] = "\342\200\256"; inv[++ninv] = "\342\201\240"
  inv[++ninv] = "\342\201\246"; inv[++ninv] = "\342\201\247"; inv[++ninv] = "\342\201\250"
  inv[++ninv] = "\342\201\251"; inv[++ninv] = "\343\200\200"; inv[++ninv] = "\343\205\244"
  inv[++ninv] = "\357\273\277"
  mode = (whole ? "index" : "free")
  prevk = "blank"; tstate = 0; seen_entry = 0; extra = 0
}
{
  line = $0

  # ---- 1. whole file: characters ----
  if (line ~ /[\001-\037\177]/) { err("ctrl"); gsub(/[\001-\037\177]/, "", line) }
  for (i = 1; i <= ninv; i++) if (index(line, inv[i])) { err("invisible"); break }
  if (index(line, "``") || line ~ /^ *~~~/) err("fence")
  t = line
  if (gsub(/`/, "`", t) % 2) err("tick")
  vis = ""; t = line
  while (match(t, /`[^`]*`/)) {
    if (substr(t, RSTART + 1, RLENGTH - 2) ~ /^ *$/) err("blank_code")
    vis = vis substr(t, 1, RSTART - 1) "\001"
    t = substr(t, RSTART + RLENGTH)
  }
  vis = vis t
  if (index(vis, "<")) err("html")
  if (index(vis, "\\")) err("backslash")
  if (index(vis, "$")) err("math")
  if (vis ~ /&(#[0-9A-Za-z]+|[A-Za-z][A-Za-z0-9]*);/) err("entity")
  if (index(vis, "![")) err("image")
  if (NR == 1 && index(line, "# ") != 1) err("title")
  if (line ~ /^ *([-+*]|[0-9]+[.)])  /) err("codeblock")

  # ---- 2. whole file: links ----
  nl = 0; nshape = 0; start1 = 0; len1 = 0; text1 = ""; valid1 = 0
  rest = vis
  while (match(rest, /\[[^][]*\]\([^()]*\)/)) {
    lk = substr(rest, RSTART, RLENGTH)
    mid = index(lk, "](")
    text = substr(lk, 2, mid - 2)
    target = substr(lk, mid + 2, RLENGTH - mid - 2)
    nshape++
    if (nshape == 1) { start1 = RSTART; len1 = RLENGTH; text1 = text }
    rest = substr(rest, 1, RSTART - 1) "\002" substr(rest, RSTART + RLENGTH)
    if (text ~ /^ *$/) err("link_text")
    if (index(text, "\002")) { err("bracket"); continue }
    path = target; anchor = ""
    h = index(target, "#")
    if (h) { path = substr(target, 1, h - 1); anchor = substr(target, h) }
    if (!path_ok(path) || index(anchor, " ")) { err("target", target); continue }
    nl++; lpath[nl] = path; lanchor[nl] = anchor
    if (nshape == 1) valid1 = 1
  }
  if (index(rest, "[") || index(rest, "]")) err("bracket")

  k = kind_of(line)

  # ---- 3. AGENTS.md: which section ----
  if (!whole && index(line, "## ") == 1) {
    close_table()
    if (line in is_named) { mode = is_named[line]; times[line]++ }
    else mode = "index"
    if (mode != "free" && length(line) > max) err("long", length(line))
    emit("text")
    seen_entry = 0; extra = 0; prevk = "heading"
    next
  }

  # ---- 4. sections without a per-line limit: only the whole-file rules ----
  if (mode == "free") {
    if (k == "indent" && !(prevk == "marker" || prevk == "entry" || prevk == "indent")) err("codeblock")
    if (vis ~ /^ *([-+*]|[0-9]+[.)]) \[/) err("entry_in_free")
    emit("text"); prevk = k
    next
  }
  if (k == "blank") { close_table(); prevk = k; next }
  if (length(line) > max) err("long", length(line))

  # ---- 5. the pointer section ----
  if (mode == "pointer") {
    if (!(k == "prose" || k == "entry" || (k == "marker" && index(line, "- ") == 1))) err("pointer_shape")
    count_extra()
    emit("text"); prevk = k
    next
  }

  # ---- 6. index sections and the whole INDEX.md ----
  role = "text"
  if (k == "table") {
    if (whole) err("table")
    else if (tstate == 0) {
      if (!(prevk == "blank" || prevk == "heading")) err("glued")
      thead_bad = (vis !~ /[|] *$/ || pipes(line) != pipes(vis))
      if (thead_bad) err("table_head")
      tstate = 1; thead = NR; tcells = pipes(vis)
      count_extra()
    } else if (tstate == 1) {
      if (!thead_bad && (vis !~ /^[|]( *:?-+:? *[|])+ *$/ || pipes(vis) != tcells)) err_at(thead, "table_head")
      tstate = 2
    } else {
      if (vis !~ /[|] *$/ || pipes(line) != pipes(vis) || pipes(vis) != tcells) err("table_row")
      if (nshape != 1 || !valid1) err("row_links")
      else role = "entry"
      seen_entry = 1
    }
  } else {
    if (tstate == 2) err("after")
    close_table()
    if (k == "entry") {
      after = substr(vis, start1 + len1)
      if (nshape < 1 || start1 != 3 || substr(after, 1, length(dash)) != dash || substr(after, length(dash) + 1) !~ /[^ ]/) err("entry_form")
      else if (nshape != 1) err("entry_links")
      else if (valid1) {
        role = "entry"
        if (whole) {
          if (lanchor[1] != "" || lpath[1] !~ /^(TEMPLATE|[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[A-Za-z0-9._-]+)\.md$/) { err("case_entry", lpath[1]); role = "text" }
          else if (lpath[1] != "TEMPLATE.md" && substr(text1, 1, 11) != substr(lpath[1], 1, 10) " ") err("entry_date", lpath[1])
        }
      }
      seen_entry = 1
    } else if (k == "heading") { count_extra(); seen_entry = 0 }
    else if (k == "prose") {
      if (seen_entry) err("after")
      else { count_extra(); if (nshape >= 1 && start1 == 1) err("bare_entry") }
    } else err(k)
  }
  emit(role); prevk = k
}
END {
  close_table()
  print "N" S tag S NR
  if (whole) exit
  for (i = 1; i <= nnamed; i++) if (times[named[i]] != 1) print "E" S tag S 0 S is_named[named[i]] "_missing" S named[i] S "-" S "-"
}
AWK
