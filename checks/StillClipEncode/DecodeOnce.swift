import Foundation

// **图只该解一次、缩一次**（静帧管线出过两次「产物完全正确、只是慢 20 倍」的 bug，
// 见 docs/bugfixes/2026-08-08-still-clip-decode-per-frame.md）。产物上看不出来，所以两条判据都拿生产参数真跑：
//
//   1. **数出来的**：ffmpeg 自己在结尾报的「读了几个包、解了几帧」，必须是 1 / 1。不看时间，机器快慢、忙闲都不影响。
//   2. **量出来的**：多出来那 119 帧的边际成本，和**同一次运行里**「同一张图先缩到产物尺寸」的边际成本比。
//      这 119 帧的编码活两边一样，大图那边多出来的只能是跟着源图大小逐帧重做的活（重解、重缩）。
//      数不出来的那一类 —— 缩放写到了 `loop` 后面，解码还是一次、缩放成了 120 次 —— 靠这一条。
//
// 2026-11-11 之前第 2 条拿「一次解码的耗时 + 0.25s」当上限：解码和编码不是一种活，CI 的慢 runner 上编 119 帧比解一次图贵，
// 正确的实现两次被判红、重跑就过（docs/bugfixes/2026-11-11-still-clip-encode-timing-flake.md）。
//
// 不管：产物的形状（main.swift）、透明的图（Alpha.swift）。

// MARK: - 边际成本怎么判（纯值）

struct StillMarginalCost {
    /// 一张图的两次计时（秒）：生产参数只出 1 帧、出满全部帧。
    struct Timing {
        var oneFrame: Double
        var allFrames: Double
        /// 多出来那些帧的边际成本。
        var marginal: Double { allFrames - oneFrame }
    }

    /// 大图：解码、缩放都贵（自检里是 6000×4500 的 PNG）。
    var big: Timing
    /// 同一张图先缩到产物尺寸：解码、缩放几乎不要钱，编码那 119 帧的活和大图一样。
    var small: Timing

    /// 大图的边际成本最多是小图的几倍。正确的实现是 1 倍；本机实测（2026-11-11，M1）逐帧重解 10–16 倍、
    /// 逐帧重缩 6–8 倍。2.5 离两边都有两倍以上：慢 runner 上两边一起慢、比值不变，单边抖动到 2 倍也不红。
    static let ratioLimit = 2.5
    /// 快机器上边际成本只有 0.1 秒上下，倍数那一条太紧：至少留这么多秒给计时的毛刺。
    static let slack = 0.25

    /// 小图的边际成本（计时毛刺偶尔会量出负数，按 0 算）。
    var reference: Double { max(small.marginal, 0) }
    var allowance: Double { max(reference * Self.ratioLimit, reference + Self.slack) }
    var passes: Bool { big.marginal <= allowance }
}

/// 规则本身的自检：拿实测过的数（和它们的 1.2 倍抖动、6 倍退化）喂给 `StillMarginalCost`，不跑 ffmpeg，每次结果都一样。
/// 把 `allowance` 改回「一次解码 + 0.25s」，慢 runner 那几行就红；把倍数放到分不出退化，退化那几行就红。
func checkMarginalCostRule() {
    typealias T = StillMarginalCost.Timing
    func timing(one: Double, marginal: Double) -> T { T(oneFrame: one, allFrames: one + marginal) }
    let cases: [(name: String, big: T, small: T, passes: Bool)] = [
        // 正确的实现：边际成本两边一样。
        ("本机（M1）正确的实现", T(oneFrame: 0.43, allFrames: 0.56), T(oneFrame: 0.06, allFrames: 0.19), true),
        // CI 两次误报时大图那一侧的实测（一次解码 0.48 / 0.49 秒，多出来的 119 帧 0.86 / 0.87 秒，旧上限 0.73 / 0.74）；
        // 小图那一侧当时没量，正确的实现两边一样，按一样记。
        ("CI 慢 runner 的误报（0.86 秒对旧上限 0.73）", timing(one: 0.48, marginal: 0.86), timing(one: 0.07, marginal: 0.86), true),
        ("CI 慢 runner 的误报（0.87 秒对旧上限 0.74）", timing(one: 0.49, marginal: 0.87), timing(one: 0.07, marginal: 0.87), true),
        // 抖动：只有一边被拖慢。
        ("慢 runner，大图那边再慢 1.2 倍", timing(one: 0.48, marginal: 0.86 * 1.2), timing(one: 0.07, marginal: 0.86), true),
        ("慢 runner，小图那边快 1.2 倍", timing(one: 0.48, marginal: 0.86), timing(one: 0.07, marginal: 0.86 / 1.2), true),
        ("本机，大图那边慢 1.2 倍", timing(one: 0.43, marginal: 0.13 * 1.2), timing(one: 0.06, marginal: 0.13), true),
        ("慢 runner，大图那边慢 2 倍", timing(one: 0.48, marginal: 0.86 * 2), timing(one: 0.07, marginal: 0.86), true),
        ("小图量出了负的边际成本（计时毛刺）", timing(one: 0.43, marginal: 0.13), timing(one: 0.07, marginal: -0.02), true),
        // 真退化：本机实测（2026-11-11，M1，把生产参数改坏之后量的）。
        ("逐帧重解（-loop 1）", T(oneFrame: 0.86, allFrames: 6.85), T(oneFrame: 0.09, allFrames: 0.71), false),
        ("逐帧重缩（缩放写在 loop 后面）", T(oneFrame: 0.44, allFrames: 1.56), T(oneFrame: 0.06, allFrames: 0.26), false),
        // 6 倍的退化，快机器、慢机器都要红。
        ("本机，大图那边贵 6 倍", timing(one: 0.43, marginal: 0.13 * 6), timing(one: 0.06, marginal: 0.13), false),
        ("慢 runner，大图那边贵 6 倍", timing(one: 0.48, marginal: 0.86 * 6), timing(one: 0.07, marginal: 0.86), false),
    ]
    for item in cases {
        let rule = StillMarginalCost(big: item.big, small: item.small)
        check(
            rule.passes == item.passes,
            String(format: "边际成本的规则：「%@」应该判%@（大图 %.2fs、小图 %.2fs、上限 %.2fs）",
                   item.name, item.passes ? "过" : "红", rule.big.marginal, rule.small.marginal, rule.allowance)
        )
    }
}

// MARK: - 数出来的：ffmpeg 报的解码次数

/// 生产参数真跑一遍，读 ffmpeg 结尾报的输入统计（读了几个包、解了几帧）。跑不成、读不出来都返回 nil —— 算失败，不许当通过。
/// 只把生产参数里的 `-loglevel` 换成 verbose：统计是这一档才打的，别的一个字不动。
func decodeCounts(_ productionArgs: [String]) -> (packets: Int, frames: Int)? {
    var args = productionArgs
    guard let index = args.firstIndex(of: "-loglevel"), index + 1 < args.count else { return nil }
    args[index + 1] = "verbose"
    let (code, output) = run(ffmpegPath, args)
    guard code == 0 else { return nil }
    // 「Input stream #0:0 (video): 1 packets read (9505568 bytes); 1 frames decoded; 0 decode errors;」
    let pattern = #"Input stream #0:0 \(video\): (\d+) packets read \(\d+ bytes\); (\d+) frames decoded"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
          let packets = Range(match.range(at: 1), in: output).flatMap({ Int(output[$0]) }),
          let frames = Range(match.range(at: 2), in: output).flatMap({ Int(output[$0]) }) else { return nil }
    return (packets, frames)
}

private func checkDecodeCount(_ image: URL, nativeResolution: Bool, label: String) {
    let args = StillImageClipFactory.conversionArguments(
        image: image, output: root.appendingPathComponent("count-\(label).mp4"), nativeResolution: nativeResolution
    )
    guard let counts = decodeCounts(args) else {
        failures += 1
        print("FAIL \(label)：读不出 ffmpeg 报的解码次数（生产参数里没有 -loglevel，或者这版 ffmpeg 的统计换了写法）")
        return
    }
    check(
        counts.packets == 1 && counts.frames == 1,
        "\(label)：这张图应该只读一次、解一次，ffmpeg 报读了 \(counts.packets) 个包、解了 \(counts.frames) 帧 —— 被逐帧重解了"
    )
}

// MARK: - 量出来的：边际成本和同一次运行里的小图比

/// 生产参数改成只出 1 帧（基线从**生产参数**改出来，不另写一条命令：另写的话生产参数改了、基线还照着老路子跑）。
private func oneFrameArgs(_ productionArgs: [String], output: URL) -> [String]? {
    var args = productionArgs
    guard let index = args.firstIndex(of: "-frames:v"), index + 1 < args.count else { return nil }
    args[index + 1] = "1"
    args[args.count - 1] = output.path
    return args
}

/// 四条命令轮着跑三轮、每条取最快的一次（接着 `best` 里已有的往下取）：第一轮顺带把文件缓存热了，
/// 轮着跑让一阵卡顿不至于只落在某一条上。有一条没跑成就返回 false。
private func fastestRuns(_ commands: [[String]], into best: inout [Double], rounds: Int = 3) -> Bool {
    for _ in 0..<rounds {
        for (index, args) in commands.enumerated() {
            let result = timed(args)
            if result.code != 0 { return false }
            best[index] = min(best[index], result.seconds)
        }
    }
    return true
}

/// `native` 是给原生政策数解码次数用的那张图（4000×3000）。
func checkDecodeOnce(native: URL) {
    checkMarginalCostRule()

    // 素材要够大：跟着源图大小走的活（解码、缩放）必须明显贵过「编 120 帧 1080p」，否则分不出好坏。
    // 只量照片政策 —— 原生政策要编 120 帧原尺寸，编码本身就占大头。
    let big = makeImage("perf.png", size: "4000x3000", upscale: "6000:4500")
    checkDecodeCount(big, nativeResolution: false, label: "照片政策")
    checkDecodeCount(native, nativeResolution: true, label: "原生政策")

    // 小图 = 大图的产物里取一帧：尺寸就是产物的尺寸、画面一样，于是多出来那 119 帧的编码活两边一样。
    guard let product = convert(big, nativeResolution: false, name: "perf-product.mp4"),
          let small = extractFrame(product.url, at: 0, name: "perf-small.png") else {
        failures += 1
        print("FAIL 边际成本：造不出产物尺寸的小图")
        return
    }
    let bigAll = StillImageClipFactory.conversionArguments(
        image: big, output: root.appendingPathComponent("perf-big.mp4"), nativeResolution: false
    )
    let smallAll = StillImageClipFactory.conversionArguments(
        image: small, output: root.appendingPathComponent("perf-small.mp4"), nativeResolution: false
    )
    guard let bigOne = oneFrameArgs(bigAll, output: root.appendingPathComponent("perf-big-1.mp4")),
          let smallOne = oneFrameArgs(smallAll, output: root.appendingPathComponent("perf-small-1.mp4")) else {
        failures += 1
        print("FAIL 生产参数里没有 -frames:v，边际成本无从下手")
        return
    }
    let commands = [bigOne, bigAll, smallOne, smallAll]
    var seconds = [Double](repeating: .infinity, count: commands.count)
    func measured() -> StillMarginalCost {
        StillMarginalCost(
            big: .init(oneFrame: seconds[0], allFrames: seconds[1]),
            small: .init(oneFrame: seconds[2], allFrames: seconds[3])
        )
    }
    guard fastestRuns(commands, into: &seconds) else {
        failures += 1
        print("FAIL 边际成本：计时用的转换没跑成")
        return
    }
    var cost = measured()
    if !cost.passes {
        // 超了先再量三轮、每条接着取最快的：一阵卡顿正好压在大图那几次上的会被洗掉，真退化每一轮都贵、照样超。
        print(String(format: "     （第一遍大图边际 %.2fs 超了上限 %.2fs，再量一遍）", cost.big.marginal, cost.allowance))
        guard fastestRuns(commands, into: &seconds) else {
            failures += 1
            print("FAIL 边际成本：再量一遍时转换没跑成")
            return
        }
        cost = measured()
    }
    let extra = StillImageClipFactory.stillFrameCount - 1
    check(
        cost.passes,
        String(
            format: "边际成本：大图多出来的 %d 帧花了 %.2fs，同一次运行里产物尺寸的小图只花 %.2fs"
                + "（上限 %.2fs = 小图的 %.1f 倍、至少多 %.2fs）—— 有活在跟着源图大小逐帧重做（重解 / 重缩）",
            extra, cost.big.marginal, cost.small.marginal, cost.allowance,
            StillMarginalCost.ratioLimit, StillMarginalCost.slack
        )
    )
    print(String(
        format: "     （耗时：大图 1 帧 %.2fs、%d 帧 %.2fs，边际 %.2fs；小图 1 帧 %.2fs、%d 帧 %.2fs，边际 %.2fs；上限 %.2fs）",
        cost.big.oneFrame, extra + 1, cost.big.allFrames, cost.big.marginal,
        cost.small.oneFrame, extra + 1, cost.small.allFrames, cost.small.marginal, cost.allowance
    ))
}
