import AVFoundation
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// **按层量混在一起之后的声音**（AudioStemRender / MixMeasurement / MixBandMeter / MixBusMeter，listen mix=true 的 AIListenMixPlan /
// AIListenMixReport）。信号都是现造的（不拿真素材）：
//   1. oracle：已知频率和电平的正弦（四个频段各一个，24 / 30 / 60 fps）→ 整体电平、那一段的电平、别的段压得够低、四段加起来 = 整体；
//      已知时刻的脉冲 → 峰值落在那个采样、最响的帧就是它那一帧；一条 0.56 秒的音效 → 最响处到帧；EBU Tech 3341 的 1 kHz 正弦 →
//      瞬时 / 短时 / 整体响度 = −23 / −33 LUFS。
//   2. 和导出对账：整条时间线量出来的峰值、写出去的峰值、过线的帧数、压得最深、整体响度和 ExportAudioMixdown 报的逐位一样；
//      每层加起来 = 整条混音（限幅之前）；只量中间一段 = 整段量里同样那几帧；单声道的人声量出来的电平 = 真导出的成片里的电平。
//   3. listen 的参数和结果：层怎么分、越界给合法建议、逐帧的数放得下才给、结果里该有的都在。
// 编法见 scripts/check-mix-layers.sh；长期约束 docs/architecture/export-audio-mixdown.md「五、按层量」。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

func group(_ title: String) { print("== \(title)") }

let ffmpegPath = ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]
    ?? FileManager.default.currentDirectoryPath + "/vendor/ffmpeg"
let root = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-mixlayers-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

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

func decibels(_ meanSquare: Double) -> Double { 10 * log10(max(meanSquare, 1e-20)) }

/// 整条时间线（或 [from, to)）按层量一遍；不给层就每条轨一层。
func measure(
    _ state: TimelineState, from: Double = 0, to: Double? = nil, layers: [AudioStemLayer]? = nil,
    observe: ((AudioStemRender.Block) -> Void)? = nil
) -> MixMeasurement.Result? {
    let config = AudioEngineConfig.make(from: state)
    let grid = MixFrameGrid(fps: state.frameRate.fps)
    let total = MixMeasurement.frameCount(config, grid: grid)
    let frames = grid.frame(containing: from) ..< min(total, grid.frame(endingAt: to ?? config.duration))
    let split = layers ?? config.tracks.indices.map { AudioStemLayer(name: config.tracks[$0].name, tracks: [$0]) }
    do {
        return try MixMeasurement.measure(.init(config: config, layers: split, grid: grid, frames: frames), observe: observe)
    } catch {
        check(false, "MixMeasurement.measure 抛错：\(error)")
        return nil
    }
}

checkBandOracle()
checkPulseOracle()
checkSoundEffect()
checkLoudnessOracle()
await checkExportParity()
checkLayersAddUp()
checkWindowMatchesWhole()
await checkMonoVoiceMatchesExport()
checkPlan()
checkReport()

try? FileManager.default.removeItem(at: root)
print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
