#!/usr/bin/env bash
# 扫描守卫：AGENTS.md 是**唯一入口**，那它的索引就必须是全的、点得开的、不长回去的。
#
# AGENTS.md 只保留「全局规则」+「按任务查文档的索引」，细节全在 docs/ 下。Bug 案例的索引例外：2026-11-13 起单独放在
# docs/bugfixes/INDEX.md，AGENTS.md 只链到它 —— 两百多条每个会话一开就整份读进来（约 2.4 万 token），可只有修 bug、
# 碰到眼熟的症状时才用得上，那时按关键词搜那一份就行；改某块代码时该读的案例，必读表里已经逐行链着。
# 这套分工要成立，有五件事必须一直为真：
#
#   1. docs/ 下的每一份文档都找得到 —— 否则写了等于没写：别的代理（Codex / Kimi / Gemini…）只读 AGENTS.md，索引里没有的
#      文档它们永远不会打开。**这不是假设，是已经发生过的事**：2026-09-20 那四份案例写完之后都没进索引，一直到 09-21 才被
#      发现，而其中「播放头断线」那份正好是当天新 bug 的孪生兄弟。分两份查：docs/bugfixes/ 下的每一份（INDEX.md 自己除外）
#      在 docs/bugfixes/INDEX.md 里当条目列着；其余每一份、连同 INDEX.md，能从 AGENTS.md 的链接找到。
#   2. 索引里的链接都指向真实存在的文件 —— 死链比没有索引更坏：它会让人以为查过了。
#   3. 索引每条只有「链接 + 一句话」，AGENTS.md 整份不再长回去 —— 它每个会话一开就整份读进来。2026-11-13 之前每条索引都带着
#      一大段摘要：339 KB，一个会话光读它就约 14.7 万 token，而规则本身只有 11 KB。小节分三类（索引小节、指路的小节、
#      不设单条上限的小节），名单、几个数和它们的来历在 docs-index-drift/config.sh。
#   4. docs/bugfixes/INDEX.md 整份按文件名里日期后面那一段排、一份案例只列一次 —— 两个同时开着的 PR 各加一条，落在不同的
#      地方就不撞。以前都加在模板下面（200 个 PR 里真撞 14 回）；改成按文件名从大到小之后，同一天的头两条还撞（历史上两边
#      各加一行的 15 次合并重放还剩 5 次）；按日期后面那一段排，重放 0 次。GitHub 的 PR 合并不认 merge=union，所以靠排序。
#   5. 上面四条查的都是「守卫认得出来的写法」—— 所以两份索引里**只许出现规定的几种写法**（白名单），别的一律红、并说出是
#      哪一行。以前是认出不许的写法才红，被绕过三轮：换一种 Markdown 里合法的写法（别的列表记号、缩进的续行、不成表格的
#      竖线行、引用、注释和代码围栏里的路径、引用式链接、a 标签），守卫认不出就当没看见。
#
# 文件分工（主文件只管读清单、串起来、算整份大小；每一节不单独跑，由这里 source）：
#   docs-index-drift/config.sh     小节的名单、几个数
#   docs-index-drift/lines.sh      逐行认写法：链接、方括号、行内代码、条目、表格、说明
#   docs-index-drift/judge.sh      链接对着磁盘：死链、漏索引、案例只进 INDEX.md、重复、顺序
#   docs-index-drift/messages.sh   每个代号对应的那句话
#   docs-index-drift/self-test.sh  自测：在最小副本上一个场景一个场景跑，该红的红在对的那一条、该绿的绿
#                                  （场景在 docs-index-drift/scenarios-*.sh；每条都是真被绕过去过、或当对手试出来的写法）
#
# 用法：
#   checks/docs-index-drift.sh                 # 查仓库
#   checks/docs-index-drift.sh --self-test     # 跑自测（改这条守卫之前之后都跑；CI 上 check-all 也跑）
#   checks/docs-index-drift.sh --root <目录>   # 查另一棵树（自测用：目录里要有 AGENTS.md 和 docs/）
#
# 规矩写在 docs/architecture/doc-indexes.md；细目在 docs/testing/check-catalog.md。「手抄的清单会漂」在这个仓库已经栽过两回
# （docs/bugfixes/2026-09-18-check-script-source-list-drift.md、docs/bugfixes/2026-09-21-source-list-guard-only-watched-the-hub.md）。
# 按 docs/bugfixes/2026-08-06-build-version-and-shell-traps.md 写：变量一律 ${VAR}，awk 程序放在带引号的 heredoc 里，
# 总闸在最后，用 /bin/bash（3.2）调试。

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PARTS="${SELF_DIR}/docs-index-drift"
ROOT="${SELF_DIR}/.."
case "${1:-}" in
  "") ;;
  --self-test)
    shift
    exec /bin/bash "${PARTS}/self-test.sh" "${SELF_DIR}/docs-index-drift.sh" "$@" ;;
  --root)
    if [ -z "${2:-}" ] || [ ! -d "${2}" ]; then
      echo "✗ --root 后面要跟一个存在的目录" >&2
      exit 2
    fi
    ROOT="$2" ;;
  *)
    echo "✗ 不认识的参数：${1}（用法见文件开头）" >&2
    exit 2 ;;
esac
for part in config lines judge messages; do
  if [ ! -f "${PARTS}/${part}.sh" ]; then
    echo "✗ 找不到 ${PARTS}/${part}.sh：守卫的一节没了" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  . "${PARTS}/${part}.sh"
done
cd "${ROOT}"

INDEX="AGENTS.md"
BUG_DIR="docs/bugfixes"
BUG_INDEX="${BUG_DIR}/INDEX.md"
SEP="$(printf '\037')"
NL='
'
FAILED=0
FOUND=""   # 攒下来的问题，一行一个：E␟A|B|F␟行号␟代号␟值 1␟值 2␟值 3

# found <A|B|F> <行号> <代号> [值 1] [值 2] [值 3]
found() {
  FOUND="${FOUND}E${SEP}$1${SEP}$2${SEP}$3${SEP}${4:--}${SEP}${5:--}${SEP}${6:--}${NL}"
}

[ -f "${INDEX}" ] || { echo "✗ [missing] 找不到 ${INDEX}：唯一入口没了，守卫失去目标" >&2; exit 1; }
[ -f "${BUG_INDEX}" ] || { echo "✗ [missing] 找不到 ${BUG_INDEX}：Bug 案例的索引没了，守卫失去目标（2026-11-13 从 AGENTS.md 搬出来的，AGENTS.md「Bug 修复案例索引」一节链着它）" >&2; exit 1; }

# ── 1. 磁盘上的文档：一份清单，漏索引、死链、算上限都用它 ─────────────
# 只数普通文件：叫 xxx.md 的文件夹不是文档（以前查漏索引的两处 find 没带 -type f，会说它「没索引」，补了链接又成死链）。
DOCS_ALL="$(find docs -type f -name '*.md' | LC_ALL=C sort)"
ROOT_MD="$(find . -maxdepth 1 -type f -name '*.md' | sed 's|^\./||' | LC_ALL=C sort)"
DOC_COUNT="$(LC_ALL=C awk -v p="${BUG_DIR}/" '$0 != "" && index($0, p) != 1 { n++ } END { print n + 0 }' <<< "${DOCS_ALL}")"
BUG_COUNT="$(LC_ALL=C awk -v p="${BUG_DIR}/" -v idx="${BUG_INDEX}" 'index($0, p) == 1 && $0 != idx { n++ } END { print n + 0 }' <<< "${DOCS_ALL}")"

# 1a. 文件名只许字母、数字、. _ -：索引里的链接只认这样的路径（所以不用去支持带括号、空格的链接写法）。
while IFS= read -r doc; do
  [ -n "${doc}" ] || continue
  found F 0 name "${doc}"
done <<< "$(LC_ALL=C grep -vE '^docs/[A-Za-z0-9._/-]+\.md$' <<< "${DOCS_ALL}" || true)"
# 1b. docs/bugfixes/ 下只放带日期的案例、TEMPLATE.md、INDEX.md（顺序的键是文件名里日期后面那一段）。
while IFS= read -r doc; do
  [ -n "${doc}" ] || continue
  found F 0 case_name "${doc}"
done <<< "$(LC_ALL=C grep -E "^${BUG_DIR}/" <<< "${DOCS_ALL}" \
  | LC_ALL=C grep -vE "^${BUG_DIR}/([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[A-Za-z0-9._-]+|TEMPLATE|INDEX)\.md$" || true)"
# 1c. 符号链接、别的后缀：守卫当它不是文档，所以不许有。
while IFS= read -r doc; do
  [ -n "${doc}" ] || continue
  found F 0 symlink "${doc}"
done <<< "$(find docs -type l -name '*.md' | LC_ALL=C sort)"
while IFS= read -r doc; do
  [ -n "${doc}" ] || continue
  found F 0 ext "${doc}"
done <<< "$(find docs -type f \( -iname '*.md' -o -iname '*.markdown' -o -iname '*.mdown' -o -iname '*.mkd' -o -iname '*.mdx' \) -not -name '*.md' | LC_ALL=C sort)"

# ── 2. 逐行认两份索引的写法（docs-index-drift/lines.sh）──────────────
for file in "${INDEX}" "${BUG_INDEX}"; do
  if [ "$(LC_ALL=C tr -d '\000' < "${file}" | wc -c | tr -d ' ')" != "$(wc -c < "${file}" | tr -d ' ')" ]; then
    found F 0 nul "${file}"
  fi
done
scan_lines() {
  DRIFT_FREE_SECTIONS="${FREE_SECTIONS}" DRIFT_INDEX_SECTIONS="${INDEX_SECTIONS}" DRIFT_POINTER_SECTION="${POINTER_SECTION}" \
    DRIFT_DASH=" — " LC_ALL=C awk -v tag="$2" -v whole="$3" -v max="${ENTRY_MAX_BYTES}" -v intro_max="${INTRO_MAX_LINES}" \
    "${LINES_AWK}" "$1"
}
A_OUT="$(scan_lines "${INDEX}" A 0)"
B_OUT="$(scan_lines "${BUG_INDEX}" B 1)"
LINES_OUT="${A_OUT}${NL}${B_OUT}"

# ── 3. 链接对着磁盘：死链、漏索引、重复、顺序（docs-index-drift/judge.sh）──
JUDGE_OUT="$({
  sed "s/^/K${SEP}/" <<< "${DOCS_ALL}"
  sed "s/^/K${SEP}/" <<< "${ROOT_MD}"
  printf '%s\n' "${LINES_OUT}"
} | LC_ALL=C awk -v bug_dir="${BUG_DIR}" "${JUDGE_AWK}")"

# 指向 docs/ 和根目录以外的链接（平时没有）：一段一段对着目录里真实的名字核，大小写不对也算死链。
exists_exact() {
  local rest="$1" dir="." seg
  while [ "${rest#*/}" != "${rest}" ]; do
    seg="${rest%%/*}"
    rest="${rest#*/}"
    [ -n "$(find "${dir}" -mindepth 1 -maxdepth 1 -type d -name "${seg}" 2>/dev/null | head -n 1)" ] || return 1
    dir="${dir}/${seg}"
  done
  [ -n "$(find "${dir}" -mindepth 1 -maxdepth 1 -type f -name "${rest}" 2>/dev/null | head -n 1)" ]
}
while IFS="${SEP}" read -r kind tag nr resolved written; do
  [ "${kind}" = "X" ] || continue
  exists_exact "${resolved}" || found "${tag}" "${nr}" dead "${written}"
done <<< "${JUDGE_OUT}"

# 扫空 = 假绿：两份索引都真的读过（各有一行 N）、文档清单和两份里的链接都不是空的（一行 J），才往下算。
SCANNED="$(LC_ALL=C awk -F "${SEP}" '
  $1 == "N" && $3 > 0 { n++ }
  $1 == "J" && $2 > 0 && $3 > 0 && $4 > 0 { j++ }
  END { print ((n == 2 && j == 1) ? "yes" : "no") }' <<< "${LINES_OUT}${NL}${JUDGE_OUT}")"
if [ "${SCANNED}" != "yes" ]; then
  echo "✗ [empty] 守卫扫空了：${INDEX} 或 ${BUG_INDEX} 是空的、里面一个链接都没有，或者 docs/ 下一份文档都没找到 —— 扫空就是假绿，看看这两份文件和守卫的几节（${PARTS}/）" >&2
  exit 1
fi

# ── 4. AGENTS.md 整份的大小 ──────────────────────────────────────────
# 文档数只数 docs/bugfixes/ 以外的普通文件（Bug 案例的条目在 INDEX.md 里，不占 AGENTS.md；没进索引的那些第 3 步已经红了）。
SIZE_NOW="$(wc -c < "${INDEX}" | tr -d ' ')"
SIZE_LIMIT=$((SIZE_BASE_BYTES + SIZE_PER_DOC_BYTES * DOC_COUNT))
if [ "${SIZE_NOW}" -gt "${SIZE_LIMIT}" ]; then
  found A 0 size "${SIZE_NOW}" "${SIZE_LIMIT}" "${DOC_COUNT}"
fi

# ── 5. 把问题说出来 ──────────────────────────────────────────────────
# 同一份文件上同一种问题最多说 SHOWN_MAX 处，再说一共还有几处（整份换了顺序、整份带回车时一行一处，会刷屏）。
SHOWN_MAX=5
read -r -d '' TALLY_AWK <<'AWK' || true
BEGIN { FS = "\037"; OFS = "\037" }
$1 == "E" { n++; row[n] = $0; key[n] = $2 FS $4; seq[n] = ++count[key[n]] }
END { for (i = 1; i <= n; i++) print row[i], seq[i], count[key[i]] }
AWK
ALL="$(printf '%s\n' "${FOUND}" "${LINES_OUT}" "${JUDGE_OUT}" | LC_ALL=C awk "${TALLY_AWK}")"
while IFS="${SEP}" read -r kind tag nr code d1 d2 d3 seq total; do
  [ "${kind}" = "E" ] || continue
  FAILED=1
  if [ "${seq}" -le "${SHOWN_MAX}" ]; then
    echo "✗ [${code}] $(explain "${tag}" "${nr}" "${code}" "${d1}" "${d2}" "${d3}")" >&2
  elif [ "${seq}" -eq $((SHOWN_MAX + 1)) ]; then
    echo "✗ [${code}] 同样的问题还有 $((total - SHOWN_MAX)) 处（上面只列了前 ${SHOWN_MAX} 处）" >&2
  fi
done <<< "${ALL}"

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
echo "✓ docs-index-drift：${BUG_DIR}/ 下 ${BUG_COUNT} 份全部在 INDEX.md 里当条目列着（按文件名里日期后面那一段排、没有重复），其余 ${DOC_COUNT} 份连同 INDEX.md 全部在 AGENTS.md 索引中，两份都没有死链、只有规定的写法，索引条目都是一行；AGENTS.md ${SIZE_NOW} 字节（上限 ${SIZE_LIMIT}）"
