import Foundation

// The one preset library: native designs first, reusable project pages second. Both the panel and AI read this list.
enum MotionPresetLibrary {
    enum Entry: Identifiable {
        case native(MotionPresetKind)
        case web(UUID, WebMotionClipRecord, URL)

        var id: String {
            switch self {
            case .native(let kind): return kind.rawValue
            case .web(let id, _, _): return "project:\(id.uuidString.lowercased())"
            }
        }
    }

    static func entries(in state: TimelineState) -> [Entry] {
        MotionPresetKind.allCases.map(Entry.native) + state.allClips.compactMap { clip in
            clip.webMotion.map { .web(clip.id, $0, clip.sourceURL) }
        }
    }

    static func template(_ id: String, in state: TimelineState) throws -> WebMotionClipRecord {
        guard let entry = entries(in: state).first(where: { $0.id == id }), case .web(_, let record, _) = entry else {
            throw AIToolError("Unknown web template. Use a project:… id from get_timeline.motion_library; use set_text for native presets.")
        }
        var copy = record
        let canvas = TimelineRenderSize.size(for: state)
        copy.width = Int(canvas.width)
        copy.height = Int(canvas.height)
        copy.fps = state.frameRate.fps
        return copy
    }
}
