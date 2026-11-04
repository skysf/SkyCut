import Foundation
import SrtFlowCore

// 远处首段会决定 auto 的实际画布；本文件只用真实模型和合成文件属性，不解码媒体。
func runProductionCanvasChecks(root: URL) throws {
    typealias Snapshot = AIFilmProductionSnapshot
    let wideSource = root.appendingPathComponent("canvas-wide-synthetic.mp4")
    let tallSource = root.appendingPathComponent("canvas-tall-synthetic.mp4")
    try Data(repeating: 11, count: 2048).write(to: wideSource)
    try Data(repeating: 12, count: 2048).write(to: tallSource)
    func clip(at time: Double, source: URL, size: CGSize) -> EditClip {
        var result = EditClip(sourceURL: source, sourceDuration: 5, timelineStart: time)
        result.info = MediaInfo(duration: 5, displaySize: size, frameRate: 24,
            videoCodec: "synthetic", audioCodec: "synthetic", hasAudio: false, audioCanCopyToMP4: false, fileBytes: 2048)
        return result
    }
    let wideSize = CGSize(width: 320, height: 180)
    let tallSize = CGSize(width: 180, height: 320)
    var state = TimelineState()
    state.frameRate = .fps24
    state.canvasRatio = .auto
    // 0...5 秒的首段离被观察的 23...27 秒接缝很远，不能靠局部贡献段列表碰巧失效。
    state.mainClips = [clip(at: 0, source: wideSource, size: wideSize)]
        + [20.0, 25.0, 30.0].map { clip(at: $0, source: wideSource, size: wideSize) }
    var plan = try productionFixture()
    for index in plan.shots.indices { plan.shots[index].outputClipID = state.mainClips[index + 1].id }
    let shots = try AIFilmProductionGraph.decode(plan)
    let own = try Snapshot.authoredSource(shots[0], state: state)
    let seam = try Snapshot.authoredSeam(shots[0], shots[1], state: state)

    var changed = state
    changed.mainClips[0].sourceURL = tallSource
    changed.mainClips[0].info!.displaySize = tallSize
    check(TimelineRenderSize.size(for: state) == wideSize && TimelineRenderSize.size(for: changed) == tallSize,
          "distant first source changes the actual auto canvas")
    check(try Snapshot.authoredSource(shots[0], state: changed) != own,
          "auto canvas change invalidates an unchanged later shot observation")
    check(try Snapshot.authoredSeam(shots[0], shots[1], state: changed) != seam,
          "auto canvas change invalidates a seam with unchanged local contributors")
    var unordered = changed
    unordered.mainClips.swapAt(0, 1)
    check(try Snapshot.authoredSource(shots[0], state: unordered) == Snapshot.authoredSource(shots[0], state: changed),
          "unsorted loaded clips use the same effective canvas as the sorted builder state")

    state.canvasRatio = .wide16x9
    changed.canvasRatio = .wide16x9
    check(TimelineRenderSize.size(for: state) == TimelineRenderSize.size(for: changed),
          "fixed canvas remains independent of distant first source dimensions")
    check(try Snapshot.authoredSource(shots[0], state: state) == Snapshot.authoredSource(shots[0], state: changed),
          "fixed canvas keeps an unchanged later shot observation current")
    check(try Snapshot.authoredSeam(shots[0], shots[1], state: state) == Snapshot.authoredSeam(shots[0], shots[1], state: changed),
          "fixed canvas does not invalidate an unrelated seam for distant metadata")
}
