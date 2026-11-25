import Foundation
import SrtFlowMCPKit

// Identical paid requests in a row (user, 2026-11-25; SkyStudioRepeatGuard; docs/architecture/sky-studio-jobs.md "Identical paid
// requests in a row"), the pure half; the tool entries with POSTs counted are checks/VoiceRecovery/RepeatRequestChecks.swift:
// - counting: per project + tool, only what started counts, another tool's calls or another project do not break a run, a
//   different request starts a new one, the 5th asks, a yes covers the rest of its run only;
// - the words: the line from the 2nd on, the note at the question and after a yes, ordinals, the question, token actions;
// - the identity: the resolved request (the canvas aspect, language, voice, options, model, prompt), files by their bytes (a copy is
//   the same request, a changed file is not), never the idempotency_key, the price cap or upload addresses; large files by samples;
// - the gate: the 5th asks in full access and in ask mode, as one question with the draft question there; a draft-only token never
//   answers it; a yes approves the run; the daily limit refuses first; the question alone for change_voice / add_voiceover;
//   manage_voices design merges it into the fee question.
@MainActor
func runRepeatGuardChecks() async {
    countingChecks()
    wordChecks()
    await identityChecks()
    gateChecks()
}

@MainActor
private func countingChecks() {
    let runs = SkyStudioRepeatGuard()
    let a = "request:a", b = "request:b"
    var check1 = runs.check(.generateMedia, project: 1, identity: a, credits: 12)
    check(check1.number == 1 && !check1.isRepeat && !check1.asks, "a new request is the 1st of its run and carries no line")
    runs.started(check1)
    for number in 2...4 {
        check1 = runs.check(.generateMedia, project: 1, identity: a, credits: 12)
        check(check1.number == number && check1.isRepeat && !check1.asks, "the \(SkyStudioRepeatWords.ordinal(number)) identical request carries the line and does not ask")
        runs.started(check1)
    }
    let fifth = runs.check(.generateMedia, project: 1, identity: a, credits: 12)
    check(fifth.number == 5 && fifth.asks && !fifth.approved, "the 5th identical request in a row asks")
    checkEqual(runs.check(.generateMedia, project: 1, identity: a, credits: 12).number, 5, "asked again without starting: still the 5th (only what started counts)")
    runs.started(runs.check(.upscaleClip, project: 1, identity: b, credits: 3))
    runs.started(runs.check(.changeVoice, project: 1, identity: a, credits: 3))
    checkEqual(runs.check(.generateMedia, project: 1, identity: a, credits: 12).number, 5, "other tools' requests in between do not break the run")
    checkEqual(runs.check(.generateMedia, project: 2, identity: a, credits: 12).number, 1, "another project has its own run")
    checkEqual(runs.check(.upscaleClip, project: 1, identity: a, credits: 12).number, 1, "another tool has its own run")

    runs.approve(SkyStudioRepeatGuard.Check(tool: .generateMedia, project: 1, identity: a, number: 5, approved: false, run: fifth.run + 99,
                                            credits: 12))
    check(runs.check(.generateMedia, project: 1, identity: a, credits: 12).asks, "a yes for another run approves nothing")
    runs.approve(fifth)
    let approved = runs.check(.generateMedia, project: 1, identity: a, credits: 12)
    check(approved.number == 5 && !approved.asks && approved.approved, "after the yes the 5th goes through")
    runs.started(approved)
    for number in 6...7 {
        let next = runs.check(.generateMedia, project: 1, identity: a, credits: 12)
        check(next.number == number && !next.asks && next.approved, "the \(SkyStudioRepeatWords.ordinal(number)) goes through without asking after the yes")
        runs.started(next)
    }

    let different = runs.check(.generateMedia, project: 1, identity: b, credits: 12)
    check(different.number == 1 && !different.asks, "a different request to the tool starts a new run")
    runs.started(different)
    var again = runs.check(.generateMedia, project: 1, identity: a, credits: 12)
    checkEqual(again.number, 1, "back to the first request after a different one: a new run")
    for _ in 1...4 {
        runs.started(again)
        again = runs.check(.generateMedia, project: 1, identity: a, credits: 12)
    }
    check(again.number == 5 && again.asks, "its 5th asks again: the yes covered only the run it answered")
}

@MainActor
private func wordChecks() {
    func made(_ number: Int, approved: Bool = false) -> SkyStudioRepeatGuard.Check {
        SkyStudioRepeatGuard.Check(tool: .generateMedia, project: 1, identity: "request:x", number: number, approved: approved, run: 7, credits: 12.5)
    }
    check(SkyStudioRepeatWords.fields(made(1)) == nil, "the first request of a run carries no repeat_request")
    let third = SkyStudioRepeatWords.fields(made(3))?["repeat_request"]
    checkEqual(third?["identical_in_a_row"], 3, "the line says which one in a row")
    checkEqual(third?["credits_each"], 12.5, "the line says the credits each")
    checkEqual(third?["asks_user_at"], 5, "the line says the 5th asks")
    checkEqual(third?["user_agreed"], false, "the line says the user has not agreed yet")
    let note = third?["note"]?.stringValue ?? ""
    check(note.contains("3rd identical generate_media request in a row in this project") && note.contains("12.5 credits each")
          && note.contains("new paid job") && note.contains("The 5th identical request in a row asks the user first"),
          "the note says which one, the credits each, a new paid job and that the 5th asks: \(note)")
    check(SkyStudioRepeatWords.note(made(5)).contains("SkyCut asks the user before starting it: nothing was started or charged"),
          "the note at the question says nothing started")
    let after = SkyStudioRepeatWords.note(made(6, approved: true))
    check(after.contains("6th identical") && after.contains("The user agreed") && after.contains("until a different request"),
          "the note after the yes says it does not ask again until a different request: \(after)")
    checkEqual(["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "101st", "111th"],
               [1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 111].map(SkyStudioRepeatWords.ordinal), "ordinals")
    let question = SkyStudioRepeatWords.question(summary: "Nano Banana 2 · 1K", made(5))
    check(question.contains("Nano Banana 2 · 1K") && question.contains("12.5 credits") && question.contains("5th identical request in a row")
          && question.hasSuffix("Keep making identical versions?"), "the question names the request, its price, the 5th and asks: \(question)")
    check(SkyStudioRepeatWords.tokenSuffix(made(5)) != SkyStudioRepeatWords.tokenSuffix(SkyStudioRepeatGuard.Check(
        tool: .generateMedia, project: 1, identity: "request:x", number: 5, approved: false, run: 8, credits: 12.5)), "a token binds its run")
    check(SkyStudioRepeatWords.action(made(5)) != SkyStudioRepeatWords.action(SkyStudioRepeatGuard.Check(
        tool: .changeVoice, project: 1, identity: "request:x", number: 5, approved: false, run: 7, credits: 12.5)), "a lone question binds its tool")
    check(SkyStudioRepeatWords.action(made(5)) != SkyStudioRepeatWords.action(SkyStudioRepeatGuard.Check(
        tool: .generateMedia, project: 1, identity: "request:x", number: 5, approved: false, run: 7, credits: 13)), "a lone question binds its price")
    let next = SkyStudioRepeatWords.nextStep(draft: "Ask about the draft.")
    check(next.hasPrefix("Ask about the draft.") && next.contains("The same answer covers the identical-request question")
          && next.contains("stop sending this request"), "the merged next step keeps the draft's and adds the repeat's: \(next)")
}

@MainActor
private func identityChecks() async {
    let base = SkyStudioJobRequest(kind: "image", model: "nano2", prompt: "a cabin in snow", params: ["aspect_ratio": "16:9", "resolution": "1K"])
    let id = SkyStudioRequestDigest.identity(base)
    var other = base
    other.idempotencyKey = "another-key"; other.maxCredits = 40; other.inputs = ["image_url": "https://uploads.example/a.png"]
    checkEqual(SkyStudioRequestDigest.identity(other), id, "the idempotency_key, the price cap and upload addresses are not the request")
    func differs(_ change: (inout SkyStudioJobRequest) -> Void, _ what: String) {
        var changed = base
        change(&changed)
        check(SkyStudioRequestDigest.identity(changed) != id, "\(what) is another request")
    }
    differs({ $0.params["aspect_ratio"] = "9:16" }, "the aspect worked out from another canvas")
    differs({ $0.params["resolution"] = "2K" }, "another resolution")
    differs({ $0.model = "seedream5-flash" }, "another model")
    differs({ $0.prompt = "a cabin at dusk" }, "another prompt")
    let voice = SkyStudioJobRequest(kind: "voice_convert", model: "auto", params: ["target_voice": "gemini:Charon", "source": ["seconds": 4.2]])
    let voiceID = SkyStudioRequestDigest.identity(voice)
    var language = voice; language.params["target_language"] = "en"
    var target = voice; target.params["target_voice"] = "voice_0123456789abcdef0123456789abcdef"
    var direct = voice; direct.params["skip_separation"] = true
    check(SkyStudioRequestDigest.identity(language) != voiceID, "another language is another request")
    check(SkyStudioRequestDigest.identity(target) != voiceID, "another voice is another request")
    check(SkyStudioRequestDigest.identity(direct) != voiceID, "another option is another request")
    var character = base; character.character = SkyStudioCharacterReference(id: "char-1", roles: nil, revision: "r1")
    var revised = character; revised.character = SkyStudioCharacterReference(id: "char-1", roles: nil, revision: "r2")
    check(SkyStudioRequestDigest.identity(character) != SkyStudioRequestDigest.identity(revised), "a character's new revision is another request")
    check(SkyStudioRequestDigest.identity(base, extra: ["from": 1, "to": 5]) != SkyStudioRequestDigest.identity(base, extra: ["from": 1, "to": 6]),
          "another source range is another request")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("skycut-repeat-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let one = folder.appendingPathComponent("one.png"), copy = folder.appendingPathComponent("copy of one.png")
        let changed = folder.appendingPathComponent("changed.png")
        try Data("the same bytes".utf8).write(to: one)
        try Data("the same bytes".utf8).write(to: copy)
        try Data("other bytes".utf8).write(to: changed)
        let first = try await SkyStudioRequestDigest.identity(base, files: [.init(role: "reference_image", url: one)])
        checkEqual(try await SkyStudioRequestDigest.identity(base, files: [.init(role: "reference_image", url: copy)]), first,
                   "a copy of the same file at another path is the same request")
        check(try await SkyStudioRequestDigest.identity(base, files: [.init(role: "reference_image", url: changed)]) != first,
              "another file's bytes are another request")
        check(try await SkyStudioRequestDigest.identity(base, files: [.init(role: "first_frame", url: one)]) != first,
              "the same file in another role is another request")
        try Data("the same bytes, edited".utf8).write(to: one)
        check(try await SkyStudioRequestDigest.identity(base, files: [.init(role: "reference_image", url: one)]) != first,
              "the same path with new bytes is another request")

        // Over 256 MiB: the size and 48 MiB of samples (sparse files: nothing is written to disk but a few bytes).
        let big = folder.appendingPathComponent("big.mov"), twin = folder.appendingPathComponent("twin.mov")
        let size: UInt64 = 300 << 20
        for (file, offset, byte) in [(big, UInt64(1 << 20), UInt8(1)), (twin, UInt64(1 << 20), UInt8(1))] {
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: size)
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: Data([byte]))
            try handle.close()
        }
        let bigDigest = try await SkyStudioRequestDigest.content(of: big)
        checkEqual(try await SkyStudioRequestDigest.content(of: twin), bigDigest, "two large files with the same bytes: the same digest")
        let poke = { (offset: UInt64) throws in
            let handle = try FileHandle(forWritingTo: twin)
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: Data([9]))
            try handle.close()
        }
        try poke(2 << 20)   // inside the first 16 MiB: sampled
        check(try await SkyStudioRequestDigest.content(of: twin) != bigDigest, "a large file changed where it is sampled: another digest")
    } catch {
        check(false, "file identities: \(error)")
    }
}

/// Through SkyStudioJobGate with the App's shared run registry (projects numbered far from any real opening).
@MainActor
private func gateChecks() {
    let scratch = ScratchDefaults("repeat-gate-check")
    defer { scratch.remove() }
    let store = SkyStudioSpendStore(defaults: scratch.defaults)
    let access = AIAccessStore(defaults: scratch.defaults)
    store.setDailyLimit(1_000)
    var project = 900_000 + Int.random(in: 0..<10_000)
    func run(_ number: Int, tool: SkyStudioRepeatGuard.Tool = .generateMedia, identity: String = "request:gate") -> SkyStudioRepeatGuard.Check {
        project += 1
        for _ in 1..<number { SkyStudioRepeatGuard.shared.started(SkyStudioRepeatGuard.shared.check(tool, project: project, identity: identity, credits: 20)) }
        return SkyStudioRepeatGuard.shared.check(tool, project: project, identity: identity, credits: 20)
    }
    func decide(_ repeated: SkyStudioRepeatGuard.Check, reason: String? = nil, token: String? = nil) -> SkyStudioJobGate.Decision? {
        try? SkyStudioJobGate.decide(credits: 20, summary: "Fixture · 5 s", identity: "approval:\(repeated.project)",
            args: AIToolArguments(.object(token.map { ["confirm_token": .string($0)] } ?? [:])), store: store, access: access,
            reason: reason, repeated: repeated)
    }
    func asked(_ decision: SkyStudioJobGate.Decision?) -> AIToolResult? {
        if case .needsConfirmation(let result) = decision { return result }
        return nil
    }
    func reserved(_ decision: SkyStudioJobGate.Decision?) -> Bool {
        if case .reserved = decision { return true }
        return false
    }

    // Full access, within the draft: only the 5th asks, before anything is reserved; its token lets it through and approves the run.
    access.setMode(.full)
    let fourth = run(4)
    check(reserved(decide(fourth)), "full access: the 4th identical request goes through")
    let fifth = run(5)
    let spent = store.spentToday()
    let question = asked(decide(fifth))
    let text = question?.payload["question"]?.stringValue ?? ""
    let token = question?.payload["confirm_token"]?.stringValue
    check(text.contains("5th identical request in a row") && text.contains("Keep making identical versions?") && token != nil
          && question?.payload["repeat_request"]?["identical_in_a_row"] == 5,
          "full access: the 5th asks with the repeat question and its fields: \(question?.payload ?? .null)")
    checkEqual(store.spentToday(), spent, "the question reserves nothing")
    check(reserved(decide(fifth, token: token)), "the token lets the 5th through")
    check(SkyStudioRepeatGuard.shared.check(.generateMedia, project: fifth.project, identity: fifth.identity, credits: 20).approved,
          "the yes approves the rest of the run")

    // Ask mode beyond the draft: one question carries both, one token answers both; a draft-only token never answers it.
    access.setMode(.ask)
    let third = run(3)
    let draftOnly = asked(decide(third, reason: "Higher resolution."))
    check(draftOnly?.payload["question"]?.stringValue?.contains("identical request in a row") == false
          && draftOnly?.payload["repeat_request"]?["identical_in_a_row"] == 3,
          "the 3rd beyond the draft: the draft question alone, with the line: \(draftOnly?.payload ?? .null)")
    let merged = run(5)
    let draftToken = asked(decide(merged, reason: "Higher resolution."))
    let both = draftToken?.payload["question"]?.stringValue ?? ""
    check(both.contains("Higher resolution.") && both.contains("5th identical request in a row") && both.contains("Approve this task?"),
          "ask mode: one question with the draft reason and the repeat sentence: \(both)")
    check((draftToken?.payload["next_step"]?.stringValue ?? "").contains("The same answer covers the identical-request question"),
          "its next step covers both")
    // The same request asked when it was not the 5th (the draft question alone): that token never answers the merged question.
    let before = SkyStudioRepeatGuard.Check(tool: .generateMedia, project: merged.project, identity: merged.identity, number: 4,
                                            approved: false, run: merged.run, credits: 20)
    let stale = asked(decide(before, reason: "Higher resolution."))?.payload["confirm_token"]?.stringValue
    let refused = asked(decide(merged, reason: "Higher resolution.", token: stale))
    check(stale != nil && refused?.payload["confirm_token_refused"]?.stringValue?.contains("different request") == true,
          "a token for the draft question alone (the same request) does not answer the merged one")
    check(reserved(decide(merged, reason: "Higher resolution.", token: draftToken?.payload["confirm_token"]?.stringValue)),
          "the merged question's token answers both")
    check(SkyStudioRepeatGuard.shared.check(.generateMedia, project: merged.project, identity: merged.identity, credits: 20).approved,
          "and approves the run")

    // The daily limit refuses first: blocked, no question about repeats.
    store.setDailyLimit(10)
    let blocked = decide(run(5))
    check(asked(blocked)?.payload["code"] == "daily_budget_exceeded" && asked(blocked)?.payload["confirm_token"] == nil,
          "over the daily limit the 5th is blocked, with no question")
    check(SkyStudioJobGate.repeatConfirmation(run(5, tool: .changeVoice), summary: "Voice change", token: nil, store: store) == nil,
          "the lone question leaves a refusal over the daily limit to the reservation")
    store.setDailyLimit(1_000)

    // The question alone (change_voice, add_voiceover): every mode; nil before the 5th and after the yes.
    access.setMode(.full)
    check(SkyStudioJobGate.repeatConfirmation(run(4, tool: .changeVoice), summary: "Voice change", token: nil, store: store) == nil,
          "the 4th identical change does not ask")
    let lone = run(5, tool: .addVoiceover)
    let loneAsk = SkyStudioJobGate.repeatConfirmation(lone, summary: "Voiceover · gemini:Charon · 3 lines", token: nil, store: store)
    check(loneAsk?.payload["status"] == "needs_confirmation" && (loneAsk?.payload["question"]?.stringValue ?? "").contains("Voiceover · gemini:Charon")
          && loneAsk?.payload["repeat_request"]?["identical_in_a_row"] == 5, "the 5th identical voiceover asks: \(loneAsk?.payload ?? .null)")
    check(SkyStudioJobGate.repeatConfirmation(lone, summary: "Voiceover", token: loneAsk?.payload["confirm_token"]?.stringValue, store: store) == nil
          && SkyStudioRepeatGuard.shared.check(.addVoiceover, project: lone.project, identity: lone.identity, credits: 20).approved,
          "its token answers it and approves the run")

    // manage_voices design: the question even under a standing grant; merged into the fee question when that is asked.
    let design = run(5, tool: .manageVoices)
    let standing = try? SkyStudioJobGate.voiceOneTime(credits: 20, action: "design:\(design.project)", question: "Design the voice “N”?",
                                                      token: nil, ask: .standing, store: store, repeated: design)
    check((asked(standing)?.payload["question"]?.stringValue ?? "").contains("5th identical request in a row"),
          "a standing grant does not skip the 5th identical design")
    let feeAndRepeat = try? SkyStudioJobGate.voiceOneTime(credits: 20, action: "design:\(design.project)", question: "Design the voice “N”?",
                                                          token: nil, ask: .ask, store: store, repeated: design)
    let combined = asked(feeAndRepeat)?.payload["question"]?.stringValue ?? ""
    check(combined.hasPrefix("Design the voice “N”?") && combined.contains("5th identical request in a row"),
          "ask mode: the fee question carries the repeat sentence: \(combined)")
}
