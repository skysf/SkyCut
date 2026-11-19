import AppKit
import SwiftUI
import Vision
@testable import SrtFlow

// Host production SwiftUI content in this process. Locate text in the window's own drawing and
// send its window an ordinary click through SmokeEvents, without desktop capture or AX permission.
@MainActor final class CheckWindow {
    // Allow a window to draw while the App is still within its longest folder probe (15 s).
    nonisolated static let controlTimeout: Duration = .seconds(20)
    let window: NSWindow
    private let host: NSView
    private var recognized: [String] = []

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
        try await findControl(label) { box, _ in box }
    }

    private func findControl<T>(_ label: String, match: (CGRect, CGImage) -> T?) async throws -> T {
        let started = ContinuousClock.now
        let cutoff = started + Self.controlTimeout
        var captureError: String?
        note("Waiting for '\(label)' in \(windowState)")
        repeat {
            host.layoutSubtreeIfNeeded()
            let content = host.bounds
            do {
                let drawn = try capture()
                let (box, lines) = try await Self.locate(label, in: drawn)
                captureError = nil
                recognized = lines
                if let box, host.bounds == content {
                    let bounds = CGRect(x: box.minX * content.width, y: (1 - box.maxY) * content.height,
                                        width: box.width * content.width, height: box.height * content.height)
                    if let control = match(bounds, drawn) {
                        note("Found '\(label)' after \(ContinuousClock.now - started)")
                        return control
                    }
                }
            } catch {
                captureError = String(describing: error)
            }
            try await Task.sleep(for: .milliseconds(200))
        } while ContinuousClock.now < cutoff
        let evidence = captureError ?? "OCR: \(recognized)"
        throw CheckFailure("Could not locate '\(label)' within \(Self.controlTimeout). \(windowState). \(evidence)")
    }

    func click(_ label: String) async throws {
        try await click(text(label))
    }

    func click(_ point: CGPoint) async throws {
        try await SmokeEvents(window: window).click(point, count: 1, flags: [])
    }

    /// Finds the filled, icon-only button on a labelled row. Text strokes are too narrow to satisfy the band test.
    func trailingButton(onRow label: String) async throws -> CGPoint {
        // Measure the row and its button in the same frame. The layout can move during a Vision request.
        try await findControl(label) { row, image in iconButton(on: row, in: image) }
    }

    private func iconButton(on row: CGRect, in image: CGImage) -> CGPoint? {
        let drawing = NSBitmapImageRep(cgImage: image)
        let scaleX = CGFloat(drawing.pixelsWide) / host.bounds.width
        let scaleY = CGFloat(drawing.pixelsHigh) / host.bounds.height
        let y = Int(row.midY * scaleY)
        let left = Int((row.maxX + 4) * scaleX)
        guard left < drawing.pixelsWide,
              let background = luminance(drawing, x: drawing.pixelsWide - 3, y: y) else { return nil }
        var spans: [Range<Int>] = []
        var start: Int?
        for x in left..<drawing.pixelsWide {
            let values = [y - 2, y, y + 2].compactMap { luminance(drawing, x: x, y: $0) }
            let filled = values.count == 3 && values.allSatisfy { abs($0 - background) > 0.045 }
            if filled {
                if start == nil { start = x }
            } else if let lower = start {
                if CGFloat(x - lower) / scaleX >= 18 { spans.append(lower..<x) }
                start = nil
            }
        }
        guard let button = spans.last else { return nil }
        return CGPoint(x: CGFloat(button.lowerBound + button.upperBound) / (2 * scaleX), y: row.midY)
    }

    private func luminance(_ image: NSBitmapImageRep, x: Int, y: Int) -> CGFloat? {
        guard let rgb = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
        return (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3
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

    func wait(_ condition: String, timeout: Duration = CheckWindow.controlTimeout,
              until reached: @MainActor () -> Bool) async throws {
        let started = ContinuousClock.now
        note("Waiting up to \(timeout) for \(condition) in \(windowState)")
        let deadline = started + timeout
        while !reached() {
            guard ContinuousClock.now < deadline else {
                let lines = (try? await Self.locate("", in: capture()))?.1 ?? recognized
                throw CheckFailure("Timed out waiting for \(condition). \(windowState). OCR: \(lines)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        note("Condition met after \(ContinuousClock.now - started) (\(condition))")
    }

    private var windowState: String {
        "window \(window.windowNumber), visible=\(window.isVisible), key=\(window.isKeyWindow), frame=\(window.frame), "
            + "content=\(host.bounds), scale=\(window.backingScaleFactor)"
    }

    private nonisolated static func locate(_ label: String, in image: CGImage) async throws -> (CGRect?, [String]) {
        try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            var partial: CGRect?
            let matches = (request.results ?? []).compactMap { observation in
                observation.topCandidates(1).first.map { ($0, observation.boundingBox) }
            }
            let lines = matches.map { $0.0.string }
            for (match, bounds) in matches {
                guard !label.isEmpty, let range = match.string.range(of: label, options: .caseInsensitive) else { continue }
                let found = try match.boundingBox(for: range)?.boundingBox ?? bounds
                if match.string.caseInsensitiveCompare(label) == .orderedSame { return (found, lines) }
                if partial == nil { partial = found }
            }
            return (partial, lines)
        }.value
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func note(_ line: String) {
    FileHandle.standardError.write(Data("GUI E2E: \(line)\n".utf8))
}
