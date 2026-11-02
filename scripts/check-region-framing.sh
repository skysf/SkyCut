#!/usr/bin/env bash
# 完整 App 的矩形取景：真实单项 / 批量编辑、look、AVFoundation 预览及生产 ffmpeg 导出的像素对账。
# 独立 bundle / 临时工程，不启动用户 App、不改用户工程；SRTFLOW_REGION_ARTIFACTS 可保留验收图。
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_OUT="$(swift build --arch arm64 --product SrtFlow 2>&1)" || { printf '%s\n' "${BUILD_OUT}"; exit 1; }
BUILD_DIR="$(swift build --arch arm64 --show-bin-path)"
ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
APP="${ROOT}/RegionFramingCheck.app"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${ROOT}/work"
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.srtflow.SrtFlow.regionframingcheck</string>
<key>CFBundleExecutable</key><string>RegionFramingCheck</string>
<key>CFBundleName</key><string>RegionFramingCheck</string>
</dict></plist>
PLIST
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/Resources/SrtFlow_SrtFlow.bundle"
ditto "${BUILD_DIR}/SrtFlow_SrtFlow.bundle" "${APP}/Contents/MacOS/SrtFlow_SrtFlow.bundle"
xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 -I "${BUILD_DIR}/Modules" \
  checks/RegionFraming/Fixture.swift checks/RegionFraming/Pixels.swift checks/RegionFraming/Main.swift \
  @"${BUILD_DIR}/SrtFlow.product/Objects.LinkFileList" -o "${APP}/Contents/MacOS/RegionFramingCheck"
# 坐标渐变 + 棋盘代表录屏，可独立判定四角与源方向；固定帧避免时刻误差。
python3 - "${ROOT}/work" "${SRTFLOW_FFMPEG:-${PWD}/vendor/ffmpeg}" <<'PYTHON'
import pathlib
import subprocess
import sys
root, ffmpeg = pathlib.Path(sys.argv[1]), sys.argv[2]
for name, width, height in [("landscape", 640, 360), ("portrait", 360, 640), ("chroma", 640, 360)]:
    pixels = bytearray()
    for y in range(height):
        for x in range(width):
            # 几何尺的 R/G 是低频坐标；强色度棋盘单独比两条渲染管线，避免把其插值差当几何偏移。
            low, high = (70, 210) if name == "chroma" else (120, 136)
            pixels.extend((round(255*x/(width-1)), round(255*y/(height-1)), low if (x//16+y//16)%2 else high))
    ppm = root / (name + ".ppm")
    ppm.write_bytes(f"P6\n{width} {height}\n255\n".encode() + pixels)
    subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-loop", "1", "-i", str(ppm),
                    "-t", "1", "-r", "24", "-an", "-vf", "scale=out_color_matrix=bt709", "-c:v", "libx264", "-g", "1", "-crf", "10",
                    "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-pix_fmt", "yuv420p", str(root/(name+".mp4"))], check=True)
for rotation in (90, 180, 270):
    subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-display_rotation", str(rotation), "-i", str(root/"landscape.mp4"),
                    "-c", "copy", str(root/f"rotate{rotation}.mp4")], check=True)
PYTHON
SRTFLOW_REGION_CHECK_DIR="${ROOT}/work" SRTFLOW_FFMPEG="${SRTFLOW_FFMPEG:-${PWD}/vendor/ffmpeg}" \
SRTFLOW_SMOKE_SCRIPT="${ROOT}/isolated" SRTFLOW_SMOKE_MUTE=1 \
python3 - "${APP}/Contents/MacOS/RegionFramingCheck" <<'PYTHON'
import subprocess
import sys
with subprocess.Popen([sys.argv[1]], stdin=subprocess.DEVNULL) as check:
    try:
        code = check.wait(timeout=240)
    except subprocess.TimeoutExpired:
        print("Region framing timed out; sampling the isolated check before stopping it", flush=True)
        try:
            subprocess.run(["/usr/bin/sample", str(check.pid), "1", "1", "-file", "/dev/stdout"], timeout=15, check=False)
        finally:
            check.kill()
            check.wait()
        raise
    if code:
        raise subprocess.CalledProcessError(code, [sys.argv[1]])
PYTHON
