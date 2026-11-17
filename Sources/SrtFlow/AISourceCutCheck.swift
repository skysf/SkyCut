import Foundation
import SrtFlowMCPKit

// MARK: - 放素材、改入点出点时提醒夹帧：扫素材、读缓存、写进结果
//
// 管什么：add_clips、edit_clip / edit_clips（给了 source_in / source_out / file）落地之后，看每段用到的源范围跨没跨过素材自己的刀
// （`AISourceCuts`），跨了就在结果里加 `source_cuts`（MCP-36；用户定：只提醒、不改）。inspect_video 交片前再查一遍也用这里的扫描。
// - 刀从素材整个扫一遍来（`AIShotScan`：和 look shots 同一次扫描、同一份缓存，按「路径 + 大小 + 修改时间」记着，一个文件只解一遍）。
// - 放素材时不能干等：没扫过的短素材（≤ `AIShotScan.quickScanSeconds`）当场扫，这一次调用一共最多等 `waitSeconds`；
//   长素材放的时候不扫（一扫几十秒、还占着唯一的那条扫描队列），没等到的、长的列进 `source_cuts_unchecked`；
//   交片前 inspect_video 不论长短都扫（它是任务，等得起）。
// - 只看有画面的视频段：纯声音、图片转的静帧、还在转的图片都没有「素材自己的刀」。
// 不管什么：怎么算跨没跨、写给 AI 的那一条（AISourceCuts）；刀怎么判（AIShotDetector.hardCuts）。

@MainActor
enum AISourceCutCheck {
    /// 放素材 / 改入点出点这一次调用最多等扫描多少秒。
    nonisolated static let waitSeconds = 10.0
    /// 一次结果里最多列几条（夹进来的一小段排前面）。
    static let listLimit = 8

    /// edit_clip 这一次动没动用到的源范围（入点、出点、换文件）：动了才提醒。
    static func movesSourceWindow(_ change: AIClipChange) -> Bool {
        change.sourceIn != nil || change.sourceOut != nil || change.replacement != nil
    }

    /// 这一段有没有「素材自己的刀」可查。
    static func checkable(_ clip: EditClip) -> Bool {
        !clip.isAudioOnly && !clip.isStillImage && !clip.needsStillConversion
    }

    /// 把这几段的素材扫好：缓存里有的不再扫；没扫过的开始扫（`anyLength` 为 false 时只扫短素材），一共最多等 `seconds` 秒。
    /// 短的先排（扫描一个接一个跑，`MediaReadQueue.shots`），免得排在长的后面等不到。
    static func prepare(
        _ clips: [EditClip], seconds: Double = waitSeconds, anyLength: Bool = false, cancelled: () -> Bool = { false }
    ) async {
        var lengths: [URL: Double] = [:]
        for clip in clips where checkable(clip) && AIShotScan.cached(clip.sourceURL) == nil
            && (anyLength || clip.assetDuration <= AIShotScan.quickScanSeconds) {
            lengths[clip.sourceURL] = clip.assetDuration
        }
        let urls = lengths.keys.sorted { (lengths[$0] ?? 0, $0.path) < (lengths[$1] ?? 0, $1.path) }
        guard !urls.isEmpty else { return }
        for url in urls { _ = try? await AIShotScan.result(for: url, waiting: 0) }
        let deadline = Date().addingTimeInterval(seconds)
        while urls.contains(where: AIShotScan.isScanning), Date() < deadline, !cancelled() {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// 缓存里有这段素材的扫描结果时，这段跨过的刀；没扫过是 nil。
    static func crossings(of clip: EditClip) -> [AISourceCuts.Crossing]? {
        guard checkable(clip), let scanned = AIShotScan.cached(clip.sourceURL) else { return nil }
        let window = clip.sourceStart...(clip.sourceStart + clip.sourceDuration)
        let signals = scanned.signals
        return AISourceCuts.crossings(window: window, times: signals.times, cuts: AIShotDetector.hardCuts(changes: signals.changes))
    }

    /// add_clips：落地之后这几段（id）跨没跨过素材自己的刀，写进 `result`。
    static func note(_ result: inout [String: JSONValue], clips ids: [UUID], in project: VideoEditProject) async {
        let placed = ids.compactMap { project.state.clip(with: $0) }.filter(checkable)
        guard !placed.isEmpty else { return }
        await prepare(placed)
        let state = project.state
        add(to: &result, clips: placed.compactMap { state.clip(with: $0.id) }, ids: AIShortIDs(state: state))
    }

    /// 把这几段跨过的刀写进 `result`（只读缓存；edit_clip / edit_clips 的扫描在 plan 那一步已经等过）。
    static func add(to result: inout [String: JSONValue], clips: [EditClip], ids: AIShortIDs) {
        var entries: [(short: Bool, value: JSONValue)] = []
        var unchecked: [String] = []
        for clip in clips where checkable(clip) {
            guard let found = crossings(of: clip) else {
                unchecked.append(ids.short(clip.id))
                continue
            }
            entries += found.map { ($0.kind != .twoShots, AISourceCuts.json($0, clip: clip, ids: ids)) }
        }
        let ordered = entries.filter(\.short) + entries.filter { !$0.short }
        if !ordered.isEmpty {
            result["source_cuts"] = .array(ordered.prefix(listLimit).map(\.value))
            if ordered.count > listLimit { result["more_source_cuts"] = .number(Double(ordered.count - listLimit)) }
        }
        if !unchecked.isEmpty {
            result["source_cuts_unchecked"] = [
                "clips": .array(unchecked.map { .string($0) }),
                "why": .string("SkyCut has not scanned these files for cuts inside them yet (long files are not scanned while placing; others "
                    + "did not finish in time). look shots=true on a file shows its cuts; inspect_video checks these clips again before delivery.")
            ]
        }
    }
}
