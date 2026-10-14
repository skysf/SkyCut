import Foundation

// MARK: - duplicate_items：把时间线上的东西复制一份（纯值）
//
// 管什么：AI 说「这几段再来一遍」「这个标题复制一个到 20 秒」时怎么改 TimelineState。**不另写一套落点**：
// 直接用 ⌘C / ⌘V 那两个纯函数（`TimelineClipboardPayload(copying:)` → `TimelinePaste.apply`），不经过系统剪贴板 ——
// 撞上了往上抬一轨、几组保住上下关系、链接组换新号、每一样换新身份，全和手动粘贴一样（docs/architecture/timeline-clipboard.md）。
// AI 多出来的只有两样：按 id 分类（和 delete_items 同一个分法），落点不给时紧接着这一批的结尾。
// 不管什么：提交、选中、静帧再转一次（AITimelineTools，同手动粘贴那条路）。

enum AIDuplicate {
    struct Selection: Equatable {
        var clips: Set<UUID> = []
        var shapes: Set<UUID> = []
        var texts: Set<UUID> = []
        var cues: Set<UUID> = []
        var filters: Set<UUID> = []
    }

    /// 按 id 分类；链接开着时剪辑带上链接伙伴（同 ⌘C，也同 ⌫）。
    static func selection(_ ids: [UUID], in state: TimelineState, linkage: Bool) throws -> Selection {
        var selection = Selection()
        for id in ids {
            switch AIItemKind.of(id, in: state) {
            case .clip:
                selection.clips.insert(id)
                if linkage { selection.clips.formUnion(state.linkedClipIDs(of: id)) }
            case .text: selection.texts.insert(id)
            case .filter: selection.filters.insert(id)
            case .shape: selection.shapes.insert(id)
            case .subtitle: selection.cues.insert(id)
            case nil: throw AIToolError("Nothing in the project has that id. Call get_timeline for current ids.")
            }
        }
        return selection
    }

    /// 复制一份，最早的那一样落在 `start`（不给就紧接着这一批的结尾）。`track`：剪辑要放的轨（只有一组剪辑时才听它，
    /// 同手动粘贴），名字同 add_clips —— V1、V2…、A1、A2… 是现有的轨，正好比现有的多一条（只有 A1 时写 A2）或
    /// new_video / new_audio 就新开一条。一样都没落下去就抛错。
    static func apply(
        _ selection: Selection, to state: inout TimelineState, at start: Double?, track: String?
    ) throws -> TimelinePasteResult {
        guard let payload = TimelineClipboardPayload(
            copying: state, clips: selection.clips, shapes: selection.shapes, texts: selection.texts,
            cues: selection.cues, filters: selection.filters
        ), let end = payload.end else {
            throw AIToolError("There is nothing to duplicate in those ids.")
        }
        var fresh: UUID?
        var pointing: TrackSlot?
        if let track {
            // 新开的那条先放一条空轨指着它（粘贴只认现有的轨）；复制出来的没落在它上面（比如复制的是画面、指着的是
            // 新音频轨），收尾时收掉，不留空轨。2026-10-06 盲测：写 A2 被当成「没有这条轨」、还叫人去用 set_track。
            switch try AITrackName.target(track, in: state) {
            case .main: pointing = .main
            case .overlay(let index): pointing = .overlay(index)
            case .audio(let index): pointing = .audio(index)
            case .newOverlayTop:
                fresh = state.insertLane(audio: false, at: state.overlayTracks.count, clips: [])
                pointing = .overlay(state.overlayTracks.count - 1)
            case .newAudioBottom:
                fresh = state.insertLane(audio: true, at: state.audioTracks.count, clips: [])
                pointing = .audio(state.audioTracks.count - 1)
            default:
                throw AIToolError("track must be V1, V2…, A1, A2…, new_video or new_audio.")
            }
        }
        let result = TimelinePaste.apply(payload, to: &state, at: max(0, start ?? end), pointing: pointing.map { .track($0) })
        if let fresh {
            state.overlayTracks.removeAll { $0.id == fresh && $0.clips.isEmpty }
            state.audioTracks.removeAll { $0.id == fresh && $0.clips.isEmpty }
        }
        guard !result.isEmpty else { throw AIToolError("SrtFlow could not place the copies.") }
        return result
    }
}
