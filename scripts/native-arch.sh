# 被检查的入口脚本 source（不单独跑）：在 Rosetta 下（x86_64 进程）被起来的，就换成原生 arm64 的 /bin/bash 重新跑自己。
#
# 为什么：Rosetta 下起的进程，它再起的子进程也优先挑 x86_64 那一半 —— 检查里的几千个 grep / awk / perl、编译器全都跟着
# 走翻译，又慢又烫。2026-11-04 在用户的 M1 上量的：同一条守卫 hover-pointer-style 33.3 秒 → 原生 6.1 秒；全部扫描守卫
# 6–7 分钟 → 89 秒。这台机器上有两个来源：Claude Code 给命令起的 shell 是翻译的（终端、登录 shell、claude 本身都是原生），
# PATH 最前面的 /usr/local/bin/bash 是 Intel 版 Homebrew 装的、只有 x86_64（`#!/usr/bin/env bash` 找到的就是它）。
# 详见 docs/build/build-and-packaging.md「本地怎么跑检查」。
#
# 用法（放在入口脚本里 `cd` 之前，"$0" 还是调用时的路径）：
#   . "$(dirname "$0")/native-arch.sh"
# CI 的 runner 本来就是原生 arm64、Intel 的 Mac 没有这个 sysctl：两种都什么也不做。
# SRTFLOW_NATIVE_REEXEC 防止万一 arch 起来的还是翻译的、来回重跑。
if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = "1" ] && [ -z "${SRTFLOW_NATIVE_REEXEC:-}" ]; then
  export SRTFLOW_NATIVE_REEXEC=1
  exec arch -arm64 /bin/bash "$0" "$@"
fi
