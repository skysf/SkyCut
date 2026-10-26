import Foundation
import SrtFlowCore

// **导出水印真的叠上了，而且只在该在的地方**（收费方案第 4 刀，docs/architecture/export-watermark.md）。
//
// 两半：纯值（PureChecks：logo、PNG、跳的表、尺寸位置、分段表达式）；真导出（ExportChecks：调真实的 `VideoEditExportGraph.plan()`，
// 开着水印和不开各导一遍、抽帧逐像素比 —— 不比绝对色值，成片是 yuv420p 有限范围，比差不受影响）。
// 编法见 scripts/check-export-watermark.sh。

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

/// 仓库里的那份 logo（打好的 App 从资源里读，自检直接读源文件）。
let logoURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Sources/SrtFlow/Resources/watermark-logo.svg")

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("srtflow-watermark-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

/// 所有出口都是 exit()，而 exit() 不跑 defer —— 统一走 finish() 清临时目录。
func finish(_ code: Int32) -> Never {
    try? FileManager.default.removeItem(at: root)
    exit(code)
}

@discardableResult
func run(_ launchPath: String, _ args: [String], in directory: URL? = nil) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.currentDirectoryURL = directory
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "启动失败：\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// 用 ffmpeg 的 lavfi 现造素材（h264、接近无损）。
func makeVideo(_ name: String, graph: String) -> URL? {
    let url = root.appendingPathComponent(name)
    let (code, out) = run(ffmpegPath, [
        "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", graph,
        "-c:v", "libx264", "-crf", "8", "-pix_fmt", "yuv420p", url.path
    ])
    guard code == 0 else { check(false, "造素材 \(name) 失败：\(out.suffix(400))"); return nil }
    return url
}

/// 跑一遍**生产**导出，返回成品路径。
func export(_ state: TimelineState, name: String, watermark: ExportWatermark?, settings: VideoEncodeSettings = VideoEncodeSettings()) async -> URL? {
    let output = root.appendingPathComponent(name)
    let plan: VideoEditExportGraph.Plan
    do {
        plan = try await VideoEditExportGraph.plan(
            state: state, settings: settings, subtitleStyle: BurnInStyle(name: "check"),
            subtitleFontURL: nil, output: output, watermark: watermark
        )
    } catch {
        check(false, "\(name) 的 plan() 失败：\(error)")
        return nil
    }
    let (code, out) = run(ffmpegPath, plan.arguments, in: plan.workspace)
    guard code == 0 else {
        try? FileManager.default.removeItem(at: plan.workspace)
        check(false, "\(name) 的 ffmpeg 执行失败：\(out.suffix(800))")
        return nil
    }
    // `tempOutput` 就在 workspace 里，清掉 workspace 等于把成品一起删了 —— 先搬出来再清。
    let kept = root.appendingPathComponent("product-\(name)")
    try? FileManager.default.removeItem(at: kept)
    do { try FileManager.default.copyItem(at: plan.tempOutput, to: kept) } catch {
        try? FileManager.default.removeItem(at: plan.workspace)
        check(false, "\(name) 的成品搬不出来：\(error)")
        return nil
    }
    try? FileManager.default.removeItem(at: plan.workspace)
    return kept
}

/// 成品第 `number` 帧的 RGB（整幅）。按帧号取，段的边界那一帧不会被 seek 的取整挪走。
struct Frame {
    var width: Int
    var height: Int
    var rgb: [UInt8]

    func difference(_ other: Frame, x: Int, y: Int) -> Int {
        let i = (y * width + x) * 3
        return max(abs(Int(rgb[i]) - Int(other.rgb[i])), max(abs(Int(rgb[i + 1]) - Int(other.rgb[i + 1])), abs(Int(rgb[i + 2]) - Int(other.rgb[i + 2]))))
    }

    /// 和另一帧差超过 `threshold` 的像素的外接框（左闭右开）和个数；一个都没有是 nil。
    func changes(from other: Frame, threshold: Int) -> (box: CGRect, count: Int)? {
        var x0 = width, y0 = height, x1 = 0, y1 = 0, count = 0
        for y in 0..<height {
            for x in 0..<width where difference(other, x: x, y: y) > threshold {
                x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x + 1); y1 = max(y1, y + 1); count += 1
            }
        }
        return count == 0 ? nil : (CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), count)
    }
}

func frame(_ url: URL, number: Int, size: CGSize, name: String) -> Frame? {
    let raw = root.appendingPathComponent("\(name)-\(number).rgb")
    let (code, out) = run(ffmpegPath, [
        "-hide_banner", "-loglevel", "error", "-y", "-i", url.path,
        "-vf", "select=eq(n\\,\(number))", "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", raw.path
    ])
    let width = Int(size.width), height = Int(size.height)
    guard code == 0, let data = try? Data(contentsOf: raw), data.count == width * height * 3 else {
        check(false, "\(name) 第 \(number) 帧抽不出来：\(out.suffix(300))")
        return nil
    }
    return Frame(width: width, height: height, rgb: [UInt8](data))
}

func main() async {
    guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
        print("找不到 ffmpeg：\(ffmpegPath)（跑 scripts/vendor-ffmpeg.sh，或设 SRTFLOW_FFMPEG）")
        finish(1)
    }
    guard let text = try? String(contentsOf: logoURL, encoding: .utf8), let logo = WatermarkImage.parse(svg: text) else {
        print("✗ 读不出 \(logoURL.path) 里的 logo")
        finish(1)
    }
    runPureChecks(logo: logo)
    await runExportChecks(logo: logo)
    if failures > 0 {
        print("✗ \(failures) of \(checks) checks failed")
        finish(1)
    }
    print("All \(checks) checks passed.")
    finish(0)
}

await main()
