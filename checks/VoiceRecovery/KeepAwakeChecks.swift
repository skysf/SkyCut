import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// AI 在干活时别让 App Nap 把 SkyCut 降速（AIKeepAwake，docs/bugfixes/2026-11-10-ai-work-throttled-by-app-nap.md），真 App 对象：
// - 计数：几份同时领只开一次断言、最后一份还掉才关；同一份还两次只算一次；领了忘了还的，放掉时也还；
// - AIJobs：起任务领一份、结束还掉，结束两次不多还；
// - 一次真的工具调用（AIToolRouter.handle，skycut_guide 没开通也照答）：从收到到回答开过一次断言，回答之后还掉。
// 哪里领、哪里还的接线在 checks/ai-keep-awake.sh；跑完全部声音检查之后一份都不剩在 Main 里查。

@MainActor
func runKeepAwakeChecks() async {
    var begins = 0
    var ends = 0
    let awake = AIKeepAwake(begin: { begins += 1; return NSObject() }, end: { _ in ends += 1 })
    let first = awake.hold()
    let second = awake.hold()
    require(begins == 1 && awake.holders == 2 && awake.isHolding, "two leases share one activity (begins \(begins), holders \(awake.holders))")
    first.release()
    first.release()
    require(ends == 0 && awake.holders == 1 && awake.isHolding, "releasing the same lease twice gives back one (holders \(awake.holders), ends \(ends))")
    second.release()
    require(ends == 1 && awake.holders == 0 && !awake.isHolding, "the last lease back ends the activity (ends \(ends))")
    do { _ = awake.hold() }
    require(begins == 2 && ends == 2 && awake.holders == 0 && awake.heldPeriods == 2,
            "a lease dropped without release still gives back (begins \(begins), ends \(ends), holders \(awake.holders))")

    let before = AIKeepAwake.shared.holders
    let job = AIJobs.shared.start(.inspection, progress: { nil }, cancel: {})
    require(AIKeepAwake.shared.holders == before + 1 && AIKeepAwake.shared.isHolding, "a running AI job holds the keep-awake assertion")
    AIJobs.shared.finish(job, .done, message: "keep-awake check")
    AIJobs.shared.finish(job, .failed, message: "a second finish is ignored")
    require(AIKeepAwake.shared.holders == before, "finishing the job gives its lease back once (holders \(AIKeepAwake.shared.holders), before \(before))")

    require(AIKeepAwake.shared.holders == 0, "no AI work is running before the tool call check (holders \(AIKeepAwake.shared.holders))")
    let periods = AIKeepAwake.shared.heldPeriods
    let request = MCPBridge.Request(tool: "skycut_guide", arguments: [:], client: "keep-awake-check")
    let answer = await AIToolRouter.shared.handle(request, begin: { true })
    require(answer.result["isError"] != true, "the guide answers through the router (got \(answer.result.encodedString().prefix(200)))")
    require(AIKeepAwake.shared.heldPeriods == periods + 1 && AIKeepAwake.shared.holders == 0 && !AIKeepAwake.shared.isHolding,
            "a tool call holds the assertion while it runs and gives it back (periods \(AIKeepAwake.shared.heldPeriods - periods), "
            + "holders \(AIKeepAwake.shared.holders))")
}
