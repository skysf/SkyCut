import AppKit
import SwiftUI

// scripts/check-app-theme.sh: the shared looks as laid out and as VoiceOver gets them (review FBG1 U1, U4). In both themes:
// the subtitle lists' numbers #9 … #9999 stay on one line and fit their column, current or not (the chip takes no width
// from them), and a short list keeps the old widths (24 pt on the edit page, 30 pt in the Burn In table). In Forest: each
// icon toggle is one named "toggle button" with its on / off value and the chip's frame, no image or switch beside it.

@MainActor
enum StateViewChecks {
    static func run(_ check: (Bool, String) -> Void) {
        for theme in [AppTheme.forest, .classic] {
            AppThemeStore.shared.setTheme(theme)
            numbers(theme, check)
        }
        AppThemeStore.shared.setTheme(.forest)
        voiceOver(check)
    }

    private static func size<V: View>(_ view: V) -> CGSize { NSHostingView(rootView: view).fittingSize }

    private static func numbers(_ theme: AppTheme, _ check: (Bool, String) -> Void) {
        let lines = [9, 10, 99, 256, 888, 1000, 9999]
        let template = SubtitleIndexColumn.editTemplate(largest: 9999)
        let oneLine = size(SubtitleIndexColumn.editLabel(index: 9, template: template, isCurrent: false)).height
        for index in lines {
            for current in [false, true] {
                let label = size(SubtitleIndexColumn.editLabel(index: index, template: template, isCurrent: current))
                let text = size(Text("#\(index)").font(.caption2).monospacedDigit().fixedSize())
                // Every row's column is the same width (the timecodes line up), whatever its number.
                check(abs(label.width - size(SubtitleIndexColumn.editLabel(index: 9, template: template, isCurrent: false)).width) < 0.5,
                      "\(theme) edit page: #\(index)'s column is as wide as #9's (got \(label.width))")
                check(abs(label.height - oneLine) < 0.5 && label.width + 0.5 >= text.width,
                      "\(theme) edit page: #\(index)\(current ? " (current)" : "") stays on one line and fits (\(label) for a \(text.width)-wide number)")
                let cell = size(Text("\(index)").fontWeight(.semibold).fixedSize()
                    .padding(.horizontal, theme == .forest && current ? SubtitleIndexColumn.chipOutset : 0))
                let column = SubtitleIndexColumn.tableWidth(largest: index, chip: theme == .forest)
                check(cell.width <= column, "\(theme) Burn In: \(index)\(current ? " (current)" : "") fits its \(column)-pt column (needs \(cell.width))")
            }
        }
        let short = size(SubtitleIndexColumn.editLabel(index: 4, template: SubtitleIndexColumn.editTemplate(largest: 4), isCurrent: false))
        check(abs(short.width - SubtitleIndexColumn.editMinimumWidth) < 0.5, "\(theme) edit page: a short list keeps its 24-pt number column (\(short.width))")
        check(SubtitleIndexColumn.tableWidth(largest: 4, chip: theme == .forest) == SubtitleIndexColumn.tableMinimumWidth,
              "\(theme) Burn In: a short file keeps its 30-pt number column")
    }

    /// The tree VoiceOver reads, as the reviewer's probe reads it (accessibility asked for in this process only).
    private static func voiceOver(_ check: (Bool, String) -> Void) {
        let set = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            _ = NSApplication.shared.perform(set, with: NSNumber(value: true), with: attribute)
        }
        let host = NSHostingView(rootView: HStack {
            Toggle(isOn: .constant(true)) { Image(systemName: "arrow.left.and.right") }
                .stateToggle(classicTint: nil).accessibilityLabel(Text(verbatim: "Flip horizontally"))
            Toggle(isOn: .constant(false)) { Image(systemName: "arrow.up.and.down") }
                .stateToggle(classicTint: nil).accessibilityLabel(Text(verbatim: "Flip vertically"))
        }.padding(10))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 200, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var elements: [(role: String, subrole: String, label: String, value: String, frame: NSRect)] = []
        func walk(_ element: Any) {
            guard let object = element as? NSObject else { return }
            func text(_ name: String) -> String {
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() else { return "" }
                return "\(value)"
            }
            let frame = (element as? NSAccessibilityElementProtocol)?.accessibilityFrame() ?? .zero
            elements.append((text("accessibilityRole"), text("accessibilitySubrole"), text("accessibilityLabel"), text("accessibilityValue"), frame))
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [Any] { children.forEach(walk) }
        }
        walk(host)
        window.contentView = nil
        let toggles = elements.filter { $0.role == "AXCheckBox" }
        check(toggles.count == 2 && toggles.allSatisfy { $0.subrole == "AXToggle" },
              "Forest VoiceOver: each icon toggle is one toggle button (got \(elements.map { "\($0.role) \($0.subrole)" }))")
        check(toggles.map(\.label) == ["Flip horizontally", "Flip vertically"] && toggles.map(\.value) == ["1", "0"],
              "Forest VoiceOver: the toggles keep their names and on / off values (got \(toggles.map { "\($0.label)=\($0.value)" }))")
        check(!elements.contains { $0.role == "AXImage" || $0.subrole == "AXSwitch" },
              "Forest VoiceOver: no stray image or switch beside the toggles")
        check(toggles.allSatisfy { $0.frame.width <= 32 && $0.frame.height <= 26 && $0.frame.width >= 20 },
              "Forest VoiceOver: each toggle's frame is its chip (got \(toggles.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" }))")
    }
}
