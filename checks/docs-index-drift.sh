#!/usr/bin/env bash
# 扫描守卫：AGENTS.md 是**唯一入口**，那它的索引就必须是全的。
#
# AGENTS.md 只保留「全局规则」+「按任务查文档的索引」，细节全在 docs/ 下。Bug 案例的索引例外：2026-11-13 起单独放在
# docs/bugfixes/INDEX.md，AGENTS.md 只链到它 —— 两百多条每个会话一开就整份读进来（约 2.4 万 token），可只有修 bug、
# 碰到眼熟的症状时才用得上，那时按关键词搜那一份就行；改某块代码时该读的案例，必读表里已经逐行链着。
# 这套分工要成立，有三件事必须一直为真：
#
#   1. docs/ 下的每一份文档都找得到 —— 否则写了等于没写：
#      别的代理（Codex / Kimi / Gemini…）只读 AGENTS.md，索引里没有的文档它们
#      永远不会打开。**这不是假设，是已经发生过的事**：2026-09-20 那四份案例
#      （播放头断线、转场遮罩漂移、转场预览与成片分叉、悬停光标卡住）写完之后
#      都没进索引，一直到 2026-09-21 才被发现，而其中「播放头断线」那份正好是
#      当天新 bug 的孪生兄弟 —— 索引里有的话，横向那一半当场就能想到。
#      分两份查：docs/bugfixes/ 下的每一份（INDEX.md 自己除外）列在 docs/bugfixes/INDEX.md 里；其余每一份、
#      连同 docs/bugfixes/INDEX.md，列在 AGENTS.md 里 —— AGENTS.md 一断了指向 INDEX.md 的链，整份案例就没人打开了。
#   2. 索引里的链接都指向真实存在的文件 —— 文档改名/挪窝之后留下的死链，比没有
#      索引更坏：它会让人以为查过了。INDEX.md 里的链接按它所在的文件夹解析
#      （同文件夹写 xxx.md，别的文件夹写 ../architecture/xxx.md）。
#
#   3. 索引每条只有「链接 + 一句话」，AGENTS.md 整份不再长回去 —— AGENTS.md 每个会话一开就整份读进来。
#      2026-11-13 之前每条索引都带着一大段摘要：339 KB，一个会话光读它就约 14.7 万 token，而规则本身
#      只有 11 KB。那天收成每条一行（153 KB），细节留在各自的文档里；同一天又把 Bug 案例的索引搬了出去（100 KB）。
#      守的办法见第 3 节，分三类小节：
#        · 索引小节（AGENTS.md 里除下面两类以外的每个「## 」小节 —— 规划与实施报告索引、架构与长期约束索引、根目录文档，
#          以后新加的小节也照这个管 —— 和整份 docs/bugfixes/INDEX.md）：一条索引只许两种写法，顶格的「- [」列表行或表格行，
#          每行不超过 ENTRY_MAX_BYTES；条目以外的行（开头的说明、小标题）每节最多 INTRO_MAX_LINES 行、也不超过 ENTRY_MAX_BYTES；
#          别的列表记号（+、*、1.）、缩进的行、接在条目后面的行都红 —— 它们在 Markdown 里照样是列表或上一条的续行，
#          2026-11-13 复审时用这几种写法把约 600 字节、1,800 字节的摘要塞回了只认顶格「- [」一个物理行的老守卫，退出 0
#          （docs/bugfixes/2026-11-13-index-entry-limit-bypassed.md）。
#        · 「Bug 修复案例索引」一节：只留指路的话（同样有界），出现任何写法的条目都红 —— 条目只进 docs/bugfixes/INDEX.md。
#        · 不设单条上限的小节（FREE_SECTIONS）：唯一入口约定、开始任务前、全局规则、文档目录职责四节是规则本身；
#          「按修改范围选必读文档」和「构建与检查入口」**有意不设单独的预算**：必读表一行要带一串检索线索和几份文档的链接、
#          一两条硬约束，检查入口每个脚本一行，都不是「链接 + 一句话」，按条数或每行设上限只会逼人把检索线索删掉
#          （2026-11-13 复审的 F2 就是删了左列的检索词）。它们和别的小节一起只受整份上限约束。
#      整份上限 = SIZE_BASE_BYTES + SIZE_PER_DOC_BYTES × docs/bugfixes/ 以外的文档数 —— 多一份文档多一条索引是应该的，
#      所以上限跟着文档数走，不用每加一份文档就来改数字；必读表、检查入口这些不随文档数涨的部分算在基数里。
#      Bug 案例不再往 AGENTS.md 里加一行，所以不算进文档数；它们在必读表里加的链接从基数的余量里出（见第 3 节）。
#      超了的修法见第 3 节（摘要挪进它指向的文档；必读表里的旧案例链接只许撤一种），不是抬这几个数。
#
#   4. docs/bugfixes/INDEX.md 整份按文件名从大到小排，一份案例只列一次（2026-11-13 起，见 1d）。以前新案例一律加在模板那一行下面：
#      两个同时开着的 PR 都往同一处加一行，后合的那个必撞 —— 2026-10-15 到 11-13 合的 200 个 PR 里 88 个加过案例索引，真撞了
#      14 回，回回是在 PR 开着以后（得把 main 合进去、再等一轮 CI）。按文件名插，同一天已经有条目时两行多半落在不同的地方：
#      拿那 15 次「两边各加了一行」的合并重放，10 次不再撞。顺带，同一份案例列了两次（解冲突时两边的改动都留下了）也红。
#      GitHub 的 PR 合并不认 .gitattributes 的 merge=union（2026-11-13 实测），所以靠排序，不靠 union。
#      为什么、撞了怎么解见 docs/architecture/doc-indexes.md 第五节。
#
# 「手抄的清单会漂」在这个仓库已经栽过两回（见
# docs/bugfixes/2026-09-18-check-script-source-list-drift.md 与
# docs/bugfixes/2026-09-21-source-list-guard-only-watched-the-hub.md），
# 分类目录职责见 AGENTS.md 的「文档目录职责」；索引怎么写见 docs/architecture/doc-indexes.md。

set -euo pipefail
cd "$(dirname "$0")/.."

INDEX="AGENTS.md"
BUG_DIR="docs/bugfixes"
BUG_INDEX="${BUG_DIR}/INDEX.md"
FAILED=0
TAB="$(printf '\t')"

fail() {
  echo "✗ $1" >&2
  FAILED=1
}

[ -f "${INDEX}" ] || { echo "✗ 找不到 ${INDEX}：唯一入口没了，守卫失去目标" >&2; exit 1; }
[ -f "${BUG_INDEX}" ] || { echo "✗ 找不到 ${BUG_INDEX}：Bug 案例的索引没了，守卫失去目标（2026-11-13 从 AGENTS.md 搬出来的，AGENTS.md「Bug 修复案例索引」一节链着它）" >&2; exit 1; }

# 一份索引里所有形如 (path.md) 的链接目标，原样、去重。
links_in() {
  grep -o '([^()]*\.md)' "$1" | tr -d '()' | sort -u || true
}

# 把链接换成仓库根目录下的路径：前面接上索引所在的文件夹（$1），再消掉 "." 和 ".."。
# INDEX.md 里写的 xxx.md、../architecture/xxx.md 由此变成 docs/bugfixes/xxx.md、docs/architecture/xxx.md。
resolve_from() {
  awk -v base="$1" '
    {
      path = (base == "." ? $0 : base "/" $0)
      n = split(path, parts, "/")
      m = 0
      for (i = 1; i <= n; i++) {
        if (parts[i] == "" || parts[i] == ".") continue
        if (parts[i] == ".." && m > 0 && out[m] != "..") { m--; continue }
        out[++m] = parts[i]
      }
      line = ""
      for (i = 1; i <= m; i++) line = line (i > 1 ? "/" : "") out[i]
      print line
    }'
}

AGENTS_LINKS="$(links_in "${INDEX}")"
BUG_LINKS="$(links_in "${BUG_INDEX}")"
AGENTS_RESOLVED="$(resolve_from . <<< "${AGENTS_LINKS}")"
BUG_RESOLVED="$(resolve_from "${BUG_DIR}" <<< "${BUG_LINKS}")"

# ── 1. docs/ 下的每一份 .md 都找得到 ─────────────────────────────────
# 1a. docs/bugfixes/ 下的每一份（INDEX.md 自己除外）列在 INDEX.md 里。
BUG_DOCS="$(find "${BUG_DIR}" -name '*.md' -not -path "${BUG_INDEX}" | sort)"
while IFS= read -r doc; do
  [ -n "${doc}" ] || continue
  grep -qxF "${doc}" <<< "${BUG_RESOLVED}" \
    || fail "${doc} 没有列在 ${BUG_INDEX} 里：只读 AGENTS.md 的代理顺着它找案例，漏一行等于这份案例不存在 —— 补一行（日期 + 链接 + 一句教训），按文件名插到文件名比它小的第一条上面（整份按文件名从大到小排，别都加在模板下面），链接写同文件夹的 ${doc#"${BUG_DIR}"/}"
done <<< "${BUG_DOCS}"

# 1b. 其余每一份、连同 INDEX.md，列在 AGENTS.md 里。
REST_DOCS="$({ find docs -name '*.md' -not -path "${BUG_DIR}/*"; echo "${BUG_INDEX}"; } | sort)"
while IFS= read -r doc; do
  [ -n "${doc}" ] || continue
  if grep -qxF "${doc}" <<< "${AGENTS_RESOLVED}"; then
    continue
  fi
  if [ "${doc}" = "${BUG_INDEX}" ]; then
    fail "${INDEX} 没有链到 ${BUG_INDEX}：Bug 案例的索引从入口断了，只读 AGENTS.md 的代理一份案例都找不到 —— 「Bug 修复案例索引」一节要链着它"
  else
    fail "${doc} 没有出现在 ${INDEX} 的索引里：只读 AGENTS.md 的代理永远打不开它 —— 按「文档目录职责」补一行到对应的索引小节"
  fi
done <<< "${REST_DOCS}"

# 1c. AGENTS.md 的「Bug 修复案例索引」一节只留指路的话，条目只写进 INDEX.md —— 和第 3 节的小节规则一起查（见 3a）。

# 1d. INDEX.md 整份按每条的链接（文件名）从大到小排，一份案例只列一次（文件开头第 4 条）。按字节比（LC_ALL=C）：
#     文件名以日期开头，所以是从新到旧、同一天的按文件名；模板 TEMPLATE.md 比任何日期都大，自然在最上面。
#     每个问题输出一行「行号<TAB>dup<TAB>先列的行号<TAB>链接」或「行号<TAB>order<TAB>上一条的行号<TAB>链接<TAB>上一条的链接」。
read -r -d '' ORDER_AWK <<'AWK' || true
index($0, "- [") == 1 {
  p = index($0, "](")
  if (p == 0) next
  rest = substr($0, p + 2)
  q = index(rest, ")")
  if (q == 0) next
  key = substr(rest, 1, q - 1)
  if (key in seen) { print NR "\tdup\t" seen[key] "\t" key; next }
  seen[key] = NR
  if (have && key > prev) print NR "\torder\t" prev_nr "\t" key "\t" prev
  prev = key; prev_nr = NR; have = 1
}
AWK
ORDER_HITS="$(LC_ALL=C awk "${ORDER_AWK}" "${BUG_INDEX}")"
ORDER_SHOWN=0
ORDER_MORE=0
while IFS="${TAB}" read -r o_n o_code o_other o_key o_prev; do
  [ -n "${o_n}" ] || continue
  if [ "${o_code}" = "dup" ]; then
    fail "${BUG_INDEX} 第 ${o_n} 行又列了一次 ${o_key}（第 ${o_other} 行已经有了）：同一份案例列了两次 —— 多半是解冲突时两边的改动都留下了；留一条，把两边的改动并进那一条"
  elif [ "${ORDER_SHOWN}" -lt 5 ]; then
    ORDER_SHOWN=$((ORDER_SHOWN + 1))
    fail "${BUG_INDEX} 第 ${o_n} 行的 ${o_key} 比上一条（第 ${o_other} 行）的 ${o_prev} 大，该排在它上面：整份按文件名从大到小排（文件名以日期开头，所以是从新到旧）—— 新案例插到文件名比它小的第一条上面，别都加在模板下面：两个同时开着的 PR 都加在同一处，后合的那个必撞"
  else
    ORDER_MORE=$((ORDER_MORE + 1))
  fi
done <<< "${ORDER_HITS}"
if [ "${ORDER_MORE}" -gt 0 ]; then
  fail "${BUG_INDEX} 还有 ${ORDER_MORE} 处顺序不对（上面只列了前 5 处）：整份按文件名从大到小排"
fi

# ── 2. 两份索引里的链接都必须指向真实文件 ─────────────────────────────
# 只管仓库内的相对链接；http(s):// 之类交给别处。链接按索引所在的文件夹解析，和点开它时一样。
check_links() {
  local file="$1" base="$2" hint="$3" links link
  links="$(links_in "${file}")"
  while IFS= read -r link; do
    [ -n "${link}" ] || continue
    case "${link}" in
      http://*|https://*) continue ;;
    esac
    [ -f "${base}/${link}" ] \
      || fail "${file} 指向了不存在的 ${link}：死链比没有索引更坏 —— 它会让人以为查过了${hint}"
  done <<< "${links}"
}
check_links "${INDEX}" "." ""
check_links "${BUG_INDEX}" "${BUG_DIR}" "（这份索引里的链接按 ${BUG_DIR}/ 解析：同文件夹写 xxx.md，别的文件夹写 ../architecture/xxx.md）"

# ── 3. 索引每条一行，AGENTS.md 整份不许再长回去 ──────────────────────
# 数字是 2026-11-13 定的，那天定了三回：
#   · 收短索引那次：400 份文档、约 153 KB（最长的一条索引 303 字节），上限 58,000 + 250 × 400 = 158,000。
#   · Bug 案例的索引搬去 docs/bugfixes/INDEX.md 之后：AGENTS.md 100,067 字节，docs/bugfixes/ 以外 137 份文档。
#     基数 = 100,067 − 250 × 137 = 65,817，加余量取整到 71,000：上限 105,250，余量 5,183 字节。
#     余量留给新案例在必读表里加的链接：案例不算进文档数，上限不跟着它涨，可修 bug 的人常要在必读表那一行加一个
#     案例链接。表里当时 103 个案例链接，平均 112 字节（含顿号）；10-14 到 11-13 这 30 天新写了 118 份案例，22 份链进了
#     必读表，约 2.5 KB / 月。余量 ≈ 35 个这样的链接（约 3.9 KB，照这个速度约一个半月）+ 约 1.2 KB 规则和左列的零碎改动。
#     用完了照下面「超了怎么收」收，别抬基数。
#   · 复审之后（条目识别能绕过去，docs/bugfixes/2026-11-13-index-entry-limit-bypassed.md）：400、71,000、250 都没动；
#     新加 INTRO_MAX_LINES —— 那时条目以外的行最多的是「Bug 修复案例索引」一节的 4 行（一段话 + 三条要点），留一行。
# 超了怎么收（2026-11-13 用户定），只有两种：① 摘要挪进它指向的文档；② 撤掉必读表里的旧案例链接，但**只许撤这一种**：
#   同一行链着的架构文档已经写了那条规矩，并且那份架构文档里链着这份案例 —— 规矩和案例都还找得到，只是不在入口上重复；
#   案例本身照旧留在 docs/bugfixes/INDEX.md。别的链接（规矩只写在案例里的、架构文档没链它的）不许撤；这几个数也不许抬。
ENTRY_MAX_BYTES=400
INTRO_MAX_LINES=5
SIZE_BASE_BYTES=71000
SIZE_PER_DOC_BYTES=250

# 不设单条上限的小节（只受整份上限，为什么见文件开头第 3 条）。标题要和 AGENTS.md 里一字不差：改了标题就同步改这里，
# 不然那一节会被当成索引小节来管（守卫也会先说找不到它）。
FREE_SECTIONS="## 唯一入口约定
## 开始任务前
## 全局规则（必须遵守）
## 文档目录职责
## 按修改范围选必读文档
## 构建与检查入口"
POINTER_SECTION="## Bug 修复案例索引"

# 3a. 逐行认小节、认条目。awk 程序放在带引号的 heredoc 里，一个字都不经 shell 展开（shell 陷阱 5）；LC_ALL=C 下 length 数的是字节。
# 每个问题输出一行「行号<TAB>代号<TAB>附带的值」，代号的意思见下面的 case。
#   AGENTS.md（whole=0）：第一个「## 」之前（标题和开头那段话）和 FREE_SECTIONS 不管；POINTER_SECTION 只许说明；别的「## 」小节按索引管。
#   docs/bugfixes/INDEX.md（whole=1）：整份按索引管，条目以外的行整份一起数。
read -r -d '' SCAN_AWK <<'AWK' || true
function kind_of(line) {
  if (line ~ /^[ \t]*$/) return "blank"
  if (line ~ /^#+([ \t]|$)/) return "heading"
  if (index(line, "- [") == 1) return "list"
  if (substr(line, 1, 1) == "|") return "table"
  if (line ~ /^[ \t]/) return "indent"
  if (line ~ /^[-+*]([ \t]|$)/ || line ~ /^[0-9]+[.)]([ \t]|$)/) return "marker"
  return "prose"
}
BEGIN {
  n = split(ENVIRON["DRIFT_FREE_SECTIONS"], parts, "\n")
  for (i = 1; i <= n; i++) if (parts[i] != "") { is_free[parts[i]] = 1; free_seen[parts[i]] = 0 }
  pointer_title = ENVIRON["DRIFT_POINTER_SECTION"]
  mode = (whole ? "index" : "free")
  seen_entry = 0; extra = 0; prev = "blank"; pointer_seen = 0
}
{
  line = $0
  k = kind_of(line)
  if (!whole && index(line, "## ") == 1) {
    if (line in is_free) { mode = "free"; free_seen[line]++ }
    else if (line == pointer_title) { mode = "pointer"; pointer_seen++ }
    else mode = "index"
    if (mode != "free" && length(line) > max) print NR "\tlong\t" length(line)
    seen_entry = 0; extra = 0; prev = "heading"
    next
  }
  if (mode == "free" || k == "blank") { prev = k; next }
  if (length(line) > max) print NR "\tlong\t" length(line)
  if (mode == "pointer") {
    if (line ~ /^[ \t]*([-+*]|[0-9]+[.)])[ \t]+\[/ || line ~ /^[ \t]*\|/) print NR "\tstray\t0"
    if (++extra > intro_max) print NR "\tintro\t" extra
    prev = k; next
  }
  if (k == "list") { seen_entry = 1 }
  else if (k == "table") { if (prev == "list") print NR "\tglued\t0"; seen_entry = 1 }
  else if (k == "indent") print NR "\tindent\t0"
  else if (k == "marker") print NR "\tmarker\t0"
  else if (k == "prose" && seen_entry) print NR "\tafter\t0"
  else {
    if (++extra > intro_max) print NR "\tintro\t" extra
    if (k == "heading") seen_entry = 0
  }
  prev = k
}
END {
  if (whole) exit
  for (t in free_seen) if (free_seen[t] != 1) print "0\tfree_missing\t" t
  if (pointer_seen != 1) print "0\tpointer_missing\t0"
}
AWK

scan_index() {
  DRIFT_FREE_SECTIONS="${FREE_SECTIONS}" DRIFT_POINTER_SECTION="${POINTER_SECTION}" LC_ALL=C awk \
    -v whole="$2" -v max="${ENTRY_MAX_BYTES}" -v intro_max="${INTRO_MAX_LINES}" "${SCAN_AWK}" "$1"
}

for file in "${INDEX}" "${BUG_INDEX}"; do
  whole=0
  if [ "${file}" = "${BUG_INDEX}" ]; then
    whole=1
  fi
  HITS="$(scan_index "${file}" "${whole}")"
  while IFS="${TAB}" read -r n code extra; do
    [ -n "${n}" ] || continue
    case "${code}" in
      long)
        fail "${file} 第 ${n} 行有 ${extra} 字节，超过 ${ENTRY_MAX_BYTES}：索引小节里每一行（条目、表格行、开头的说明）只写「链接 + 一句话」，摘要和细节写进它指向的文档" ;;
      marker)
        fail "${file} 第 ${n} 行：索引条目只许两种写法 —— 顶格的「- [链接](…) — 一句话」或表格行；别的列表记号（+、*、1.）和不以链接开头的「- 」都不算条目，每条 ${ENTRY_MAX_BYTES} 字节的上限也就管不到它" ;;
      indent)
        fail "${file} 第 ${n} 行是缩进的行：在索引里它是上一条的续行或嵌套的列表，摘要会借它长回去 —— 条目写成顶格的一行，细节写进它指向的文档" ;;
      after)
        fail "${file} 第 ${n} 行接在索引条目后面，既不是条目也不是小标题：紧跟着条目时它是那一条的续行，隔了空行就是夹在索引里的一段摘要 —— 并进那一条的一句话，或写进它指向的文档；说明写在这一节的条目前面" ;;
      glued)
        fail "${file} 第 ${n} 行的表格行紧跟在一条「- [」索引后面、中间没有空行：在 Markdown 里它是那一条的续行 —— 表格前面空一行，或者并进那一条" ;;
      intro)
        fail "${file} 第 ${n} 行：这一节条目以外的行（开头的说明、小标题）到这里是 ${extra} 行，超过 ${INTRO_MAX_LINES}：说明只写怎么用这份索引，摘要写进文档" ;;
      stray)
        fail "${INDEX} 第 ${n} 行：Bug 案例的条目写进 ${BUG_INDEX}（按文件名插进去，链接写同文件夹的 xxx.md），AGENTS.md「Bug 修复案例索引」一节只留指路的话" ;;
      free_missing)
        fail "守卫登记的不设单条上限的小节「${extra}」在 ${INDEX} 里没有、或不止一个：改了标题就同步改守卫的 FREE_SECTIONS，不然那一节会被当成索引小节来管" ;;
      pointer_missing)
        fail "${INDEX} 里没有「${POINTER_SECTION}」一节、或不止一个：守卫失去目标，Bug 案例的条目会混进别的小节 —— 改了标题就同步改守卫的 POINTER_SECTION" ;;
      *)
        fail "${file} 第 ${n} 行：守卫自己认不出的代号「${code}」（检查脚本写错了）" ;;
    esac
  done <<< "${HITS}"
done

# 3b. AGENTS.md 整份的大小。文档数只数 docs/bugfixes/ 以外的普通文件（Bug 案例的条目在 INDEX.md 里，不占 AGENTS.md；
#     叫 xxx.md 的文件夹、符号链接不算 —— 上限不能靠它们涨。没进索引的那些第 1 节已经红了，这里不再只数 git 跟踪的）。
DOC_COUNT="$(find docs -type f -name '*.md' -not -path "${BUG_DIR}/*" | wc -l | tr -d ' ')"
SIZE_NOW="$(wc -c < "${INDEX}" | tr -d ' ')"
SIZE_LIMIT=$((SIZE_BASE_BYTES + SIZE_PER_DOC_BYTES * DOC_COUNT))
if [ "${SIZE_NOW}" -gt "${SIZE_LIMIT}" ]; then
  fail "${INDEX} 有 ${SIZE_NOW} 字节，超过上限 ${SIZE_LIMIT}（${SIZE_BASE_BYTES} + ${SIZE_PER_DOC_BYTES} × ${DOC_COUNT} 份 ${BUG_DIR}/ 以外的文档）：每个会话一开就整份读它 —— 必读表右列只留链接和一两条硬约束、检查入口每个脚本一行、索引每条一句话，细节挪进文档（docs/testing/check-catalog.md 或对应的架构文档），Bug 案例的条目只进 ${BUG_INDEX}；必读表里的旧案例链接只许撤一种：同一行链着的架构文档已经写了那条规矩、并且那份架构文档里链着这份案例（案例照旧留在 ${BUG_INDEX}）；别抬上限"
fi

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
BUG_COUNT="$(grep -c . <<< "${BUG_DOCS}" || true)"
echo "✓ docs-index-drift：${BUG_DIR}/ 下 ${BUG_COUNT} 份全部列在 INDEX.md 里（按文件名从大到小、没有重复），其余 ${DOC_COUNT} 份连同 INDEX.md 全部在 AGENTS.md 索引中，两份都没有死链，索引条目都是一行；AGENTS.md ${SIZE_NOW} 字节（上限 ${SIZE_LIMIT}）"
