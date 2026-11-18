import Foundation
import WebKit

// MARK: - Everything that keeps a page from reaching anything but its own drawing
//
// Owns: the WKWebView configuration every page (and the calibration page) gets, and the delegate that refuses
// navigation, windows and permissions. The locks, and which leak each one closes (measured 2026-11-17 against a local
// TCP + UDP listener; docs/architecture/web-motion-renderer.md「锁」has the table):
// - a content rule list that blocks every URL (fetch, XHR, images, styles, fonts, sockets, beacons, frames, …);
// - the CSP meta tags written into the page first (`WebMotionPageHTML`): blocks the same loads in the page, reports
//   them as page errors (the AI learns why), and forbids workers and eval;
// - only the first main-frame load (`about:blank` from `loadHTMLString`) is allowed: later navigations, form posts,
//   meta refreshes and subframes are cancelled; no new windows;
// - a non-persistent data store (no cookies, localStorage or IndexedDB survive);
// - camera / microphone requests denied, JavaScript dialogs answered at once (nothing can block a frame);
// - WebKit feature switches (non-public) for what CSP and content rules do not cover: WebRTC sent STUN over UDP and TURN
//   over TCP, link preconnect opened TCP connections, with every public lock on. Those switches are read back after
//   setting; when one is missing the render is refused (fail closed: the network lock is never relaxed, user 2026-11-16).
// Does not own: the clock (`PageClock`), the alpha switch (`PageWorker`), time limits (`Deadline`).

enum LockdownError: Error, CustomStringConvertible {
    case unavailable(String)
    case stillOn(String)
    case ruleList(String)

    var description: String {
        switch self {
        case .unavailable(let what):
            "SkyCut's network lock is not available on this macOS (\(what)); the page was not rendered."
        case .stillOn(let what): "SkyCut's network lock could not switch off \(what); the page was not rendered."
        case .ruleList(let detail): "SkyCut's network lock could not be compiled: \(detail)"
        }
    }
}

@MainActor
enum Lockdown {
    /// WebKit features switched off for every page: WebRTC and link preconnect leaked in the 2026-11-17 measurement;
    /// DNS prefetch (lookups that cannot be observed without touching DNS), WebTransport, early-hint preconnects and
    /// beacons are switched off as well so no other path is left open.
    static let switchedOffFeatures = [
        "PeerConnectionEnabled", "LinkPreconnect", "LinkDNSPrefetchEnabled", "WebTransportEnabled",
        "LinkPreconnectEarlyHintsEnabled", "BeaconAPIEnabled",
    ]

    /// One rule: block every URL. The page itself comes from `loadHTMLString`, which is not a load these rules see.
    static func compileRuleList(storeDirectory: URL) async throws -> WKContentRuleList {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        guard let store = WKContentRuleListStore(url: storeDirectory) else {
            throw LockdownError.ruleList("no rule list store at \(storeDirectory.path)")
        }
        let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        do {
            guard let list = try await store.compileContentRuleList(forIdentifier: "block-everything", encodedContentRuleList: rules) else {
                throw LockdownError.ruleList("WebKit returned no rule list")
            }
            return list
        } catch let error as LockdownError {
            throw error
        } catch {
            throw LockdownError.ruleList(error.localizedDescription)
        }
    }

    /// A locked configuration with the given scripts (all at document start, page world, main frame only).
    static func configuration(ruleList: WKContentRuleList, scripts: [String]) throws -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        try switchOff(switchedOffFeatures, in: configuration.preferences)
        let content = WKUserContentController()
        content.add(ruleList)
        for source in scripts {
            content.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        configuration.userContentController = content
        return configuration
    }

    /// Switches each named WebKit feature off and reads it back. Any missing piece throws: no render without the lock.
    static func switchOff(_ keys: [String], in preferences: WKPreferences) throws {
        let listSelector = NSSelectorFromString("_features")
        let setSelector = NSSelectorFromString("_setEnabled:forFeature:")
        let getSelector = NSSelectorFromString("_isEnabledForFeature:")
        let preferencesClass: AnyObject = WKPreferences.self
        guard preferencesClass.responds(to: listSelector), preferences.responds(to: setSelector),
              preferences.responds(to: getSelector),
              let features = preferencesClass.perform(listSelector)?.takeUnretainedValue() as? [NSObject]
        else { throw LockdownError.unavailable("WebKit feature switches") }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        typealias Getter = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let set = unsafeBitCast(preferences.method(for: setSelector), to: Setter.self)
        let get = unsafeBitCast(preferences.method(for: getSelector), to: Getter.self)
        for key in keys {
            guard let feature = features.first(where: { ($0.value(forKey: "key") as? String) == key }) else {
                throw LockdownError.unavailable("feature \(key)")
            }
            set(preferences, setSelector, false, feature)
            if get(preferences, getSelector, feature) { throw LockdownError.stillOn(key) }
        }
    }

    /// The WebKit processes behind a page (WebContent, GPU, Networking), for SkyCut's memory watch and teardown.
    /// Non-public accessors; a missing one is skipped (SkyCut then watches less, and says so).
    static func processIdentifiers(of web: WKWebView) -> [Int32] {
        var pids = ["_webProcessIdentifier", "_gpuProcessIdentifier"].compactMap { processIdentifier($0, of: web) }
        // WKWebView's testing network getter can assert before its first load. The configured store exists already;
        // its non-launching existence check makes the optional PID read safe without creating a network process.
        let store = web.configuration.websiteDataStore
        let exists = "_networkProcessExists"
        if store.responds(to: NSSelectorFromString(exists)), (store.value(forKey: exists) as? NSNumber)?.boolValue == true,
           let pid = processIdentifier("_networkProcessIdentifier", of: store) { pids.append(pid) }
        return pids
    }

    static func processIdentifier(_ key: String, of object: NSObject) -> Int32? {
        guard object.responds(to: NSSelectorFromString(key)), let value = object.value(forKey: key) as? NSNumber else { return nil }
        return value.int32Value > 0 ? value.int32Value : nil
    }
}

/// Refuses everything except the page's own first load; reports load results and a dead WebContent process.
@MainActor
final class LockedNavigation: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var firstLoadAllowed = false
    private var loading: CheckedContinuation<Void, Error>?
    /// Set when the page's WebContent process ended (memory, crash, killed).
    private(set) var processEnded = false

    struct ProcessEnded: Error, CustomStringConvertible {
        var description: String { "The page's WebKit process ended unexpectedly (it may have used too much memory)." }
    }

    func waitForLoad(_ start: () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loading = continuation
            start()
        }
    }

    private func finishLoading(_ error: Error?) {
        guard let continuation = loading else { return }
        loading = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let first = !firstLoadAllowed && action.targetFrame?.isMainFrame == true
            && action.request.url?.absoluteString == "about:blank"
        if first { firstLoadAllowed = true }
        decisionHandler(first ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoading(nil) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoading(error) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        processEnded = true
        finishLoading(ProcessEnded())
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        completionHandler(nil)
    }
}
