import AVFoundation
import Foundation

// **The preview does not wait for a straight-alpha source's premultiplied copy** (2026-11-17,
// docs/bugfixes/2026-11-17-alpha-media-waits-and-oversized-stills.md). Before, the preview rebuild awaited `AlphaSourceCopies`:
// a long straight-alpha clip (a web-motion title rendered as alpha video) held the whole preview — every other edit too —
// until the copy was written. Now the preview's build (`OptimizedMediaLookup.readyAlphaCopiesOnly`, which only the coordinator
// sets) inserts the original when the copy is not on disk and never starts a conversion; `CompositionSource.missingAlphaCopies`
// names the source, the coordinator makes the copy and swaps it in while stopped. Checked with the production builder, cold cache:
// - preview build: afterwards the copy is still not on disk (it neither made nor waited for one), and the clip is drawn — the
//   opaque band is right at once, the semi-transparent band too bright (the original, straight read as premultiplied: what the
//   user sees for that moment);
// - `missingAlphaCopies` names exactly that source, and nothing once the copy exists; then the preview matches the reference;
// - the exact build (`.none` — export prerender, AI look) on a cold cache still waits for the copy and matches the reference.
// Reference = premultiplied colour + the colour measured under it with only the base (same as AlphaVideo.swift).

private let previewOnly = OptimizedMediaLookup(readyAlphaCopiesOnly: true)

/// Largest per-channel difference of the four bands from the reference (overlay premultiplied, nothing else applied).
private func worstBand(_ codes: [[Double]], base: [Double], overlay: [[Double]], bands: [Int]) -> Double {
    bands.map { band in
        (0..<3).map { abs(codes[band][$0] - (overlay[band][$0] + base[$0] * (1 - overlay[band][3] / 255))) }.max() ?? 99
    }.max() ?? 99
}

/// `source` is a straight-alpha file; `overlay` its premultiplied bands as the preview's decoder sees them.
func checkPreviewDoesNotWait(_ source: URL, info: MediaInfo, base: URL, baseInfo: MediaInfo, overlay: [[Double]], label: String) async {
    guard let copy = AlphaSourceCopies.cacheURL(.premultiplied, for: source) else {
        check(false, "\(label): no cache path for the premultiplied copy")
        return
    }
    try? FileManager.default.removeItem(at: copy)
    var baseOnly = TimelineState()
    baseOnly.mainClips = [EditClip(sourceURL: base, sourceDuration: 2, timelineStart: 0, info: baseInfo)]
    var state = baseOnly
    state.overlayTracks = [EditLane(clips: [EditClip(sourceURL: source, sourceDuration: 2, timelineStart: 0, info: info)])]
    let asset: (URL) -> AVURLAsset = { MediaAssetCache.asset(for: $0).asset }

    let missing = await CompositionSource.missingAlphaCopies(in: state, asset: asset)
    check(missing == [source], "\(label): the coordinator is told to make this source's copy (\(missing.map(\.lastPathComponent)))")
    guard let underneath = await previewCodes(baseOnly, points: [bandCenters[0]], at: 1, proxies: previewOnly)?.first,
          let first = await previewCodes(state, points: bandCenters, at: 1, proxies: previewOnly) else {
        check(false, "\(label): the preview without the copy gives no frame")
        return
    }
    check(!FileManager.default.fileExists(atPath: copy.path), "\(label): the preview build neither made nor waited for the copy")
    let opaque = worstBand(first, base: underneath, overlay: overlay, bands: [0, 2])
    check(opaque <= 10, "\(label): the clip is drawn at once (transparent and opaque bands right, off by \(Int(opaque))): \(first)")
    let edge = worstBand(first, base: underneath, overlay: overlay, bands: [1])
    check(edge >= 20, "\(label): until the copy exists the preview shows the original (semi-transparent band too bright by \(Int(edge)))")

    // The coordinator makes the copy, then swaps it in (the next preview build picks it up).
    guard await AlphaSourceCopies.url(.premultiplied, for: source) != nil else {
        check(false, "\(label): the copy cannot be made")
        return
    }
    let after = await CompositionSource.missingAlphaCopies(in: state, asset: asset)
    check(after.isEmpty, "\(label): once the copy exists nothing is missing (\(after.map(\.lastPathComponent)))")
    if let swapped = await previewCodes(state, points: bandCenters, at: 1, proxies: previewOnly) {
        let worst = worstBand(swapped, base: underneath, overlay: overlay, bands: [0, 1, 2, 3])
        check(worst <= 10, "\(label): after the swap the preview matches the reference (off by \(Int(worst))): \(swapped)")
    } else {
        check(false, "\(label): the preview with the copy gives no frame")
    }

    // Export prerender and AI look (`.none`) still wait for the copy on a cold cache.
    try? FileManager.default.removeItem(at: copy)
    if let exact = await previewCodes(state, points: bandCenters, at: 1) {
        let worst = worstBand(exact, base: underneath, overlay: overlay, bands: [0, 1, 2, 3])
        check(worst <= 10 && FileManager.default.fileExists(atPath: copy.path),
              "\(label): the exact build waits for the copy and matches the reference (off by \(Int(worst)))")
    } else {
        check(false, "\(label): the exact build gives no frame")
    }
}
