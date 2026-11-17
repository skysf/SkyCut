import AVFoundation
import CoreGraphics
import Foundation
import SrtFlowCore

// Frame windows in the real export graph: upper video (ordinary and fill + matte), blur, mosaic and grades.
// One small scene per project rate puts all four in separate horizontal bands over cuts and crossfades. Every output
// frame is checked, including both neighbours of every window. Moving upper video also identifies its source frame.
// Preview/AI look use the same native composition and FilterStack/CoverStack; their boundary states are checked too.
// This does not test GUI attachment or the effects' pixel mathematics (the cover/filter checks own those).
enum LayerWindowChecks {
    private static let size = CGSize(width: 320, height: 180)

    private struct Window {
        var first: Int
        var end: Int
        var fps: Int
        var prerendered = false
        var start: Double { Double(first) / Double(fps) }
        var duration: Double { Double(end - first) / Double(fps) }
        func contains(_ frame: Int) -> Bool { frame >= first && frame < end }
    }

    private struct Sample {
        var upper: Int
        var blur: Int
        var mosaic: Int
        var saturation: Int
    }

    static func runAll() async {
        checkNativeRequests()
        let baseGraph = "nullsrc=s=320x180:r=10:d=30,format=yuv444p," +
            "geq=lum='if(lt(Y,40),16,if(lt(Y,120),if(mod(floor(X/2)+floor(Y/2),2),235,16),81))':" +
            "cb='if(lt(Y,120),128,90)':cr='if(lt(Y,120),128,240)'"
        guard let base = await source("windows-base", graph: baseGraph) else { return }
        for rate in ProjectFrameRate.allCases {
            let fps = rate.fps
            let graph = "nullsrc=s=320x40:r=\(fps):d=2,geq=lum='if(lt(X,32+12*mod(N,16)),235,16)':cb=128:cr=128"
            guard let upper = await source("windows-upper-\(fps)", graph: graph) else { continue }
            let windows = [3.16, 131.0 / 30, 7.2, 9.5, 12.0, 15.1].map { start in
                let first = Int((start * Double(fps)).rounded())
                return Window(first: first, end: first + fps, fps: fps, prerendered: start == 12)
            }
            let state = scene(rate, base: base, upper: upper, windows: windows)
            guard let product = await export(state, name: "windows-\(fps)"),
                  let samples = await decode(product, name: "windows-\(fps)") else { continue }
            let expectedCount = Int((state.duration * Double(fps)).rounded())
            check(abs(samples.count - expectedCount) <= 2, "layer windows @\(fps): complete export (\(samples.count) frames)")
            measure(samples, state: state, windows: windows, fps: fps)
            await preview(state, samples: samples, windows: windows, rate: rate)
        }
    }

    private static func checkNativeRequests() {
        for rate in ProjectFrameRate.allCases {
            let wrong = (0..<100_000).filter { frame in
                [0.0, 0.75].contains { fraction in
                    let time = (Double(frame) + fraction) / Double(rate.fps)
                    let quantized = TextAnimator.quantize(time, frameRate: rate)
                    let request = NativeSourceFrameSampler.requestedTime(for: quantized)
                    return CMTimeCompare(request, CMTime(value: Int64(frame), timescale: Int32(rate.fps))) != 0
                }
            }
            check(wrong.isEmpty, "native look requests @\(rate.fps): exact frames must stay on their ticks; wrong \(wrong.prefix(8))")
        }
    }

    private static func info(_ size: CGSize, seconds: Double, fps: Double) -> MediaInfo {
        MediaInfo(duration: seconds, displaySize: size, frameRate: fps, videoCodec: "h264", audioCodec: nil,
                  hasAudio: false, audioCanCopyToMP4: false, fileBytes: 1)
    }

    private static func scene(_ rate: ProjectFrameRate, base: URL, upper: URL, windows: [Window]) -> TimelineState {
        var state = TimelineState()
        state.frameRate = rate
        // Fractional segment lengths deliberately leave AVTB timestamps a few microseconds off the grid, just as in
        // production. In particular the frame at 7.2 s can arrive as 7.199999999999999 after the cuts.
        let lengths = [2.13, 1.97, 2.71, 3.33, 2.07, 4.19, 3.11]
        let fades = [0.0, 0.5, 0, 0.73, 0.4, 0, 0]
        var cursor = 0.0
        for (index, length) in lengths.enumerated() {
            state.mainClips.append(EditClip(
                sourceURL: base, sourceStart: Double(index) * 0.37, sourceDuration: length, timelineStart: cursor,
                transitionAfter: fades[index] > 0 ? .crossFade : .none, transitionDuration: fades[index],
                info: info(size, seconds: 30, fps: 10)
            ))
            cursor += length - fades[index]
        }
        var lane = EditLane()
        for window in windows {
            var clip = EditClip(sourceURL: upper, sourceDuration: window.duration, timelineStart: window.start,
                                info: info(CGSize(width: 320, height: 40), seconds: 2, fps: Double(rate.fps)))
            clip.placement = ClipPlacement(centerX: 0.5, centerY: 20.0 / 180, width: 1, height: 40.0 / 180)
            if window.prerendered {
                var animation = ClipAnimation()
                animation.opacity = KeyframeTrack(keys: [Keyframe(time: 0, value: 0.75), Keyframe(time: 1, value: 0.75)])
                clip.animation = animation
            }
            lane.clips.append(clip)
            for (kind, y) in [(ShapeKind.blur, 60.0), (.mosaic, 100.0)] {
                state.shapes.append(ShapeAnnotation(kind: kind, timelineStart: window.start, duration: window.duration,
                                                     centerX: 0.5, centerY: y / 180, width: 0.5, height: 32.0 / 180,
                                                     coverAmount: 48))
            }
            state.filters.append(FilterClip(preset: .inkShadow, strength: 1, timelineStart: window.start,
                                            duration: window.duration, layer: 0))
        }
        state.overlayTracks = [lane]
        return state
    }

    private static func source(_ name: String, graph: String) async -> URL? {
        let url = root.appendingPathComponent(name + ".mp4")
        let result = await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            run(ffmpegPath, ["-y", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", graph,
                             "-c:v", "libx264", "-crf", "5", "-pix_fmt", "yuv420p", url.path])
        }
        check(result.0 == 0, "layer windows source \(name): \(result.1.suffix(300))")
        return result.0 == 0 ? url : nil
    }

    private static func export(_ state: TimelineState, name: String) async -> URL? {
        do {
            var settings = VideoEncodeSettings()
            settings.preset = .veryfast
            settings.crf = 10
            let plan = try await VideoEditExportGraph.plan(state: state, settings: settings,
                subtitleStyle: BurnInStyle(name: "check"), subtitleFontURL: nil,
                output: root.appendingPathComponent(name + ".mp4"), watermark: nil)
            defer { try? FileManager.default.removeItem(at: plan.workspace) }
            let result = await MediaReadQueue.run(on: MediaReadQueue.analysis) {
                let process = Process()
                process.currentDirectoryURL = plan.workspace
                process.executableURL = URL(fileURLWithPath: ffmpegPath)
                process.arguments = plan.arguments
                let log = Pipe()
                process.standardOutput = log
                process.standardError = log
                do { try process.run() } catch { return (Int32(-1), String(describing: error)) }
                let data = log.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: data, as: UTF8.self))
            }
            check(result.0 == 0, "layer windows export \(name): \(result.1.suffix(500))")
            guard result.0 == 0 else { return nil }
            let output = root.appendingPathComponent(name + ".mp4")
            try FileManager.default.moveItem(at: plan.tempOutput, to: output)
            return output
        } catch {
            check(false, "layer windows \(name): \(error)")
            return nil
        }
    }

    // One column for the effects and one row for the moving upper edge (1,500 bytes per frame). No fps filter or seek:
    // each decoded frame is measured in order, so neither can hide an extra, missing or repeated frame.
    private static func decode(_ url: URL, name: String) async -> [Sample]? {
        let raw = root.appendingPathComponent(name + ".rgb")
        let row = root.appendingPathComponent(name + "-row.rgb")
        let result = await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            run(ffmpegPath, ["-y", "-hide_banner", "-loglevel", "error", "-i", url.path, "-an",
                             "-vf", "format=rgb24,crop=1:180:100:0:exact=1", "-vsync", "0",
                             "-f", "rawvideo", "-pix_fmt", "rgb24", raw.path])
        }
        guard result.0 == 0, let data = try? Data(contentsOf: raw), !data.isEmpty, data.count % 540 == 0 else {
            check(false, "layer windows decode \(name): \(result.1.suffix(300))")
            return nil
        }
        let rowResult = await MediaReadQueue.run(on: MediaReadQueue.analysis) {
            run(ffmpegPath, ["-y", "-hide_banner", "-loglevel", "error", "-i", url.path, "-an",
                             "-vf", "format=rgb24,crop=320:1:0:12:exact=1", "-vsync", "0",
                             "-f", "rawvideo", "-pix_fmt", "rgb24", row.path])
        }
        guard rowResult.0 == 0, let pixels = try? Data(contentsOf: row), pixels.count % 960 == 0,
              pixels.count / 960 == data.count / 540 else {
            check(false, "layer windows row decode \(name): \(rowResult.1.suffix(300))")
            return nil
        }
        return stride(from: 0, to: data.count, by: 540).map { offset in
            func channel(_ y: Int, _ c: Int = 0) -> Int { Int(data[offset + y * 3 + c]) }
            let start = offset / 540 * 960
            let width = (0..<320).filter { pixels[start + $0 * 3] > 120 }.count
            return Sample(upper: width, blur: channel(56), mosaic: channel(96),
                          saturation: channel(156) - channel(156, 1))
        }
    }

    private static func measure(_ samples: [Sample], state: TimelineState, windows: [Window], fps: Int) {
        for (name, active) in [
            ("upper video", { (s: Sample) in s.upper > 20 }),
            ("blur", { (s: Sample) in s.blur > 50 && s.blur < 200 }),
            ("mosaic", { (s: Sample) in s.mosaic > 50 && s.mosaic < 200 }),
            ("grade", { (s: Sample) in abs(s.saturation) < 20 })
        ] {
            let wrong = samples.indices.filter { frame in
                active(samples[frame]) != windows.contains { $0.contains(frame) }
            }
            check(wrong.isEmpty, "\(name) @\(fps): first/last present, no extra frame; wrong frames \(wrong.prefix(12))")
        }
        // Stacks used by preview and AI look must choose the same first/last frames as the integer oracle.
        let wrongStacks = samples.indices.filter { frame in
            let time = Double(frame) / Double(fps)
            let expected = windows.contains { $0.contains(frame) }
            return !FilterStack(in: state, at: time).isEmpty != expected || !CoverStack(in: state, at: time).isEmpty != expected
        }
        check(wrongStacks.isEmpty, "preview/look stacks @\(fps): boundary frames \(wrongStacks.prefix(12))")
    }

    private static func preview(_ state: TimelineState, samples: [Sample], windows: [Window], rate: ProjectFrameRate) async {
        guard let built = await VideoEditCompositionBuilder.build(from: state), let video = built.videoComposition else {
            check(false, "layer windows preview @\(rate.fps): no composition")
            return
        }
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = video
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let look = AVAssetImageGenerator(asset: built.composition)
        look.videoComposition = video
        let half = CMTime(seconds: rate.halfFrameTolerance, preferredTimescale: 6000)
        look.requestedTimeToleranceBefore = half
        look.requestedTimeToleranceAfter = half
        for window in windows {
            var wrong: [String] = []
            // Every active frame and both adjacent frames; this also detects selecting the previous moving source frame
            // after a crossfade. A black/white edge is immune to the two pipelines' color conversion differences.
            for frame in (window.first - 1)...window.end where samples.indices.contains(frame) {
                do {
                    let image = try await generator.image(at: CMTime(value: Int64(frame), timescale: Int32(rate.fps))).image
                    let value = await MediaReadQueue.run(on: MediaReadQueue.analysis) { whiteWidth(image) }
                    let lookTime = TextAnimator.quantize((Double(frame) + 0.75) / Double(rate.fps), frameRate: rate)
                    let requested = NativeSourceFrameSampler.requestedTime(for: lookTime)
                    let looked = try await look.image(at: requested).image
                    let lookWidth = await MediaReadQueue.run(on: MediaReadQueue.analysis) { whiteWidth(looked) }
                    if abs(lookWidth - value) > 2 { wrong.append("\(frame): look \(lookWidth), preview \(value)") }
                    let expected = window.contains(frame)
                    if (value > 20) != expected { wrong.append("\(frame): preview \(value)") }
                    if expected {
                        if abs(samples[frame].upper - value) > 2 {
                            wrong.append("\(frame): export \(samples[frame].upper), preview \(value)")
                        }
                    }
                } catch { wrong.append("\(frame): \(error)") }
            }
            check(wrong.isEmpty, "upper video \(window.prerendered ? "fill+matte" : "ordinary") @\(rate.fps), from frame \(window.first): \(wrong.prefix(8))")
        }
    }

    private static func whiteWidth(_ image: CGImage) -> Int {
        var pixels = [UInt8](repeating: 0, count: 320 * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 320, height: 1, bitsPerComponent: 8, bytesPerRow: 1280,
                                          space: FilterLUT.workingColorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
            context.draw(image, in: CGRect(x: 0, y: 12 - image.height + 1, width: image.width, height: image.height))
            return (0..<320).filter { buffer[$0 * 4] > 120 }.count
        }
    }
}
