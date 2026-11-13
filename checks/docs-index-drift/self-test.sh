#!/usr/bin/env bash
# checks/docs-index-drift.sh 的自测：在一份最小的副本上一个场景一个场景跑守卫，该红的要红在对的那一条上、该绿的要绿。
#
# 为什么要有：这条守卫被绕过三轮（D1 写的 → 复审修 → Codex 又跑出 4 类），每一轮都是「换一种 Markdown 里合法的写法，
# 守卫认不出就当没看见」。场景里的每一条都是真被绕过去过、或者写守卫的人当对手试出来的写法；以后谁改这条守卫，
# 先过这一道（docs/bugfixes/2026-11-13-index-entry-limit-bypassed.md 的「后续」）。
#
# **不单独跑**：`checks/docs-index-drift.sh --self-test [选项]` 转到这里（第一个参数是主文件的绝对路径）。
#   （不带选项）        断言：有一个场景对不上就退出 1。CI 上 scripts/check-all.sh 跑的是这个。
#   --table            不断言，一个场景打一行「组 ␟ 场景 ␟ 该怎样 ␟ 实际退出码 ␟ 红在该红的那一条上没有」。
#   --against <守卫>    拿另一份单文件的守卫（比如改之前的那一版）跑同一批场景，照 --table 打表：写报告里
#                      「改之前 / 改之后」那一栏用。老守卫要的是老顺序，所以基线的 INDEX.md 换成按文件名从大到小，
#                      只对新顺序才有意义的那一组（order）跳过。
#
# 管什么：造最小副本（make_base）、改副本的小工具（edit、fill_to …）、跑一个场景（scenario）、最后的结论。
# 不管什么：场景本身 —— 在 scenarios-links.sh（链接怎么认）、scenarios-shapes.sh（条目和小节的形状）、
#           scenarios-order.sh（顺序、重复、磁盘上的文件）。加场景：在对应的文件里加一行 scenario。
set -euo pipefail

GUARD="${1:?第一个参数是 docs-index-drift.sh 的路径（由 --self-test 传进来）}"
shift
PARTS="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=checks/docs-index-drift/config.sh
. "${PARTS}/config.sh"

MODE="assert"
OTHER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --table) MODE="table"; shift ;;
    --against)
      OTHER="${2:-}"
      [ -f "${OTHER}" ] || { echo "✗ --against 后面要跟一份守卫脚本" >&2; exit 2; }
      MODE="table"; shift 2 ;;
    *) echo "✗ 不认识的参数：${1}" >&2; exit 2 ;;
  esac
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/docs-index-drift-self-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
SEP="$(printf '\037')"
TOTAL=0
WRONG=0
GROUP=""

# ── 最小副本 ──────────────────────────────────────────────────────────
# 小节的标题照 config.sh 的名单（改了名单要同步改这里：基线场景会先红）；写法照真的 AGENTS.md —— 编号列表带续行、
# 嵌套的列表、不设上限的小节里的表格、行内代码里的尖括号 / 方括号 / 反斜杠 / 括号里的路径，这些都得是绿的。
# beta 只在架构索引里链了一次（拿它试「唯一的索引被藏起来」）；四份案例按新顺序是 apple、kiwi、mango、zebra，
# 日期故意不顺（01-09、03-01、01-05、02-01），按日期排、按文件名从大到小排都和它不一样。
make_base() {
  local root="$1" order="$2"
  mkdir -p "${root}/docs/architecture" "${root}/docs/build" "${root}/docs/plans" "${root}/docs/bugfixes"
  printf '# readme\n' > "${root}/README.md"
  printf '# alpha\n' > "${root}/docs/architecture/alpha.md"
  printf '# beta\n' > "${root}/docs/architecture/beta.md"
  printf '# gamma\n' > "${root}/docs/build/gamma.md"
  printf '# plan\n' > "${root}/docs/plans/2026-01-01-some-plan.md"
  printf '# template\n' > "${root}/docs/bugfixes/TEMPLATE.md"
  for name in 2026-01-09-apple-case 2026-03-01-kiwi-case 2026-01-05-mango-case 2026-02-01-zebra-case; do
    printf '# case\n' > "${root}/docs/bugfixes/${name}.md"
  done
  cat > "${root}/AGENTS.md" <<'MD'
# AGENTS.md — 自测用的最小副本

这里只有两类内容：规则和索引。行内代码里可以有 `<尖括号>`、`[方括号]`、`\N`、`a | b` 和 `(docs/x.md)`。

## 唯一入口约定

- 规则一：不建第二套入口（`CLAUDE.md`、`.cursorrules`）。
- 规则二：细节写进 `docs/architecture/`。

## 开始任务前

1. 先读「全局规则」。
2. 修改后跑 `scripts/check-local.sh <相关检查>`：一项一项跑，
   完整的交给 CI。

## 全局规则（必须遵守）

### Bug 修复、守卫与文档

1. 修复任何 bug 后，必须按
   [Bugfix 模板](docs/bugfixes/TEMPLATE.md) 新增 `YYYY-MM-DD-<slug>.md`，并在
   [Bug 修复案例索引](docs/bugfixes/INDEX.md) 补一行。
2. 代码要模块化：
   - 一个文件只管一件事。
   - 超了就拆，跑 `checks/source-file-size.sh --update`
     把基线改小。

## 文档目录职责

| 目录 | 放什么 |
| --- | --- |
| `docs/architecture/` | 长期约束 |
| `docs/bugfixes/` | 案例 |

## 按修改范围选必读文档

| 修改范围 | 动手前必读 |
| --- | --- |
| alpha 那一块（`AlphaThing`） | [Alpha](docs/architecture/alpha.md)（只能这样做）、[芒果案例](docs/bugfixes/2026-01-05-mango-case.md) |

## 构建与检查入口

- 构建与打包：[Gamma](docs/build/gamma.md)。
- `checks/docs-index-drift.sh` — 两份索引是全的。

## 规划与实施报告索引

每份一行：链接 + 一句话。

### 方案（docs/plans/）

- [某方案](docs/plans/2026-01-01-some-plan.md) — 拍过的板。

## 架构与长期约束索引

每份一行：链接 + 这份文档管什么。

- [Alpha](docs/architecture/alpha.md) — 管 alpha。
- [Beta](docs/architecture/beta.md) — 管 beta。
- [Gamma](docs/build/gamma.md) — 管 gamma。

## Bug 修复案例索引

全部案例的索引在 [docs/bugfixes/INDEX.md](docs/bugfixes/INDEX.md)：每条一行。

- 修 bug 之前先在那份索引里搜一遍。
- 新案例照 [Bugfix 模板](docs/bugfixes/TEMPLATE.md) 写。

## 根目录文档

- [README.md](README.md) — 项目介绍。
MD
  {
    printf '%s\n' '# Bug 修复案例索引' '' '每条一行：日期 + 链接 + 一句教训。' '' \
      '怎么排见[Alpha](../architecture/alpha.md)。' '' '- [Bugfix 模板](TEMPLATE.md) — 新案例必须使用的结构。'
    if [ "${order}" = "old" ]; then
      printf '%s\n' "${E_KIWI}" "${E_ZEBRA}" "${E_APPLE}" "${E_MANGO}"
    else
      printf '%s\n' "${E_APPLE}" "${E_KIWI}" "${E_MANGO}" "${E_ZEBRA}"
    fi
  } > "${root}/docs/bugfixes/INDEX.md"
  # 老守卫把行内代码里括号括着的路径也当链接（报死链）：给它跑的基线去掉那一处，不然每个场景都是红的、看不出差别。
  if [ "${order}" = "old" ]; then
    edit sub "${root}/AGENTS.md" ' 和 `(docs/x.md)`' ''
  fi
}
E_APPLE='- [2026-01-09 苹果案例](2026-01-09-apple-case.md) — 教训一。'
E_KIWI='- [2026-03-01 奇异果案例](2026-03-01-kiwi-case.md) — 教训二。'
E_MANGO='- [2026-01-05 芒果案例](2026-01-05-mango-case.md) — 教训三。'
E_ZEBRA='- [2026-02-01 斑马案例](2026-02-01-zebra-case.md) — 教训四。'
E_ALPHA='- [Alpha](docs/architecture/alpha.md) — 管 alpha。'
E_BETA='- [Beta](docs/architecture/beta.md) — 管 beta。'
A="AGENTS.md"
B="docs/bugfixes/INDEX.md"

# ── 改副本的小工具（都在副本的根目录里跑；找不到要改的那一行就失败 —— 没改成的场景不能算跑过）──
# edit <after|before|swap|drop|sub> <文件> <锚：这一行里有的一段字> [新的字，可以多行]
#   after / before 在那一行后面 / 前面加；swap 整行换掉；drop 删掉那一行；sub 只把那一段字换掉。只动第一处。
edit() {
  local op="$1" file="$2"
  if DRIFT_T_ANCHOR="$3" DRIFT_T_TEXT="${4:-}" LC_ALL=C awk -v op="${op}" '
    BEGIN { a = ENVIRON["DRIFT_T_ANCHOR"]; t = ENVIRON["DRIFT_T_TEXT"] }
    !done && index($0, a) {
      done = 1
      if (op == "after") { print; print t }
      else if (op == "before") { print t; print }
      else if (op == "swap") print t
      else if (op == "sub") { p = index($0, a); print substr($0, 1, p - 1) t substr($0, p + length(a)) }
      next
    }
    { print }
    END { if (!done) exit 3 }' "${file}" > "${file}.edit"; then
    mv "${file}.edit" "${file}"
  else
    rm -f "${file}.edit"
    echo "edit ${op}：${file} 里找不到「$3」" >&2
    return 3
  fi
}
bytes_of() { printf '%s' "$1" | wc -c | tr -d ' '; }
# fill_to <字节数> <开头> —— 把「开头」用汉字（3 字节一个）和 x 补到正好那么多字节。
fill_to() {
  local want="$1" text="$2" have
  have="$(bytes_of "${text}")"
  while [ $((want - have)) -ge 3 ]; do text="${text}字"; have=$((have + 3)); done
  while [ "${have}" -lt "${want}" ]; do text="${text}x"; have=$((have + 1)); done
  printf '%s' "${text}"
}
# pad_agents <字节数> —— 往不设上限的小节里加几行，把 AGENTS.md 补到正好那么多字节。
pad_agents() {
  local want="$1" have need
  have="$(wc -c < "${A}" | tr -d ' ')"
  need=$((want - have))
  [ "${need}" -ge 3 ] || { echo "pad_agents：已经有 ${have} 字节，补不到 ${want}" >&2; return 3; }
  edit after "${A}" "规则二" "$(LC_ALL=C awk -v need="${need}" 'BEGIN {
    while (need > 0) {
      chunk = (need > 1000 ? 1000 : need)
      if (need - chunk > 0 && need - chunk < 3) chunk -= 3
      line = "- "
      for (i = 3; i < chunk; i++) line = line "x"
      printf "%s%s", sep, line
      sep = "\n"; need -= chunk
    }
  }')"
}
size_limit() { echo $((SIZE_BASE_BYTES + SIZE_PER_DOC_BYTES * $1)); }

# ── 跑一个场景 ────────────────────────────────────────────────────────
# scenario <green|red> <红在哪个代号上，绿的写 -> <场景的名字> <改副本的命令…>
# 前面写 RUN_LOCALE=en_US.UTF-8 就在那个 locale 下跑守卫（守卫自己把 awk / sort / grep 钉在 LC_ALL=C，结果不该变）。
run_guard() {
  if [ -n "${OTHER}" ]; then
    mkdir -p "$1/checks"
    cp "${OTHER}" "$1/checks/docs-index-drift.sh"
    OUT="$(LC_ALL="${RUN_LOCALE:-${LC_ALL:-}}" /bin/bash "$1/checks/docs-index-drift.sh" 2>&1)" && RC=0 || RC=$?
  else
    OUT="$(LC_ALL="${RUN_LOCALE:-${LC_ALL:-}}" /bin/bash "${GUARD}" --root "$1" 2>&1)" && RC=0 || RC=$?
  fi
}
scenario() {
  local expect="$1" code="$2" name="$3" hit="-" verdict
  shift 3
  if [ -n "${OTHER}" ] && [ "${GROUP}" = "order" ]; then return 0; fi
  rm -rf "${WORK}/run"
  cp -R "${WORK}/base" "${WORK}/run"
  if ! (cd "${WORK}/run" && "$@"); then
    echo "✗ 自测自己坏了：场景「${name}」的改动没做成（上面是原因）" >&2
    WRONG=$((WRONG + 1)); TOTAL=$((TOTAL + 1))
    return 0
  fi
  run_guard "${WORK}/run"
  TOTAL=$((TOTAL + 1))
  if [ "${expect}" = "red" ]; then
    case "${OUT}" in *"[${code}]"*) hit="yes" ;; *) hit="no" ;; esac
  fi
  if [ "${MODE}" = "table" ]; then
    printf '%s\n' "${GROUP}${SEP}${name}${SEP}${expect}${SEP}${RC}${SEP}${hit}"
    return 0
  fi
  verdict="ok"
  if [ "${expect}" = "green" ] && [ "${RC}" -ne 0 ]; then verdict="该绿的红了（退出 ${RC}）"; fi
  if [ "${expect}" = "red" ] && [ "${RC}" -ne 1 ]; then verdict="该红的没红（退出 ${RC}）"; fi
  if [ "${expect}" = "red" ] && [ "${RC}" -eq 1 ] && [ "${hit}" != "yes" ]; then verdict="红了，但不是红在 [${code}] 上"; fi
  if [ "${verdict}" != "ok" ]; then
    WRONG=$((WRONG + 1))
    echo "✗ 场景「${name}」：${verdict}" >&2
    printf '%s\n' "${OUT}" | sed 's/^/      /' | cut -c1-300 | head -n 8 >&2
  fi
}
keep() { :; }   # 什么都不改

if [ -n "${OTHER}" ]; then make_base "${WORK}/base" old; else make_base "${WORK}/base" new; fi
for part in links shapes order; do
  [ -f "${PARTS}/scenarios-${part}.sh" ] || { echo "✗ 找不到 ${PARTS}/scenarios-${part}.sh：自测的场景没了" >&2; exit 1; }
  # shellcheck source=/dev/null
  . "${PARTS}/scenarios-${part}.sh"
done

if [ "${MODE}" = "table" ]; then
  exit 0
fi
if [ "${TOTAL}" -lt 100 ]; then
  echo "✗ docs-index-drift 自测只跑了 ${TOTAL} 个场景（该有一百多个）：场景文件读漏了就是假绿" >&2
  exit 1
fi
if [ "${WRONG}" -ne 0 ]; then
  echo "✗ docs-index-drift 自测：${TOTAL} 个场景里 ${WRONG} 个对不上" >&2
  exit 1
fi
echo "✓ docs-index-drift 自测：${TOTAL} 个场景，该红的都红在对的那一条上、该绿的都绿"
