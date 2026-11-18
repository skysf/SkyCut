import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SrtFlowMCPKit
@testable import SrtFlow

// look sound=… on a real project (MCP-66): the real tool (AILookTool), the engine's offline render of the export's configuration
// (AISoundStripMeasure) and the strip stacked under the sheet. A synthetic 6 s stereo WAV — a quiet 220 Hz bed with one loud 20 ms
// burst at 2.5 s — sits on A1 from timeline second 1 (the burst at 3.5 s, frame 84 at 24 fps); a steady 440 Hz tone starts on A2
// at 3.2 s. V1 is the silent synthetic footage. Checks: the rows and their loudest frame (the burst's), the A2 start listed with
// its clip and track and only in the mix row, the picture is the sheet with the strip under it and its level bars are tall at the
// burst and short elsewhere, clip_id spans that clip's seconds, image=false still gives the numbers, and the refusals.

@MainActor func runLookSoundPathChecks(_ root: URL) async throws {
    let failuresBefore = LookCheckLog.failures
    let ffmpeg = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]!)
    let video = root.appendingPathComponent("testsrc2.mp4")
    let info = try await MediaProbe.probe(url: video, ffmpeg: ffmpeg).get()
    let burst = root.appendingPathComponent("burst.wav"), tone = root.appendingPathComponent("tone.wav")
    try writeWave(burst, seconds: 6) { t in t >= 2.5 && t < 2.52 ? 0.8 * sin(2 * .pi * 1_000 * t) : 0.004 * sin(2 * .pi * 220 * t) }
    try writeWave(tone, seconds: 3) { t in 0.05 * sin(2 * .pi * 440 * t) }
    let look = try LookProject(folder: root.appendingPathComponent("sound"), name: "Sound", session: "session-sound",
                               sources: [(video, info)], count: 4)
    defer { _ = OpenProjects.shared.close(look.project) }
    var state = look.project.state
    state.frameRate = .fps24
    state.audioTracks = [
        EditLane(clips: [EditClip(sourceURL: burst, isAudioOnly: true, sourceDuration: 6, timelineStart: 1, audioAssetDuration: 6)]),
        EditLane(clips: [EditClip(sourceURL: tone, isAudioOnly: true, sourceDuration: 3, timelineStart: 3.2, audioAssetDuration: 3)])
    ]
    look.project.restoreTimeline(state)
    let ids = AIShortIDs(state: look.project.state)
    let burstID = ids.short(state.audioTracks[0].clips[0].id), toneID = ids.short(state.audioTracks[1].clips[0].id)
    let times: JSONValue = [3.25, 3.375, 3.5, 3.625, 3.75]

    let plain = try await lookCall(look, ["times": times])
    let drawn = try await lookCall(look, ["times": times, "sound": ["mix", "A1"]])
    let sound = drawn.payload["sound"]
    let rows = sound?["rows"]?.arrayValue ?? []
    require(rows.compactMap { $0["row"]?.stringValue } == ["mix", "A1"], "look sound: the rows in the order asked (\(rows))")
    for row in rows {
        require(row["loudest_at"]?.doubleValue == 3.5, "look sound: \(row["row"]?.stringValue ?? "?")'s loudest frame is the burst's (\(row))")
    }
    let peak = rows.first?["peak_db"]?.doubleValue ?? 0
    require(peak > -3 && peak < -1, "look sound: the mix's true peak is the burst's, before the limiter (\(peak) dBTP)")
    let starts = sound?["starts"]?.arrayValue ?? []
    require(starts.count == 1 && starts.first?["clip"]?.stringValue == toneID && starts.first?["track"]?.stringValue == "A2"
                && starts.first?["at"]?.doubleValue == 3.2,
            "look sound: the A2 tone's start is listed with its clip and track; A1's clip starts before the window (\(starts))")
    require(drawn.payload["image"]?.stringValue?.contains("Below the pictures") == true
                && drawn.payload["image"]?.stringValue?.contains("labelled #n") == true,
            "look sound: the image note says how to read the strip and the #n labels")
    try checkPicture(plain: plain, drawn: drawn, from: sound?["from"]?.doubleValue ?? 0, to: sound?["to"]?.doubleValue ?? 1)

    let span = try await lookCall(look, ["clip_id": .string(burstID), "count": 3, "sound": true])
    require(span.payload["sound"]?["from"]?.doubleValue == 1 && span.payload["sound"]?["to"]?.doubleValue == 7
                && span.payload["sound"]?["rows"]?.arrayValue?.first?["row"]?.stringValue == "mix",
            "look sound=true over clip_id: the mix over that clip's seconds (\(span.payload["sound"] ?? .null))")
    let numbers = try await lookCall(look, ["times": times, "sound": ["mix"], "image": false])
    require(numbers.images.isEmpty && numbers.payload["sound"]?["rows"]?.arrayValue?.count == 1,
            "look sound with image=false: the numbers without a picture")
    for (arguments, says) in [
        (["times": times, "sound": ["A9"]] as JSONValue, "There is no track A9"),
        (["times": times, "sound": []] as JSONValue, "at least one row"),
        (["times": times, "sound": ["mix", "A1", "A2", "V1", "rest"]] as JSONValue, "at most 4 rows"),
        (["file": .string(video.path), "sound": ["mix"]] as JSONValue, "leave out file, files, shots and text_scan")
    ] {
        do {
            _ = try await lookCall(look, arguments)
            require(false, "look sound refuses \(arguments)")
        } catch let error as AIToolError {
            require(error.message.contains(says), "look sound refuses \(arguments): \(error.message)")
        }
    }
    if LookCheckLog.failures == failuresBefore {
        print("look sound: the engine's mix and A1 drawn under five frames, the burst's frame loudest in both, the A2 start listed")
    }
}

/// The same sheet with the strip under it: as wide, taller, and the level bars at the burst's frame much taller than at 3.3 s.
@MainActor private func checkPicture(plain: AIToolResult, drawn: AIToolResult, from: Double, to: Double) throws {
    guard let sheet = plain.images.first.flatMap(decode), let picture = drawn.images.first.flatMap(decode) else {
        return require(false, "look sound: both looks came back with a picture")
    }
    require(picture.width == sheet.width && picture.height > sheet.height + 100,
            "look sound: the strip goes under the sheet (\(sheet.width)×\(sheet.height) → \(picture.width)×\(picture.height))")
    let pixels = rgba(picture)
    /// Level-colored pixels in the strip, in the column holding `time`.
    func bars(at time: Double) -> Int {
        let x = Int(Double(picture.width) * (time - from) / max(1e-9, to - from))
        return (sheet.height ..< picture.height).filter { y in
            let index = (y * picture.width + x) * 4
            return pixels[index + 1] > 200 && pixels[index] < 200
        }.count
    }
    let atBurst = bars(at: 3.5 + 1.0 / 48), before = bars(at: 3.3125)
    require(atBurst > 3 * max(1, before) && atBurst > 40,
            "look sound: tall level bars at the burst's frame, short ones at 3.31 s (\(atBurst) vs \(before) pixels)")
}

@MainActor private func lookCall(_ look: LookProject, _ arguments: JSONValue) async throws -> AIToolResult {
    try await AICallContext.$current.withValue(look.context) { try await AILookTool.look(AIToolArguments(arguments), look.project) }
}

private func decode(_ data: Data) -> CGImage? {
    CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
}

/// RGBA bytes, row 0 at the top.
private func rgba(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
}

/// A 48 kHz stereo float WAV, both channels `sample(t)`.
private func writeWave(_ url: URL, seconds: Double, _ sample: (Double) -> Double) throws {
    let rate = 48_000.0
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * rate)),
          let channels = buffer.floatChannelData else { throw AIToolError("Could not make the test sound.") }
    buffer.frameLength = buffer.frameCapacity
    for index in 0 ..< Int(buffer.frameLength) {
        let value = Float(sample(Double(index) / rate))
        channels[0][index] = value
        channels[1][index] = value
    }
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}
