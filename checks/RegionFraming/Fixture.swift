import AppKit
import AVFoundation
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 实际工程 / 编辑入口的夹具。只生成测试工程，不打开用户 App，不注入几何或渲染替身。
@MainActor final class RegionFixture {
    let project: VideoEditProject
    let before: TimelineState
    let id: UUID

    init(folder: URL, source: URL, info: MediaInfo, canvas: CanvasRatio = .auto) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let registered = OpenProjects.shared.newProject(savingAs: folder.appendingPathComponent("region.skycut"), placement: .background) else {
            throw AIToolError(OpenProjects.shared.failure ?? "Could not create isolated check project")
        }
        project = registered
        var state = TimelineState()
        state.canvasRatio = canvas
        state.mainMagnet = false
        var clip = EditClip(sourceURL: source, sourceDuration: 0.5, timelineStart: 0, info: info)
        clip.crop = ClipCrop(top: 0.1, leading: 0.1)
        clip.placement = ClipPlacement(centerX: 0.4, centerY: 0.6, width: 0.7, height: 0.8)
        state.mainClips = [clip]
        id = clip.id
        before = state
        project.restoreTimeline(state)
        project.effectiveUndoManager!.removeAllActions()
        AIReadGrants.shared.remember([folder, source.deletingLastPathComponent()])
    }

    func arguments(region: CGRect, fill: Bool) -> JSONValue {
        ["clip_id": .string(AIShortIDs(state: project.state).short(id)),
         "region": ["x": .number(region.minX), "y": .number(region.minY), "width": .number(region.width), "height": .number(region.height)],
         "fit": .string(fill ? "fill" : "fit")]
    }

    func edit(region: CGRect, fill: Bool) async throws -> AIToolResult {
        let args = arguments(region: region, fill: fill)
        if let error = MCPArgumentCheck.problem(tool: .editClip, arguments: args) { throw AIToolError(error) }
        let plan = try await AIClipTools.plan(AIToolArguments(args), project)
        return try AIClipTools.apply(plan, project)
    }

    func look() async throws -> AIToolResult {
        try await AILookTool.look(AIToolArguments(["time": 0.25, "size": "large"]), project)
    }

    func export(ffmpeg: URL) async throws -> CGImage {
        print("EXPORT: preparing graph")
        let plan = try await VideoEditExportGraph.plan(
            state: project.state, settings: VideoEncodeSettings(), subtitleStyle: BurnInStyle(name: "region-check"),
            subtitleFontURL: nil, output: project.documentURL!.deletingLastPathComponent().appendingPathComponent("export.mp4"), watermark: nil
        )
        defer { try? FileManager.default.removeItem(at: plan.workspace) }
        print("EXPORT: running ffmpeg")
        try await FFmpegProcess().run(executable: ffmpeg, arguments: plan.arguments, workingDirectory: plan.workspace)
        print("EXPORT: decoding output frame")
        return try await Self.fileFrame(plan.tempOutput)
    }

    static func fileFrame(_ url: URL) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        return try await generator.image(at: CMTime(seconds: 0.25, preferredTimescale: 600)).image
    }

    func preview() async throws -> CGImage {
        guard let built = await VideoEditCompositionBuilder.build(from: project.state) else { throw AIToolError("Preview build failed") }
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        return try await generator.image(at: CMTime(seconds: 0.25, preferredTimescale: 600)).image
    }
}
