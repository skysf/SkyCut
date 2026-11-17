import Foundation
import WebKit

// MARK: - One instance of the page
//
// Owns: a windowless WKWebView with the locked configuration, its geometry (the output size at 1× pixels per device
// pixel: the view is sized in points = pixels / backing scale and `pageZoom` makes CSS px map onto output pixels, as
// the probe found — rendering at 2× and scaling down was 2.7× slower), loading, drawing one frame, the public path's
// backdrop and snapshots. No window and no NSApplication: measured as fast as an off-screen window, and nothing can
// appear on screen. Does not own: locks (`Lockdown`), the clock script (`PageClock`), time limits (`Deadline`).

@MainActor
final class PageWorker {
    let web: WKWebView
    let navigation = LockedNavigation()
    private let pixelWidth: Int
    private let pixelHeight: Int

    /// What the page reported after loading.
    struct Loaded {
        let errors: [String]
        let hasFrame: Bool
        let declaredDuration: Double?
        let width: Double
        let height: Double
        let ratio: Double
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// - Parameters:
    ///   - points: the view's size in points (pixels / backing scale).
    ///   - zoom: `pageZoom` (CSS px → points).
    ///   - transparent: switch WebKit's background off (the fast alpha path).
    init(configuration: WKWebViewConfiguration, points: CGSize, zoom: Double, pixels: (Int, Int), transparent: Bool) {
        web = WKWebView(frame: CGRect(origin: .zero, size: points), configuration: configuration)
        web.pageZoom = zoom
        web.navigationDelegate = navigation
        web.uiDelegate = navigation
        pixelWidth = pixels.0
        pixelHeight = pixels.1
        if transparent { _ = PageWorker.drawNoBackground(web) }
    }

    /// The fast alpha path: WebKit's non-public "draws background" switch. False when this WebKit has no such switch
    /// (the calibration then fails and `.auto` uses the public path).
    static func drawNoBackground(_ web: WKWebView) -> Bool {
        if ProcessInfo.processInfo.environment["SRTFLOW_WEB_MOTION_TEST_BREAK_FAST_ALPHA"] == "1" { return false }
        let selectors = ["setDrawsBackground:", "_setDrawsBackground:"].map(NSSelectorFromString)
        guard selectors.contains(where: { web.responds(to: $0) }) else { return false }
        web.setValue(false, forKey: "drawsBackground")
        return true
    }

    /// Resizes (the calibration page is measured at zoom 1 first, then redrawn at 1×).
    func resize(points: CGSize, zoom: Double) {
        web.frame = CGRect(origin: .zero, size: points)
        web.pageZoom = zoom
    }

    func load(_ html: String) async throws {
        try await navigation.waitForLoad { web.loadHTMLString(html, baseURL: nil) }
    }

    func finishLoading() async throws -> Loaded {
        let value = try await call(PageClock.finishLoadingCall, [:])
        guard let report = value as? [String: Any] else {
            throw Failure(description: "The renderer's clock did not start in the page (no control object).")
        }
        func number(_ key: String) -> Double { (report[key] as? NSNumber)?.doubleValue ?? -1 }
        return Loaded(errors: report["errors"] as? [String] ?? [], hasFrame: report["hasFrame"] as? Bool ?? false,
                      declaredDuration: (report["duration"] as? NSNumber)?.doubleValue,
                      width: number("width"), height: number("height"), ratio: number("ratio"))
    }

    /// Draws frame t; the page's errors from this frame (empty = none). `backdrop` paints an opaque background after
    /// the frame (public alpha path).
    func draw(t: Double, backdrop: String?) async throws -> [String] {
        let value = try await call(PageClock.drawFrameCall, ["t": t, "backdrop": backdrop ?? false])
        return value as? [String] ?? []
    }

    func setBackdrop(_ color: String) async throws {
        _ = try await call(PageClock.setBackdropCall, ["backdrop": color])
    }

    func snapshot() async throws -> CGImage {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = web.bounds
        configuration.snapshotWidth = NSNumber(value: Double(web.bounds.width))
        configuration.afterScreenUpdates = false
        let image: NSImage
        do {
            image = try await web.takeSnapshot(configuration: configuration)
        } catch {
            if navigation.processEnded { throw LockedNavigation.ProcessEnded() }
            throw error
        }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw Failure(description: "WebKit returned a snapshot without pixels.")
        }
        guard cgImage.width == pixelWidth, cgImage.height == pixelHeight else {
            throw Failure(description: "The snapshot is \(cgImage.width)×\(cgImage.height), not \(pixelWidth)×\(pixelHeight).")
        }
        return cgImage
    }

    var processIdentifiers: [Int32] { Lockdown.processIdentifiers(of: web) }

    private func call(_ body: String, _ arguments: [String: Any]) async throws -> Any? {
        do {
            return try await web.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
        } catch {
            if navigation.processEnded { throw LockedNavigation.ProcessEnded() }
            throw error
        }
    }
}
