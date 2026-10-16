import Foundation

// 选择的两个跨类型入口：⌘A 全选 / ⌘⇧A 取消，以及「拖一个选中的东西时谁跟着走」（含联动压在主轨块上的东西）；
// 还有「恰好选中一个时的那一个」（检查器、预览的选中框读它；2026-10-17 从 VideoEditProject.swift 搬过来，那个文件在行数基线里只许降）。
//
// 2026-09-25 用户拍板：⌘A 选中时间线上的一切 —— 剪辑（含隐藏轨上的）、形状、文字、数字、
// 字幕 cue、滤镜段；标记和转场跟着各自的段走（它们长在段上，段动 / 段删它们就动 / 删）；
// 磁吸开着时拖这一片，主轨不动（`draggingClipIDs` 的 magnetPinsMainTrack）。
// 快捷键接在 `VideoEditView.handleEvent`（本地按键监听，带 ⌘ 的组合里只放行这两个）。
// 选择模型的合同见 docs/architecture/subtitle-track-visibility-and-layout.md。
@MainActor
extension VideoEditProject {

    /// 恰好选中一个时的那一个（检查器只在单选时展示细节）。
    ///
    /// 判据是**跨三类**只选中一个（`EditSelection.soleClipID`），不是"剪辑里只选
    /// 中一个"：框选能同时选中剪辑和形状，那种情况下预览该一套框都不画。
    var selectedClip: EditClip? {
        selection.soleClipID.flatMap { state.clip(with: $0) }
    }

    var selectedShape: ShapeAnnotation? {
        selection.soleShapeID.flatMap { id in state.shapes.first { $0.id == id } }
    }

    var selectedTextOverlay: TextOverlay? {
        selection.soleTextID.flatMap { id in state.textOverlays.first { $0.id == id } }
    }

    /// 预览上那个字幕布局拖框的归属。同样只在跨三类唯一选中时才有。
    var selectedSubtitleCueID: UUID? { selection.soleSubtitleCueID }

    /// ⌘A：时间线上的一切。走框选那一个混选入口（`applyBoxSelection`），所以标记和转场的
    /// 选择照样被清掉 —— 它们跟着段走，不单独选。
    func selectAllOnTimeline() {
        applyBoxSelection(
            clips: Set(state.allClips.map(\.id)),
            shapes: Set(state.shapes.map(\.id)),
            texts: Set(state.textOverlays.map(\.id)),
            cues: Set(state.allSubtitleCues.map(\.id)),
            filters: Set(state.filters.map(\.id))
        )
    }

    /// 跟着一起动的非剪辑伙伴：框选 / ⌘A 一起选中的形状、文字、字幕 cue 和滤镜段。
    ///
    /// 只在**被拖的那个本来就在选中集合里**时才有伙伴 —— 拖一个没选中的东西
    /// 是「单选它再拖」，那时候整片选择已经被换掉了，不该再拉着旧的一片走。
    func movingCompanions(
        draggedID: UUID,
        movingClipIDs: Set<UUID>
    ) -> (
        shapes: [(id: UUID, span: TimelineSpan)],
        texts: [(id: UUID, span: TimelineSpan)],
        cues: [(id: UUID, span: TimelineSpan)],
        filters: [(id: UUID, span: TimelineSpan)],
        ids: Set<UUID>
    ) {
        let engaged = movingClipIDs.contains(draggedID)
            || selectedShapeIDs.contains(draggedID)
            || selectedTextIDs.contains(draggedID)
            || selectedSubtitleCueIDs.contains(draggedID)
            || selectedFilterIDs.contains(draggedID)
        guard engaged else { return ([], [], [], [], []) }
        let shapes = state.shapes
            .filter { selectedShapeIDs.contains($0.id) }
            .map { (id: $0.id, span: TimelineSpan(start: $0.timelineStart, end: $0.timelineEnd)) }
        let texts = state.textOverlays
            .filter { selectedTextIDs.contains($0.id) }
            .map { (id: $0.id, span: TimelineSpan(start: $0.timelineStart, end: $0.timelineEnd)) }
        let cues = state.allSubtitleCues
            .filter { selectedSubtitleCueIDs.contains($0.id) }
            .map { (id: $0.id, span: TimelineSpan(start: $0.start, end: $0.end)) }
        let filters = state.filters
            .filter { selectedFilterIDs.contains($0.id) }
            .map { (id: $0.id, span: TimelineSpan(start: $0.timelineStart, end: $0.timelineEnd)) }
        let ids = Set(shapes.map(\.id)).union(texts.map(\.id)).union(cues.map(\.id)).union(filters.map(\.id))
        return (shapes, texts, cues, filters, ids)
    }

    /// 联动开着时，压在 `movingIDs` 里那几段**主轨块**上的东西（`TimelineLinkage.attachments`，底下压着的主轨块全在
    /// 名单里才算）；关着是空的。拖主轨块时它们是这一轮的成员：实时跟着画、没有障碍、不当吸附参考点
    /// （docs/architecture/timeline-linkage.md）。
    func linkedAttachments(of movingIDs: Set<UUID>) -> TimelineLinkage.Attachments {
        guard linkageEnabled else { return .none }
        let hosts = Set(movingIDs.filter { state.location(of: $0)?.track.isMain == true })
        return TimelineLinkage.attachments(of: hosts, in: state)
    }
}
