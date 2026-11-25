import Foundation
import SrtFlowMCPKit

// generate_media's way back to a paid result held for Download again (2026-11-24 / 25, the reviews of PR #554;
// docs/bugfixes/2026-11-24-download-lost-connection-no-retry.md), pure: the idempotency_key is part of what a request is bound to, as
// before the PR, as SkyCut reads it (trimmed, or the key SkyCut made), so the key it returned names that same request (a key sent with
// spaces and sent back without them was once refused as other inputs, CXD3); only that key's own cached answer
// (its job id) reaches the held job, and the job stays held until a download of it succeeds. Another key, or none (which makes a new
// one), is a new request (user, 2026-11-25: an identical paid request sent again is a deliberate new version). The same through the
// tool entry, with POSTs counted at a fake server: PaidToolEntryChecks in scripts/check-voice-recovery.sh.

@MainActor
func runHeldDownloadChecks() async {
    let arguments: JSONValue = ["kind": "image", "prompt": "a cabin in snow"]
    func identity(_ args: JSONValue, _ key: String) -> JSONValue {
        SkyStudioGenerationRequests.identity(arguments: args, key: key, project: "p", generation: 1, account: "acct")
    }
    // The key is part of the identity; the one SkyCut made is filled in when the caller gave none; the confirm token is not part.
    let minted = "minted-\(UUID().uuidString)"
    var named = arguments.objectValue ?? [:]
    named["idempotency_key"] = .string(minted)
    named["confirm_token"] = "t-1"
    checkEqual(identity(arguments, minted), identity(.object(named), minted),
               "the key SkyCut made names the same request when it comes back with the same arguments (a confirm token is not part)")
    check(identity(arguments, "k-1") != identity(arguments, "k-2"), "the key is part of what a request is bound to")
    var spaced = arguments.objectValue ?? [:]
    spaced["idempotency_key"] = "  k-1\n"
    var copied = arguments.objectValue ?? [:]
    copied["idempotency_key"] = "k-1"
    checkEqual(identity(.object(spaced), "k-1"), identity(.object(copied), "k-1"),
               "the key as SkyCut reads it (trimmed): sent with spaces, then as the receipt gives it, the same request")
    check(identity(["kind": "image", "prompt": "a lake"], minted) != identity(arguments, minted), "the arguments are part of it")

    // A first call without a key: SkyCut made the key and started the job, whose download then gave up.
    let job = "generate-held-\(UUID().uuidString.prefix(6))"
    _ = try? SkyStudioGenerationRequests.begin(minted, identity: identity(arguments, minted))
    SkyStudioGenerationRequests.complete(minted, result: .ok(["status": "started", "job_id": .string(job)]))
    var retries = 0
    SkyStudioHeldDownloads.hold(job) { retries += 1 }

    // The returned key with the same arguments: its own cached answer reaches its held job, which stays held while it downloads again.
    let cached = try? SkyStudioGenerationRequests.begin(minted, identity: identity(.object(named), minted))
    var answer = cached.flatMap(SkyStudioGenerationRequests.heldAnswer(for:))
    check(answer?.payload["status"] == "downloading_again" && answer?.payload["job_id"]?.stringValue == job
            && answer?.payload["submitted_again"] == false && retries == 1,
          "the key SkyCut returned, with the same arguments: Download again of that job: \(String(describing: answer?.payload))")
    check(SkyStudioHeldDownloads.isHeld(job), "it stays held while that Download again runs (and when it fails again)")
    answer = cached.flatMap(SkyStudioGenerationRequests.heldAnswer(for:))
    check(answer?.payload["job_id"]?.stringValue == job && retries == 2,
          "asked again, the same job is asked again (the run itself starts nothing while its Download again runs)")

    // The same key with other arguments is refused, as before; another key is a new request: neither reaches the held job.
    var refused = false
    do { _ = try SkyStudioGenerationRequests.begin(minted, identity: identity(["kind": "image", "prompt": "a lake"], minted)) }
    catch { refused = true }
    let other = "other-\(UUID().uuidString)"
    let fresh = try? SkyStudioGenerationRequests.begin(other, identity: identity(arguments, other))
    SkyStudioGenerationRequests.abandonPreparation(other)
    check(refused && fresh == nil && retries == 2,
          "the same key with other arguments is refused, another key is a new request (nothing cached): neither downloads that job")

    // Once its result came down, the key's cached answer stands as it was.
    SkyStudioHeldDownloads.release(job)
    check(cached.flatMap(SkyStudioGenerationRequests.heldAnswer(for:)) == nil && !SkyStudioHeldDownloads.isHeld(job) && retries == 2,
          "nothing held: the cached answer stands as it was")

    // An official key's cached answer (its generation's or its recovery's job id): that job's own Download again.
    SkyStudioHeldDownloads.hold(job) { retries += 1 }
    answer = SkyStudioGenerationRequests.heldAnswer(for: .ok(["status": "recovering", "job_id": .string(job)]))
    check(answer?.payload["job_id"]?.stringValue == job && retries == 3, "a cached official answer reaches its own held job")
    SkyStudioHeldDownloads.release(job)
}
