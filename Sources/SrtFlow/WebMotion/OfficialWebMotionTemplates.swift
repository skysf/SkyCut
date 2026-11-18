import Foundation
import SrtFlowMCPKit

// SkyCut's original web designs and their default editable values. Pages are bundled source, not a second renderer;
// placement, approval, persistence and cache recovery stay on the existing shared web-motion path.
enum OfficialWebMotionTemplate: String, CaseIterable, Identifiable, Hashable, Sendable {
    case boxToEarth = "box-to-earth"
    case wordCollision = "word-collision"
    case iceCrackLight = "ice-crack-light"

    var id: String { "official:" + rawValue.replacingOccurrences(of: "-", with: "_") }

    static func matching(_ id: String?) -> Self? { allCases.first { $0.id == id } }

    var titleKey: String {
        switch self {
        case .boxToEarth: return "Box to Earth"
        case .wordCollision: return "Word Collision"
        case .iceCrackLight: return "Light Through Ice"
        }
    }

    var blurbKey: String {
        switch self {
        case .boxToEarth: return "A title box stretches into a globe with fine latitude and longitude lines."
        case .wordCollision: return "Two words meet in a flash with drifting fragments; the picture stays steady."
        case .iceCrackLight: return "A jagged ice crack opens with light and reveals the title."
        }
    }

    var duration: Double { 4 }

    var fieldLabelKeys: [String: String] {
        var labels = ["text": "Text", "font": "Font", "color": "Colour"]
        if self == .wordCollision { labels["second_text"] = "Second word" }
        return labels
    }

    func fieldLabelKey(for key: String) -> String? { fieldLabelKeys[key] }

    var hit: Double {
        switch self {
        case .boxToEarth: return 0.6
        case .wordCollision: return 0.9
        case .iceCrackLight: return 0.5
        }
    }

    var parameters: [String: JSONValue] {
        var values: [String: JSONValue] = ["font": "Avenir Next", "color": "#D6F4FF", "duration": .number(duration), "hit": .number(hit)]
        switch self {
        case .boxToEarth: values["text"] = "EARTH"
        case .wordCollision: values["text"] = "NORTH"; values["second_text"] = "SOUTH"
        case .iceCrackLight: values["text"] = "THROUGH THE ICE"
        }
        return values
    }

    /// Small checked movies are packaged for browsing. Opening the panel never starts helpers to build these previews.
    var previewURL: URL? { Self.resource(rawValue + "-preview", extension: "mov") }

    func record() throws -> WebMotionClipRecord {
        guard let page = Self.pages[self] else { throw AIToolError("Unknown official motion template.") }
        var fields = [WebMotionParameterField(key: "text", label: L10n("Text")),
                      .init(key: "font", label: L10n("Font"), kind: .font),
                      .init(key: "color", label: L10n("Colour"), kind: .color)]
        if self == .wordCollision { fields.insert(.init(key: "second_text", label: L10n("Second word")), at: 1) }
        return try WebMotionParameters.normalized(.init(page: page.get(), parametersJSON: WebMotionParameters.canonical(parameters),
                                                        templateID: id, name: L10n(titleKey), parameterFields: fields,
                                                        duration: duration, hitTime: hit, fps: 24))
    }

    // AppResources covers packaged apps and SwiftPM. Bundle.module is absent from the installed app.
    private static func resource(_ name: String, extension suffix: String) -> URL? {
        AppResources.url(named: name + "." + suffix)
            ?? AppResources.url(named: "WebMotionTemplates/" + name + "." + suffix)
    }

    private static let pages: [Self: Result<String, Error>] = Dictionary(uniqueKeysWithValues: allCases.map { template in
        (template, Result {
            guard let file = resource(template.rawValue, extension: "html") else {
                throw AIToolError("The official motion page is missing from SkyCut: \(template.rawValue).")
            }
            return try String(contentsOf: file, encoding: .utf8)
        })
    })
}
