import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// A crossFade between two stills plays centred on the cut, in the preview and in the export, and the stills keep their
// keyframes (2026-11-17, docs/bugfixes/2026-11-17-still-crossfade-half-a-transition-late.md). The transition used to be
// planned from the outgoing clip's tail first: a still has 56 s of tail and nothing before its first frame, so the whole
// dissolve came after the cut — the first still unchanged at the cut, half gone where set_transition said it ends.
// Stills are made with the production conversion arguments into this check's own folder (never the app's cache): opaque
// PNGs the H.264 way, the transparent one the shared-frame ProRes way (#441). Compiled by scripts/check-video-fade.sh.

private let stillSize = CGSize(width: 128, height: 72)
private let centre = (x: 64, y: 36)

/// 容量是不是「能放、最长约 `expected` 秒」。容量是乘出来的（长度 × 0.4），
/// 1.5 × 0.4 在 Double 里是 0.6000000000000001 —— 枚举的 `==` 是精确比较，
/// 拿它断言浮点结果会假红。(Also used by main.swift's 4b–4c; moved here to keep main.swift under its size baseline.)
func capacity(_ value: TransitionCapacity, isAbout expected: Double) -> Bool {
    if case .available(let maxDuration) = value { return abs(maxDuration - expected) < 1e-9 }
    return false
}

/// A solid PNG (grey `level`); `transparentBorder` leaves the outer 4 px see-through, so it converts as a transparent still.
private func drawPNG(level: Double, transparentBorder: Bool, name: String) -> URL {
    let url = root.appendingPathComponent("\(name).png")
    let width = Int(stillSize.width), height = Int(stillSize.height)
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: (transparentBorder ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
    )!
    context.setFillColor(CGColor(srgbRed: level, green: level, blue: level, alpha: 1))
    let inset = transparentBorder ? 4 : 0
    context.fill(CGRect(x: inset, y: inset, width: width - 2 * inset, height: height - 2 * inset))
    let sink = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(sink, context.makeImage()!, nil)
    _ = CGImageDestinationFinalize(sink)
    return url
}

/// A 4-second still clip of that PNG, converted as the factory does (same arguments, same frame sharing).
private func stillClip(level: Double, transparentBorder: Bool = false, name: String) -> EditClip? {
    let png = drawPNG(level: level, transparentBorder: transparentBorder, name: name)
    let still = root.appendingPathComponent(transparentBorder
        ? StillAlphaNaming.stillName(key: name, nativeResolution: false) : "\(name)-v3.mp4")
    let arguments = transparentBorder
        ? StillImageClipFactory.alphaConversionArguments(image: png, output: still, nativeResolution: false)
        : StillImageClipFactory.conversionArguments(image: png, output: still, nativeResolution: false)
    let (code, out) = run(ffmpegPath, arguments)
    guard code == 0 else {
        check(false, "\(name): the still conversion failed: \(out.suffix(300))")
        return nil
    }
    if transparentBorder {
        do {
            try StillFrameSharing.shareSingleFrame(in: still, count: StillImageClipFactory.stillFrameCount)
        } catch {
            check(false, "\(name): sharing the one frame failed: \(error)")
            return nil
        }
    }
    let info = MediaInfo(
        duration: StillImageClipFactory.stillDuration, displaySize: stillSize, frameRate: StillImageClipFactory.stillFrameRate,
        videoCodec: transparentBorder ? "prores" : "h264", audioCodec: nil, hasAudio: false, audioCanCopyToMP4: false, fileBytes: 1
    )
    var clip = EditClip(sourceURL: still, sourceDuration: 4, timelineStart: 0, info: info)
    clip.stillImageURL = png
    return clip
}

/// `a` on 0–4 s, `b` on 4–8 s, touching, a 1-second crossFade on the cut at 4 s.
private func seam(_ a: EditClip, _ b: EditClip) -> TimelineState {
    var first = a
    first.transitionAfter = .crossFade
    first.transitionDuration = 1
    var second = b
    second.timelineStart = 4
    var state = TimelineState()
    state.mainClips = [first, second]
    return state
}

/// Scale keys from `from` (first frame) to `to` (4 s into the still), centred.
private func scaled(_ clip: EditClip, from: Double, to: Double) -> EditClip {
    var keyed = clip
    var animation = ClipAnimation()
    animation.width = KeyframeTrack(keys: [Keyframe(time: 0, value: from), Keyframe(time: 4, value: to)])
    animation.height = animation.width
    keyed.animation = animation
    return keyed
}

/// How far the picture at the centre is from `dark` towards `bright` (0…1), preview and export each against their own levels.
private func mix(_ value: Double?, dark: Double?, bright: Double?) -> Double? {
    guard let value, let dark, let bright, bright - dark > 0.3 else { return nil }
    return (value - dark) / (bright - dark)
}

/// The share of the bright still at 3.75 s and 4.25 s, the bright one being `a` (outgoing) or `b` (incoming).
private func checkCentred(_ state: TimelineState, brightIsOutgoing: Bool, label: String) async {
    // Centred on the cut: the dissolve runs 3.5–4.5 s, so a quarter of the way in the outgoing still has 75 %.
    let expected = brightIsOutgoing ? (early: 0.75, late: 0.25) : (early: 0.25, late: 0.75)
    let (brightAt, darkAt) = brightIsOutgoing ? (1.0, 7.0) : (7.0, 1.0)
    let bright = await previewPixel(state, x: centre.x, y: centre.y, at: brightAt)
    let dark = await previewPixel(state, x: centre.x, y: centre.y, at: darkAt)
    for (time, want) in [(3.75, expected.early), (4.25, expected.late)] {
        let got = mix(await previewPixel(state, x: centre.x, y: centre.y, at: time), dark: dark, bright: bright)
        check(got.map { abs($0 - want) < 0.12 } == true,
              "\(label), preview at \(time) s: the bright still should be \(want) of the picture (dissolve centred on the cut), got \(got ?? -1)")
    }
    guard let product = await export(state, name: "\(label)-export.mp4") else { return }
    let exportBright = pixel(product, x: centre.x, y: centre.y, at: brightAt, name: "\(label)-bright")
    let exportDark = pixel(product, x: centre.x, y: centre.y, at: darkAt, name: "\(label)-dark")
    for (time, want) in [(3.75, expected.early), (4.25, expected.late)] {
        let got = mix(pixel(product, x: centre.x, y: centre.y, at: time, name: "\(label)-mix"), dark: exportDark, bright: exportBright)
        check(got.map { abs($0 - want) < 0.12 } == true,
              "\(label), export at \(time) s: the bright still should be \(want) of the picture (dissolve centred on the cut), got \(got ?? -1)")
    }
    if let length = mediaDuration(product) {
        check(abs(length - 8) < 0.15, "\(label): the export keeps the timeline's 8 s, got \(length)")
    }
}

func checkStillCrossfade() async {
    guard let white = stillClip(level: 1, name: "still-white"), let black = stillClip(level: 0, name: "still-black"),
          let clearWhite = stillClip(level: 1, transparentBorder: true, name: "still-white-alpha") else { return }

    // ---- The plan both pipelines render: half a transition each side, the incoming still's half a free hold ----
    let pair = seam(white, black)
    check(capacity(pair.transitionCapacity(afterMainIndex: 0), isAbout: 1.6), "two 4-second stills take up to 1.6 s (4 × 0.4)")
    let plan = TimelineState.transitionExtension(outgoing: pair.mainClips[0], incoming: pair.mainClips[1], duration: 1)
    check(abs(plan.outgoingExtension - 0.5) < 1e-9 && abs(plan.incomingExtension - 0.5) < 1e-9,
          "two stills: each reaches half the transition past the cut, got \(plan)")
    check(plan.tail == 0.5 && plan.holdHead == 0.5, "…the outgoing still from its footage, the incoming one by holding its first frame")
    let expanded = pair.expandingTransitionHandles()
    check(abs(expanded.mainClips[0].timelineEnd - 4.5) < 1e-9 && abs(expanded.mainClips[1].timelineStart - 3.5) < 1e-9,
          "the render copies overlap 3.5–4.5 s, centred on the cut")
    let window = pair.renderedTransitionWindow(afterMainIndex: 0)
    check(window.map { abs($0.start - 3.5) < 1e-9 && abs($0.duration - 1) < 1e-9 } == true,
          "where it plays is where the timeline draws it (3.5–4.5 s), got \(String(describing: window))")

    // ---- Preview and export, opaque stills (the H.264 way; both cover the frame, so the preview is the exact dissolve) ----
    // White → black: the outgoing still plays on into its footage. Black → white: the incoming still's held first frame.
    await checkCentred(pair, brightIsOutgoing: true, label: "still-white-black")
    await checkCentred(seam(black, white), brightIsOutgoing: false, label: "still-black-white")

    // ---- Keyframes stay: A (H.264) shrinks 1 → 0.5, B (the shared-frame ProRes, #441) grows 0.5 → 1, both white ----
    // At 3.75 s A is at about 0.53 of the frame and B (in its held first frame) at 0.5, so a point 16 px from the left edge is
    // outside both: black. Without A's keys it would be 75 % white, without B's 25 %. In the middle both are white: in the
    // export that is white only if B's held frame is there (75 % without it); the preview's two-way fade dips to about 0.81.
    let keyed = seam(scaled(white, from: 1, to: 0.5), scaled(clearWhite, from: 0.5, to: 1))
    for time in [3.75, 4.25] {
        let edge = await previewPixel(keyed, x: 16, y: centre.y, at: time)
        let middle = await previewPixel(keyed, x: centre.x, y: centre.y, at: time)
        check(edge.map { $0 < 0.1 } == true, "keyed stills, preview at \(time) s: both are scaled down, the edge is black, got \(edge ?? -1)")
        check(middle.map { $0 > 0.7 } == true, "keyed stills, preview at \(time) s: the middle shows the stills, got \(middle ?? -1)")
    }
    if let product = await export(keyed, name: "still-keyed-export.mp4") {
        for time in [3.75, 4.25] {
            let edge = pixel(product, x: 16, y: centre.y, at: time, name: "still-keyed-edge")
            let middle = pixel(product, x: centre.x, y: centre.y, at: time, name: "still-keyed-middle")
            check(edge.map { $0 < 0.15 } == true, "keyed stills, export at \(time) s: both are scaled down, the edge is black, got \(edge ?? -1)")
            check(middle.map { $0 > 0.85 } == true, "keyed stills, export at \(time) s: the middle is white (both stills), got \(middle ?? -1)")
        }
    }
}
