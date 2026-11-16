import Foundation
import WebKit

// The page clock takeover, driven directly: the production script (`PageClock.bootstrap`) in a plain WKWebView, the
// renderer's own calls (`finishLoading`, `drawFrame`), and the page's log of what it saw. Pins every rule of the clock:
// timers and requestAnimationFrame wait for the render time and run in due order, performance.now / Date / timelines
// read it, Math.random and crypto are seeded per t, CSS animations follow it, errors are captured, the control object
// cannot be replaced.

@MainActor
enum ClockChecks {
    static let epoch = 1_000_000.0

    static let page = """
        <!doctype html><html><head><style>
        #a{width:10px;height:10px;animation:move 1s linear forwards}
        @keyframes move{from{transform:translateX(0px)}to{transform:translateX(100px)}}
        </style></head><body><div id="a"></div><script>
        const log = window.__log = [];
        const start = { perf: performance.now(), date: Date.now() };
        log.push('load perf=' + start.perf + ' date=' + start.date);
        setTimeout(() => log.push('timeout250 at ' + performance.now()), 250);
        setTimeout(() => log.push('timeout100 at ' + performance.now()), 100);
        const interval = setInterval(() => log.push('interval at ' + performance.now()), 400);
        setTimeout(() => log.push('zero at ' + performance.now()), 0);
        requestAnimationFrame((time) => log.push('raf at ' + time));
        window.motion = { frame(t) {
          log.push('frame ' + t + ' perf=' + performance.now() + ' date=' + (Date.now() - start.date)
            + ' random=' + Math.random().toFixed(9));
          if (t >= 0.9) clearInterval(interval);
          if (t === 2) throw new Error('boom');
          if (t === 3) Promise.reject(new Error('later'));
        } };
        </script></body></html>
        """

    final class Loader: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    static func run() async {
        section("Page clock takeover (production script in a WKWebView)")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: PageClock.bootstrap(seed: 7, epochMilliseconds: epoch),
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController = content
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 100), configuration: configuration)
        let loader = Loader()
        web.navigationDelegate = loader
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            loader.done = done
            web.loadHTMLString(page, baseURL: nil)
        }
        do {
            try await exercise(web)
        } catch {
            check(false, "the clock harness ran without a WebKit error (\(error))")
        }
    }

    private static func exercise(_ web: WKWebView) async throws {
        func call(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
            try await web.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
        }
        func draw(_ t: Double) async throws -> [String] {
            try await call(PageClock.drawFrameCall, ["t": t, "backdrop": false]) as? [String] ?? []
        }
        func log() async throws -> [String] { try await call("return window.__log.splice(0);") as? [String] ?? [] }

        _ = try await call(PageClock.finishLoadingCall)
        let loaded = try await log()
        check(loaded == ["load perf=0 date=1000000", "zero at 0"],
              "at load: performance.now() is 0, Date.now() is the epoch, zero-delay timers ran (\(loaded))")
        _ = try await draw(0)
        let first = try await log()
        check(first.count == 2 && first[0] == "raf at 0" && first[1].hasPrefix("frame 0 perf=0 date=0"),
              "frame 0: requestAnimationFrame ran first with the render time, then frame(t) (\(first))")
        _ = try await draw(0.3)
        let second = try await log()
        check(Array(second.prefix(2)) == ["timeout100 at 100", "timeout250 at 250"],
              "t = 0.3: the 100 and 250 ms timers ran in due order, each seeing its due time (\(second))")
        check(second.last?.hasPrefix("frame 0.3 perf=300 date=300") == true, "t = 0.3: performance.now and Date.now read 300 ms")
        let random03 = second.last?.components(separatedBy: "random=").last
        _ = try await draw(0.9)
        let third = try await log()
        check(Array(third.prefix(2)) == ["interval at 400", "interval at 800"], "t = 0.9: the 400 ms interval ran at 400 and 800")
        _ = try await draw(1.5)
        let fourth = try await log()
        check(fourth.count == 1 && fourth[0].hasPrefix("frame 1.5"), "a cleared interval stays cleared (\(fourth))")
        _ = try await draw(0.3)
        let again = try await log()
        check(again.last?.components(separatedBy: "random=").last == random03,
              "Math.random gives the same numbers for the same t, whatever was drawn before")
        check(random03 != fourth[0].components(separatedBy: "random=").last, "Math.random differs between frames")
        try await dates(call)
        try await randomBytes(call, draw)
        _ = try await draw(0.25)
        let transform = try await call("return getComputedStyle(document.getElementById('a')).transform;") as? String
        check(transform == "matrix(1, 0, 0, 1, 25, 0)", "a CSS animation that started at load stands at t: 25 px at 0.25 s (\(transform ?? "nil"))")
        let thrown = try await draw(2)
        check(thrown.contains { $0.hasPrefix("Error: boom") && $0.contains("while drawing t = 2.000 s") },
              "an error thrown by frame(t) comes back verbatim with the time (\(thrown))")
        _ = try await draw(3)
        let afterReject = try await draw(3.1)
        check(afterReject.contains { $0.contains("Unhandled promise rejection: Error: later") },
              "an unhandled rejection is reported (\(afterReject))")
        let replaced = try await call("""
            try { window.__SKYCUT_MOTION_CLOCK__ = null; } catch (e) {}
            try { delete window.__SKYCUT_MOTION_CLOCK__; } catch (e) {}
            return typeof window.__SKYCUT_MOTION_CLOCK__.drawFrame;
            """) as? String
        check(replaced == "function", "the page cannot replace or delete the renderer's control object")
    }

    private static func dates(_ call: (String, [String: Any]) async throws -> Any?) async throws {
        let report = try await call("""
            const n = Date.now();
            return [new Date().getTime() === n, typeof Date() === 'string', new Date(0).getTime() === 0,
                    new Date(2020, 0, 2).getFullYear() === 2020, new Date() instanceof Date,
                    document.timeline.currentTime === performance.now()].join(',');
            """, [:]) as? String
        check(report == "true,true,true,true,true,true",
              "new Date(), Date(), Date(x), instanceof and document.timeline all follow the render clock (\(report ?? "nil"))")
    }

    private static func randomBytes(_ call: (String, [String: Any]) async throws -> Any?,
                                    _ draw: (Double) async throws -> [String]) async throws {
        let read = "return Array.from(crypto.getRandomValues(new Uint8Array(8))).join(',');"
        _ = try await draw(0.7)
        let first = try await call(read, [:]) as? String
        _ = try await draw(0.7)
        let second = try await call(read, [:]) as? String
        check(first != nil && first == second, "crypto.getRandomValues is seeded per t too")
    }
}
