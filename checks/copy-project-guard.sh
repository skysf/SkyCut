#!/usr/bin/env bash
# 守卫：冒烟用的 copy-project.sh 不许把「下载」「桌面」「文稿」、家目录、根目录整个拷走，太大的文件夹也不拷。
#
# 由来（docs/bugfixes/2026-10-17-copy-project-copied-all-of-downloads.md）：这个脚本把工程所在的整个文件夹当素材目录拷，
# 一份直接放在「下载」根目录的工程让它拷了 45 GB、把磁盘写满。这里真跑它：在一个假的家目录里造工程，
# 放在「下载」根目录的、放在超过上限的文件夹里的都必须被拒、一个文件都不拷；放在自己文件夹里的照常拷、路径改好。
#
# 用法：checks/copy-project-guard.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SCRIPT="$(pwd)/scripts/gui-smoke/in-process/copy-project.sh"
FAILED=0
fail() {
  echo "✗ copy-project-guard：$1" >&2
  FAILED=1
}
[ -f "${SCRIPT}" ] || { fail "找不到 ${SCRIPT}：脚本挪走了 —— 同步改这里"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
FAKE_HOME="${WORK}/home"
mkdir -p "${FAKE_HOME}/Downloads/clips" "${FAKE_HOME}/Projects/Trip"
printf 'x' > "${FAKE_HOME}/Downloads/clips/a.mp4"
printf 'x' > "${FAKE_HOME}/Projects/Trip/a.mp4"
printf '{"media":[{"path":"%s"}]}' "${FAKE_HOME}/Downloads/clips/a.mp4" > "${FAKE_HOME}/Downloads/Edit.srtflowproj"
printf '{"media":[{"path":"%s"}]}' "${FAKE_HOME}/Projects/Trip/a.mp4" > "${FAKE_HOME}/Projects/Trip/Edit.srtflowproj"

# 1. 工程直接放在「下载」根目录：拒绝、退出码 2、目标目录不出现。
DST="${WORK}/out-downloads"
HOME="${FAKE_HOME}" /bin/bash "${SCRIPT}" "${FAKE_HOME}/Downloads/Edit.srtflowproj" "${DST}" >/dev/null 2>&1
CODE=$?
[ "${CODE}" -eq 2 ] || fail "工程放在「下载」根目录时没拒绝（退出码 ${CODE}）：会把整个下载文件夹拷走"
[ ! -e "${DST}" ] || fail "工程放在「下载」根目录时还是拷了东西（${DST} 出现了）"

# 2. 放在自己的文件夹里、但超过上限（上限设成 0 GB，任何文件夹都超）：拒绝、不拷。
DST="${WORK}/out-big"
HOME="${FAKE_HOME}" SRTFLOW_COPY_PROJECT_MAX_GB=0 /bin/bash "${SCRIPT}" "${FAKE_HOME}/Projects/Trip/Edit.srtflowproj" "${DST}" >/dev/null 2>&1
CODE=$?
[ "${CODE}" -eq 2 ] || fail "超过上限的文件夹没拒绝（退出码 ${CODE}）"
[ ! -e "${DST}" ] || fail "超过上限的文件夹还是拷了东西"

# 3. 放在自己的文件夹里、没超上限：照常拷，路径改到目标目录里。
DST="${WORK}/out-ok"
HOME="${FAKE_HOME}" /bin/bash "${SCRIPT}" "${FAKE_HOME}/Projects/Trip/Edit.srtflowproj" "${DST}" >/dev/null 2>&1 \
  || fail "放在自己文件夹里的工程拷不动了"
[ -f "${DST}/a.mp4" ] || fail "素材没跟着拷过去"
grep -q "${DST}/a.mp4" "${DST}/Edit.srtflowproj" 2>/dev/null || fail "拷过去的工程里素材路径没改到目标目录"

if [ "${FAILED}" = "0" ]; then
  echo "✓ copy-project-guard：「下载」根目录的工程、超过上限的文件夹都拒绝且一个文件都不拷；自己文件夹里的照常拷、路径改好"
fi
exit "${FAILED}"
