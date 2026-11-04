#!/usr/bin/env bash
# 扫描守卫：本地跑检查的三个入口（check-local / check-guards / check-all）都用原生 arm64 的 /bin/bash 跑。
#
# 为什么（docs/build/build-and-packaging.md「本地怎么跑检查」）：在 Rosetta 下起的检查，连同它起的几千个 grep / awk、
# 编译器全走翻译。2026-11-04 在用户的 M1 上：全部扫描守卫 6–7 分钟 → 原生 /bin/bash 89 秒，笔记本也不再烫。两个来源：
# Claude Code 给命令起的 shell 是翻译的；PATH 上的 bash 是 Intel 版 Homebrew 的、只有 x86_64。CI 的 runner 本来就是原生，
# 所以这件事 CI 上看不出来，只能这里钉着：
#   一、scripts/native-arch.sh 在 Rosetta 下换成 `arch -arm64 /bin/bash` 重跑自己、有防来回重跑的标记；
#   二、三个入口在 `cd` 之前 source 它（"$0" 还是调用时的路径）；
#   三、check-guards / check-local 起检查用 /bin/bash，不用 PATH 上的 bash（同 check-all 的 run_check，也和 CI 同一个 3.2）；
#   四、这台机器装了 Rosetta 就真跑一遍：x86_64 起的探针 source 它之后报原生；没 source 的对照组报翻译。
#       没装 Rosetta（arch -x86_64 起不来）就照实说这一节没跑。
set -euo pipefail
cd "$(dirname "$0")/.."
FAILED=0
fail() {
  echo "✗ $*" >&2
  FAILED=1
}

HELPER="scripts/native-arch.sh"
# ---- 一、helper 本身 ----
for needle in 'sysctl -n sysctl.proc_translated' 'exec arch -arm64 /bin/bash "$0" "$@"' 'SRTFLOW_NATIVE_REEXEC'; do
  if [ "$({ grep -cF -- "${needle}" "${HELPER}" || true; })" = "0" ]; then
    fail "${HELPER} 里没有「${needle}」：在 Rosetta 下不会换成原生 arm64 重跑"
  fi
done

# ---- 二、三个入口在 cd 之前 source 它 ----
SOURCE_LINE='. "$(dirname "$0")/native-arch.sh"'
CD_LINE='cd "$(dirname "$0")/.."'
for entry in scripts/check-local.sh scripts/check-guards.sh scripts/check-all.sh; do
  src_at="$(grep -nF -- "${SOURCE_LINE}" "${entry}" | head -1 | cut -d: -f1 || true)"
  cd_at="$(grep -nF -- "${CD_LINE}" "${entry}" | head -1 | cut -d: -f1 || true)"
  if [ -z "${src_at}" ]; then
    fail "${entry} 没有 source ${HELPER}：从 Rosetta 下的终端起，整趟检查都走翻译"
  elif [ -z "${cd_at}" ] || [ "${src_at}" -gt "${cd_at}" ]; then
    fail "${entry} 第 ${src_at} 行 source ${HELPER}，要放在第一个 cd（第 ${cd_at:-?} 行）之前：cd 之后相对的 \$0 就找不到自己了"
  fi
done

# ---- 三、起检查用 /bin/bash ----
if [ "$({ grep -cF -- '/bin/bash ${guard}' scripts/check-guards.sh || true; })" != "1" ]; then
  fail "scripts/check-guards.sh 起守卫要用 /bin/bash \${guard}（PATH 上的 bash 可能是 5.x，还可能只有 x86_64）"
fi
BARE="$({ grep -nE '(^|[^/[:alnum:]_])bash +"?\$\{?(guard|name)' scripts/check-guards.sh scripts/check-local.sh || true; })"
if [ -n "${BARE}" ]; then
  fail "起检查用了 PATH 上的 bash，要写 /bin/bash：${BARE}"
fi

# ---- 四、装了 Rosetta 就真跑一遍 ----
if arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
  PROBE_DIR="$(mktemp -d)"
  trap 'rm -rf "${PROBE_DIR}"' EXIT
  cp "${HELPER}" "${PROBE_DIR}/native-arch.sh"
  printf '%s\n' "${SOURCE_LINE}" 'sysctl -n sysctl.proc_translated' >"${PROBE_DIR}/probe.sh"
  printf '%s\n' 'sysctl -n sysctl.proc_translated' >"${PROBE_DIR}/control.sh"
  control="$(env -u SRTFLOW_NATIVE_REEXEC arch -x86_64 /bin/bash "${PROBE_DIR}/control.sh")"
  probe="$(env -u SRTFLOW_NATIVE_REEXEC arch -x86_64 /bin/bash "${PROBE_DIR}/probe.sh")"
  if [ "${control}" != "1" ]; then
    fail "对照组（x86_64 起、没 source）报 proc_translated=${control}，应该是 1：这一节测不出翻译，改这条守卫"
  elif [ "${probe}" != "0" ]; then
    fail "x86_64 起的探针 source ${HELPER} 之后报 proc_translated=${probe}，应该是 0（换成原生了）"
  fi
  RAN="；Rosetta 下真跑过：x86_64 起的探针换成了原生"
else
  RAN="；这台没装 Rosetta，第四节（真跑一遍）没跑"
fi

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
echo "✓ native-local-checks：三个入口都在 cd 之前换成原生 arm64、起检查用 /bin/bash${RAN}"
