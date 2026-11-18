import Foundation

// Recognized official defaults follow the UI language; project-authored names and field labels remain verbatim.
// Metadata lookup never loads HTML or changes the saved source/parameter values.
@MainActor
enum OfficialWebMotionLabels {
    private static var aliases: [String: Set<String>] = [:]

    static func title(_ record: WebMotionClipRecord) -> String {
        guard let template = OfficialWebMotionTemplate.matching(record.templateID) else { return record.name }
        return localizedDefault(record.name, key: template.titleKey)
    }

    static func field(_ field: WebMotionParameterField, record: WebMotionClipRecord) -> String {
        guard let template = OfficialWebMotionTemplate.matching(record.templateID),
              let key = template.fieldLabelKeys[field.key] else { return field.label }
        return localizedDefault(field.label, key: key)
    }

    private static func localizedDefault(_ original: String, key localizationKey: String) -> String {
        let known: Set<String>
        if let cached = aliases[localizationKey] {
            known = cached
        } else {
            known = Set([localizationKey] + AppLanguage.allCases.filter { $0 != .system }.map {
                $0.bundle.localizedString(forKey: localizationKey, value: localizationKey, table: nil)
            })
            aliases[localizationKey] = known
        }
        return known.contains(original) ? L10n(localizationKey) : original
    }
}
