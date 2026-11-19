import AppKit
import SwiftUI
import Vision
@testable import SrtFlow

// Host production SwiftUI content in this process. Locate text in the window's own drawing and
// send its window an ordinary click through SmokeEvents, without desktop capture or AX permission.
@MainActor final class CheckWindow {
    let window: NSWindow
    private let host: NSView

    init(_ content: some View, width: CGFloat, height: CGFloat) throws {
        guard let screen = NSScreen.main else { throw CheckFailure("GUI check needs a graphical session") }
        let hosting = NSHostingView(rootView: content.appLanguage()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AppThemePalette.current.window))
        host = hosting
        let rect = NSRect(origin: screen.visibleFrame.origin, size: CGSize(width: width, height: height))
        window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.orderBack(nil)
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }

    func text(_ label: String) async throws -> CGPoint {
        let box = try await textBounds(label)
        return CGPoint(x: box.midX, y: box.midY)
    }

    func textBounds(_ label: String) async throws -> CGRect {
        let cutoff = ContinuousClock.now + .seconds(4)
        repeat {
            host.layoutSubtreeIfNeeded()
            let drawn = try capture()
            if let box = try await Self.locate(label, in: drawn) {
                return CGRect(x: box.minX * host.bounds.width, y: (1 - box.maxY) * host.bounds.height,
                              width: box.width * host.bounds.width, height: box.height * host.bounds.height)
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < cutoff
        throw CheckFailure("The window never displayed '\(label)'")
    }

    func click(_ label: String) async throws {
        try await click(text(label))
    }

    func click(_ point: CGPoint) async throws {
        try await SmokeEvents(window: window).click(point, count: 1, flags: [])
    }

    func type(_ value: String, replacing current: String) throws {
        guard let field = textField(with: current, in: host), window.makeFirstResponder(field),
              let editor = field.currentEditor() as? NSTextView else {
            throw CheckFailure("No editable text field contained '\(current)'")
        }
        editor.selectAll(nil)
        editor.insertText(value, replacementRange: editor.selectedRange())
        guard window.makeFirstResponder(nil) else { throw CheckFailure("Text field did not commit") }
    }

    private func textField(with value: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, field.stringValue == value { return field }
        for child in view.subviews {
            if let field = textField(with: value, in: child) { return field }
        }
        return nil
    }

    private func capture() throws -> CGImage {
        let bounds = host.bounds
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw CheckFailure("Could not draw the test window")
        }
        host.cacheDisplay(in: bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw CheckFailure("Test window did not produce pixels") }
        return image
    }

    private nonisolated static func locate(_ label: String, in image: CGImage) async throws -> CGRect? {
        try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            var partial: CGRect?
            for observation in request.results ?? [] {
                guard let match = observation.topCandidates(1).first,
                      let range = match.string.range(of: label, options: .caseInsensitive) else { continue }
                let found = try match.boundingBox(for: range)?.boundingBox ?? observation.boundingBox
                if match.string.caseInsensitiveCompare(label) == .orderedSame { return found }
                if partial == nil { partial = found }
            }
            return partial
        }.value
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor func eventually(_ condition: String, timeout: Duration = .seconds(5),
                           _ reached: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !reached() {
        guard ContinuousClock.now < deadline else { throw CheckFailure(condition) }
        try await Task.sleep(for: .milliseconds(50))
    }
}
