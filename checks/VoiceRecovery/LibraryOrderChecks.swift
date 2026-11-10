import AVFoundation
import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 声音库的收费单（设计、建 MiniMax 版）：2026-11-11 深度审查（#362 / #367）之后补的场景，真 App 对象 + 假协议（VoiceLibraryHTTP）。
// 假协议不再每一单当场做完、实扣等于报价：这里的单先排队、问几次才有结局，同一个 key / 同一个声音 + 语言回原来那一单，
// 会改价（409 price_changed）、会失败退款，MiniMax 设计上限 760 实扣 751.4。
// - **一份设计只下一单**（docs/bugfixes/2026-11-11-design-voice-ordered-twice.md）：对话框上连按两次只预留一次、只起一个任务、只交一次；
//   绕过对话框的闩、同一份直接起两次，第二次回开着的那一单、预留退回；改了字是另一份。
// - 账按实收：上限 760 的设计做完记 751.4；改价 / 失败退款的一分不留，get_job 带原因、新价和下一步；排队中的单做完照样落账。
// - **MiniMax 版已经在建就跟着那一单**：没等它做完又调 add_voiceover（带不带令牌、全部权限 + 长期授权都一样），不再问、不再预留、不再交。
// - 授权那句升了版本（consent_outdated）：忘掉目录、用新版本、新文案再问一次，旧令牌不认，点过头按新版本建成。
// - 临时文件夹：只清一天以前留下的那三种；QueuedAudioWindow 在 MediaReadQueue 上抽出 16 kHz 的探针、能取消。

@MainActor
func runVoiceLibraryOrderChecks(_ root: URL) async throws {
    // 这几个场景记的账做完退掉：后面的场景（每日额度 1,000 的那一摊）看到的当天已花和以前一样。
    let spend = SkyStudioSpendStore.shared
    let base = spend.spentToday()
    defer { spend.refund(spend.spentToday() - base, on: Date()) }
    try await designOnceChecks(root)
    try await designSettlementChecks(root)
    try await enrollOnceChecks(root)
    try await consentVersionChecks(root)
    try await temporaryFolderChecks(root)
    try await queuedWindowChecks(root)
}

@MainActor
private func eventually(_ what: String, _ done: @MainActor () -> Bool) async {
    for _ in 0..<600 {
        if done() { return }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    require(false, "timed out waiting for \(what)")
}

@MainActor
private func designOnceChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("order-design-once"))
    let store = VoiceLibraryStore()
    store.api = fixture.services.api
    store.readKey = { .success("local-library-fixture") }
    await store.refresh()
    let spend = SkyStudioSpendStore.shared
    // 这一单先排着队：第二下按下去时第一单还开着（真服务器上设计要几十秒）。
    VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.holdPolls = 1; VoiceLibraryHTTP.holding = true }
    let model = DesignVoiceModel(store: store)
    model.quoteDelay = 0
    model.project = { fixture.project }
    model.name = "Twice"
    model.prompt = "A bright, quick presenter."
    await eventually("the design quote") { model.quote != nil }
    let before = spend.spentToday()
    require(model.design() && model.ordered, "the first press orders the design")
    require(!model.design(), "a second press on the same quote does nothing")
    require(!model.design(), "nor does a third (a held-down Return key)")
    require(abs(spend.spentToday() - before - 22.5) < 0.001, "the price is reserved once, not once per press: \(spend.spentToday() - before)")
    require(store.designing == ["Twice"], "one design is in progress: \(store.designing)")
    require(AIJobs.shared.running.filter { $0.kind == .voiceDesign }.count == 1, "one job is running")
    await eventually("the order to reach Sky Studio") { VoiceLibraryHTTP.orderPosts("voice_design").count >= 1 }

    // 绕过对话框的闩：同一份（同一个 idempotency_key）直接再起一次，本机回开着的那一单、这一笔预留退回。
    let draft = try SkyStudioVoiceDesignOrder.draft(description: "A slow, low storyteller.", name: "Direct", sampleText: nil)
    let quote = try await fixture.services.api.quote(draft, key: "local-library-fixture")
    let mark = spend.spentToday()
    let first = SkyStudioVoiceDesignOrder.start(draft, quote: quote, key: "local-library-fixture",
        reservation: SkyStudioJobGate.reserveWithoutAsking(credits: quote.credits)!, project: fixture.project, api: fixture.services.api)
    require(SkyStudioVoiceDesignOrder.running(draft)?.id == first.id, "an open order is found by its request")
    let second = SkyStudioVoiceDesignOrder.start(draft, quote: quote, key: "local-library-fixture",
        reservation: SkyStudioJobGate.reserveWithoutAsking(credits: quote.credits)!, project: fixture.project, api: fixture.services.api)
    require(second.id == first.id, "the same order started again is the open job, not a second one")
    require(abs(spend.spentToday() - mark - 22.5) < 0.001, "and its second reservation is returned: \(spend.spentToday() - mark)")

    VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.holding = false }
    await eventually("both designs to finish") { store.designing.isEmpty && first.status != .running }
    // 那一单做完了、对话框还没来得及收（或者它当场就没做成）：手里这份报价已经用掉了，再按也不下第二单。
    require(!model.design(), "a quote that was ordered cannot be ordered again after its job ended")
    let posts = VoiceLibraryHTTP.orderPosts("voice_design")
    require(posts.count == 2 && Set(posts.compactMap { $0["idempotency_key"]?.stringValue }).count == 2,
            "two designs were ordered in all (the dialog's and the direct one), each sent once: \(posts.compactMap { $0["idempotency_key"]?.stringValue })")
    require(abs(spend.spentToday() - before - 45) < 0.001, "the day's spend is the two designs, each counted once: \(spend.spentToday() - before)")
    require(SkyStudioVoiceDesignOrder.running(draft) == nil, "a finished order is no longer open")

    // 改了字是另一份报价：可以再下一单（另一个 key）。
    model.sampleText = "Good morning."
    require(!model.ordered && model.quote == nil, "editing a field takes a new quote before anything can be ordered")
    await eventually("the new quote") { model.quote != nil }
    require(model.design(), "the new quote can be ordered")
    await eventually("the third design") { store.designing.isEmpty }
    let keys = VoiceLibraryHTTP.orderPosts("voice_design").compactMap { $0["idempotency_key"]?.stringValue }
    require(keys.count == 3 && Set(keys).count == 3, "a changed design is a different order with its own key")
    model.close()
}

@MainActor
private func designSettlementChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("order-design-settle"))
    let access = AIAccessStore.shared
    let mode = access.mode
    defer { access.setMode(mode) }
    access.setMode(.ask)
    let spend = SkyStudioSpendStore.shared

    // 上限 760、实扣 751.4，而且先排队、问两次才做完：账按实收。
    VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.holdPolls = 2 }
    var spent = spend.spentToday()
    let chinese: JSONValue = ["action": "design", "description": "三十多岁的男声，沉稳。", "name": "沉稳"]
    let asked = try await fixture.manage(chinese)
    require(asked.payload["credits"] == 760 && asked.payload["credits_expected"] == 751.4, "a MiniMax design is asked with its maximum and expected price")
    var confirmed = chinese.objectValue ?? [:]
    confirmed["confirm_token"] = asked.payload["confirm_token"] ?? .null
    let started = try await fixture.manage(.object(confirmed))
    require(abs(spend.spentToday() - spent - 760) < 0.001, "the maximum is reserved while the job runs")
    let done = try await fixture.wait(started)
    require(done["status"] == "done" && done["credits_charged"] == 751.4 && VoiceLibraryHTTP.calls("GET", containing: "/jobs/") >= 2,
            "a queued design finishes after polling and reports what was charged: \(done)")
    require(abs(spend.spentToday() - spent - 751.4) < 0.001, "the day's spend settles at the charge, not the maximum: \(spend.spentToday() - spent)")

    // 服务器算出来更贵（price_changed）：一分不扣，get_job 带新价和下一步；旧令牌不能再用。
    VoiceLibraryHTTP.reset()
    spent = spend.spentToday()
    let args: JSONValue = ["action": "design", "description": "A calm, warm narrator", "name": "Calm"]
    let question = try await fixture.manage(args)
    confirmed = args.objectValue ?? [:]
    confirmed["confirm_token"] = question.payload["confirm_token"] ?? .null
    VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.priceChange = 30 }
    let repriced = try await fixture.wait(try await fixture.manage(.object(confirmed)))
    require(repriced["status"] == "failed" && repriced["code"] == "price_changed" && repriced["credits_now"] == 30
            && repriced["credits_approved"] == 22.5 && repriced["failure"]?["code"] == "price_changed"
            && repriced["next_step"]?.stringValue?.contains("manage_voices") == true,
            "a changed price ends the job with the new price and what to do next: \(repriced)")
    require(abs(spend.spentToday() - spent) < 0.001, "and nothing stays on the day's spend")
    let again = try await fixture.manage(.object(confirmed))
    require(again.payload["status"] == "needs_confirmation" && again.payload["confirm_token_refused"] != nil
            && again.payload["confirm_token"] != question.payload["confirm_token"], "the used token starts nothing; the user is asked again")

    // 设计失败、钱全退了：账上不留，get_job 带服务器的结算证据。
    VoiceLibraryHTTP.reset()
    spent = spend.spentToday()
    let fresh = try await fixture.manage(args)
    confirmed["confirm_token"] = fresh.payload["confirm_token"] ?? .null
    VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.failNext = true; VoiceLibraryHTTP.holdPolls = 1 }
    let failed = try await fixture.wait(try await fixture.manage(.object(confirmed)))
    require(failed["status"] == "failed" && failed["skystudio_job_id"] == "design-1" && failed["failure"]?["billing"] != nil,
            "a refunded design fails with its job id and billing evidence: \(failed)")
    require(abs(spend.spentToday() - spent) < 0.001, "a refunded design leaves nothing on the day's spend: \(spend.spentToday() - spent)")
}

@MainActor
private func enrollOnceChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("order-enroll-once"))
    let access = AIAccessStore.shared
    let mode = access.mode
    defer { access.setMode(mode) }
    access.setMode(.ask)
    let spend = SkyStudioSpendStore.shared
    let lines = ["Hello there.", "This is my own voice."]
    VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.needsEnroll = true; VoiceLibraryHTTP.holdPolls = 1; VoiceLibraryHTTP.holding = true }
    let spent = spend.spentToday()
    guard case .result(let asked) = try await fixture.narrate(lines), let token = asked.payload["confirm_token"]?.stringValue else {
        return require(false, "the fee is asked first")
    }
    guard case .result(let building) = try await fixture.narrate(lines, token: token), let job = building.payload["job_id"]?.stringValue else {
        return require(false, "the approved fee starts the enrolment")
    }
    require(abs(spend.spentToday() - spent - 377.6) < 0.001, "the fee is reserved once")
    await eventually("the enrolment to reach Sky Studio") { VoiceLibraryHTTP.orderPosts("voice_enroll").count == 1 }

    // AI 没等它做完又调了一次：报价还说要建。跟着开着的那一单，不再问、不再预留、不再交。
    guard case .result(let impatient) = try await fixture.narrate(lines) else { return require(false, "a library voice never reads locally") }
    require(impatient.payload["job_id"] == .string(job) && impatient.payload["already_building"] == true
            && impatient.payload["confirm_token"] == nil && impatient.payload["status"] == "started",
            "a second call while it builds gets the open job, not another question: \(impatient.payload)")
    // 带着用过的那张令牌再来一次也一样。
    guard case .result(let replayed) = try await fixture.narrate(lines, token: token) else { return require(false, "a replayed token starts nothing") }
    require(replayed.payload["job_id"] == .string(job) && replayed.payload["confirm_token"] == nil, "nor does a replayed token ask or pay again")
    require(abs(spend.spentToday() - spent - 377.6) < 0.001 && VoiceLibraryHTTP.orderPosts("voice_enroll").count == 1
            && AIJobs.shared.running.filter { $0.kind == .voiceEnroll }.count == 1,
            "one reservation, one job, one POST while it builds: \(spend.spentToday() - spent)")

    VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.holding = false }
    let built = try await fixture.wait(building)
    require(built["status"] == "done" && abs(spend.spentToday() - spent - 377.6) < 0.001, "the fee is on the day's spend once: \(spend.spentToday() - spent)")
    guard case .result(let reading) = try await fixture.narrate(lines) else { return require(false, "after building, the script is read in the cloud") }
    let read = try await fixture.wait(reading)
    require(read["status"] == "done" && VoiceLibraryHTTP.orderPosts("voice_enroll").count == 1, "and the next call narrates without another fee")

    // 全部权限 + 长期授权（不问、直接建）：连着调两次也只建一单、只记一笔。
    VoiceLibraryHTTP.reset()
    access.setMode(.full)
    VoiceLibraryHTTP.lock.withLock {
        VoiceLibraryHTTP.standing = ("voice-standing-consent-v1", true)
        VoiceLibraryHTTP.needsEnroll = true; VoiceLibraryHTTP.holdPolls = 1; VoiceLibraryHTTP.holding = true
    }
    let base = spend.spentToday()
    guard case .result(let direct) = try await fixture.narrate(lines), case .result(let repeated) = try await fixture.narrate(lines) else {
        return require(false, "full access builds without asking")
    }
    require(direct.payload["kind"] == "voice_enroll" && repeated.payload["job_id"] == direct.payload["job_id"] && repeated.payload["already_building"] == true,
            "with standing consent the second call follows the first build: \(repeated.payload)")
    await eventually("the standing enrolment to reach Sky Studio") { VoiceLibraryHTTP.orderPosts("voice_enroll").count == 1 }
    require(abs(spend.spentToday() - base - 377.6) < 0.001, "and the fee is reserved once: \(spend.spentToday() - base)")
    VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.holding = false }
    _ = try await fixture.wait(direct)
    require(VoiceLibraryHTTP.orderPosts("voice_enroll").count == 1 && abs(spend.spentToday() - base - 377.6) < 0.001, "one build, one charge")
}

@MainActor
private func consentVersionChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("order-consent"))
    let access = AIAccessStore.shared
    let mode = access.mode
    defer { access.setMode(mode) }
    access.setMode(.ask)
    let file = try fixture.recording()
    let args: JSONValue = ["action": "create", "file": .string(file.path), "name": "Versioned", "language": "en"]
    let asked = try await fixture.manage(args)
    let token = asked.payload["confirm_token"]?.stringValue ?? ""
    require(asked.payload["question"]?.stringValue?.contains("voice-consent-v1") == true, "the first question shows the catalog's statement")
    // Sky Studio 把那一句升到 v2；SkyCut 手里 10 分钟一份的目录还是 v1。
    VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.consentVersion = "voice-consent-v2" }
    var confirmed = args.objectValue ?? [:]
    confirmed["confirm_token"] = .string(token)
    let renewed = try await fixture.manage(.object(confirmed))
    let question = renewed.payload["question"]?.stringValue ?? ""
    let next = renewed.payload["confirm_token"]?.stringValue ?? ""
    require(renewed.payload["status"] == "needs_confirmation" && renewed.payload["consent_statement_updated"] == true
            && question.contains("voice-consent-v2") && question.contains("NEW STATEMENT") && !next.isEmpty && next != token,
            "an outdated statement is refreshed and asked again with the new text and a new token: \(renewed.payload)")
    require(VoiceLibraryHTTP.calls("POST", "/voices").count == 1 && VoiceLibraryHTTP.voices.count == 1, "nothing was created on the old statement")
    confirmed["confirm_token"] = .string(next)
    let created = try await fixture.manage(.object(confirmed))
    require(created.payload["status"] == "created" && VoiceLibraryHTTP.calls("POST", "/voices").last?["consent_statement_version"] == "voice-consent-v2",
            "after the user agrees to the new statement the voice is created with its version")
}

@MainActor
private func temporaryFolderChecks(_ root: URL) async throws {
    let temp = root.appendingPathComponent("order-temp")
    let manager = FileManager.default
    let now = Date()
    let old = now.addingTimeInterval(-VoiceLibraryTemp.residueAge - 3_600)
    func make(_ name: String, created: Date) throws -> URL {
        let url = temp.appendingPathComponent(name)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("sample".utf8).write(to: url.appendingPathComponent("recording.wav"))
        try manager.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        return url
    }
    let stale = try VoiceLibraryTemp.Kind.allCases.map { try make($0.rawValue + "stale", created: old) }
    let live = try VoiceLibraryTemp.Kind.allCases.map { try make($0.rawValue + "live", created: now) }
    let other = try make("SrtFlow-ASR-stale", created: old)
    require(VoiceLibraryTemp.folder(.dialog, in: temp).lastPathComponent.hasPrefix("SkyCut-new-voice-")
            && VoiceLibraryTemp.folder(.reference, in: temp).lastPathComponent.hasPrefix("SkyCut-voice-reference-")
            && VoiceLibraryTemp.folder(.language, in: temp).lastPathComponent.hasPrefix("SkyCut-voice-language-"),
            "the three temporary folders keep their names")
    let removed = VoiceLibraryTemp.sweepResidue(in: temp, now: now)
    require(removed == 3 && stale.allSatisfy { !manager.fileExists(atPath: $0.path) }, "day-old voice folders left by a crash are removed: \(removed)")
    require(live.allSatisfy { manager.fileExists(atPath: $0.path) }, "folders in use (another SkyCut's open dialog) are left alone")
    require(manager.fileExists(atPath: other.path), "and so is anything that is not a voice folder")
}

@MainActor
private func queuedWindowChecks(_ root: URL) async throws {
    let folder = root.appendingPathComponent("order-window")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appendingPathComponent("three-seconds.wav")
    let samples = (0..<(44_100 * 3)).map { Int16(sin(Double($0) * 0.05) * 6_000) }
    try VoiceReferenceSample.wavData(samples: samples, sampleRate: 44_100).write(to: source)
    let probe = try await QueuedAudioWindow.extract(assetURL: source, range: SourceRange(start: 0, end: 2), into: folder, on: MediaReadQueue.analysis)
    let file = try AVAudioFile(forReading: probe)
    require(file.fileFormat.sampleRate == AudioWindowReader.sampleRate && file.fileFormat.channelCount == 1
            && abs(Double(file.length) / AudioWindowReader.sampleRate - 2) < 0.05,
            "the probe read on the media queue is 16 kHz mono and as long as asked: \(file.length)")
    let cancelled = Task { try await QueuedAudioWindow.extract(assetURL: source, range: SourceRange(start: 0, end: 3), into: folder, on: MediaReadQueue.analysis) }
    cancelled.cancel()
    do {
        _ = try await cancelled.value
        require(false, "a cancelled probe read does not return a file")
    } catch {
        require(error is CancellationError, "a cancelled probe read throws CancellationError: \(error)")
    }
}
