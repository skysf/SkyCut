import Foundation
import SrtFlowMCPKit

// generate_media's re-ask of a paid result held for Download again (2026-11-24, the review of PR #554;
// docs/bugfixes/2026-11-24-download-lost-connection-no-retry.md): the key is not part of what a request is bound to, so the key SkyCut
// returned works on the next call; a re-ask with that key, or the same request without a key, starts the held Download again (one
// re-ask, one Download again) instead of minting a key and paying again; another request, another key, another scope or nothing held
// leaves the call as it was; an official key's cached answer (a generation or a recovery) finds its held job by id. The run side
// (what Download again does) is checked with real App objects in scripts/check-voice-recovery.sh.

@MainActor
func runHeldDownloadChecks() async {
    let arguments: JSONValue = ["kind": "image", "prompt": "a cabin in snow"]
    let withKey: JSONValue = ["kind": "image", "prompt": "a cabin in snow", "idempotency_key": "k-1", "confirm_token": "t-1"]
    let identity = SkyStudioGenerationRequests.identity(arguments: arguments, project: "p", generation: 1, account: "acct")
    checkEqual(SkyStudioGenerationRequests.identity(arguments: withKey, project: "p", generation: 1, account: "acct"), identity,
               "the key and the confirm token are not part of what a request is bound to")
    let other = SkyStudioGenerationRequests.identity(arguments: ["kind": "image", "prompt": "a lake"], project: "p", generation: 1, account: "acct")

    // A first call without a key: SkyCut made the key and started the job, whose download then gave up.
    let key = "held-\(UUID().uuidString)"
    let job = "generate-held-\(UUID().uuidString.prefix(6))"
    _ = try? SkyStudioGenerationRequests.begin(key, identity: identity)
    SkyStudioGenerationRequests.complete(key, result: .ok(["status": "started", "job_id": .string(job)]))
    var retries = 0
    SkyStudioHeldDownloads.hold(job) { retries += 1 }

    var answer = SkyStudioGenerationRequests.heldAnswer(key: key, identity: identity)
    check(answer?.payload["status"] == "downloading_again" && answer?.payload["job_id"]?.stringValue == job
            && answer?.payload["submitted_again"] == false && retries == 1,
          "the key SkyCut returned, with the same arguments: Download again under the same job id: \(String(describing: answer?.payload))")
    check(!SkyStudioHeldDownloads.isHeld(job), "one re-ask, one Download again (released as it starts)")
    check(SkyStudioGenerationRequests.heldAnswer(key: key, identity: identity) == nil && retries == 1,
          "a second re-ask while the first Download again runs starts nothing")

    SkyStudioHeldDownloads.hold(job) { retries += 1 }
    answer = SkyStudioGenerationRequests.heldAnswer(key: nil, identity: identity)
    check(answer?.payload["job_id"]?.stringValue == job && retries == 2,
          "the same request without a key downloads the held result again instead of minting a key and paying again")

    SkyStudioHeldDownloads.hold(job) { retries += 1 }
    check(SkyStudioGenerationRequests.heldAnswer(key: nil, identity: other) == nil, "another request goes on as before")
    check(SkyStudioGenerationRequests.heldAnswer(key: "another-key", identity: identity) == nil, "another key goes on as before")
    check(SkyStudioGenerationRequests.heldAnswer(key: nil, identity: identity, scope: "official-submission:acct") == nil,
          "an ordinary request never reaches an official key's job, nor the other way round")
    check(retries == 2 && SkyStudioHeldDownloads.isHeld(job), "none of those started anything")

    // An official key's cached answer (its generation's or its recovery's job id): that job's Download again.
    answer = SkyStudioGenerationRequests.heldAnswer(for: .ok(["status": "recovering", "job_id": .string(job)]))
    check(answer?.payload["job_id"]?.stringValue == job && retries == 3, "a cached official answer finds its held job by id")
    check(SkyStudioGenerationRequests.heldAnswer(for: .ok(["status": "started", "job_id": .string(job)])) == nil,
          "nothing held: the cached answer stands as it was")
}
