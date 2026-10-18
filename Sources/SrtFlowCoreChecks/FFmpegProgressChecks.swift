import Foundation
import SrtFlowCore

// ffmpeg 的 -progress 输出怎么读（FFmpegProgressParser）：分块喂、N/A 不当 0、只有 out_time 时的回退、比例和剩余时间不越界。
// 2026-10-18 从 main.swift 原样搬出来（那个文件在行数基线里，加新的一组检查要从它身上拆出等量的行）。

func runFFmpegProgressChecks() {
    var parser = FFmpegProgressParser()
    // 分块喂进来，模拟管道读到一半的情况。
    check(!parser.consume("frame=90\nfps=0.00\nout_time_us=30000"), "partial line yields no update")
    check(parser.consume("00\ntotal_size=3900841\nspeed=9.25x\nprogress=continue\n"), "batch boundary reported")
    checkEqual(parser.progress.frame, 90, "parsed frame")
    checkEqual(parser.progress.outTimeSeconds, 3, "parsed out_time_us as microseconds")
    checkEqual(parser.progress.totalSize, 3_900_841, "parsed total_size")
    checkEqual(parser.progress.speed, 9.25, "parsed speed with trailing x")
    check(!parser.progress.finished, "not finished at progress=continue")

    checkEqual(parser.progress.fraction(duration: 30), 0.1, "fraction of duration")
    checkEqual(parser.progress.remainingSeconds(duration: 30), 27 / 9.25, "eta from speed")
    check(parser.progress.fraction(duration: 0) == nil, "no fraction without duration")

    _ = parser.consume("progress=end\n")
    check(parser.progress.finished, "finished at progress=end")

    // N/A 要忽略，不能把 speed 写成 0
    var fresh = FFmpegProgressParser()
    _ = fresh.consume("speed=N/A\nout_time_us=N/A\nprogress=continue\n")
    check(fresh.progress.speed == nil, "ignores N/A speed")
    check(fresh.progress.outTimeSeconds == nil, "ignores N/A out_time")

    // 只有 out_time 没有 out_time_us 时的回退路径（6 位小数）
    var fallback = FFmpegProgressParser()
    _ = fallback.consume("out_time=00:00:03.500000\nprogress=continue\n")
    checkEqual(fallback.progress.outTimeSeconds, 3.5, "parses out_time with 6 fractional digits")

    // 进度比例不会越界
    var over = FFmpegProgressParser()
    _ = over.consume("out_time_us=99000000\nspeed=2.0x\nprogress=continue\n")
    checkEqual(over.progress.fraction(duration: 10), 1, "fraction clamped to 1")
    checkEqual(over.progress.remainingSeconds(duration: 10), 0, "eta clamped to 0")
    // 没有 speed 就没法估时间，这时候返回 nil 而不是瞎猜一个数。
    var noSpeed = FFmpegProgressParser()
    _ = noSpeed.consume("out_time_us=1000000\nprogress=continue\n")
    check(noSpeed.progress.remainingSeconds(duration: 10) == nil, "no eta without a speed reading")
}
