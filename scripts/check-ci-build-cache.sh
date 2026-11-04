#!/usr/bin/env bash
# CI 的 .build 缓存：不会拿旧的目标文件去测新代码，也真的省得下编译。
#
# CI 先用 scripts/ci-stable-mtimes.py 把入库文件的修改时间按内容设好，再恢复 main 上存的 .build
# （docs/bugfixes/2026-11-04-ci-build-cache-never-saved-a-compile.md）。这套做法押在 SwiftPM 的一个行为上：它比的是修改时间
# 「和上次记下的一不一样」，不是「是不是比目标文件新」。按内容算出来的时间多半比上次编译早 —— 要是哪天 SwiftPM 改成只认
# 「更新」，改过的文件就不会重编，CI 拿旧的目标文件测新代码、一路假绿。所以在临时目录里建一个三个文件的小包，照 CI 的样子
# 真走一遍：
#   一、改了内容、修改时间拨回 2001 年的文件照样重编，跑出来是新值（反过来什么都没改再编，0 个文件重编）；
#   二、像 CI 一样换一份新 checkout（同一个路径，新的 inode、新的修改时间）、跑 ci-stable-mtimes.py、放回 main 存的 .build：
#       a. 同一个提交：0 个文件重编；b. 新提交改了一个文件（PR 上真正的样子）：那个文件重编、跑出新值；
#   三、对照：同一个提交换一份新 checkout 但不跑 ci-stable-mtimes.py：照样全部重编（证明二 a 测得出区别，也就是以前 CI 的样子）。
#
# 用法：scripts/check-ci-build-cache.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
SRC="${WORK}/src"
PKG="${WORK}/pkg"
FAILED=0
fail() {
  echo "✗ $*" >&2
  FAILED=1
}

mkdir -p "${SRC}/Sources/Probe"
cat >"${SRC}/Package.swift" <<'EOF'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Probe", targets: [.executableTarget(name: "Probe")])
EOF
printf '%s\n' 'let greeting = "OLD-VALUE-0001"' >"${SRC}/Sources/Probe/A.swift"
printf '%s\n' 'func helper() -> Int { 42 }' >"${SRC}/Sources/Probe/B.swift"
printf '%s\n' 'print(greeting)' 'print(helper())' >"${SRC}/Sources/Probe/main.swift"
git -C "${SRC}" init -q -b main
git -C "${SRC}" -c user.name=check -c user.email=check@example.invalid -c commit.gpgsign=false add -A
git -C "${SRC}" -c user.name=check -c user.email=check@example.invalid -c commit.gpgsign=false commit -q -m base

# 编一遍，打印这一遍重编了几样（Compiling / Emitting module 的行数）。编不过就把输出倒出来、整条检查红。
compiled() {
  local out
  if ! out="$(cd "${PKG}" && swift build --arch arm64 2>&1)"; then
    printf '%s\n' "${out}" >&2
    echo "✗ 小包编不过（上面是 swift build 的输出）" >&2
    exit 1
  fi
  { grep -cE 'Compiling|Emitting module' <<<"${out}" || true; }
}
run_probe() {
  "${PKG}/.build/arm64-apple-macosx/debug/Probe" | head -n 1
}
# 换一份新 checkout，放在同一个路径（.build 里的模块缓存记着绝对路径，CI 上的检出目录也每次都一样）。旧的挪开、不删。
GEN=0
fresh_checkout() {
  if [ -d "${PKG}" ]; then
    GEN=$((GEN + 1))
    mv "${PKG}" "${WORK}/pkg-old-${GEN}"
  fi
  git clone -q "${SRC}" "${PKG}"
}
stable_mtimes() {
  python3 "${ROOT}/scripts/ci-stable-mtimes.py" "${PKG}" >/dev/null
}

# ---- 一、改了内容、时间拨回 2001 年照样重编 ----
fresh_checkout
stable_mtimes
cold="$(compiled)"
again="$(compiled)"
if [ "${cold}" -lt 1 ] || [ "${again}" != "0" ]; then
  fail "小包冷编了 ${cold} 样、什么都没改再编了 ${again} 样（应该是 ≥1 和 0）：数法不对，这条检查测不出东西"
fi
printf '%s\n' 'let greeting = "NEW-VALUE-0002"' >"${PKG}/Sources/Probe/A.swift"
touch -t 200101010000 "${PKG}/Sources/Probe/A.swift"
changed="$(compiled)"
output="$(run_probe)"
if [ "${changed}" -lt 1 ] || [ "${output}" != "NEW-VALUE-0002" ]; then
  fail "A.swift 改了内容、修改时间比上次编译早：重编了 ${changed} 样、跑出来是「${output}」。SwiftPM 不再按「一不一样」判断了 —— CI 的 .build 缓存会拿旧的目标文件测新代码，先把 ci-stable-mtimes.py 那一步撤掉"
fi

# ---- 二、新 checkout + 按内容设时间 + 放回 main 上存的 .build ----
# 先照 main 的样子编一份存起来（base 提交、按内容设了时间）。
fresh_checkout
stable_mtimes
compiled >/dev/null
mv "${PKG}/.build" "${WORK}/main-build"
# 二 a：同一个提交的新 checkout，什么都没改：0 个文件重编。
fresh_checkout
stable_mtimes
cp -R "${WORK}/main-build" "${PKG}/.build"
restored="$(compiled)"
if [ "${restored}" != "0" ]; then
  fail "新 checkout、按内容设了修改时间、放回 .build 之后又重编了 ${restored} 样（应该是 0）：CI 的缓存省不下编译"
fi
# 三、对照：同一个提交的新 checkout，不按内容设时间：照样全部重编（以前 CI 就是这样）。
fresh_checkout
cp -R "${WORK}/main-build" "${PKG}/.build"
control="$(compiled)"
if [ "${control}" -lt 1 ]; then
  fail "对照组（新 checkout、没按内容设时间）放回 .build 之后一样都没重编：第二节测不出 ci-stable-mtimes.py 管不管用，改这条检查"
fi
# 二 b：PR 上真正的样子 —— 新提交改了 A.swift，新 checkout、按内容设时间、放回 main 的 .build：A.swift 必须重编、跑出新值。
# 这一节验的是 ci-stable-mtimes.py 本身：内容变了，算出来的时间就得跟着变（哪天它把所有文件设成同一个时间，这里红）。
printf '%s\n' 'let greeting = "NEW-VALUE-0003"' >"${SRC}/Sources/Probe/A.swift"
git -C "${SRC}" -c user.name=check -c user.email=check@example.invalid -c commit.gpgsign=false commit -q -am change
fresh_checkout
stable_mtimes
cp -R "${WORK}/main-build" "${PKG}/.build"
pr_changed="$(compiled)"
pr_output="$(run_probe)"
if [ "${pr_changed}" -lt 1 ] || [ "${pr_output}" != "NEW-VALUE-0003" ]; then
  fail "新提交改了 A.swift、放回 main 的 .build：重编了 ${pr_changed} 样、跑出来是「${pr_output}」（应该重编、是 NEW-VALUE-0003）：拿旧的目标文件测了新代码"
fi

if [ "${FAILED}" -ne 0 ]; then
  exit 1
fi
echo "✓ ci-build-cache：改过的文件时间拨早了照样重编；新 checkout 按内容设时间、放回 .build 重编 0 样（不设时间是 ${control} 样）"
