import CoreText
import Darwin
import Foundation
import SrtFlowWebMotionKit

// Identifies the local renderer and fonts for cache keys and portable-project warnings. It never loads a page.
enum WebMotionEnvironment {
    static var versions: WebMotionVersions {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var length = 0
        sysctlbyname("kern.osversion", nil, &length, nil, 0)
        var build = [CChar](repeating: 0, count: max(1, length))
        sysctlbyname("kern.osversion", &build, &length, nil, 0)
        let kit = Bundle(path: "/System/Library/Frameworks/WebKit.framework")
        return .init(renderer: WebMotionVersion.renderer,
                     macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                     macOSBuild: String(cString: build),
                     webKit: kit?.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")
    }

    static func hasFont(_ name: String) -> Bool {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        return [CTFontCopyFullName(font), CTFontCopyFamilyName(font), CTFontCopyPostScriptName(font)]
            .contains { ($0 as String) == name }
    }

    static func fonts(in record: WebMotionClipRecord) -> [String] {
        let parameters = WebMotionParameters.object(record.parametersJSON)
        let fields = record.parameterFields.filter { $0.kind == .font }.compactMap { parameters[$0.key]?.stringValue }
        return Array(Set(record.fonts + fields)).sorted()
    }

    /// A custom font can change without an OS update. Include its installed file identity in new cache keys.
    static func fontIdentities(_ fonts: [String]) -> [String] {
        fonts.sorted().map { name in
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            guard let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return name }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(name):\(size):\(modified)"
        }
    }

    static func warnings(for record: WebMotionClipRecord, versions: WebMotionVersions = versions,
                         installed: Set<String>? = nil) -> [String] {
        guard let previous = record.provenance else { return [] }
        var warnings: [String] = []
        if previous.macOS != versions.macOS || previous.macOSBuild != versions.macOSBuild || previous.webKit != versions.webKit {
            warnings.append(L10n("This motion was rendered on another system. Its carried video is kept; re-rendering may change the lettering."))
        }
        let missing = previous.fonts.filter { name in installed.map { !$0.contains(name) } ?? !hasFont(name) }
        if !missing.isEmpty {
            warnings.append(String(format: L10n("Missing motion fonts: %@. The carried video is kept; choose installed fonts before re-rendering."),
                                   missing.joined(separator: ", ")))
        }
        return warnings
    }
}
