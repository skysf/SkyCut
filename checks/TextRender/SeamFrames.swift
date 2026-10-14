import CoreGraphics
import Foundation
import SrtFlowCore

// 第 19 组：一段带入场 / 出场的文字在成片里切成三段（入场序列 / 中间静止图 / 出场序列，`OverlayExportFile`），
// 接缝上的每一帧都**正好贴一层**：不空（字闪没）、不叠（字和阴影叠成两层、闪一下更浓）。
//
// 由来（docs/bugfixes/2026-10-14-text-blinks-at-animation-seam.md）：2026-10-06 盲测的课程片里，rise 入场结束前那一帧字没了
// （14.55 / 17.35 / 28.80 s），预览正常。三件事凑在一起才露馅，所以场景必须同时有：
//   · 文字的起点不在帧的格子上（AI 按词的时间放字）：`-itsoffset` 换算到序列的 1/fps 格子时最多提前半帧，序列的最后一帧够不到区间终点；
//   · 主轨是几段拼起来的：拼接（concat）之后画面的时间戳是微秒、比格子晚几微秒，正好落在序列最后一帧「之后」→ EOF → 这一层被撤掉；
//   · 接缝正好落在一帧上：两头都闭的 `between` 让两段同时贴。
// 一次导出放一串互不重叠的字（起点各不相同），逐帧量画面正中那一块：字该在的帧不能暗下去，不能比稳定时更亮。

func checkSeamFrames() async {
    let canvas = CGSize(width: 640, height: 360)
    guard let source = try? await makeSolidVideo(white: 0, seconds: 30, name: "seam-black.mp4", size: canvas) else {
        check(false, "接缝：造不出素材")
        return
    }
    for fps in [ProjectFrameRate.fps24, .fps30] {
        var state = TimelineState()
        state.frameRate = fps
        var cursor = 0.0
        // 长度故意不是帧长的整数倍、源起点各不相同：拼出来的时间戳带微秒级的取整误差（生产里就是这样）。
        for (index, length) in [2.13, 1.97, 2.71, 3.33, 2.07, 4.19, 3.11].enumerated() {
            state.mainClips.append(EditClip(
                sourceURL: source, sourceStart: Double(index) * 0.37, sourceDuration: length,
                timelineStart: cursor, info: info(canvas, seconds: 30)
            ))
            cursor += length
        }
        var titles: [TextOverlay] = []
        var start = 0.61
        while start + 1.4 < cursor {
            var title = whiteTitle(start: start, duration: 1.2)
            title.animation = TextAnimation(
                entrance: .rise, exit: .fade, entranceDuration: 0.5, exitDuration: 0.3, emphasis: .none, intensity: 0.6
            )
            titles.append(title)
            start += 1.43
        }
        state.textOverlays = titles
        guard let url = await export(state, name: "seam-\(fps.fps).mp4") else { continue }
        let frames = centerBrightness(url, name: "seam-\(fps.fps)")
        guard frames.count > Int(cursor * Double(fps.fps)) / 2 else {
            check(false, "接缝 @\(fps.fps)fps：抽不出帧（\(frames.count) 帧）")
            continue
        }
        // 稳定时的亮度：每段字中间那一截（入场已结束、出场没开始）的中位数。
        func inside(_ time: Double, from head: Double, to tail: Double) -> Bool {
            titles.contains { title in time >= title.timelineStart + head && time <= title.timelineEnd - tail }
        }
        var settled: [Double] = []
        for frame in frames where inside(frame.time, from: 0.6, to: 0.4) { settled.append(frame.brightness) }
        settled.sort()
        let plateau = settled.isEmpty ? 0 : settled[settled.count / 2]
        check(plateau > 0.2, "接缝 @\(fps.fps)fps：字中间那一截该亮（\(plateau)）")
        var blank: [String] = []
        var doubled: [String] = []
        for frame in frames {
            // 入场的后半截到出场开始之前：字已经大半显出来，任何一帧都不该暗下去（暗下去 = 那一层被撤掉了）。
            if inside(frame.time, from: 0.4, to: 0.31), frame.brightness < plateau * 0.6 {
                blank.append(String(format: "%.4f", frame.time))
            }
            if frame.brightness > plateau * 1.02 { doubled.append(String(format: "%.4f", frame.time)) }
        }
        check(blank.isEmpty, "接缝 @\(fps.fps)fps：这些帧上字没了（序列的最后一帧够不到区间终点 → EOF → 撤层）：\(blank)")
        check(doubled.isEmpty, "接缝 @\(fps.fps)fps：这些帧上字叠了两层（两段的区间在接缝上重叠）：\(doubled)")
    }
}

/// 成片每一帧画面正中那一块（字在那儿）的平均亮度，带时刻。
private func centerBrightness(_ url: URL, name: String) -> [(time: Double, brightness: Double)] {
    let raw = root.appendingPathComponent("\(name).gray")
    let (code, out) = run(ffmpegPath, [
        "-hide_banner", "-loglevel", "error", "-y", "-i", url.path,
        "-vf", "crop=200:60:220:150,scale=1:1:flags=area,format=gray",
        "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "gray", raw.path
    ])
    guard code == 0, let data = try? Data(contentsOf: raw) else {
        check(false, "\(name) 抽帧失败：\(out.suffix(300))")
        return []
    }
    let (probeCode, times) = run(ffmpegPath, [
        "-hide_banner", "-i", url.path, "-vf", "showinfo", "-fps_mode", "passthrough", "-f", "null", "-"
    ])
    let stamps = times.split(separator: "\n").compactMap { line -> Double? in
        guard line.contains("Parsed_showinfo"), let range = line.range(of: "pts_time:") else { return nil }
        return Double(line[range.upperBound...].prefix { $0 == "." || $0.isNumber })
    }
    guard probeCode == 0, stamps.count == data.count else {
        check(false, "\(name) 帧时刻和帧数对不上：\(stamps.count) vs \(data.count)")
        return []
    }
    return zip(stamps, data).map { (time: $0, brightness: Double($1) / 255) }
}
