import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// 声音库的收费单跨一次 SkyCut 重启（docs/bugfixes/2026-11-11-voice-library-job-after-restart.md）：真 App 对象 + 假协议（VoiceLibraryHTTP）。
// 「重启」这样模拟：旧进程起的那一单交上去、拿到任务号之后停在下一次问之前（`parked`：间隔等一个小时，这一次运行里永远轮不到它
// 结账、退款、删记录——和进程没了一样）；它在 AIJobs 里的那一项、云端任务浮层里的那一行按没了算（`quit`）。假 Sky Studio 不重置
// （服务器上的单还在）。之后只看盘上的：新的 SkyStudioSpendStore 读同一份账，SkyStudioVoiceLibraryOrders 每次现读记录。
// - 建 MiniMax 版在建、重启、AI 再调（带不带令牌，启动时读 Key 那一步还没走到）：不问、不预留、不交，跟着服务器上那一单；做完账上一笔。
// - 两单设计在建、重启、读到 Key（启动那一步）：接着跟到底，上限 760 实扣 751.4 的按实收结、没做成的退回，再读一次 Key 不跟第二遍。
// - 交的回答丢了（不知道收没收）：那一笔留在账上；再点头时服务器回的就是那一单（202、同一个 job_id）：认出来，两笔只留一笔。
// - 两天以前的记录丢掉、账不动；别的 Key 的记录不跟。
// - 实收记在预留的那一天（第二天早上才接着跟完的，不挪到今天的额度上）。

private let fixtureKey = "local-library-fixture"
/// 旧进程的任务停在这里：等一个小时（整个检查几分钟就跑完）。
private let parked: @Sendable (Double) async throws -> Void = { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) }
/// 新进程照 VoiceLibraryFixture 的：问的间隔不真等。
private let fast: @Sendable (Double) async throws -> Void = { _ in try await Task.sleep(nanoseconds: 20_000_000) }

@MainActor
func runVoiceLibraryRestartChecks(_ root: URL) async throws {
    // 这几个场景记的账做完退掉：后面的场景看到的当天已花和以前一样。
    let spend = SkyStudioSpendStore.shared
    let base = spend.spentToday()
    defer { spend.refund(spend.spentToday() - base, on: Date()) }
    let access = AIAccessStore.shared
    let mode = access.mode
    defer { access.setMode(mode) }
    access.setMode(.ask)
    unresolvedChecks()
    settleDayChecks()
    try await enrollAcrossRestartChecks(root)
    try await designsAcrossRestartChecks(root)
    try await lostAnswerChecks(root)
    try await staleAndForeignChecks(root)
    require(orders().isEmpty, "no voice library order is left on disk after these checks: \(orders())")
    SkyStudioVoiceLibraryJob.pollSleep = fast
}

@MainActor
private func orders() -> [SkyStudioVoiceLibraryOrders.Record] {
    SkyStudioVoiceLibraryOrders.records.values.sorted { ($0.jobID ?? "") < ($1.jobID ?? "") }
}

@MainActor
private func eventually(_ what: String, _ done: @MainActor () -> Bool) async {
    for _ in 0..<600 {
        if done() { return }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    require(false, "timed out waiting for \(what)")
}

/// SkyCut 退出了：旧进程里那几个任务（停在 `parked` 里）在 AIJobs 里按结束算、浮层里的那一行拿掉；新进程照新的问法问 Sky Studio。
/// 停住的任务一直占着它领的那个槽（进程没了才会还）：全 App 那一份多开几个，后面的检查看到的空槽和以前一样。
@MainActor
private func quit(_ jobIDs: [String]) {
    for id in jobIDs {
        guard let job = AIJobs.shared.job(id) else { require(false, "the old job \(id) exists"); continue }
        AIJobs.shared.finish(job, .cancelled, message: "SkyCut quit (simulated).")
        for row in SkyStudioGenerationActivity.shared.runs where row.aiJobID == id { SkyStudioGenerationActivity.shared.remove(row) }
    }
    let limits = SkyStudioJobSlots.shared.snapshot.limits
    SkyStudioJobSlots.shared.adopt(.init(shared: limits.shared + jobIDs.count, audio: limits.audio))
    SkyStudioVoiceLibraryJob.pollSleep = fast
}

/// 假 Sky Studio 上建过的单。
private func serverOrders() -> [String] { VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.orderIDs } }

/// 新进程读到的当天已花（一个新的账本对象读同一份 UserDefaults）。
@MainActor
private func spentOnDisk() -> Double { SkyStudioSpendStore(defaults: .standard).spentToday() }

@MainActor
private func unresolvedChecks() {
    let refused = SkyStudioServerError(status: 409, code: "price_changed", message: "", fields: [:])
    let missing = SkyStudioServerError(status: 404, code: "not_found", message: "", fields: [:])
    let busy = SkyStudioServerError(status: 503, code: "unavailable", message: "", fields: [:])
    typealias Orders = SkyStudioVoiceLibraryOrders
    require(Orders.unresolved(.request(.network("lost")), accepted: false), "a lost answer to the POST is unresolved: Sky Studio may have taken it")
    require(!Orders.unresolved(.request(.server(refused)), accepted: false) && !Orders.unresolved(.stopped(.nothingCharged), accepted: false),
            "a refusal or a stop before Sky Studio accepted it is resolved")
    require(Orders.unresolved(.request(.network("lost")), accepted: true) && Orders.unresolved(.timedOut, accepted: true)
            && Orders.unresolved(.stopped(.alreadyStarted), accepted: true) && Orders.unresolved(.stopped(.unknown), accepted: true)
            && Orders.unresolved(.request(.server(busy)), accepted: true),
            "an accepted order SkyCut lost track of (network, five hours, could not stop, a server error) is followed later")
    require(!Orders.unresolved(.failed(SkyStudioJobFailure(message: "no")), accepted: true) && !Orders.unresolved(.request(.server(missing)), accepted: true)
            && !Orders.unresolved(.badAnswer("odd"), accepted: true),
            "an order Sky Studio ended (failed, not found, an answer SkyCut cannot use) is resolved")
}

/// 前一天预留、今天才结账（SkyCut 第二天早上开起来接着跟完的）：实收换在前一天，今天的额度不动。
@MainActor
private func settleDayChecks() {
    let spend = SkyStudioSpendStore.shared
    guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) else { return require(false, "yesterday exists") }
    let before = spend.ledger.spent(on: yesterday), today = spend.spentToday()
    spend.record(760, now: yesterday)
    var held = SkyStudioHeldCredits(SkyStudioJobGate.Reservation(credits: 760, day: yesterday))
    held.settle(charged: 751.4)
    require(abs(spend.ledger.spent(on: yesterday) - before - 751.4) < 0.001 && abs(spend.spentToday() - today) < 0.001,
            "a charge settled the next day stays on the day it was reserved: yesterday +\(spend.ledger.spent(on: yesterday) - before), today +\(spend.spentToday() - today)")
    held.refund()
    require(abs(spend.ledger.spent(on: yesterday) - before) < 0.001, "and refunding it later takes it off that day")
}

/// 建 MiniMax 版在建时 SkyCut 退出；重启之后 AI 再调 add_voiceover（启动时读 Key 那一步还没走到：比如钥匙串要授权）。
@MainActor
private func enrollAcrossRestartChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("restart-enroll"))
    let spend = SkyStudioSpendStore.shared
    let lines = ["Hello there.", "This is my own voice."]
    VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.needsEnroll = true; VoiceLibraryHTTP.holdPolls = 1; VoiceLibraryHTTP.holding = true }
    let spent = spend.spentToday()
    SkyStudioVoiceLibraryJob.pollSleep = parked
    guard case .result(let asked) = try await fixture.narrate(lines), let token = asked.payload["confirm_token"]?.stringValue,
          case .result(let building) = try await fixture.narrate(lines, token: token), let old = building.payload["job_id"]?.stringValue else {
        return require(false, "the fee is asked and the approved enrolment starts")
    }
    await eventually("the enrolment to be accepted and written down") { orders().first?.jobID == "enroll-1" }
    quit([old])

    // 新进程：盘上有那一笔预留和那一单。
    require(abs(spentOnDisk() - spent - 377.6) < 0.001, "the reservation made before the restart is on the day's spend: \(spentOnDisk() - spent)")
    let saved = orders()
    require(saved.count == 1 && saved[0].jobID == "enroll-1" && saved[0].kind == "voice_enroll" && saved[0].reservedCredits == 377.6
            && saved[0].account == SkyStudioVoiceLibraryOrders.account(fixtureKey) && saved[0].request.params["voice"] == .string(VoiceLibraryHTTP.voiceID),
            "the open order is on disk with Sky Studio's job id: \(saved)")
    let raw = UserDefaults.standard.data(forKey: SkyStudioVoiceLibraryOrders.defaultsKey).map { String(decoding: $0, as: UTF8.self) } ?? ""
    require(!raw.isEmpty && !raw.contains(fixtureKey), "the order on disk keeps the Key's digest, never the Key")

    // AI 又调了一次：跟着服务器上那一单，不问、不预留、不交。带着用过的令牌也一样。
    guard case .result(var again) = try await fixture.narrate(lines) else { return require(false, "a library voice never reads locally") }
    require(again.payload["status"] == "started" && again.payload["already_building"] == true && again.payload["confirm_token"] == nil
            && again.payload["job_id"] != .string(old), "after the restart the open order is followed, not asked again: \(again.payload)")
    if let asked = again.payload["confirm_token"]?.stringValue, case .result(let approved) = try await fixture.narrate(lines, token: asked) {
        again = approved  // 修复前的样子：又问了一遍。照用户点头往下走，看本机的账记了几笔。
    }
    guard case .result(let replayed) = try await fixture.narrate(lines, token: token) else { return require(false, "a used token reads nothing locally") }
    require(replayed.payload["job_id"] == again.payload["job_id"] && replayed.payload["confirm_token"] == nil, "nor does the used token ask or pay again")
    require(abs(spend.spentToday() - spent - 377.6) < 0.001 && VoiceLibraryHTTP.orderPosts("voice_enroll").count == 1,
            "no second reservation and no second POST: \(spend.spentToday() - spent)")

    VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.holding = false }
    let built = try await fixture.wait(again)
    require(built["status"] == "done" && built["skystudio_job_id"] == "enroll-1" && built["credits_charged"] == 377.6,
            "the order from before the restart is followed to the end with GET only: \(built)")
    require(abs(spend.spentToday() - spent - 377.6) < 0.001 && orders().isEmpty, "the fee is on the day's spend once and the order is closed")
    guard case .result(let reading) = try await fixture.narrate(lines) else { return require(false, "after building, the script is read in the cloud") }
    let read = try await fixture.wait(reading)
    require(read["status"] == "done" && VoiceLibraryHTTP.orderPosts("voice_enroll").count == 1, "and the next call narrates without another fee")
}

/// 两单设计在建时 SkyCut 退出；重启之后读到 Key（启动那一步）就接着跟，不等谁再点头。
@MainActor
private func designsAcrossRestartChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("restart-design"))
    let spend = SkyStudioSpendStore.shared
    VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.holdPolls = 1; VoiceLibraryHTTP.holding = true }
    let spent = spend.spentToday()
    SkyStudioVoiceLibraryJob.pollSleep = parked
    // 中文描述：MiniMax，上限 760、实扣 751.4。英文描述：Qwen3 的 22.5，这一单服务器上做不成、钱全退。
    let chinese = try await approvedDesign(fixture, ["action": "design", "description": "三十多岁的男声，沉稳。", "name": "沉稳"])
    // 第一单交上去之后才拨「下一单做不成」（任务是在后台交的）。
    await eventually("the first design to be accepted") { orders().first?.jobID == "design-1" }
    VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.failNext = true }
    let english = try await approvedDesign(fixture, ["action": "design", "description": "A calm, warm narrator", "name": "Calm"])
    await eventually("both designs to be accepted and written down") { orders().compactMap(\.jobID) == ["design-1", "design-2"] }
    quit([chinese, english])

    require(abs(spentOnDisk() - spent - 782.5) < 0.001, "both reservations are on the day's spend when SkyCut comes back: \(spentOnDisk() - spent)")
    let gets = VoiceLibraryHTTP.calls("GET", containing: "/jobs/")
    let followed = SkyStudioVoiceLibraryOrders.resume(key: fixtureKey, api: fixture.services.api)
    require(followed.count == 2 && followed.allSatisfy { $0.kind == .voiceDesign }, "reading the Key at launch follows both open orders")
    require(SkyStudioVoiceLibraryOrders.resume(key: fixtureKey, api: fixture.services.api).isEmpty, "reading the Key again does not follow them twice")
    VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.holding = false }
    for job in followed { await AIJobs.shared.wait(for: job, seconds: 30) }
    let results = followed.map { AIJobs.shared.json($0) }
    let done = results.first { $0["skystudio_job_id"] == "design-1" }
    let failed = results.first { $0["skystudio_job_id"] == "design-2" }
    require(done?["status"] == "done" && done?["credits_charged"] == 751.4, "the MiniMax design finishes and reports what was charged: \(done ?? .null)")
    require(failed?["status"] == "failed" && failed?["failure"]?["billing"] != nil
            && failed?["next_step"]?.stringValue?.contains("manage_voices action=design") == true,
            "the refunded design fails with its billing and what to do next: \(failed ?? .null)")
    require(VoiceLibraryHTTP.calls("GET", containing: "/jobs/") > gets && VoiceLibraryHTTP.orderPosts("voice_design").count == 2,
            "the orders were followed with GET only, never sent again")
    require(abs(spend.spentToday() - spent - 751.4) < 0.001, "the day's spend is the charge once, the refunded one returned: \(spend.spentToday() - spent)")
    require(orders().isEmpty, "both orders are closed")
}

/// manage_voices design 问一次、带令牌再调：回起来的那一单的任务号。
@MainActor
private func approvedDesign(_ fixture: VoiceLibraryFixture, _ args: JSONValue) async throws -> String {
    let asked = try await fixture.manage(args)
    var confirmed = args.objectValue ?? [:]
    confirmed["confirm_token"] = asked.payload["confirm_token"] ?? .null
    let started = try await fixture.manage(.object(confirmed))
    guard let id = started.payload["job_id"]?.stringValue else { throw AIToolError("No design job: \(started.payload)") }
    return id
}

/// 交建单的回答丢了（断网，或者交的那一刻 SkyCut 退出了）：服务器其实收下了。再点头时它回的就是那一单。
@MainActor
private func lostAnswerChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("restart-lost-answer"))
    let spend = SkyStudioSpendStore.shared
    let lines = ["Hello there.", "This is my own voice."]
    VoiceLibraryHTTP.lock.withLock {
        VoiceLibraryHTTP.needsEnroll = true; VoiceLibraryHTTP.holdPolls = 1; VoiceLibraryHTTP.holding = true; VoiceLibraryHTTP.loseNextOrderAnswer = true
    }
    let spent = spend.spentToday()
    guard case .result(let asked) = try await fixture.narrate(lines), let token = asked.payload["confirm_token"]?.stringValue,
          case .result(let building) = try await fixture.narrate(lines, token: token) else {
        return require(false, "the fee is asked and the approved enrolment starts")
    }
    let lost = try await fixture.wait(building)
    require(lost["status"] == "failed" && VoiceLibraryHTTP.orderPosts("voice_enroll").count == 1 && serverOrders() == ["enroll-1"],
            "the answer to the POST was lost while Sky Studio took the order: \(lost)")
    require(abs(spend.spentToday() - spent - 377.6) < 0.001, "SkyCut cannot know it was taken, so the reservation stays on the day's spend")
    require(orders().count == 1 && orders().first?.jobID == nil, "and the order stays on disk without a job id")

    // 本机不知道那一单在不在：照常问一次。服务器对同一个声音 + 语言开着的建单回原来那一单（202、同一个 job_id）。
    guard case .result(let again) = try await fixture.narrate(lines), let fresh = again.payload["confirm_token"]?.stringValue,
          case .result(let second) = try await fixture.narrate(lines, token: fresh) else {
        return require(false, "an order whose answer was lost cannot be followed, so the user is asked again")
    }
    await eventually("the second POST to come back with the first order") { orders().first?.jobID == "enroll-1" }
    require(orders().count == 1, "the order whose answer was lost is merged into the accepted one: \(orders())")
    require(abs(spend.spentToday() - spent - 377.6) < 0.001, "Sky Studio charged that order once, so the second reservation is returned: \(spend.spentToday() - spent)")
    VoiceLibraryHTTP.lock.withLock { VoiceLibraryHTTP.holding = false }
    let built = try await fixture.wait(second)
    require(built["status"] == "done" && built["skystudio_job_id"] == "enroll-1", "the accepted order is the first one: \(built)")
    require(abs(spend.spentToday() - spent - 377.6) < 0.001 && orders().isEmpty && VoiceLibraryHTTP.orderPosts("voice_enroll").count == 2
            && serverOrders() == ["enroll-1"], "one order on Sky Studio, one charge on the day's spend: \(spend.spentToday() - spent)")
}

/// 两天以前的记录：不再跟、丢掉，账不动。别的 Key 的：留给那把 Key。
@MainActor
private func staleAndForeignChecks(_ root: URL) async throws {
    let fixture = try VoiceLibraryFixture(folder: root.appendingPathComponent("restart-stale"))
    let spend = SkyStudioSpendStore.shared
    func record(_ name: String, account: String, day: Date, job: String) throws -> SkyStudioVoiceLibraryOrders.Record {
        .init(kind: AIJobs.Kind.voiceDesign.rawValue, account: account,
              request: try SkyStudioVoiceRequests.design(description: "A voice", name: name, maxCredits: 22.5), reservedCredits: 22.5,
              reservedDay: day, jobID: job, nextStep: "")
    }
    let stale = try record("Old", account: SkyStudioVoiceLibraryOrders.account(fixtureKey), day: Date().addingTimeInterval(-3 * 86_400), job: "design-old")
    let foreign = try record("Theirs", account: SkyStudioVoiceLibraryOrders.account("another-key"), day: Date(), job: "design-theirs")
    SkyStudioVoiceLibraryOrders.save(stale)
    SkyStudioVoiceLibraryOrders.save(foreign)
    let spent = spend.spentToday()
    let followed = SkyStudioVoiceLibraryOrders.resume(key: fixtureKey, api: fixture.services.api)
    require(followed.isEmpty && VoiceLibraryHTTP.calls("GET", containing: "/jobs/") == 0, "neither a stale order nor another Key's is followed")
    require(Set(SkyStudioVoiceLibraryOrders.records.keys) == [foreign.request.idempotencyKey], "the stale order is dropped, another Key's is kept for that Key")
    require(spend.spentToday() == spent, "dropping a stale order does not touch the day's spend")
    SkyStudioVoiceLibraryOrders.remove(foreign.request.idempotencyKey)
}
