import CoreImage
import Foundation
import SrtFlowCore

// 四、纯黑不抬（2026-10-14 用户拍板）：滤镜照旧给画面抬黑褪色，但原本就是纯黑的地方 —— 空档、黑场、黑底字卡 ——
// 任何滤镜之后都还是纯黑，预览和成片一起。症状是盲测里褪色胶片把空档和黑底字卡抬成了发品红的灰。
// 案例：docs/bugfixes/2026-10-14-filters-lift-pure-black.md。辅助函数在 main.swift / Parity.swift。

private func same(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Bool {
    abs(a.r - b.r) < 1e-12 && abs(a.g - b.g) < 1e-12 && abs(a.b - b.b) < 1e-12
}

func pureBlackMath() {
    let n = FilterLUT.dimension
    let step = 1.0 / Double(n - 1)

    for preset in FilterPreset.allCases {
        // ① 纯黑那一格就是纯黑（表的第一格 = 输入 (0,0,0)），任何强度都是。
        for strength in [1.0, 0.5] {
            let table = FilterLUT.table(for: preset, strength: strength)
            check(
                table[0] == 0 && table[1] == 0 && table[2] == 0,
                "\(preset.rawValue) 强度 \(strength)：纯黑查出来还是纯黑，得 \(table[0]) \(table[1]) \(table[2])"
            )
        }

        // ② 出了保护范围就是配方本身：这条规矩只碰最暗的那一截。
        for sample in [(0.2, 0.2, 0.2), (FilterLUT.blackHold, 0, 0), (0.7, 0.35, 0.24), (0.05, 0.05, 0.6)] {
            let held = FilterLUT.apply(preset.recipe, sample)
            let graded = FilterLUT.grade(preset.recipe, sample)
            check(
                same(held, graded),
                "\(preset.rawValue)：\(sample) 最亮的通道够亮，和配方一样"
            )
        }

        // ③ 保护范围里只收「往亮里调」的那部分：不比配方亮，也不比原色和配方里暗的那个更暗。
        for sample in [(0.01, 0.01, 0.01), (0.05, 0.03, 0.02), (0.09, 0.09, 0.09), (0, 0, 0.1)] {
            let held = FilterLUT.apply(preset.recipe, sample)
            let graded = FilterLUT.grade(preset.recipe, sample)
            let pairs = [(held.r, graded.r, sample.0), (held.g, graded.g, sample.1), (held.b, graded.b, sample.2)]
            check(
                pairs.allSatisfy { $0.0 <= $0.1 + 1e-12 && $0.0 >= min($0.2, $0.1) - 1e-12 },
                "\(preset.rawValue)：\(sample) 在配方和原色之间"
            )
        }

        // ④ 没有台阶：沿灰轴从黑往上，保护范围里每一格（1/32）最多升 0.08（输入一格的 2.6 倍）。
        //    只把正好是 0 的那一格按回黑、旁边一格照旧抬的写法，第一格就是一个台阶 —— 暗处的渐变会断成色带。
        let table = FilterLUT.fullTable(for: preset)
        var previous = (0.0, 0.0, 0.0)
        var steepest = 0.0
        for k in 1...5 {
            let index = ((k * n + k) * n + k) * 4
            let value = (Double(table[index]), Double(table[index + 1]), Double(table[index + 2]))
            steepest = max(steepest, value.0 - previous.0, value.1 - previous.1, value.2 - previous.2)
            previous = value
        }
        check(steepest <= 0.08, "\(preset.rawValue)：从黑往上没有台阶（最陡一格升 \(steepest)，输入一格 \(step)）")
    }

    // ⑤ 压死黑的照旧压：冷铁、夜金、墨影在暗处本来就往暗里调，这条规矩一点不碰。
    for preset in [FilterPreset.coldIron, .nightGold, .inkShadow] {
        let sample = (0.06, 0.06, 0.06)
        let held = FilterLUT.apply(preset.recipe, sample)
        let graded = FilterLUT.grade(preset.recipe, sample)
        check(
            same(held, graded),
            "\(preset.rawValue)：暗处照样压死黑"
        )
    }

    // ⑥ 褪色照样褪色：暗灰（0.2）照旧抬起来，抬黑这个味道没丢。
    let lifted = lookup(FilterLUT.fullTable(for: .fadedFilm), (0.2, 0.2, 0.2))
    check(
        lifted.0 > 0.25 && lifted.1 > 0.25 && lifted.2 > 0.25,
        "褪色胶片照样把暗灰抬起来，得 \(lifted)"
    )
}

func pureBlackParity() async {
    // 预览那条路：纯黑交给 CoreImage，十款出来都是纯黑；褪色照样抬暗灰。
    for preset in FilterPreset.allCases {
        guard let black = previewPixel((0, 0, 0), preset: preset, strength: 1) else {
            check(false, "\(preset.rawValue)：CoreImage 渲不出来"); continue
        }
        check(
            black.0 <= 1 / 255 && black.1 <= 1 / 255 && black.2 <= 1 / 255,
            "\(preset.rawValue) 预览：纯黑还是纯黑，得 \(black)"
        )
    }
    if let grey = previewPixel((51, 51, 51), preset: .fadedFilm, strength: 1) {
        check(
            grey.0 > 61 / 255 && grey.1 > 61 / 255 && grey.2 > 61 / 255,
            "褪色胶片预览照样把暗灰抬起来，得 \(grey)"
        )
    } else {
        check(false, "褪色胶片：CoreImage 渲不出来")
    }

    // 成片那条路：黑底素材 0–1 秒、空档 1–2 秒、暗灰素材 2–3 秒，褪色胶片盖满整条。
    let black = root.appendingPathComponent("black.mp4")
    let grey = root.appendingPathComponent("grey.mp4")
    for (url, color) in [(black, "black"), (grey, "0x333333")] {
        let (code, out) = run(ffmpegPath, [
            "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "color=c=\(color):size=320x180:rate=30:duration=1",
            "-c:v", "libx264", "-crf", "0", "-pix_fmt", "yuv420p", url.path,
        ])
        guard code == 0 else { check(false, "造素材失败：\(out)"); return }
    }
    guard let decodedGrey = exportedPixel(grey, at: 0.5) else {
        check(false, "暗灰素材的像素取不到"); return
    }
    let info = MediaInfo(
        duration: 1, displaySize: CGSize(width: 320, height: 180), frameRate: 30,
        videoCodec: "h264", audioCodec: nil, hasAudio: false,
        audioCanCopyToMP4: false, fileBytes: 1
    )
    var state = TimelineState()
    state.frameRate = .fallback
    state.canvasRatio = .wide16x9
    state.mainClips = [
        EditClip(sourceURL: black, sourceDuration: 1, timelineStart: 0, info: info),
        EditClip(sourceURL: grey, sourceDuration: 1, timelineStart: 2, info: info),
    ]
    state.filters = [FilterClip(preset: .fadedFilm, timelineStart: 0, duration: 3, layer: 0)]
    guard let rendered = await exportTimeline(state, name: "faded-over-black") else { return }
    check(rendered.arguments.contains("lut3d"), "褪色胶片真的进了滤镜图")

    for (seconds, what) in [(0.5, "黑底素材"), (1.5, "空档")] {
        guard let pixel = exportedPixel(rendered.url, at: seconds) else {
            check(false, "\(what)的像素取不到"); continue
        }
        check(
            pixel.0 <= 2 / 255 && pixel.1 <= 2 / 255 && pixel.2 <= 2 / 255,
            "成片里\(what)盖了褪色胶片还是纯黑，得 \(pixel)"
        )
    }
    guard let graded = exportedPixel(rendered.url, at: 2.5) else {
        check(false, "暗灰那一段的像素取不到"); return
    }
    let expected = lookup(FilterLUT.fullTable(for: .fadedFilm), decodedGrey)
    checkClose(graded.0, expected.0, 4 / 255, "成片的暗灰照表抬起来 R")
    checkClose(graded.1, expected.1, 4 / 255, "成片的暗灰照表抬起来 G")
    checkClose(graded.2, expected.2, 4 / 255, "成片的暗灰照表抬起来 B")
    check(graded.0 > decodedGrey.0 + 10 / 255, "成片的暗灰真的抬亮了，得 \(graded.0)，原色 \(decodedGrey.0)")
}
