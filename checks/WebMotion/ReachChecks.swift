import Foundation
import SrtFlowWebMotionKit

// Pages that reach outside: not one connection or datagram arrives at a local listener the page aims every network
// path at; no file is read; camera, microphone, location, clipboard and notifications are refused; storage does not
// survive a render. The helper lingers after its result (`SRTFLOW_WEB_MOTION_TEST_LINGER`) so a missing lock has time
// to leak before the process is gone.

enum ReachChecks {
    static let linger = "SRTFLOW_WEB_MOTION_TEST_LINGER"

    static func run() async {
        section("Reaching outside the page")
        await network()
        await files()
        await access()
    }

    private static func network() async {
        guard let listener = try? NetworkListener() else {
            check(false, "the local TCP + UDP listener started")
            return
        }
        defer { listener.stop() }
        check(listener.selfTest(), "positive control: this process reaches the listener on port \(listener.port) by TCP and UDP")
        for (name, page) in [("network", ReachPages.network(port: listener.port)), ("navigation", ReachPages.navigation(port: listener.port))] {
            listener.reset()
            Fixture.setEnvironment(linger, "2.5")
            let run = await runHelper(Fixture.job(page, name: name, limits: Fixture.tight))
            Fixture.setEnvironment(linger, nil)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let seen = listener.counts
            check(seen.connections.isEmpty && seen.datagrams == 0, "\(name) page: no request, connection or datagram left it "
                + (name == "network" ? "(fetch, XHR, beacon, sockets, event source, images, styles, fonts, scripts, media, frames, "
                    + "workers, preconnect, prefetch, WebRTC)" : "(meta refresh, form post, link and ping, location, popup)")
                + ": \(seen.connections.count) connections \(seen.connections), \(seen.datagrams) datagrams")
            check(run.processesEnded && !run.timedOut, "\(name) page: the helper and its WebKit processes ended (\(run.processSummary))")
            if name == "network" {
                let errors = run.rejected?.pageErrors ?? []
                check(errors.contains { $0.hasPrefix("Blocked:") }, "the page's attempts come back as page errors for the AI: "
                    + (errors.first ?? run.outcome))
            }
        }
    }

    private static func files() async {
        let token = "secret-\(UUID().uuidString)"
        let secret = Fixture.folder.appendingPathComponent("secret.txt")
        try? token.write(to: secret, atomically: true, encoding: .utf8)
        Fixture.setEnvironment(linger, "1")
        let run = await runHelper(Fixture.job(ReachPages.files(secret: secret.path), name: "files", limits: Fixture.tight))
        Fixture.setEnvironment(linger, nil)
        let errors = run.rejected?.pageErrors ?? []
        let summary = ReachPages.summary(in: errors)
        check(!errors.joined().contains(token), "no page error carries the file's contents")
        check(summary?.count == 4 && summary?.values.allSatisfy { $0.hasPrefix("blocked:") } == true,
              "fetch, XHR, image and font loads of a local file are all blocked: \(summary.map { "\($0)" } ?? errors.joined(separator: " | "))")
    }

    private static func access() async {
        let first = await runHelper(Fixture.job(ReachPages.access(token: "first-render"), name: "access-1", limits: Fixture.tight))
        let second = await runHelper(Fixture.job(ReachPages.access(token: "second-render"), name: "access-2", limits: Fixture.tight))
        let summaries = [first, second].map { ReachPages.summary(in: $0.rejected?.pageErrors ?? []) }
        for (index, summary) in summaries.enumerated() {
            let names = ["camera", "microphone", "location", "clipboard", "notifications", "storage"]
            let blocked = names.allSatisfy { summary?[$0]?.hasPrefix("blocked:") == true }
            check(blocked, "render \(index + 1): camera, microphone, location, clipboard and notifications are refused: "
                + "\(summary.map { "\($0)" } ?? "no summary")")
        }
        let storage = summaries[1]?["storage"] ?? ""
        check(!storage.contains("first-render") && !storage.isEmpty,
              "storage written by one render is gone in the next (\(storage))")
    }
}
