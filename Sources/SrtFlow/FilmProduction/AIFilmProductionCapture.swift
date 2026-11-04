import Foundation
import SrtFlowCore

// 制作证据的窄 MainActor 捕获：原状态只用于 CAS，求值副本解析与 look/导出相同的有效字幕样式。
// 不把 App 全局样式写回工程，也不在媒体读取队列访问 EncodeQueue。
struct AIFilmProductionCapture: Sendable {
    let original: TimelineState
    let evaluation: TimelineState
    let generation: Int

    @MainActor
    init(_ project: VideoEditProject) {
        original = project.state
        generation = project.documentGeneration
        var resolved = original
        resolved.projectSubtitleStyle = original.subtitleStyle(appWide: EncodeQueue.burnIn.burnInStyle)
        evaluation = resolved
    }

    @MainActor
    func matches(_ project: VideoEditProject) -> Bool {
        project.documentGeneration == generation && project.state == original
            && project.state.subtitleStyle(appWide: EncodeQueue.burnIn.burnInStyle) == evaluation.projectSubtitleStyle
    }
}
