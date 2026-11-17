import Foundation
import SrtFlowCore

// MARK: - 联动：压在主轨块上的东西跟着它的画面走
//
// 管什么：「联动」开关（`EditorToggles.linkage`，默认开）开着时，时间线上任何不在主轨上的东西 —— 上层轨 / 音频轨的段、
// 文字、形状（含盖一块）、滤镜段、两条轨上的字幕句 —— 怎么跟着它底下压着的主轨**画面**走：画面挪了它挪、画面没了它没了。
// 一次改动结束时（`VideoEditProject.perform` / `liveApply` 收尾）拿改之前、改之后的主轨比一遍，这次操作没碰过的东西按
// 下面的规矩挪 / 删（`follow`）；拖动一段主轨块时压在它上面的东西要实时跟着画，那份名单也从这里要（`attachments`）。
// 不管什么：显式的链接组（`linkGroup`：视频 + 分离出来的音频，`linkedClipIDs`，照旧、更强）、开关本身、撤销（调用方一次
// perform 一步）、拖动中怎么画（`ClipDragPlan` 的成员）、撞上了往哪让（`TimelineLinkageLanding`）。
//
// 规矩（2026-10-02 按用户体验定的，理由见 docs/plans/2026-10-02-timeline-linkage.md；长期约束见
// docs/architecture/timeline-linkage.md）：
// 1. 跟着**画面**走，不跟块的 id：每样东西看自己底下压着主轨的哪些画面（哪个素材的第几秒），画面挪到哪它挪到哪。
//    分割、cut_speech、定格插入切出来的新 id 照样认得出（同一个素材、接着的源时间）；同 id 的段永远优先。
//    同 id 的段**换了素材**（upscale 换源、edit_clip 换文件：只换读哪个文件、从它的第几秒读，时间线上的位置和长度不动）按
//    「这段现在摆的地方，画面就是改之前这段的画面」记（`Piece.rebased`）—— 新文件的 0 秒不是原片的 0 秒，按源时间对账会把压在
//    上面的东西挪一个偏移（2026-10-15，docs/bugfixes/2026-10-15-linkage-follows-source-shift-after-swap.md）。
// 2. 完全落在一段主轨块里的：删它就删、挪它就挪（按它底下最早还在的那一截画面挪，和那截画面的相对位置不变）。
// 3. 跨两段的：底下的画面**全部**挪同一个量才跟，否则不动；画面**全没了**才删。
// 4. 画面没了只在**真删**的操作里连带删（`deletesContent`：⌫、AI 的 delete_items / cut_speech）；裁切 / 变速让画面
//    没了的，东西留在原地不动 —— 字幕句除外（第 5 条）。
// 5. 字幕句不整句平移：两头各自跟着画面换算，说话的那几秒剩不到一半就删，裁切让它没了的也删（2026-10-15，`LinkageCueFollow`）；
//    底下的段整个没了又不是真删才留在原地、报出来。
// 6. 一段画面自己分出去的声音（J / L 切伸到隔壁镜头底下的也是）跟着那段画面走，不看底下压着哪几段（2026-11-16，`LinkagePartnerSound`）。
// 纯值、不 import AppKit：scripts/check-timeline-snap.sh 直接编（checks/TimelineSnap/Linkage.swift、LinkageCues.swift）。

enum TimelineLinkage {
    static let epsilon = 0.000_5

    /// 一次操作之后联动挪了几样、删了几样（AI 的结果里报出来）。
    struct Report: Equatable {
        var moved = 0
        var deleted = 0
        /// 磁吸这次把 V1 的几段挪了位置 —— 不是联动，`perform` 收尾时 `MainMagnet.settle` 数的；`isEmpty` 只问联动。
        var magnetPacked = 0
        /// 跟着走的字幕里，底下有画面被剪掉、收短了的（字里可能还留着剪掉的词）。
        var shortenedCues: Set<UUID> = []
        /// 说话的那几秒大半没了、底下的段整个没了又不是真删（少见），留在原地的字幕：人一眼看得见，AI 要在结果里看到。
        var leftCues: Set<UUID> = []
        /// `deleted` 里有几句是字幕（说的话被删掉 / 裁掉了）：AI 只看到一个 deleted 会以为删了段。
        var deletedCues = 0
        /// Clips pushed before 0:00 that lost their head to stay in sync, and how many seconds (`LinkageHeadTrims`).
        var trimmedHeads: [UUID: Double] = [:]
        var isEmpty: Bool { moved == 0 && deleted == 0 && leftCues.isEmpty && trimmedHeads.isEmpty }
    }

    // MARK: 主轨的画面账

    /// 主轨一段的画面：时间线 `[start, end)` 对应素材的哪一截。
    struct Piece {
        let id: UUID
        let start: Double
        let end: Double
        let sourceStart: Double
        let speed: Double
        let asset: AssetKey

        /// 新切出来的段要按素材认：图片段的身份是原图（静帧缓存随时会换），别的是源文件。
        struct AssetKey: Hashable {
            var url: URL
            var audioOnly: Bool
        }

        init(_ clip: EditClip) {
            id = clip.id
            start = clip.timelineStart
            end = clip.timelineEnd
            sourceStart = clip.sourceStart
            speed = max(0.05, clip.speed)
            asset = AssetKey(url: clip.stillImageURL ?? clip.sourceURL, audioOnly: clip.isAudioOnly)
        }

        private init(id: UUID, start: Double, end: Double, sourceStart: Double, speed: Double, asset: AssetKey) {
            self.id = id
            self.start = start
            self.end = end
            self.sourceStart = sourceStart
            self.speed = speed
            self.asset = asset
        }

        /// 这段改之后的账。同 id 换了素材（upscale 换源、edit_clip 换文件）时按「这段现在摆的地方，画面就是改之前这段的画面」记：
        /// 素材和入点都按改之前的 `was`，只有时间线上的位置、长度、速度是现在的 —— 新文件的 0 秒不是原片的 0 秒，照新入点对账
        /// 会把压在上面的东西挪一个偏移。素材没换就是它自己。
        func rebased(onto was: Piece) -> Piece {
            guard asset != was.asset else { return self }
            return Piece(id: id, start: start, end: end, sourceStart: was.sourceStart, speed: speed, asset: was.asset)
        }

        var sourceEnd: Double { source(at: end) }
        func source(at time: Double) -> Double { sourceStart + (time - start) * speed }
        func time(atSource source: Double) -> Double { start + (source - sourceStart) / speed }
        func overlaps(_ span: TimelineSpan) -> Bool { start < span.end - epsilon && span.start < end - epsilon }
        func contains(_ span: TimelineSpan) -> Bool { start <= span.start + epsilon && span.end <= end + epsilon }
    }

    /// 一样东西底下的画面这次怎么了。
    enum Outcome: Equatable {
        case stay
        case move(by: Double)
        case delete
    }

    /// 改之前、改之后的主轨画面账。
    struct Ledger {
        /// 改之前主轨上的段（时间顺序）。
        let before: [Piece]
        /// 改之后同 id 的段在哪（不管在哪条轨：主轨块拖去上层轨照样认）。
        let afterByID: [UUID: Piece]
        /// 改之后主轨上这次**新出来**的段（分割 / 定格切出来的右半）。
        let fresh: [Piece]

        init(before: TimelineState, after: TimelineState) {
            self.before = before.mainClips.map(Piece.init)
            let was = Dictionary(before.allClips.map { ($0.id, Piece($0)) }, uniquingKeysWith: { first, _ in first })
            // 同 id 换了素材的按改之前的素材和入点记账（`rebased`）。
            afterByID = Dictionary(
                after.allClips.map { clip in (clip.id, was[clip.id].map { Piece(clip).rebased(onto: $0) } ?? Piece(clip)) },
                uniquingKeysWith: { first, _ in first }
            )
            fresh = after.mainClips.filter { was[$0.id] == nil }.map(Piece.init)
        }

        /// 占着 `span` 的东西该怎么办（规矩 2–4）。
        func outcome(for span: TimelineSpan, deletesContent: Bool) -> Outcome {
            guard span.end - span.start > epsilon else { return .stay }
            let hosts = before.filter { $0.overlaps(span) }
            guard !hosts.isEmpty else { return .stay }
            let inside = hosts.contains { $0.contains(span) }
            var survivors: [(at: Double, delta: Double)] = []
            for host in hosts {
                let lo = host.source(at: max(span.start, host.start))
                let hi = host.source(at: min(span.end, host.end))
                // 同 id 的段优先：它还盖着这截画面就只认它（粘贴 / 复制出来的同素材新段不算画面挪过去了）。
                let same = afterByID[host.id].flatMap { survivor($0, host: host, lo: lo, hi: hi) }
                if let same {
                    survivors.append(same)
                    continue
                }
                for piece in fresh where piece.asset == host.asset {
                    if let found = survivor(piece, host: host, lo: lo, hi: hi) { survivors.append(found) }
                }
            }
            guard !survivors.isEmpty else { return deletesContent ? .delete : .stay }
            survivors.sort { $0.at < $1.at }
            let delta = survivors[0].delta
            if !inside, !survivors.allSatisfy({ abs($0.delta - delta) <= epsilon }) { return .stay }
            return abs(delta) <= epsilon ? .stay : .move(by: delta)
        }

        /// 一段画面改之后可能在哪几段里：同 id 的那段在前（不管在哪条轨），再是这次新出来的同素材段。
        func survivors(of host: Piece) -> [Piece] {
            (afterByID[host.id].map { [$0] } ?? []) + fresh.filter { $0.asset == host.asset }
        }

        /// `piece` 还盖着 `host` 的素材 `[lo, hi)` 里的哪一截；盖着就给出那截最早一点改之前在哪、挪了多少。
        private func survivor(_ piece: Piece, host: Piece, lo: Double, hi: Double) -> (at: Double, delta: Double)? {
            let from = max(lo, piece.sourceStart)
            let to = min(hi, piece.sourceEnd)
            guard to - from > epsilon else { return nil }
            let wasAt = host.time(atSource: from)
            return (wasAt, piece.time(atSource: from) - wasAt)
        }
    }

    /// 主轨的画面有没有挪过：没挪就什么都不用算（每次 perform / liveApply 都会问一遍）。
    struct Signature: Equatable {
        var id: UUID
        var start: Double
        var sourceStart: Double
        var sourceDuration: Double
        var speed: Double
    }

    static func signature(of state: TimelineState) -> [Signature] {
        state.mainClips.map {
            Signature(id: $0.id, start: $0.timelineStart, sourceStart: $0.sourceStart, sourceDuration: $0.sourceDuration, speed: $0.speed)
        }
    }

    // MARK: 一次改动收尾：没被碰过的东西跟着画面走

    /// 把 `after` 里这次操作**没碰过**的非主轨东西按 `before` → `after` 主轨画面的变化挪 / 删；再让生成的字幕句跟着它的那段声音走
    /// （声音不在主轨上时，`CaptionSourceFollow`：配音段挪了字幕跟着挪）。
    /// `deletesContent`：这次是真删（⌫、delete_items、cut_speech）才连带删画面没了的东西。返回挪了几样、删了几样。
    @discardableResult
    static func follow(from before: TimelineState, to after: inout TimelineState, deletesContent: Bool) -> Report {
        let mainMoved = signature(of: before) != signature(of: after)
        var report = mainMoved ? followMain(from: before, to: &after, deletesContent: deletesContent) : Report()
        // A clip pushed before 0:00 (by the AI's V1 ripple or by rule 13) lost its head: the AI is told which.
        if mainMoved { report.trimmedHeads = LinkageHeadTrims.find(before: before, after: after) }
        // 主轨那条挪过的字幕不再碰（`plan` 只看这次没变过的句子）。
        let captions = CaptionSourceFollow.plan(from: before, to: after, deletesContent: deletesContent)
        CaptionSourceFollow.apply(captions, to: &after)
        report.moved += captions.timings.count
        report.deleted += captions.deletes.count
        report.deletedCues += captions.deletes.count
        report.shortenedCues.formUnion(captions.shortened)
        report.leftCues.formUnion(captions.left)
        return report
    }

    /// 主轨画面变了：压在上面、这次没碰过的东西跟着挪 / 删。
    private static func followMain(from before: TimelineState, to after: inout TimelineState, deletesContent: Bool) -> Report {
        let ledger = Ledger(before: before, after: after)
        var plan = Plan()

        let oldClips = Dictionary(before.laneClips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for clip in after.laneClips {
            guard let old = oldClips[clip.id], old == clip else { continue }
            // 规矩 13：一段画面自己分出去的声音（J / L 切伸到隔壁镜头底下的也是）跟着那段画面走，不看底下压着哪几段。
            let own = LinkagePartnerSound.outcome(of: old, before: before, after: after, deletesContent: deletesContent) {
                ledger.outcome(for: $0.span, deletesContent: deletesContent)
            }
            Plan.take(own ?? ledger.outcome(for: old.span, deletesContent: deletesContent), id: clip.id, start: old.timelineStart, into: &plan.clips)
        }
        let oldShapes = Dictionary(before.shapes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for shape in after.shapes {
            guard let old = oldShapes[shape.id], old == shape else { continue }
            Plan.take(ledger.outcome(for: old.span, deletesContent: deletesContent), id: shape.id, start: old.timelineStart, into: &plan.shapes)
        }
        let oldTexts = Dictionary(before.textOverlays.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for text in after.textOverlays {
            guard let old = oldTexts[text.id], old == text else { continue }
            Plan.take(ledger.outcome(for: old.span, deletesContent: deletesContent), id: text.id, start: old.timelineStart, into: &plan.texts)
        }
        let oldFilters = Dictionary(before.filters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for filter in after.filters {
            guard let old = oldFilters[filter.id], old == filter else { continue }
            Plan.take(ledger.outcome(for: old.span, deletesContent: deletesContent), id: filter.id, start: old.timelineStart, into: &plan.filters)
        }
        // 字幕句：两头各自跟着画面换算（规矩 12，`LinkageCueFollow`）；换了位置、中间插进别的才照老规矩整句挪。
        let oldCues = Dictionary(before.allSubtitleCues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let originals = Dictionary(before.subtitleCues(of: .original).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let links = before.subtitleCompanion?.translationLinks ?? [:]
        for cue in after.allSubtitleCues {
            guard let old = oldCues[cue.id], old == cue else { continue }
            plan.cues.take(LinkageCueFollow.outcome(
                old, speech: LinkageCueFollow.speech(of: old, originals: originals, links: links),
                hosts: ledger.before, survivors: ledger.survivors(of:), deletesContent: deletesContent,
                fallback: { ledger.outcome(for: old.span, deletesContent: deletesContent) }
            ), id: cue.id)
        }

        // 这次操作自己挪过的段 / 文字 / 滤镜（拖动的成员）撞上了也要让开，和联动挪的一起交给落点。
        let movedByEdit = after.laneClips.filter { clip in oldClips[clip.id].map { $0.timelineStart != clip.timelineStart } ?? false }.map(\.id)
        let textsByEdit = after.textOverlays.filter { text in oldTexts[text.id].map { $0.timelineStart != text.timelineStart } ?? false }.map(\.id)
        let filtersByEdit = after.filters.filter { filter in oldFilters[filter.id].map { $0.timelineStart != filter.timelineStart } ?? false }.map(\.id)

        plan.apply(to: &after)
        TimelineLinkageLanding.settle(
            lanes: Set(plan.clips.moves.keys).union(movedByEdit),
            texts: Set(plan.texts.moves.keys).union(textsByEdit),
            filters: Set(plan.filters.moves.keys).union(filtersByEdit),
            in: &after
        )
        return plan.report
    }

    /// 算好了要挪谁、删谁，再一次写进去。
    struct Plan {
        struct Kind {
            var moves: [UUID: Double] = [:]
            var deletes: Set<UUID> = []
        }

        /// 字幕句：换成什么时间（两头各自换算过的）、删哪几句，以及收短了 / 留在原地的（报给 AI）。
        struct CueKind {
            var timings: [UUID: SubtitleTrackEditing.Timing] = [:]
            var deletes: Set<UUID> = []
            var shortened: Set<UUID> = []
            var left: Set<UUID> = []

            mutating func take(_ outcome: LinkageCueFollow.Outcome, id: UUID) {
                switch outcome {
                case .stay: break
                case .delete: deletes.insert(id)
                case .leftBehind: left.insert(id)
                case .retime(let timing, let cut):
                    timings[id] = timing
                    if cut { shortened.insert(id) }
                }
            }
        }

        var clips = Kind()
        var shapes = Kind()
        var texts = Kind()
        var filters = Kind()
        var cues = CueKind()

        var report: Report {
            let kinds = [clips, shapes, texts, filters]
            return Report(
                moved: kinds.reduce(0) { $0 + $1.moves.count } + cues.timings.count,
                deleted: kinds.reduce(0) { $0 + $1.deletes.count } + cues.deletes.count,
                shortenedCues: cues.shortened, leftCues: cues.left, deletedCues: cues.deletes.count
            )
        }

        /// 记下的起点不夹：段挪到时间线开头之前的那一截要裁掉头（`movedForLinkage`），别的东西照旧夹在 0。
        static func take(_ outcome: Outcome, id: UUID, start: Double, into kind: inout Kind) {
            switch outcome {
            case .stay: break
            case .move(let delta): kind.moves[id] = start + delta
            case .delete: kind.deletes.insert(id)
            }
        }

        func apply(to state: inout TimelineState) {
            for id in clips.deletes { state.remove(id) }
            for (id, start) in clips.moves { state.update(id) { $0.moveForLinkage(to: start) } }
            if !shapes.deletes.isEmpty { state.shapes.removeAll { shapes.deletes.contains($0.id) } }
            for (id, start) in shapes.moves { state.updateShape(id) { $0.timelineStart = max(0, start) } }
            if !texts.deletes.isEmpty { state.textOverlays.removeAll { texts.deletes.contains($0.id) } }
            for (id, start) in texts.moves { state.updateTextOverlay(id) { $0.timelineStart = max(0, start) } }
            if !filters.deletes.isEmpty { state.filters.removeAll { filters.deletes.contains($0.id) } }
            for (id, start) in filters.moves { state.updateFilter(id) { $0.timelineStart = max(0, start) } }
            if !cues.deletes.isEmpty || !cues.timings.isEmpty {
                state.editSubtitleTracks { original, companion in
                    SubtitleTrackEditing.removeCues(ids: cues.deletes, original: &original, companion: &companion)
                    SubtitleTrackEditing.setTimings(cues.timings, original: &original, companion: &companion)
                }
            }
            if !texts.deletes.isEmpty { state.compactTextRows() }
            if !filters.deletes.isEmpty { state.compactFilterLayers() }
        }
    }

    // MARK: 拖动计划要的名单

    /// 压在某几段主轨块上的一样东西。`host`：它底下最早的那段（磁吸下按这段实际落到哪再平一次，`realignCompanions`）。
    struct Attachment: Equatable {
        var id: UUID
        var span: TimelineSpan
        var host: UUID
    }

    /// 压在这几段主轨块上的东西：底下压着的主轨块**全在** `hosts` 里才算（跨到别的块上的不算 —— 松手之后由 `follow`
    /// 按规矩 3 决定跟不跟）。
    struct Attachments: Equatable {
        var clips: [Attachment] = []
        var shapes: [Attachment] = []
        var texts: [Attachment] = []
        var cues: [Attachment] = []
        var filters: [Attachment] = []

        static let none = Attachments()

        var ids: Set<UUID> {
            Set((clips + shapes + texts + cues + filters).map(\.id))
        }
    }

    static func attachments(of hosts: Set<UUID>, in state: TimelineState) -> Attachments {
        guard !hosts.isEmpty else { return .none }
        let pieces = state.mainClips.map(Piece.init)
        func attachment(_ id: UUID, _ span: TimelineSpan) -> Attachment? {
            let under = pieces.filter { $0.overlaps(span) }
            guard let first = under.first, under.allSatisfy({ hosts.contains($0.id) }) else { return nil }
            return Attachment(id: id, span: span, host: first.id)
        }
        var result = Attachments()
        result.clips = state.laneClips.compactMap { attachment($0.id, $0.span) }
        result.shapes = state.shapes.compactMap { attachment($0.id, $0.span) }
        result.texts = state.textOverlays.compactMap { attachment($0.id, $0.span) }
        result.cues = state.allSubtitleCues.compactMap { attachment($0.id, $0.span) }
        result.filters = state.filters.compactMap { attachment($0.id, $0.span) }
        return result
    }
}

// MARK: - 规矩 13：一段画面分出去的声音跟着它自己的画面走
//
// 管什么：音频轨上的一段声音如果是某段画面**自己**分出去的（同一个链接组、同一个文件、「源 ↔ 时间线」的换算和画面对得上 ——
// 分离音频、add_clips sound=separate、set_transition 的 sound 分出来的都是），联动收尾时它按**那段画面**挪了多少挪，
// 不按它底下压着哪几段主轨块（规矩 2、3）。
// 为什么（docs/bugfixes/2026-11-16-separated-sound-left-behind-on-magnet-repack.md）：J / L 切的声音会伸到隔壁镜头底下，
// 跨在两段主轨块上；磁吸开着时调换镜头、裁隔壁那段，自己那段画面被排挪了、隔壁那段没挪（或挪了别的量），按「底下的画面全部
// 挪同一个量才跟」它就留在原地 —— 声音和自己的画面错开一整段。显式的链接组本来就说「更强、拉开了也跟」（timeline-linkage.md 一）。
// 不管什么：别的东西怎么跟（`TimelineLinkage.followMain`）、这次操作自己碰过的不再碰（规矩 5，调用方只问没碰过的）。

enum LinkagePartnerSound {
    /// 这段声音是哪段画面分出去的：同组、同文件、有画面、换算对得上（速度一样、同一个源时刻在时间线上同一刻）。不是就 nil。
    static func picture(of sound: EditClip, in state: TimelineState) -> EditClip? {
        guard sound.isAudioOnly, let group = sound.linkGroup else { return nil }
        return state.allClips.first { picture in
            picture.linkGroup == group && !picture.isAudioOnly && picture.sourceURL == sound.sourceURL
                && abs(picture.speed - sound.speed) < 1e-9
                && abs(picture.timelineTime(atSource: 0) - sound.timelineTime(atSource: 0)) <= TimelineLinkage.epsilon
        }
    }

    /// 这段声音这次该怎么办：跟着它的画面挪同样多（画面的换算挪了多少就是多少；裁头尾不挪）；画面被真删了就删、
    /// 不是真删就留着；画面变了速、换了文件、或者画面本身是被联动挪的（`pictureOutcome` 给它那一份），照画面那一份。
    /// 不是哪段画面分出去的声音回 nil，调用方照老规矩按底下的画面算。
    static func outcome(
        of sound: EditClip, before: TimelineState, after: TimelineState, deletesContent: Bool,
        pictureOutcome: (EditClip) -> TimelineLinkage.Outcome
    ) -> TimelineLinkage.Outcome? {
        guard let was = picture(of: sound, in: before) else { return nil }
        guard let now = after.clip(with: was.id) else { return deletesContent ? .delete : .stay }
        // 画面这次没被碰过（上层轨的画面，等着联动挪）：声音和它拿同一份。
        if now == was { return before.mainClips.contains(where: { $0.id == was.id }) ? .stay : pictureOutcome(was) }
        guard abs(now.speed - was.speed) < 1e-9, now.sourceURL == was.sourceURL else { return nil }
        let delta = now.timelineTime(atSource: 0) - was.timelineTime(atSource: 0)
        return abs(delta) <= TimelineLinkage.epsilon ? .stay : .move(by: delta)
    }
}

// MARK: - Which clips an edit pushed before 0:00 and trimmed at the head
//
// A clip that a move would put before 0:00 keeps its timing against its picture by losing the part before 0:00
// (`moveForLinkage`: rule 13, the AI's V1 ripple `AITimelineEdits.shiftMain`, cut_to_beat's partners), never by being clamped,
// which made a J cut's sound late by its lead-in (docs/bugfixes/2026-11-17-ai-ripple-clamps-j-cut-lead-at-zero.md). The lead-in
// is shorter afterwards, so the AI is told (`Report.trimmedHeads` → `trimmed_heads`). Found by comparing before and after: started
// after 0:00, starts at 0:00 now, same file and speed, window starts later in the file (its end may move: cut_to_beat refits it).
// An edit that itself moves a clip to 0:00 and cuts its head counts too. Kept in this file: ~20 check scripts compile it.

enum LinkageHeadTrims {
    /// Seconds of timeline each clip lost at its head because the edit from `before` to `after` pushed it before 0:00.
    static func find(before: TimelineState, after: TimelineState) -> [UUID: Double] {
        let epsilon = TimelineLinkage.epsilon
        let was = Dictionary(before.allClips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var trims: [UUID: Double] = [:]
        for clip in after.allClips {
            guard let old = was[clip.id], old.sourceURL == clip.sourceURL, abs(old.speed - clip.speed) < 1e-9,
                  old.timelineStart > epsilon, clip.timelineStart <= epsilon, clip.sourceStart - old.sourceStart > epsilon
            else { continue }
            trims[clip.id] = (clip.sourceStart - old.sourceStart) / max(0.05, clip.speed)
        }
        return trims
    }
}

// MARK: - 各种块的时间段（只给联动用的小读法）

extension TimelineState {
    /// 不在主轨上的段：上层轨 + 音频轨。
    var laneClips: [EditClip] { overlayTracks.flatMap(\.clips) + audioTracks.flatMap(\.clips) }
}

extension EditClip {
    var span: TimelineSpan { TimelineSpan(start: timelineStart, end: timelineEnd) }

    /// 联动把这段挪到 `start`。挪到时间线开头之前的那一截头裁掉（入点跟着挪、头上的渐入减掉裁去的那么多），不整段往后错开 ——
    /// 以前一律夹在 0：J 切伸到第一个镜头之前的声音整段晚了那么多，和自己的画面对不上（规矩 13 的案例）。整段都在 0 之前（少见）照旧夹在 0。
    mutating func moveForLinkage(to start: Double) {
        guard start < 0, start + timelineDuration > 0 else {
            timelineStart = max(0, start)
            return
        }
        // 窗口按「挪过去之后时间线 0 那一刻是素材的第几秒」重新定（同 AI 改入出点给绝对值的写法），换算不变。
        let sourceEnd = sourceStart + sourceDuration
        timelineStart = start
        let firstHeard = sourceTime(atTimeline: 0)
        sourceStart = firstHeard
        sourceDuration = sourceEnd - firstHeard
        fadeInDuration = max(0, fadeInDuration + start)
        timelineStart = 0
    }
}

extension ShapeAnnotation {
    var span: TimelineSpan { TimelineSpan(start: timelineStart, end: timelineEnd) }
}

extension TextOverlay {
    var span: TimelineSpan { TimelineSpan(start: timelineStart, end: timelineEnd) }
}

extension FilterClip {
    var span: TimelineSpan { TimelineSpan(start: timelineStart, end: timelineEnd) }
}

extension SubtitleCue {
    var span: TimelineSpan { TimelineSpan(start: start, end: end) }
}
