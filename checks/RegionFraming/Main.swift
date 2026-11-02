import AppKit
import CoreGraphics
import Foundation
import SrtFlowMCPKit
@testable import SrtFlow

// 真正的 MCP 编辑 / 批量计划、look、预览与生产导出，不把纯几何断言冒充渲染验收。
@main enum RegionFramingChecks {
    @MainActor static func main() async {
        let domain = "com.srtflow.SrtFlow.regionframingcheck"
        guard Bundle.main.bundleIdentifier == domain else { fatalError("Isolated check bundle required") }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: env["SRTFLOW_REGION_CHECK_DIR"]!).standardizedFileURL.resolvingSymlinksInPath()
        let evidence = env["SRTFLOW_REGION_ARTIFACTS"].map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("evidence")
        let ffmpeg = URL(fileURLWithPath: env["SRTFLOW_FFMPEG"]!)
        var count = 0, failures = 0
        func require(_ value: Bool, _ message: String) {
            count += 1
            if !value { failures += 1; print("FAIL: \(message)") }
        }
        do {
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            var infos: [String: MediaInfo] = [:]
            var sources: [String: RegionPixels] = [:]
            for name in ["landscape", "portrait", "rotate90", "rotate180", "rotate270"] {
                let file = root.appendingPathComponent(name + ".mp4")
                var info = try await MediaProbe.probe(url: file, ffmpeg: ffmpeg).get()
                info.keyframeInterval = 0 // 合成素材是 all-intra，不让无关的代理探测改候选快照。
                infos[name] = info
                sources[name] = try await RegionPixels(RegionFixture.fileFrame(file))
            }
            require(infos["rotate90"]!.displaySize.width == 360 && infos["rotate270"]!.displaySize.height == 640,
                    "rotation metadata must be real, not a portrait-shaped fake")
            var scenarios: [(String, String, CGRect, Bool, CanvasRatio)] = []
            let middle = CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.5)
            for name in ["landscape", "portrait", "rotate90", "rotate180", "rotate270"] {
                for fill in [false, true] { scenarios.append(("\(name)-\(fill ? "fill" : "fit")", name, middle, fill, .auto)) }
            }
            for (index, origin) in [CGPoint(x: 0, y: 0), .init(x: 0.96, y: 0), .init(x: 0, y: 0.94), .init(x: 0.96, y: 0.94)].enumerated() {
                for fill in [false, true] {
                    scenarios.append(("corner\(index)-\(fill ? "fill" : "fit")", "landscape",
                                      CGRect(origin: origin, size: .init(width: 0.04, height: 0.06)), fill, .auto))
                }
            }
            for fill in [false, true] {
                scenarios.append(("wide-to-tall-\(fill)", "landscape", middle, fill, .tall9x16))
                scenarios.append(("tall-to-wide-\(fill)", "portrait", middle, fill, .wide16x9))
                scenarios.append(("odd-pixels-\(fill)", "landscape", CGRect(x: 0.011, y: 0.017, width: 0.041, height: 0.063), fill, .auto))
            }
            var rows: [[String: Any]] = []
            for (label, source, region, fill, ratio) in scenarios {
                let beforeFailures = failures
                print("START: \(label)")
                let f = try RegionFixture(folder: root.appendingPathComponent(label), source: root.appendingPathComponent(source + ".mp4"), info: infos[source]!, canvas: ratio)
                defer { _ = OpenProjects.shared.close(f.project) }
                let result = try await f.edit(region: region, fill: fill)
                let after = f.project.state
                require(result.changedProject && result.payload["framing"]?["region"] != nil
                        && result.payload["framing"]?["visible_region"] != nil && result.payload["framing"]?["transform"] != nil,
                        "\(label): returns actual retained / visible regions and final transform")
                require(after.shapes.isEmpty && after.mainClips.count == 1, "\(label): native crop never inserts masking shapes or extra clips")
                print("STAGE: \(label) preview")
                let preview = try await RegionPixels(f.preview())
                print("STAGE: \(label) export")
                let output = try await RegionPixels(f.export(ffmpeg: ffmpeg))
                print("STAGE: \(label) look")
                let look = try await f.look()
                require(!look.isError && look.images.count == 1 && look.payload["looked_at"] == "timeline", "\(label): production look returns a real image")
                let looked = try RegionPixels.jpeg(look.images.first ?? Data())
                let previewError = preview.error(source: sources[source]!, region: region, fill: fill)
                let exportError = output.error(source: sources[source]!, region: region, fill: fill)
                let lookError = looked.error(source: sources[source]!, region: region, fill: fill)
                let difference = preview.difference(output)
                require(previewError < 0.055, "\(label): preview matches independent source rectangle (error \(previewError))")
                require(exportError < 0.055, "\(label): export matches independent source rectangle (error \(exportError))")
                require(lookError < 0.065, "\(label): look shows the selected region (error \(lookError))")
                require(difference < 0.04, "\(label): preview/export agree (mean RGB difference \(difference))")
                try preview.save(evidence.appendingPathComponent(label + "-preview.png"))
                try output.save(evidence.appendingPathComponent(label + "-export.png"))
                try look.images[0].write(to: evidence.appendingPathComponent(label + "-look.jpg"))
                f.project.effectiveUndoManager!.undo()
                require(f.project.state == f.before && !f.project.effectiveUndoManager!.canUndo, "\(label): one undo restores original crop and placement")
                f.project.effectiveUndoManager!.redo()
                require(f.project.state == after, "\(label): one redo restores the precise region")
                rows.append(["case": label, "preview_error": previewError, "export_error": exportError, "look_error": lookError, "preview_export_difference": difference])
                if failures == beforeFailures { print("PASS: \(label), real look / preview / export / undo") }
            }
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("measurements.json"))

            // 强色度棋盘放大后比较两条真实管线。几何用上面的低频 R/G 坐标尺守，色度插值不充当源位置真值。
            let chromaFile = root.appendingPathComponent("chroma.mp4")
            let chromaInfo = try await MediaProbe.probe(url: chromaFile, ffmpeg: ffmpeg).get()
            let chroma = try RegionFixture(folder: root.appendingPathComponent("chroma-fill"), source: chromaFile, info: chromaInfo, canvas: .tall9x16)
            _ = try await chroma.edit(region: middle, fill: true)
            let chromaPreview = try await RegionPixels(chroma.preview())
            let chromaExport = try await RegionPixels(chroma.export(ffmpeg: ffmpeg))
            let chromaDifference = chromaPreview.difference(chromaExport)
            require(chromaDifference < 0.04, "odd crop chroma: preview/export must agree after enlargement (difference \(chromaDifference))")
            try chromaPreview.save(evidence.appendingPathComponent("chroma-preview.png"))
            try chromaExport.save(evidence.appendingPathComponent("chroma-export.png"))

            let f = try RegionFixture(folder: root.appendingPathComponent("validation"), source: root.appendingPathComponent("landscape.mp4"), info: infos["landscape"]!)
            var bad = f.arguments(region: middle, fill: false).objectValue!
            bad["region"] = ["x": 0, "y": 0, "width": 0.001, "height": 0.1]
            for input: JSONValue in [.object(bad), ["clip_id": .string(AIShortIDs(state: f.before).short(f.id)), "region": ["x": 0, "y": 0, "width": 0.1, "height": 0.1], "scale": 2]] {
                do { _ = try await AIClipTools.plan(AIToolArguments(input), f.project); require(false, "invalid region must fail before modification") }
                catch { require(f.project.state == f.before && !f.project.effectiveUndoManager!.canUndo, "invalid / conflicting region leaves no modification or undo") }
            }
            let valid = f.arguments(region: middle, fill: false)
            do {
                _ = try await AIBatchEditTools.planClips(AIToolArguments(["clips": [valid, .object(bad)]]), f.project)
                require(false, "bad last region in batch must fail")
            } catch { require(f.project.state == f.before && !f.project.effectiveUndoManager!.canUndo, "batch failure leaves no first-half region modification") }
            let batch = try await AIBatchEditTools.planClips(AIToolArguments(["clips": [valid, f.arguments(region: middle, fill: true)]]), f.project)
            let batchResult = try AIBatchEditTools.applyClips(batch, f.project)
            require(batchResult.payload["count"] == 2 && batchResult.payload["clips"]?.arrayValue?.allSatisfy { $0["framing"]?["transform"] != nil } == true,
                    "batch reuses single edit region and returns each final transform")
            f.project.effectiveUndoManager!.undo()
            require(f.project.state == f.before && !f.project.effectiveUndoManager!.canUndo, "whole region batch is one undo")
        } catch {
            require(false, "acceptance could not execute: \(error)")
        }
        print("Region framing: \(count) assertions, \(failures) failures")
        UserDefaults.standard.removePersistentDomain(forName: domain)
        exit(failures == 0 ? 0 : 1)
    }
}
