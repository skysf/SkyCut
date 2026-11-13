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
#      AGENTS.md 的「Bug 修复案例索引」一节只留指路的话、不放条目：开工早的会话上下文里还是旧规矩，会往那里补一行。
#   2. 索引里的链接都指向真实存在的文件 —— 文档改名/挪窝之后留下的死链，比没有
#      索引更坏：它会让人以为查过了。INDEX.md 里的链接按它所在的文件夹解析
#      （同文件夹写 xxx.md，别的文件夹写 ../architecture/xxx.md）。
#
#   3. 索引每条只有「链接 + 一句话」，AGENTS.md 整份不再长回去 —— AGENTS.md 每个会话一开就整份读进来。
#      2026-11-13 之前每条索引都带着一大段摘要：339 KB，一个会话光读它就约 14.7 万 token，而规则本身
#      只有 11 KB。那天收成每条一行（153 KB），细节留在各自的文档里；同一天又把 Bug 案例的索引搬了出去（100 KB）。两道闸：
#        · 两份索引里以 "- [" 开头的索引行，每条不超过 ENTRY_MAX_BYTES；
#        · AGENTS.md 整份不超过 SIZE_BASE_BYTES + SIZE_PER_DOC_BYTES × docs/bugfixes/ 以外的文档数 —— 多一份文档多一条索引
#          是应该的，所以上限跟着文档数走，不用每加一份文档就来改数字；必读表、检查入口这些不随文档数涨的部分算在基数里。
#          Bug 案例不再往 AGENTS.md 里加一行，所以不算进文档数；它们在必读表里加的链接从基数的余量里出（见第 3 节）。
#      超了的修法是把摘要挪进它指向的文档，不是抬这三个数。
#
# 「手抄的清单会漂」在这个仓库已经栽过两回（见
# docs/bugfixes/2026-09-18-check-script-source-list-drift.md 与
# docs/bugfixes/2026-09-21-source-list-guard-only-watched-the-hub.md），
# 分类目录职责见 AGENTS.md 的「文档目录职责」。

set -euo pipefail
cd "$(dirname "$0")/.."

INDEX="AGENTS.md"
BUG_DIR="docs/bugfixes"
BUG_INDEX="${BUG_DIR}/INDEX.md"
FAILED=0

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
    || fail "${doc} 没有列在 ${BUG_INDEX} 里：只读 AGENTS.md 的代理顺着它找案例，漏一行等于这份案例不存在 —— 在模板那一行下面补一行（日期 + 链接 + 一句教训），链接写同文件夹的 ${doc#"${BUG_DIR}"/}"
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

# 1c. AGENTS.md 的「Bug 修复案例索引」一节只留指路的话，条目只写进 INDEX.md。
STRAY_LINES="$(LC_ALL=C awk '
  index($0, "## ") == 1 { inside = ($0 == "## Bug 修复案例索引"); next }
  inside && index($0, "- [") == 1 { print NR }
' "${INDEX}")"
while IFS= read -r n; do
  [ -n "${n}" ] || continue
  fail "${INDEX} 第 ${n} 行：Bug 案例的条目写进 ${BUG_INDEX}（模板那一行下面，链接写同文件夹的 xxx.md），AGENTS.md「Bug 修复案例索引」一节只留指路的话"
done <<< "${STRAY_LINES}"

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
# 数字是 2026-11-13 定的，那天定了两回：
#   · 收短索引那次：400 份文档、约 153 KB（最长的一条索引 303 字节），上限 58,000 + 250 × 400 = 158,000。
#   · Bug 案例的索引搬去 docs/bugfixes/INDEX.md 之后：AGENTS.md 100,067 字节，docs/bugfixes/ 以外 137 份文档。
#     基数 = 100,067 − 250 × 137 = 65,817，加余量取整到 71,000：上限 105,250，余量 5,183 字节。
#     余量留给新案例在必读表里加的链接：案例不算进文档数，上限不跟着它涨，可修 bug 的人常要在必读表那一行加一个
#     案例链接。表里当时 103 个案例链接，平均 112 字节（含顿号）；10-14 到 11-13 这 30 天新写了 118 份案例，22 份链进了
#     必读表，约 2.5 KB / 月。余量 ≈ 35 个这样的链接（约 3.9 KB，照这个速度约一个半月）+ 约 1.2 KB 规则和左列的零碎改动。
#     用完了照上面第 3 条的修法收，别抬基数。
ENTRY_MAX_BYTES=400
SIZE_BASE_BYTES=71000
SIZE_PER_DOC_BYTES=250

# 3a. 一条索引 = 以 "- [" 开头的一行，两份索引都算。LC_ALL=C 下 awk 的 length 数的是字节。
for file in "${INDEX}" "${BUG_INDEX}"; do
  LONG_ENTRIES="$(LC_ALL=C awk -v max="${ENTRY_MAX_BYTES}" 'index($0, "- [") == 1 && length($0) > max { printf "%d:%d\n", NR, length($0) }' "${file}")"
  while IFS= read -r hit; do
    [ -n "${hit}" ] || continue
    fail "${file} 第 ${hit%%:*} 行这条索引有 ${hit##*:} 字节，超过 ${ENTRY_MAX_BYTES}：索引只写「链接 + 一句话」，摘要和细节写进它指向的文档"
  done <<< "${LONG_ENTRIES}"
done

# 3b. AGENTS.md 整份的大小。文档数只数 docs/bugfixes/ 以外的（Bug 案例的条目在 INDEX.md 里，不占 AGENTS.md）。
DOC_COUNT="$(find docs -name '*.md' -not -path "${BUG_DIR}/*" | wc -l | tr -d ' ')"
SIZE_NOW="$(wc -c < "${INDEX}" | tr -d ' ')"
SIZE_LIMIT=$((SIZE_BASE_BYTES + SIZE_PER_DOC_BYTES * DOC_COUNT))
if [ "${SIZE_NOW}" -gt "${SIZE_LIMIT}" ]; then
  fail "${INDEX} 有 ${SIZE_NOW} 字节，超过上限 ${SIZE_LIMIT}（${SIZE_BASE_BYTES} + ${SIZE_PER_DOC_BYTES} × ${DOC_COUNT} 份 ${BUG_DIR}/ 以外的文档）：每个会话一开就整份读它 —— 必读表右列只留链接和一两条硬约束、检查入口每个脚本一行、索引每条一句话，细节挪进文档（docs/testing/check-catalog.md 或对应的架构文档），Bug 案例的条目只进 ${BUG_INDEX}；别抬上限"
fi

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
BUG_COUNT="$(grep -c . <<< "${BUG_DOCS}" || true)"
echo "✓ docs-index-drift：${BUG_DIR}/ 下 ${BUG_COUNT} 份全部列在 INDEX.md 里，其余 ${DOC_COUNT} 份连同 INDEX.md 全部在 AGENTS.md 索引中，两份都没有死链；AGENTS.md ${SIZE_NOW} 字节（上限 ${SIZE_LIMIT}）"
