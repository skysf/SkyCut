import AppKit
import SwiftUI
@testable import SrtFlow

// Draw the production web-clip label in the same host across language changes. This catches a missing locale
// dependency that pure metadata checks cannot see; the wiring guard binds this view to both real consumers.
@MainActor func runMotionClipNameChecks() async throws {
    let language = AppLanguageStore.shared.language
    defer { AppLanguageStore.shared.language = language }
    AppLanguageStore.shared.language = .english
    let original = try OfficialWebMotionTemplate.wordCollision.record()
    var custom = original
    custom.name = "My Expedition"
    let officialHost = MotionClipNameCapture(WebMotionClipName(record: original))
    let customHost = MotionClipNameCapture(WebMotionClipName(record: custom))
    defer { officialHost.close(); customHost.close() }
    let english = try await officialHost.png()
    let authored = try await customHost.png()
    for next in [AppLanguage.simplifiedChinese, .spanish, .english] {
        AppLanguageStore.shared.language = next
        let expected = MotionClipNameCapture(Text(verbatim: L10n(OfficialWebMotionTemplate.wordCollision.titleKey)))
        let translated = try await officialHost.png()
        let reference = try await expected.png()
        expected.close()
        motionRequire(translated == reference,
                      "the already-mounted official clip name draws the current \(next.rawValue) title")
        motionRequire(next == .english ? translated == english : translated != english,
                      "switching locale redraws an English stored official name and returning restores it")
        motionRequire(try await customHost.png() == authored,
                      "the already-mounted custom clip name stays verbatim in \(next.rawValue)")
    }
    motionRequire(original.name == "Word Collision" && custom.name == "My Expedition"
                    && original.parametersJSON == custom.parametersJSON,
                  "displaying localized clip names never rewrites saved names or authored values")
}

@MainActor private final class MotionClipNameCapture {
    private let host: NSView
    private let window: NSWindow

    init<Content: View>(_ content: Content) {
        let size = CGSize(width: 240, height: 32)
        host = NSHostingView(rootView: content.font(.system(size: 14)).foregroundStyle(.black)
            .frame(width: size.width, height: size.height).background(.white).appLanguage())
        window = NSWindow(contentRect: NSRect(origin: NSScreen.main?.visibleFrame.origin ?? .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .aqua)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        host.frame = container.bounds
        container.addSubview(host)
        window.contentView = container
        window.orderBack(nil)
    }

    func png() async throws -> Data {
        for _ in 0..<4 {
            try await Task.sleep(nanoseconds: 40_000_000)
            host.layoutSubtreeIfNeeded()
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw AIToolError("Could not draw the web-clip name regression fixture")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let hasInk = (0..<bitmap.pixelsWide).contains { x in
            (0..<bitmap.pixelsHigh).contains { y in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return color.redComponent < 0.5 && color.alphaComponent > 0.5
            }
        }
        guard hasInk, let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AIToolError("The web-clip name regression fixture drew no text")
        }
        return png
    }

    func close() { window.orderOut(nil); window.close() }
}
