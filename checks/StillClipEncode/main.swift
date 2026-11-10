import AVFoundation
import CoreGraphics
import Foundation
import SrtFlowCore

// **图片转静帧的真实产物回归**：调 `StillImageClipFactory.conversionArguments()`
// 拿生产 ffmpeg 参数，真跑一遍，量产物（帧数 / 时长 / 尺寸 / 静不静）和**耗时**。
//
// 为什么非要量耗时：静帧管线出过两次「产物完全正确、只是慢 20 倍」的 bug
// （见 docs/bugfixes/2026-08-08-still-clip-loop-decode-slow.md 与
// 2026-08-08-still-clip-decode-per-frame.md）。这类差价**一点都不体现在产物上**，
// 只看文件永远发现不了，所以这里必须数解码次数、再有一条对着时间的断言（DecodeOnce.swift）。
//
// 编译方式见 scripts/check-still-clip-encode.sh。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

let ffmpegPath = ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]
    ?? FileManager.default.currentDirectoryPath + "/vendor/ffmpeg"

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("srtflow-stillclip-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

// 不能用顶层 defer 清理：本文件所有出口都是 exit()，而 exit() 不跑 defer
// （先例：previewcheck 因此攒了 52 个临时目录）。统一走 finish()。
func finish(_ code: Int32) -> Never {
    try? FileManager.default.removeItem(at: root)
    exit(code)
}

/// 跑一条命令，返回 (退出码, 合并输出)。
@discardableResult
func run(_ launchPath: String, _ args: [String]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "启动失败：\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// 跑一条命令并计时（秒）。
func timed(_ args: [String]) -> (seconds: Double, code: Int32, output: String) {
    let start = Date()
    let (code, output) = run(ffmpegPath, args)
    return (Date().timeIntervalSince(start), code, output)
}

/// 数一个文件的视频帧数。
func frameCount(_ url: URL) -> Int {
    let (_, out) = run(ffmpegPath, [
        "-hide_banner", "-loglevel", "error",
        "-i", url.path, "-map", "0:v", "-f", "null", "-",
        "-progress", "pipe:1",
    ])
    // `-progress` 会多次打印 frame=N，取最后一个。
    return out.split(separator: "\n").compactMap { line -> Int? in
        guard line.hasPrefix("frame=") else { return nil }
        return Int(line.dropFirst("frame=".count).trimmingCharacters(in: .whitespaces))
    }.last ?? -1
}

/// 取出某个时刻那一帧存成 PNG。
func extractFrame(_ url: URL, at seconds: Double, name: String) -> URL? {
    let out = root.appendingPathComponent(name)
    let (code, _) = run(ffmpegPath, [
        "-hide_banner", "-loglevel", "error", "-y",
        "-ss", String(seconds), "-i", url.path, "-frames:v", "1", out.path,
    ])
    return code == 0 ? out : nil
}

/// 两张图的 PSNR（dB）。完全相同返回 .infinity。
func psnr(_ a: URL, _ b: URL) -> Double {
    let (_, out) = run(ffmpegPath, [
        "-hide_banner", "-i", a.path, "-i", b.path, "-lavfi", "psnr", "-f", "null", "-",
    ])
    guard let range = out.range(of: "average:", options: .backwards) else { return -1 }
    let tail = out[range.upperBound...].prefix { !$0.isWhitespace }
    if tail.hasPrefix("inf") { return .infinity }
    return Double(tail) ?? -1
}

// MARK: - 素材

/// 造一张图。`upscale` 用来造更大的：lavfi 直接生成 6000×4500 会申请不到内存，
/// 先出 4000×3000 再放大。
func makeImage(_ name: String, size: String, upscale: String? = nil) -> URL {
    let url = root.appendingPathComponent(name)
    var args = [
        "-y", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "mandelbrot=size=\(size)",
    ]
    if let upscale { args += ["-vf", "scale=\(upscale)"] }
    args += ["-frames:v", "1", url.path]
    let (code, out) = run(ffmpegPath, args)
    if code != 0 { print("造素材失败（\(name)）：\(out)") }
    return url
}

/// 造一张 10 帧的动图：验「多帧输入也必须截到 stillDuration」。
func makeAnimatedGIF() -> URL {
    let url = root.appendingPathComponent("anim.gif")
    let (code, out) = run(ffmpegPath, [
        "-y", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10:duration=1", url.path,
    ])
    if code != 0 { print("造动图失败：\(out)") }
    return url
}

let bigImage = makeImage("big.png", size: "4000x3000")
let animated = makeAnimatedGIF()

// MARK: - 产物形状（两条分辨率政策各来一遍）

/// 跑一遍生产命令，返回产物。
func convert(_ image: URL, nativeResolution: Bool, name: String) -> (url: URL, seconds: Double)? {
    let output = root.appendingPathComponent(name)
    let args = StillImageClipFactory.conversionArguments(
        image: image,
        output: output,
        nativeResolution: nativeResolution
    )
    let result = timed(args)
    guard result.code == 0 else {
        print("转换失败（\(name)）：\(result.output)")
        return nil
    }
    return (output, result.seconds)
}

let expectedFrames = StillImageClipFactory.stillFrameCount
check(expectedFrames == 120, "帧数常量应为 120，实际 \(expectedFrames)")

for (nativeResolution, label) in [(false, "照片政策"), (true, "原生政策")] {
    guard let made = convert(bigImage, nativeResolution: nativeResolution, name: "still-\(label).mp4") else {
        failures += 1
        continue
    }

    let frames = frameCount(made.url)
    check(frames == expectedFrames, "\(label)：帧数应为 \(expectedFrames)，实际 \(frames)")

    // 时长走 MediaProbe —— 生产读素材信息就是它，ffmpeg 说 60 秒但 AVFoundation
    // 读出别的数，时间线上的图片段就是错的。
    let probed = await MediaProbe.probe(url: made.url, ffmpeg: URL(fileURLWithPath: ffmpegPath))
    guard case .success(let info) = probed else {
        failures += 1
        print("FAIL \(label)：MediaProbe 读不出产物")
        continue
    }
    check(
        abs(info.duration - StillImageClipFactory.stillDuration) < 0.05,
        "\(label)：时长应为 \(StillImageClipFactory.stillDuration)s，实际 \(info.duration)s"
    )

    // 尺寸政策，以及**政策能不能从产物尺寸反推回来** —— `refreshStillClips` 在
    // 缓存被系统清掉后重转，判据只有 `needsNativeResolution(for: info.displaySize)`。
    if nativeResolution {
        check(
            info.displaySize == CGSize(width: 4000, height: 3000),
            "原生政策：应保住 4000×3000，实际 \(info.displaySize)"
        )
    } else {
        check(
            info.displaySize.width <= StillImageClipFactory.photoMaxWidth
                && info.displaySize.height <= StillImageClipFactory.photoMaxHeight,
            "照片政策：应压进 1920×1080 以内，实际 \(info.displaySize)"
        )
    }
    check(
        StillImageClipFactory.needsNativeResolution(for: info.displaySize) == nativeResolution,
        "\(label)：产物尺寸 \(info.displaySize) 反推出的政策不是原来那条"
    )

    // 真的是静帧：头尾两帧只该差在编码抖动上（实测 ~49dB；换成另一帧是 ~21dB）。
    if let head = extractFrame(made.url, at: 0, name: "head-\(label).png"),
       let tail = extractFrame(made.url, at: StillImageClipFactory.stillDuration - 0.5, name: "tail-\(label).png") {
        let db = psnr(head, tail)
        check(db > 40, "\(label)：首尾两帧 PSNR 只有 \(db)dB，画面动了")
    } else {
        failures += 1
        print("FAIL \(label)：取不出首尾帧")
    }
}

// MARK: - 多帧输入必须被截断

// 动图/多页图在 `loop` 复制完第一帧之后，剩下的帧会接着往下吐 —— 没有
// `-frames:v` 上限的话产物会超过 stillDuration，图片段的可拖长度就跟着错。
if let made = convert(animated, nativeResolution: true, name: "still-anim.mp4") {
    let frames = frameCount(made.url)
    check(frames == expectedFrames, "动图输入：帧数应为 \(expectedFrames)，实际 \(frames)")
    if let head = extractFrame(made.url, at: 0, name: "anim-head.png"),
       let tail = extractFrame(made.url, at: StillImageClipFactory.stillDuration - 0.5, name: "anim-tail.png") {
        let db = psnr(head, tail)
        check(db > 40, "动图输入：首尾两帧 PSNR 只有 \(db)dB，动画被带进静帧段了")
    }
} else {
    failures += 1
    // gif 走 gif demuxer、heic 走 mov demuxer，两个都不认 `-loop` / `-framerate`：
    // 参数里出现它们的话，这些格式在开文件那一步就死（"Option loop not found"）。
    print("FAIL 动图输入转换失败 —— 参数里是不是又出现了只有 image2 认的选项？")
}

// MARK: - 图只该解一次、缩一次（DecodeOnce.swift）

// 数 ffmpeg 报的解码次数，再把多出来那 119 帧的边际成本和同一次运行里产物尺寸的小图比。
await checkDecodeOnce(native: bigImage)

// MARK: - 同一张图同一条政策，产物必须逐字节稳定

// 缓存是按「路径+改动时间+大小」指纹命中的，前提是同一张图每次都转出同一个
// 产物；不稳定的话「命中缓存」和「重转」会给出不一样的画面。
if let first = convert(bigImage, nativeResolution: false, name: "stable-1.mp4"),
   let second = convert(bigImage, nativeResolution: false, name: "stable-2.mp4"),
   let a = try? Data(contentsOf: first.url),
   let b = try? Data(contentsOf: second.url) {
    check(a == b, "同一张图转两次的产物不一样（\(a.count) vs \(b.count) 字节）")
} else {
    failures += 1
    print("FAIL 稳定性对比跑不起来")
}

// MARK: - 带透明的图（Alpha.swift）

checkAlphaStills()

print("\(checks - failures)/\(checks) 通过")
if failures > 0 {
    print("❌ \(failures) 项失败")
    finish(1)
}
print("✅ 全部通过")
finish(0)
