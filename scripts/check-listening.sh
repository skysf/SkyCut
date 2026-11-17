#!/usr/bin/env bash
# 「听声音的引擎」第 2、3 步的纯计算自检（docs/architecture/listening-engine.md「守卫」）：
#   - ESTOI 和研究时自己写的 numpy 版逐数对账：同一份合成输入，每个数差 ≤ 1e-9（实测最大 2.6e-11）；
#   - ESTOI 论文该有的性质：同一信号 = 1、整体增益不变、加噪随信噪比单调、134 Hz 以下看不见、太短 / 长度不一样回 nil；
#   - 「拿掉谁涨多少」和 20–150 Hz 另报；原声的九个特征（同样和 numpy 版对账）和描述；
#   - 地基：任意长度的 DFT 对定义式、整段 FFT 截断的重采样、电平的口径。
# 全用合成的信号（类语音、噪声、正弦、敲击），不要 ffmpeg、不要 App、不碰网络。
#
# 用法：
#   scripts/check-listening.sh                 # 跑自检
#   scripts/check-listening.sh --dump <目录>   # 只把对账的输入写出来（重算 Python 对照值时用，见架构文档「和 Python 版对」）
set -euo pipefail
cd "$(dirname "$0")/.."

TRIPLE="arm64-apple-macosx15.0"
OUT="$(mktemp -d)/listeningcheck"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

echo "==> 编译自检二进制"
# 纯计算，只编这几个文件（不依赖 App 里别的类型；清单是手抄的，由 checks/check-script-source-lists.sh 守着）。
# -O：几十次长 DFT 和逐采样合成的信号，调试版要跑二三十秒，优化版一两秒。编译错误照样打在终端上，不吞。
xcrun swiftc \
  -target "$TRIPLE" \
  -O \
  -wmo \
  -o "$OUT" \
  Sources/SrtFlow/Listening/ListeningDFT.swift \
  Sources/SrtFlow/Listening/ListeningMath.swift \
  Sources/SrtFlow/Listening/ListeningResample.swift \
  Sources/SrtFlow/Listening/ESTOIAnalysis.swift \
  Sources/SrtFlow/Listening/ESTOI.swift \
  Sources/SrtFlow/Listening/MaskerAttribution.swift \
  Sources/SrtFlow/Listening/SourceSoundFeatures.swift \
  Sources/SrtFlow/Listening/SourceSoundSpectrogram.swift \
  Sources/SrtFlow/Listening/SourceSoundTrait.swift \
  Sources/SrtFlow/Listening/VoiceClarity.swift \
  Sources/SrtFlow/Listening/VoiceLines.swift \
  checks/Listening/main.swift \
  checks/Listening/Harness.swift \
  checks/Listening/Signals.swift \
  checks/Listening/DFTChecks.swift \
  checks/Listening/ESTOIChecks.swift \
  checks/Listening/MaskerChecks.swift \
  checks/Listening/TraitChecks.swift \
  checks/Listening/VoiceChecks.swift \
  checks/Listening/ParityCases.swift \
  checks/Listening/ParityChecks.swift \
  checks/Listening/PythonReference.swift \
  checks/Listening/Dump.swift

echo "==> 跑自检"
"$OUT" "$@"
