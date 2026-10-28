import AVFoundation
import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// **视频 upscale 任务的自检**：范围怎么算（三选一、余料、对齐到整帧、夹在文件里、谁被盖住、「另一处更长」的提示）、
// 起名落盘（原名_宽x高_档位、撞名加编号、文件夹写不进去退路）、封回原声的 ffmpeg 参数（精确裁、画面复制、HEVC 点名 hvc1）、
// 真裁一段（帧数 / 时长 / 尺寸对、首帧就是原片那一刻的画面、没有声音、能取消）、Sky Studio 的档位怎么从 /models 读、一段送不送得了，
// 以及整条流水线对着假 Sky Studio 走一遍（裁 → 探 → /uploads + PUT → /jobs → 等 → 下载 → 封声 → 落盘；整个 mp4 直接上传；
// 排队中停下替它取消、不留文件；被拒就没有文件）。2026-10-28 起走 Sky Studio（收费方案第 6 刀），之前对着假 fal。
// 编译方式见 scripts/check-upscale.sh；方案 docs/plans/2026-10-02-video-upscale.md；长期约束 docs/architecture/video-upscale.md。

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL [line \(line)] \(message): got \(actual), expected \(expected)")
    }
}

func checkClose(_ actual: Double?, _ expected: Double, _ message: String, tolerance: Double = 1e-6, line: Int = #line) {
    checks += 1
    guard let actual, abs(actual - expected) <= tolerance else {
        failures += 1
        print("FAIL [line \(line)] \(message): got \(String(describing: actual)), expected \(expected)")
        return
    }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-upscale-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let ffmpegPath = ProcessInfo.processInfo.environment["SRTFLOW_FFMPEG"]
let ffmpeg = ffmpegPath.map { URL(fileURLWithPath: $0) }

func finish(_ code: Int32) -> Never {
    try? FileManager.default.removeItem(at: root)
    exit(code)
}

func probe(_ url: URL) async -> MediaInfo? {
    if case .success(let info) = await MediaProbe.probe(url: url, ffmpeg: ffmpeg) { return info }
    return nil
}

/// 带声音的原片（ffmpeg 现造：testsrc 画面 + 1 kHz 正弦）。
func makeVideoWithAudio(seconds: Double, name: String) async throws -> URL {
    guard let ffmpeg else { throw FixtureError(description: "没有 ffmpeg（SRTFLOW_FFMPEG）") }
    let url = root.appendingPathComponent(name)
    let process = FFmpegProcess()
    try await process.run(executable: ffmpeg, arguments: [
        "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "testsrc=size=640x360:rate=24", "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000",
        "-t", String(seconds), "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "48", "-c:a", "aac", "-b:a", "128k", url.path,
    ], workingDirectory: nil)
    return url
}

final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FalJobPhase] = []
    func add(_ phase: FalJobPhase) { lock.lock(); items.append(phase); lock.unlock() }
    var all: [FalJobPhase] { lock.lock(); defer { lock.unlock() }; return items }
    /// 阶段的名字按先后、连续相同的并成一个（上传 0% → 100% 是同一阶段）。
    var steps: [String] { all.map(\.name).reduce(into: []) { if $0.last != $1 { $0.append($1) } } }
    func fractions(of name: String) -> [Double] { all.filter { $0.name == name }.compactMap(\.fraction) }
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    // ---- 1. 范围 ----
    print("==> 1. 范围：三选一、余料、对齐到整帧、夹在文件里、谁被盖住、「另一处更长」")
    let a = UUID(), b = UUID(), c = UUID()
    let uses = [UpscaleUse(clipID: a, start: 3, duration: 3), UpscaleUse(clipID: b, start: 2, duration: 6), UpscaleUse(clipID: c, start: 8, duration: 2)]
    let mine = UpscaleRange.make(.thisClip, thisClip: a, uses: uses, fileDuration: 12, frameRate: 24)
    checkClose(mine.start, 2, "这一段 3–6：起点往前留 1 秒余料")
    checkClose(mine.end, 7, "…终点往后留 1 秒余料")
    checkEqual(mine.coveredClipIDs, [a], "只盖住这一段（B 用到 8、C 从 8 起：都不在 2–7 里）")
    checkEqual(mine.chosen?.clipID, a, "选的那一处记着（面板写「用了 3.0 s」）")
    let longest = UpscaleRange.make(.longestUse, thisClip: a, uses: uses, fileDuration: 12, frameRate: 24)
    checkClose(longest.start, 1, "最长的那处 2–8：起点 1")
    checkClose(longest.end, 9, "…终点 9")
    checkEqual(Set(longest.coveredClipIDs), Set([a, b]), "盖住 A 和 B，C（8–10）盖不住")
    checkEqual(longest.chosen?.clipID, b, "选的是 B")
    let whole = UpscaleRange.make(.wholeFile, thisClip: a, uses: uses, fileDuration: 12, frameRate: 24)
    checkClose(whole.start, 0, "整个文件：从 0")
    checkClose(whole.end, 12, "…到结尾")
    checkEqual(Set(whole.coveredClipIDs), Set([a, b, c]), "整个文件盖住全部")
    check(whole.chosen == nil, "整个文件没有「选的那一处」")
    let odd = UpscaleRange.make(.thisClip, thisClip: a, uses: [UpscaleUse(clipID: a, start: 3.02, duration: 2.98)], fileDuration: 12, frameRate: 24)
    checkClose(odd.start, 2, "起点对到整帧（往前）", tolerance: 1e-9)
    checkClose(odd.end, 7, "终点对到整帧（往后）", tolerance: 1e-9)
    let edge = UpscaleRange.make(.thisClip, thisClip: a, uses: [UpscaleUse(clipID: a, start: 0.5, duration: 11.4)], fileDuration: 12, frameRate: 24)
    checkClose(edge.start, 0, "余料不出文件头")
    checkClose(edge.end, 12, "余料不出文件尾")
    let gone = UpscaleRange.make(.thisClip, thisClip: UUID(), uses: uses, fileDuration: 12, frameRate: 24)
    checkClose(gone.end, 12, "这一段已经不在了：退到整个文件")
    checkEqual(UpscaleRange.longerUseElsewhere(thisClip: a, uses: uses)?.clipID, b, "点开 A 时提示：B 用得更长")
    check(UpscaleRange.longerUseElsewhere(thisClip: b, uses: uses) == nil, "点开最长的那处：不提示")
    check(UpscaleRange.longerUseElsewhere(thisClip: a, uses: [uses[0], UpscaleUse(clipID: b, start: 0, duration: 3)]) == nil, "一样长：不提示")
    checkClose(UpscaleRange.handle, 1, "余料两头各 1 秒")
    // 一次最长 30.5 秒、余料算在里面（Sky Studio 的 /models 报）：放不下就两头一样少留；选中的那段本身放不下照原样算（档位说先切开）。
    let roomy = UpscaleRange.make(.thisClip, thisClip: a, uses: [UpscaleUse(clipID: a, start: 10, duration: 3)], fileDuration: 60, frameRate: 24, maxSeconds: 30.5)
    checkClose(roomy.duration, 5, "放得下：两头照旧各 1 秒")
    let tight = UpscaleRange.make(.thisClip, thisClip: a, uses: [UpscaleUse(clipID: a, start: 10, duration: 29.5)], fileDuration: 60, frameRate: 24, maxSeconds: 30.5)
    check(tight.duration <= 30.5 + 1e-9, "29.5 秒的一段：总长不超过 30.5（\(tight.duration)）")
    checkClose(tight.start, 9.5, "两头各少留到 0.5 秒", tolerance: 1e-9)
    check(tight.start <= 10 && tight.end >= 39.5, "选中的那段一帧不少")
    let odd30 = UpscaleRange.make(.thisClip, thisClip: a, uses: [UpscaleUse(clipID: a, start: 10.013, duration: 29.97)], fileDuration: 60, frameRate: 24, maxSeconds: 30.5)
    check(odd30.duration <= 30.5 + 1e-9 && odd30.start <= 10.013 && odd30.end >= 39.983, "对到整帧多出来的那一两帧从余料里收回（\(odd30.start)–\(odd30.end)）")
    let over = UpscaleRange.make(.thisClip, thisClip: a, uses: [UpscaleUse(clipID: a, start: 10, duration: 31)], fileDuration: 60, frameRate: 24, maxSeconds: 30.5)
    checkClose(over.duration, 31, "选中的本身就超了：不收余料、照原样（由档位说先切开）", tolerance: 1e-9)

    // ---- 1b. Sky Studio 的 upscale 档位（/models 读成 UpscaleTier；一段送不送得了）----
    print("==> 1b. 档位：从 /models 读、能升到哪几档、上限、送不送得了")
    let modelsSample = """
    {"models": [
      {"id": "topaz-starlight", "kind": "upscale", "title": "Topaz Starlight",
       "price": {"per": "second", "credits_by_target": {"1080p": 30, "4K": 65}}, "params": {"target": ["1080p", "4K"]},
       "limits": {"max_source_seconds": 30.5, "max_source_fps": 30, "max_output_pixels": 8294400, "max_upload_bytes": 209715200}},
      {"id": "bytedance-upscaler-pro", "kind": "upscale", "title": "ByteDance Upscaler Pro",
       "price": {"per": "second", "credits_by_target": {"1080p": 18, "2K": 36, "4K": 72}}, "params": {"target": ["1080p", "2K", "4K"]},
       "limits": {"max_source_seconds": 30.5, "max_source_fps": 30, "max_output_pixels": 8294400, "max_upload_bytes": 209715200}},
      {"id": "seedream5-flash", "kind": "image", "title": "Seedream 5.0 Flash"},
      {"id": "odd-upscaler", "kind": "upscale", "title": "Odd", "params": {"target": ["8K"]}}
    ]}
    """
    let catalog = (try? JSONValue.decode(Data(modelsSample.utf8))).flatMap(SkyStudioCatalog.init(json:))
    let tiers = catalog.map(UpscaleTier.all(in:)) ?? []
    checkEqual(tiers.map(\.id), ["topaz-starlight", "bytedance-upscaler-pro"], "upscale 的两档；别的 kind、一档都认不出的不算")
    let topaz = tiers.first, bytedance = tiers.last
    checkEqual(topaz?.targets, [.p1080, .p2160], "Topaz 没有 2K")
    checkEqual(bytedance?.targets, [.p1080, .p1440, .p2160], "字节：1080p / 2K / 4K")
    checkEqual(topaz?.maxSourceSeconds, 30.5, "一次最长 30.5 秒")
    checkEqual(topaz?.maxSourceFPS, 30, "最高 30 fps")
    checkEqual(topaz?.maxUploadBytes, 209_715_200, "最大 200 MB")
    checkEqual(topaz?.creditsPerSecond[.p2160], 65, "给人看的每秒价")
    checkEqual(UpscaleTarget(skyStudioName: "2K"), .p1440, "Sky Studio 的 2K = 短边 1440")
    checkEqual(UpscaleTarget.p2160.skyStudioName, "4K", "短边 2160 = 4K")
    checkEqual(UpscaleTarget.p1080.outputSize(for: CGSize(width: 640, height: 360)), CGSize(width: 1920, height: 1080), "估的输出尺寸")
    checkEqual(topaz?.refusal(seconds: 5, frameRate: 24, target: .p1440), .targetNotOffered([.p1080, .p2160]), "Topaz 升不到 1440p")
    checkEqual(topaz?.refusal(seconds: 5, frameRate: 59.94, target: .p1080), .frameRateTooHigh(limit: 30), "60 fps 的源送不了")
    checkEqual(topaz?.refusal(seconds: 5, frameRate: 29.97, target: .p1080), nil, "29.97 算在 30 以内")
    checkEqual(topaz?.refusal(seconds: 31, frameRate: 24, target: .p1080), .tooLong(limit: 30.5), "超过 30.5 秒送不了")
    checkEqual(topaz?.refusal(seconds: 30.5, frameRate: 24, target: .p1080), nil, "正好 30.5 秒送得了")
    check(UpscaleRefusal.tooLong(limit: 30.5).message.contains("at most 30 s"), "说给人听的按整秒（30 秒，不说 30.5）")
    checkEqual(UpscaleTier.displayName(for: "topaz-precision"), "Topaz precision · Proteus", "fal 时代的档位名照旧认得")
    checkEqual(UpscaleTier.displayName(for: "something-new"), "something-new", "认不出的原样")

    // ---- 2. 起名落盘 ----
    print("==> 2. 起名落盘：原名_宽x高_档位、撞名加编号、文件夹写不进去退路")
    let original = root.appendingPathComponent("Shot_鲸鱼.mp4")
    checkEqual(UpscaleOutputName.stem(original: original, outputSize: CGSize(width: 1890, height: 1080), tier: "topaz-precision"),
               "Shot_鲸鱼_1890x1080_topaz-precision", "文件名 = 原名_宽x高_档位")
    let first = UpscaleOutputName.destination(original: original, outputSize: CGSize(width: 1920, height: 1080), tier: "flux-precise", fallbacks: [], exists: { _ in false })
    checkEqual(first.lastPathComponent, "Shot_鲸鱼_1920x1080_flux-precise.mp4", "不撞名就是它")
    checkEqual(first.deletingLastPathComponent(), original.deletingLastPathComponent(), "放在原片旁边")
    let taken = UpscaleOutputName.destination(original: original, outputSize: CGSize(width: 1920, height: 1080), tier: "flux-precise", fallbacks: []) { $0.lastPathComponent == "Shot_鲸鱼_1920x1080_flux-precise.mp4" }
    checkEqual(taken.lastPathComponent, "Shot_鲸鱼_1920x1080_flux-precise 2.mp4", "撞名加编号（全 App 同一个规矩）")
    let home = root.appendingPathComponent("home"), downloads = root.appendingPathComponent("downloads")
    checkEqual(UpscaleOutputName.folder(original: original, fallbacks: [home, downloads], isWritable: { $0 != original.deletingLastPathComponent() }), home, "原片的文件夹写不进去：退到工程的家")
    checkEqual(UpscaleOutputName.folder(original: original, fallbacks: [home, downloads], isWritable: { $0 == downloads }), downloads, "家也写不进去：退到下载")
    checkEqual(UpscaleOutputName.folder(original: original, fallbacks: [home], isWritable: { _ in false }), original.deletingLastPathComponent(), "哪都写不进去：还是原片旁边（写的时候报错）")

    // ---- 3. 封回原声的参数 ----
    print("==> 3. 封回原声：精确裁原片的声音、画面流复制、HEVC 点名 hvc1")
    let args = UpscaleAudioMux.arguments(upscaled: URL(fileURLWithPath: "/u.mp4"), original: URL(fileURLWithPath: "/o.mp4"), start: 1.5, duration: 2.5, videoCodec: "avc1", output: URL(fileURLWithPath: "/m.mp4"))
    check(args.contains("-c:v") && args[args.firstIndex(of: "-c:v")! + 1] == "copy", "画面流原样复制")
    check(args.contains("-c:a") && args[args.firstIndex(of: "-c:a")! + 1] == "aac", "声音重编成 AAC（流复制只能在帧边界上切）")
    if let ss = args.firstIndex(of: "-ss"), let second = args.lastIndex(of: "-i") {
        check(ss < second, "-ss 在原片的 -i 之前：解码后精确裁，不是流复制的帧边界")
        checkEqual(args[ss + 1], "1.500000", "从原片的 1.5 秒起")
    } else { check(false, "参数里没有 -ss / -i") }
    check(args.contains("-map") && args.contains("0:v:0") && args.contains("1:a:0"), "画面取 upscale 文件的、声音取原片的")
    check(!args.contains("hvc1"), "H.264 不点名 hvc1")
    let hevc = UpscaleAudioMux.arguments(upscaled: URL(fileURLWithPath: "/u.mp4"), original: URL(fileURLWithPath: "/o.mp4"), start: 0, duration: 1, videoCodec: "hvc1", output: URL(fileURLWithPath: "/m.mp4"))
    check(hevc.contains("-tag:v") && hevc.contains("hvc1"), "HEVC 点名 hvc1（不然 AVFoundation 不认）")
    check(UpscaleAudioMux.arguments(upscaled: URL(fileURLWithPath: "/u.mp4"), original: URL(fileURLWithPath: "/o.mp4"), start: 0, duration: 1, videoCodec: "hevc", output: URL(fileURLWithPath: "/m.mp4")).contains("hvc1"), "ffprobe 叫它 hevc 时也点名")

    // ---- 4. 真裁一段 ----
    print("==> 4. 真裁一段：帧数 / 时长 / 尺寸对、首帧是原片那一刻的画面、没有声音、能取消")
    do {
        let ramp = try await makeRampVideo(seconds: 6, fps: 24, size: CGSize(width: 640, height: 360), keyframeEvery: 48, name: "ramp.mp4")
        guard case .success(let source) = await UpscaleSourceTrimmer.load(ramp) else { check(false, "load"); finish(1) }
        let out = root.appendingPathComponent("ramp-cut.mp4")
        let result = await MediaReadQueue.run(on: MediaReadQueue.export) { UpscaleSourceTrimmer.trim(source, start: 1.5, end: 4.0, to: out) }
        guard case .success = result else { check(false, "裁失败：\(result)"); finish(1) }
        let info = await probe(out)
        checkClose(info?.duration, 2.5, "裁出来 2.5 秒", tolerance: 1.0 / 24 + 0.001)
        checkEqual(info?.displaySize, CGSize(width: 640, height: 360), "原分辨率")
        checkEqual(info?.hasAudio, false, "没有声音（做完再从原片封回去）")
        checkEqual(info?.videoCodec.hasPrefix("avc") ?? false, true, "H.264")
        let srcAt15 = await brightness(of: ramp, at: 1.5), cutAt0 = await brightness(of: out, at: 0.0)
        check(abs(srcAt15 - cutAt0) < 0.03, "首帧就是原片 1.5 秒那一帧的画面（\(srcAt15) vs \(cutAt0)）")
        let srcAt39 = await brightness(of: ramp, at: 3.9), cutAt24 = await brightness(of: out, at: 2.4)
        check(abs(srcAt39 - cutAt24) < 0.03, "靠近尾巴也对得上（\(srcAt39) vs \(cutAt24)）")
        checkEqual(UpscaleSourceTrimmer.bitRate(for: CGSize(width: 1280, height: 720), frameRate: 24), 6_635_520, "720p 24 fps 的码率 = 像素 × 帧率 × 0.3")
        checkEqual(UpscaleSourceTrimmer.bitRate(for: CGSize(width: 3840, height: 2160), frameRate: 60), 20_000_000, "封顶 20 Mbps")
        checkEqual(UpscaleSourceTrimmer.bitRate(for: CGSize(width: 320, height: 180), frameRate: 24), 6_000_000, "保底 6 Mbps")
        let cancelled = root.appendingPathComponent("ramp-cancel.mp4")
        let cancelResult = await MediaReadQueue.run(on: MediaReadQueue.export) { UpscaleSourceTrimmer.trim(source, start: 1.5, end: 4.0, to: cancelled, isCancelled: { true }) }
        checkEqual(cancelResult, .failure(.cancelled), "取消了就停")
        check(!FileManager.default.fileExists(atPath: cancelled.path), "取消不留半个文件")

        // ---- 5. 流水线对着假 Sky Studio ----
        print("==> 5. 流水线：裁 → 探 → /uploads + PUT → /jobs → 等 → 下载 → 落盘；整个 mp4 直接上传；排队中停下；被拒")
        let fakeOutput = try await makeRampVideo(seconds: 2.5, fps: 24, size: CGSize(width: 1920, height: 1080), keyframeEvery: 12, name: "fake-upscaled.mp4")
        let fakeBytes = try Data(contentsOf: fakeOutput)
        let tier = UpscaleTier(id: "topaz-starlight", title: "Topaz Starlight", targets: [.p1080, .p2160], maxSourceSeconds: 30.5, maxSourceFPS: 30, maxUploadBytes: 209_715_200)
        let base = "http://127.0.0.1:8123/api/skycut/v1"
        let bucket = "http://127.0.0.1:8124/r2/originals/u/skycut/in.mp4?sig=1"
        let resultURL = "https://cdn.skystudioai.com/generations/out.mp4"
        let api = SkyStudioAPI(session: SkyStudioStub.session, base: URL(string: base)!, version: "0.18.50", machine: String(repeating: "a", count: 64))
        let noSleep: @Sendable (Double) async throws -> Void = { _ in }
        guard let rampInfo = await probe(ramp) else { check(false, "probe ramp"); finish(1) }
        var polls = 0
        let uploaded = #"{"upload_url": "\#(bucket)", "method": "PUT", "headers": {"Content-Type": "video/mp4"}, "file_url": "https://r2.example/originals/u/skycut/in.mp4"}"#
        func happy(_ seen: StubSeen) -> SkyStudioStub.Reply {
            switch (seen.method, seen.url) {
            case ("POST", base + "/uploads"): return .http(200, uploaded)
            case ("PUT", bucket): return .http(200, "")
            case ("POST", base + "/jobs"):
                return .http(202, #"{"job_id": "job-up", "status": "queued", "credits_reserved": 75, "typical_seconds": 180, "poll_after_seconds": 15}"#)
            case ("GET", base + "/jobs/job-up"):
                polls += 1
                if polls == 1 { return .http(200, #"{"job_id": "job-up", "status": "queued", "queue_position": 1, "poll_after_seconds": 15}"#) }
                if polls == 2 { return .http(200, #"{"job_id": "job-up", "status": "running", "phase": "processing", "poll_after_seconds": 15}"#) }
                return .http(200, #"{"job_id": "job-up", "status": "done", "phase": "saving", "credits_charged": 72, "result": {"url": "\#(resultURL)", "generation_id": "gen-up", "content_type": "video/mp4", "width": 1920, "height": 1080, "duration": 2.5, "fps": 24}}"#)
            case ("GET", resultURL): return .data(200, fakeBytes)
            default: return .http(404, #"{"error": {"code": "not_found", "message": "unexpected \#(seen.method) \#(seen.url)"}}"#)
            }
        }
        SkyStudioStub.reset(happy)
        let work = root.appendingPathComponent("work")
        let range = UpscaleRange.make(.thisClip, thisClip: a, uses: [UpscaleUse(clipID: a, start: 2.5, duration: 0.5)], fileDuration: rampInfo.duration, frameRate: 24, maxSeconds: 30.5)
        checkClose(range.start, 1.5, "这一段 2.5–3.0 加余料：1.5 起")
        let request = UpscaleRequest(originalURL: ramp, originalInfo: rampInfo, range: range, tier: tier, target: .p1080, credits: 75, typicalSeconds: 180, fallbackFolders: [])
        check(!UpscalePipeline.uploadsWholeFile(request), "只做一段：要裁")
        let phases = PhaseLog()
        let submittedJob = SubmittedLog()
        do {
            let outcome = try await UpscalePipeline.run(request, api: api, key: "sk-test", ffmpeg: ffmpeg, workFolder: work, sleep: noSleep, onSubmitted: { submittedJob.add($0) }) { phases.add($0) }
            checkEqual(outcome.file, root.appendingPathComponent("ramp_1920x1080_topaz-starlight.mp4"), "落在原片旁边、按规矩起名（模型名）")
            check(FileManager.default.fileExists(atPath: outcome.file.path), "文件真在")
            checkEqual(outcome.info.displaySize, CGSize(width: 1920, height: 1080), "探测的是落盘的那个文件")
            checkClose(outcome.record.sourceOffset, 1.5, "记录：新文件的 0 秒 = 原片的 1.5 秒")
            checkEqual(outcome.record.tier, "topaz-starlight", "记录：模型名")
            checkClose(outcome.record.credits, 72, "记录：实收的积分")
            check(outcome.record.costUSD == nil, "记录：没有美元")
            checkEqual(outcome.record.originalURL, ramp, "记录：原片")
            checkEqual(outcome.creditsCharged, 72, "实收（服务器按实际的文件算，比报价 75 低就收低的）")
            checkEqual(outcome.jobID, "job-up", "任务号带回来")
            check(outcome.audioRestored, "原片没声音：没什么可封，算封好了")
        } catch {
            check(false, "流水线失败：\(error)")
        }
        checkEqual(submittedJob.all, ["job-up"], "交上了叫一次（UpscaleJob 据此分清没交上和交上之后断了）")
        checkEqual(phases.steps, ["preparing", "uploading", "queued", "processing", "downloading", "finishing"], "阶段按顺序报")
        check(phases.all.contains(.queued(position: 1)), "排队带位置")
        checkEqual(phases.fractions(of: "uploading").last, 1, "上传报到 100%")
        check(phases.fractions(of: "uploading") == phases.fractions(of: "uploading").sorted(), "上传的比例只升不降")
        checkEqual(phases.fractions(of: "downloading").last, 1, "下载报到 100%")
        check(zip(phases.all, phases.all.dropFirst()).allSatisfy { $0 != $1 }, "同一阶段同一比例只报一次")
        let log = SkyStudioStub.log
        let put = log.first { $0.method == "PUT" && $0.url == bucket }
        check((put?.body?.count ?? 0) > 0 && (put?.body?.count ?? 0) < (try! Data(contentsOf: ramp)).count, "上传的是裁出来的那一段，不是整个原片")
        check(put?.headers["Authorization"] == nil, "Key 不发给存储桶")
        let ask = log.first { $0.url == base + "/uploads" }?.body.flatMap { try? JSONValue.decode($0) }
        checkEqual(ask?["purpose"], "video", "上传的用途是 video")
        let submit = log.first { $0.method == "POST" && $0.url == base + "/jobs" }?.body.flatMap { try? JSONValue.decode($0) }
        checkEqual(submit?["kind"], "upscale", "kind")
        checkEqual(submit?["model"], "topaz-starlight", "模型")
        checkEqual(submit?["inputs"]?["video_url"], "https://r2.example/originals/u/skycut/in.mp4", "交的是上传得到的地址")
        checkEqual(submit?["params"]?["target"], "1080p", "目标用 Sky Studio 的叫法")
        checkEqual(submit?["params"]?["source"]?["width"], 640, "source 照送上去的那个文件：宽")
        checkEqual(submit?["params"]?["source"]?["height"], 360, "…高")
        checkClose(submit?["params"]?["source"]?["seconds"]?.doubleValue, 2.5, "…时长（两位小数）", tolerance: 0.05)
        checkEqual(submit?["params"]?["source"]?["fps"], 24, "…帧率")
        checkEqual(submit?["max_credits"], 75, "max_credits = 用户同意的价")
        check(submit?["idempotency_key"]?.stringValue?.isEmpty == false, "带 idempotency_key")
        check(!log.contains { $0.url.hasSuffix("/cancel") }, "正常做完不会取消")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        checkEqual(leftovers, [], "中间文件一个不留")

        // 整个 mp4 直接上传；超过这一档的时长上限还是裁。
        polls = 0
        SkyStudioStub.reset(happy)
        let wholeRange = UpscaleRange.make(.wholeFile, thisClip: a, uses: [], fileDuration: rampInfo.duration, frameRate: 24, maxSeconds: 30.5)
        let wholeRequest = UpscaleRequest(originalURL: ramp, originalInfo: rampInfo, range: wholeRange, tier: tier, target: .p1080, credits: 180, typicalSeconds: nil, fallbackFolders: [])
        check(UpscalePipeline.uploadsWholeFile(wholeRequest), "整个 mp4：直接上传")
        var shortTier = wholeRequest
        shortTier.tier = UpscaleTier(id: "x", title: "x", targets: [.p1080], maxSourceSeconds: 5)
        check(!UpscalePipeline.uploadsWholeFile(shortTier), "超过这一档的时长上限（这里 5 秒、原片 6 秒）：还是要裁")
        do {
            let outcome = try await UpscalePipeline.run(wholeRequest, api: api, key: "sk-test", ffmpeg: ffmpeg, workFolder: work, sleep: noSleep) { _ in }
            checkClose(outcome.record.sourceOffset, 0, "整个文件：偏移 0")
            checkEqual(outcome.file.lastPathComponent, "ramp_1920x1080_topaz-starlight 2.mp4", "第二次撞名加编号")
            let put = SkyStudioStub.log.last { $0.method == "PUT" }
            checkEqual(put?.body, try Data(contentsOf: ramp), "上传的就是原片的字节")
        } catch {
            check(false, "整个文件的流水线失败：\(error)")
        }

        // 带声音的原片：封回去
        if ffmpeg != nil {
            polls = 0
            SkyStudioStub.reset(happy)
            let withAudio = try await makeVideoWithAudio(seconds: 6, name: "voice.mp4")
            guard let audioInfo = await probe(withAudio) else { check(false, "probe voice"); finish(1) }
            check(audioInfo.hasAudio, "造出来的原片带声音")
            let audioRange = UpscaleRange.make(.thisClip, thisClip: a, uses: [UpscaleUse(clipID: a, start: 2.5, duration: 0.5)], fileDuration: audioInfo.duration, frameRate: 24, maxSeconds: 30.5)
            let audioRequest = UpscaleRequest(originalURL: withAudio, originalInfo: audioInfo, range: audioRange, tier: tier, target: .p1080, credits: 75, typicalSeconds: nil, fallbackFolders: [])
            do {
                let outcome = try await UpscalePipeline.run(audioRequest, api: api, key: "sk-test", ffmpeg: ffmpeg, workFolder: work, sleep: noSleep) { _ in }
                check(outcome.audioRestored, "原片的声音封回去了")
                checkEqual(outcome.info.hasAudio, true, "落盘的文件有声音")
                checkEqual(outcome.info.displaySize, CGSize(width: 1920, height: 1080), "画面是 Sky Studio 给的")
                checkClose(outcome.info.duration, 2.5, "时长照画面（-shortest）", tolerance: 0.1)
                checkEqual(outcome.file.lastPathComponent, "voice_1920x1080_topaz-starlight.mp4", "起名照旧")
            } catch {
                check(false, "带声音的流水线失败：\(error)")
            }
        } else {
            check(false, "没有 ffmpeg（SRTFLOW_FFMPEG）：封回原声那一段没测到")
        }

        // 排队中停下：替它取消（退钱），不落文件、不留中间文件。等的时候「睡」在第 2 次抛出 = Task 被取消。
        SkyStudioStub.reset { seen in
            switch (seen.method, seen.url) {
            case ("POST", base + "/uploads"): return .http(200, uploaded)
            case ("PUT", bucket): return .http(200, "")
            case ("POST", base + "/jobs"): return .http(202, #"{"job_id": "job-c", "status": "queued", "poll_after_seconds": 15}"#)
            case ("POST", base + "/jobs/job-c/cancel"): return .http(200, #"{"status": "cancelled", "credits_refunded": 75}"#)
            default: return .http(200, #"{"job_id": "job-c", "status": "queued", "queue_position": 3, "poll_after_seconds": 15}"#)
            }
        }
        let before = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let sleeps = SleepCounter()
        do {
            _ = try await UpscalePipeline.run(request, api: api, key: "sk-test", ffmpeg: ffmpeg, workFolder: work, sleep: sleeps.sleep) { _ in }
            check(false, "停了不该有结果")
        } catch let error as SkyStudioJobError {
            checkEqual(error, .stopped(.nothingCharged), "排队中停下：取消了、积分退回")
        } catch {
            check(false, "停下抛的是 \(error)")
        }
        checkEqual(SkyStudioStub.log.filter { $0.url.hasSuffix("/jobs/job-c/cancel") }.count, 1, "替它向 Sky Studio 取消了")
        let after = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        checkEqual(Set(after), Set(before), "停下不落文件")
        checkEqual((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? [], [], "停下不留中间文件")

        // 被拒（价格变了）：一分没扣、没有文件，服务器的话原样带回来。
        SkyStudioStub.reset { seen in
            switch (seen.method, seen.url) {
            case ("POST", base + "/uploads"): return .http(200, uploaded)
            case ("PUT", bucket): return .http(200, "")
            default: return .http(409, #"{"error": {"code": "price_changed", "message": "The price is now 90 credits.", "credits": 90}}"#)
            }
        }
        do {
            _ = try await UpscalePipeline.run(request, api: api, key: "sk-test", ffmpeg: ffmpeg, workFolder: work, sleep: noSleep) { _ in }
            check(false, "被拒了不该有结果")
        } catch let error as SkyStudioJobError {
            checkEqual(error.message, "The price is now 90 credits.", "服务器的拒绝原话带回来")
        } catch {
            check(false, "被拒抛的是 \(error)")
        }
        checkEqual(Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []), Set(before), "被拒不落文件")
    } catch {
        check(false, "素材造不出来：\(error)")
    }

    if failures > 0 {
        print("✗ \(failures) of \(checks) upscale checks failed.")
        finish(1)
    }
    print("All \(checks) upscale checks passed.")
    finish(0)
}

/// 交上了的任务号（回调在别的线程上）。
final class SubmittedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ id: String) { lock.lock(); items.append(id); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// 「睡」的替身：不真睡，第 2 次抛出（就像 Task 在等的时候被取消了）。
final class SleepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var sleep: @Sendable (Double) async throws -> Void {
        { [self] _ in if next() >= 2 { throw CancellationError() } }
    }
}

semaphore.wait()
