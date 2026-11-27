import AppKit
import SwiftUI

// MARK: - The number columns of the two subtitle lists: wide enough for the list's largest number
//
// What it does: the edit page's "#12" column is sized by a hidden template of the list's largest number ("#9999" for a
// four-digit list) and is never narrower than the 24 pt it always had; the Burn In table's "#" column is 30 pt as before and
// wider when the largest number wouldn't fit (semibold when current, with Forest's chip around it). A number never wraps
// or truncates, current or not, and the chip never takes width from it (review FBG1 U1; this also ends the edit page's old
// wrap from #100 on).
// What it doesn't: the current / selected look itself (StateMarks.swift `chipText`).
// Rules: docs/architecture/app-themes.md "On / off at a glance"; scripts/check-app-theme.sh measures #9 to #9999.

enum SubtitleIndexColumn {
    /// The edit page's narrowest number column (what it always was).
    static let editMinimumWidth: CGFloat = 24
    /// The Burn In table's narrowest "#" column (what it always was).
    static let tableMinimumWidth: CGFloat = 30
    /// How far Forest's chip reaches beyond a marked text on each side (StateMarks.swift `chipText`).
    static let chipOutset: CGFloat = 3

    static func digits(_ largest: Int) -> Int { String(max(largest, 0)).count }

    /// As many 9s as the largest number has digits (at least two, so a short list keeps its old 24 pt). The label draws it
    /// the way it draws the numbers ("#9,999": the same grouping), so every row's column is the same width.
    static func editTemplate(largest: Int) -> Int { Int(String(repeating: "9", count: max(2, digits(largest)))) ?? 99 }

    /// The edit page's number: one line, as wide as the template of the list's largest number, at least 24 pt.
    @MainActor
    @ViewBuilder
    static func editLabel(index: Int, template: Int, isCurrent: Bool) -> some View {
        ZStack(alignment: .leading) {
            Text("#\(template)").hidden()
            Text("#\(index)")
                .lineLimit(1)
                .fixedSize()
                .chipText(isCurrent, normal: Color.secondary, semibold: false)
        }
        .font(.caption2)
        .monospacedDigit()
        .frame(minWidth: editMinimumWidth, alignment: .leading)
    }

    /// The Burn In table's "#" column for the largest number: its digits in the table's semibold (current) font, the cell's
    /// own inset and, in Forest, the chip around it; never below 30 pt.
    /// Measured once per digit count and theme (the Burn In panel asks on every clock tick).
    @MainActor
    static func tableWidth(largest: Int, chip: Bool) -> CGFloat {
        let key = digits(largest) * 2 + (chip ? 1 : 0)
        if let known = measured[key] { return known }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        // As the table draws it: grouped ("8,888").
        let sample = NumberFormatter.localizedString(from: NSNumber(value: Int(String(repeating: "8", count: digits(largest))) ?? 8), number: .decimal)
        let width = (sample as NSString).size(withAttributes: [.font: font]).width
        let column = max(tableMinimumWidth, ceil(width + 4 + (chip ? 2 * chipOutset : 0)))
        measured[key] = column
        return column
    }

    @MainActor private static var measured: [Int: CGFloat] = [:]
}
