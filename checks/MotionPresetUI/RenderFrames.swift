import AppKit
import AVFoundation
import CoreText
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 三套预设各几帧：同一份时间线，左边是预览（剪辑页预览上真的那两层叠层：ShapeOverlayCanvas + TextOverlayCanvas，摆在底片上拍），
// 右边是成片（真跑导出图 VideoEditExportGraph + ffmpeg，按同一时刻抽帧）。16:9 和 9:16 各一套；预设是照 AI 的 set_text 那一句放的
//（和界面上加字的那一栏同一条路）。底片是现画的：夜里的冰面（深青到深蓝，几块亮一点的浮冰），标题 + 数字照样片放在黑底上。

@MainActor
enum MotionPresetFrames {
    struct Case {
        var name: String
        var call: [String: JSONValue]
        var black = false
        /// 抽哪几刻（落点 0.5 秒之后）。
        var times: [Double]
    }

    static let cases = [
        Case(name: "frame-reveal", call: ["text": "SKY STUDIO", "small_text": "FROM", "motion_preset": "frame_reveal", "hit_at": 0.5],
             times: [0.7, 0.85, 1.4, 2.2, 3.0]),
        Case(name: "focus-pull", call: ["text": "SKY LU", "small_text": "PRESENTS", "small_text_below": true,
                                        "motion_preset": "focus_pull", "hit_at": 0.5],
             times: [0.65, 1.2, 2.15, 3.35]),
        Case(name: "title-counter", call: ["text": "POLE TO POLE", "motion_preset": "title_counter",
                                           "number": ["to": 20004, "suffix": " KM"], "hit_at": 0.5],
             black: true, times: [0.7, 1.0, 1.8, 2.9]),
        // 中文标题（苹方回退）：框住再放开、16:9。
        Case(name: "frame-reveal-zh", call: ["text": "南极之旅", "small_text": "出品", "motion_preset": "frame_reveal", "hit_at": 0.5],
             times: [1.4])
    ]

    static func render(_ project: VideoEditProject, out: URL) async throws {
        let work = out.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for item in cases {
            for ratio in item.name.hasSuffix("-zh") ? [CanvasRatio.wide16x9] : [.wide16x9, .tall9x16] {
                try await render(item, ratio: ratio, project: project, out: out, work: work)
            }
        }
    }

    private static func render(_ item: Case, ratio: CanvasRatio, project: VideoEditProject, out: URL, work: URL) async throws {
        let canvas = ratio.fixedSize ?? CGSize(width: 1920, height: 1080)
        let tag = "\(item.name)-\(ratio == .wide16x9 ? "16x9" : "9x16")"
        let background = Backdrop.image(canvas, black: item.black)
        let video = work.appendingPathComponent("\(tag)-backdrop.mp4")
        try await Backdrop.video(background, seconds: 5, to: video)

        var state = TimelineState()
        state.frameRate = .fps30
        state.canvasRatio = ratio
        state.mainClips = [EditClip(sourceURL: video, sourceDuration: 5, info: MediaInfo(
            duration: 5, displaySize: canvas, frameRate: 10, videoCodec: "h264", audioCodec: nil, hasAudio: false,
            audioCanCopyToMP4: false, fileBytes: 1
        ))]
        _ = try AIOverlayEdits.text(AIToolArguments(.object(item.call)), at: 0, in: &state)
        project.perform(rebuildsPreview: false) { $0 = state }
        project.selectedTextIDs = []
        project.selectedShapeIDs = []

        // 预览：底片 + 剪辑页预览上的两层叠层，按点摆（Retina 上拍出来是两倍像素）。
        let box = ratio == .wide16x9 ? CGSize(width: 640, height: 360) : CGSize(width: 360, height: 640)
        var previews: [URL] = []
        for time in item.times {
            project.clock.seek(to: time)
            let file = work.appendingPathComponent("\(tag)-preview-\(time).png")
            try await Snapshot.take(PreviewStage(project: project, backdrop: background, box: box), to: file, size: box,
                                    appearance: NSAppearance(named: .aqua))
            previews.append(file)
        }
        // 成片：真跑导出图，按同一时刻抽帧，缩到和预览一样大。
        let exported = try await export(state, name: tag, work: work)
        var stills: [URL] = []
        for time in item.times {
            let file = work.appendingPathComponent("\(tag)-export-\(time).png")
            try Backdrop.frame(of: exported, at: time, fps: 30, size: CGSize(width: box.width * 2, height: box.height * 2), to: file)
            stills.append(file)
        }
        let sheet = out.appendingPathComponent("4-preset-\(tag).png")
        try ContactSheet.write(rows: zip(previews, stills).map { [$0.0, $0.1] },
                               labels: item.times.map { String(format: "t = %.2f s (hit 0.50 s)", $0) },
                               columns: ["Preview", "Export"], to: sheet)
        print("rendered \(sheet.lastPathComponent)")
    }

    private static func export(_ state: TimelineState, name: String, work: URL) async throws -> URL {
        let output = work.appendingPathComponent("\(name).mp4")
        let plan = try await VideoEditExportGraph.plan(
            state: state, settings: VideoEncodeSettings(), subtitleStyle: BurnInStyle(name: "render"),
            subtitleFontURL: nil, output: output, watermark: nil
        )
        defer { try? FileManager.default.removeItem(at: plan.workspace) }
        let (code, log) = Backdrop.run(Backdrop.ffmpeg, plan.arguments, in: plan.workspace)
        guard code == 0 else { throw AIToolError("export failed: \(log.suffix(600))") }
        let product = work.appendingPathComponent("\(name)-product.mp4")
        try? FileManager.default.removeItem(at: product)
        try FileManager.default.copyItem(at: plan.tempOutput, to: product)
        return product
    }
}

/// 预览区的样子：底片在下，上面是剪辑页预览上真的形状层和文字层（同一份 project、同一个时钟）。
private struct PreviewStage: View {
    let project: VideoEditProject
    let backdrop: CGImage
    let box: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: backdrop, scale: 1).resizable().frame(width: box.width, height: box.height)
            ShapeOverlayCanvas(project: project, clock: project.clock, boxSize: box)
            TextOverlayCanvas(project: project, clock: project.clock, boxSize: box)
        }
        .frame(width: box.width, height: box.height)
        .clipped()
    }
}

/// 现画的底片、写成视频、从成片里抽帧、跑 ffmpeg。
enum Backdrop {
    static let ffmpeg = ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]
        ?? FileManager.default.currentDirectoryPath + "/vendor/ffmpeg"

    /// 夜里的冰面：深青到深蓝的斜向渐变，几块亮一点的浮冰；`black` 就是纯黑（片名卡）。
    static func image(_ size: CGSize, black: Bool) -> CGImage {
        let width = Int(size.width), height = Int(size.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard !black else {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(rect)
            return context.makeImage()!
        }
        let colors = [CGColor(srgbRed: 0.16, green: 0.42, blue: 0.47, alpha: 1), CGColor(srgbRed: 0.04, green: 0.12, blue: 0.20, alpha: 1)]
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: rect.maxX, y: 0), options: [])
        let floes: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0.08, 0.08, 0.30, 0.22), (0.62, 0.04, 0.28, 0.16), (0.78, 0.70, 0.18, 0.12)]
        for (x, y, w, h) in floes {
            context.setFillColor(CGColor(srgbRed: 0.78, green: 0.88, blue: 0.92, alpha: 0.55))
            context.fillEllipse(in: CGRect(x: x * rect.width, y: y * rect.height, width: w * rect.width, height: h * rect.height))
        }
        return context.makeImage()!
    }

    /// 一张图铺满 `seconds` 秒的 H.264 视频（AVAssetWriter 直接写，造素材和被测的导出不共用 ffmpeg）。
    static func video(_ image: CGImage, seconds: Double, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: image.width, AVVideoHeightKey: image.height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: image.width, kCVPixelBufferHeightKey as String: image.height
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int(seconds * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let pixels = buffer else { continue }
            CVPixelBufferLockBaseAddress(pixels, [])
            if let base = CVPixelBufferGetBaseAddress(pixels),
               let context = CGContext(data: base, width: image.width, height: image.height, bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw AIToolError("backdrop video: \(writer.error?.localizedDescription ?? "failed")") }
    }

    /// 成片在 `time` 那一帧（`-ss` 落在这一帧之前四分之一帧），缩到 `size`。时刻先照预览那样钉到帧的网格上
    //（`TextAnimator.quantize`），不然两边差一帧。
    static func frame(of video: URL, at time: Double, fps: Double, size: CGSize, to file: URL) throws {
        let frame = (TextAnimator.quantize(time, frameRate: .fps30) * fps).rounded()
        let (code, log) = run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-ss", String(format: "%.4f", (frame - 0.25) / fps),
                                       "-i", video.path, "-frames:v", "1", "-vf", "scale=\(Int(size.width)):\(Int(size.height))", file.path])
        guard code == 0 else { throw AIToolError("frame \(time): \(log.suffix(300))") }
    }

    static func run(_ launchPath: String, _ args: [String], in directory: URL? = nil) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        if let directory { process.currentDirectoryURL = directory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// 拼图：每一行是同一刻的预览和成片，左边标时刻，上面标列名。
enum ContactSheet {
    static func write(rows: [[URL]], labels: [String], columns: [String], to file: URL) throws {
        let images = try rows.map { try $0.map(load) }
        guard let first = images.first?.first else { return }
        let cell = CGSize(width: first.width, height: first.height)
        let gap = 16.0, header = 56.0, label = 44.0
        let width = Int(gap + Double(columns.count) * (cell.width + gap))
        let height = Int(header + Double(images.count) * (cell.height + label + gap))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 0.13, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, title) in columns.enumerated() {
            draw(title, at: CGPoint(x: gap + Double(index) * (cell.width + gap), y: Double(height) - header + 16), size: 26, in: context)
        }
        for (row, cells) in images.enumerated() {
            let top = Double(height) - header - Double(row) * (cell.height + label + gap)
            draw(labels[row], at: CGPoint(x: gap, y: top - label + 12), size: 20, in: context)
            for (column, image) in cells.enumerated() {
                let x = gap + Double(column) * (cell.width + gap)
                context.draw(image, in: CGRect(x: x, y: top - label - cell.height, width: cell.width, height: cell.height))
            }
        }
        guard let sheet = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, sheet, nil)
        guard CGImageDestinationFinalize(destination) else { throw AIToolError("could not write \(file.lastPathComponent)") }
    }

    private static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AIToolError("could not read \(url.lastPathComponent)")
        }
        return image
    }

    private static func draw(_ text: String, at point: CGPoint, size: Double, in context: CGContext) {
        let font = CTFontCreateWithName("Avenir Next Medium" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: 0.92, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
