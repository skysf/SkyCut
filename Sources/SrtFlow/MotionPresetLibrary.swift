import Foundation

// The one preset library: native designs, official web designs, then reusable project pages. The panel and AI read this list.
enum MotionPresetLibrary {
    enum Entry: Identifiable {
        case native(MotionPresetKind)
        case official(OfficialWebMotionTemplate)
        case web(UUID, WebMotionClipRecord, URL)

        var id: String {
            switch self {
            case .native(let kind): return kind.rawValue
            case .official(let template): return template.id
            case .web(let id, _, _): return "project:\(id.uuidString.lowercased())"
            }
        }
    }

    static func entries(in state: TimelineState) -> [Entry] {
        MotionPresetKind.allCases.map(Entry.native) + OfficialWebMotionTemplate.allCases.map(Entry.official) + state.allClips.compactMap { clip in
            clip.webMotion.map { .web(clip.id, $0, clip.sourceURL) }
        }
    }

    static func template(_ id: String, in state: TimelineState) throws -> WebMotionClipRecord {
        guard let entry = entries(in: state).first(where: { $0.id == id }) else {
            throw AIToolError("Unknown web template. Use an official:… or project:… id from get_timeline.motion_library; use set_text for native presets.")
        }
        var copy: WebMotionClipRecord
        switch entry {
        case .official(let template): copy = try template.record()
        case .web(_, let record, _): copy = record
        case .native: throw AIToolError("Native motion presets use set_text motion_preset.")
        }
        let canvas = TimelineRenderSize.size(for: state)
        copy.width = Int(canvas.width)
        copy.height = Int(canvas.height)
        copy.fps = state.frameRate.fps
        return copy
    }
}
