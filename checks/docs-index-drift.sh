#!/usr/bin/env bash
# 扫描守卫：AGENTS.md 是**唯一入口**，那它的索引就必须是全的。
#
# AGENTS.md 只保留「全局规则」+「按任务查文档的索引」，细节全在 docs/ 下。
# 这套分工要成立，有三件事必须一直为真：
#
#   1. docs/ 下的每一份文档都能从 AGENTS.md 找到 —— 否则写了等于没写：
#      别的代理（Codex / Kimi / Gemini…）只读 AGENTS.md，索引里没有的文档它们
#      永远不会打开。**这不是假设，是已经发生过的事**：2026-09-20 那四份案例
#      （播放头断线、转场遮罩漂移、转场预览与成片分叉、悬停光标卡住）写完之后
#      都没进索引，一直到 2026-09-21 才被发现，而其中「播放头断线」那份正好是
#      当天新 bug 的孪生兄弟 —— 索引里有的话，横向那一半当场就能想到。
#   2. 索引里的链接都指向真实存在的文件 —— 文档改名/挪窝之后留下的死链，比没有
#      索引更坏：它会让人以为查过了。
#
#   3. 索引每条只有「链接 + 一句话」，整份不再长回去 —— AGENTS.md 每个会话一开就整份读进来。
#      2026-11-13 之前每条索引都带着一大段摘要：339 KB，一个会话光读它就约 14.7 万 token，而规则本身
#      只有 11 KB。那天收成每条一行（153 KB），细节留在各自的文档里。两道闸：
#        · 以 "- [" 开头的索引行，每条不超过 ENTRY_MAX_BYTES；
#        · 整份不超过 SIZE_BASE_BYTES + SIZE_PER_DOC_BYTES × docs/ 下的文档数 —— 多一份文档多一条索引是应该的，
#          所以上限跟着文档数走，不用每加一份文档就来改数字；必读表、检查入口这些不随文档数涨的部分算在基数里。
#      超了的修法是把摘要挪进它指向的文档，不是抬这三个数。
#
# 「手抄的清单会漂」在这个仓库已经栽过两回（见
# docs/bugfixes/2026-09-18-check-script-source-list-drift.md 与
# docs/bugfixes/2026-09-21-source-list-guard-only-watched-the-hub.md），
# 分类目录职责见 AGENTS.md 的「文档目录职责」。

set -euo pipefail
cd "$(dirname "$0")/.."

INDEX="AGENTS.md"
FAILED=0

fail() {
  echo "✗ $1" >&2
  FAILED=1
}

[ -f "$INDEX" ] || { echo "✗ 找不到 ${INDEX}：唯一入口没了，守卫失去目标" >&2; exit 1; }

# AGENTS.md 里所有形如 (path.md) 的链接目标，去重。
LINKS="$(grep -o '([^()]*\.md)' "$INDEX" | tr -d '()' | sort -u)"

# ── 1. docs/ 下的每一份 .md 都必须被索引 ──────────────────────────────
while IFS= read -r doc; do
  grep -qx "$doc" <<<"$LINKS" \
    || fail "${doc} 没有出现在 ${INDEX} 的索引里：只读 AGENTS.md 的代理永远打不开它 —— 按「文档目录职责」补一行到对应的索引小节"
done < <(find docs -name '*.md' | sort)

# ── 2. 索引里的链接都必须指向真实文件 ─────────────────────────────────
# 只管仓库内的相对链接；http(s):// 之类交给别处。
while IFS= read -r link; do
  [ -n "$link" ] || continue
  case "$link" in
    http://*|https://*) continue ;;
  esac
  [ -f "$link" ] \
    || fail "${INDEX} 指向了不存在的 ${link}：死链比没有索引更坏 —— 它会让人以为查过了"
done <<< "$LINKS"

# ── 3. 索引每条一行，整份不许再长回去 ─────────────────────────────────
# 数字是 2026-11-13 收短之后定的：当时 400 份文档、153,033 字节（最长的一条索引 303 字节），上限 158,000。
ENTRY_MAX_BYTES=400
SIZE_BASE_BYTES=58000
SIZE_PER_DOC_BYTES=250

# 3a. 一条索引 = 以 "- [" 开头的一行。LC_ALL=C 下 awk 的 length 数的是字节。
LONG_ENTRIES="$(LC_ALL=C awk -v max="${ENTRY_MAX_BYTES}" 'index($0, "- [") == 1 && length($0) > max { printf "%d:%d\n", NR, length($0) }' "$INDEX")"
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  fail "${INDEX} 第 ${hit%%:*} 行这条索引有 ${hit##*:} 字节，超过 ${ENTRY_MAX_BYTES}：索引只写「链接 + 一句话」，摘要和细节写进它指向的文档"
done <<< "$LONG_ENTRIES"

# 3b. 整份的大小。
DOC_COUNT="$(find docs -name '*.md' | wc -l | tr -d ' ')"
SIZE_NOW="$(wc -c < "$INDEX" | tr -d ' ')"
SIZE_LIMIT=$((SIZE_BASE_BYTES + SIZE_PER_DOC_BYTES * DOC_COUNT))
if [ "${SIZE_NOW}" -gt "${SIZE_LIMIT}" ]; then
  fail "${INDEX} 有 ${SIZE_NOW} 字节，超过上限 ${SIZE_LIMIT}（${SIZE_BASE_BYTES} + ${SIZE_PER_DOC_BYTES} × ${DOC_COUNT} 份文档）：每个会话一开就整份读它 —— 必读表右列只留链接和一两条硬约束、检查入口每个脚本一行、索引每条一句话，细节挪进文档（docs/testing/check-catalog.md 或对应的架构文档），别抬上限"
fi

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "✓ docs-index-drift：docs/ 下 ${DOC_COUNT} 份文档全部在 AGENTS.md 索引中，且无死链；AGENTS.md ${SIZE_NOW} 字节（上限 ${SIZE_LIMIT}）"
