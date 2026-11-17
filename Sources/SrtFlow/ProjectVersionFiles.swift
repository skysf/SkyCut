import CryptoKit
import Foundation
import SrtFlowCore

// MARK: - Saved project versions: what they are, what they are called, which ones go (pure values)
//
// What it covers: the three moments SkyCut saves a version (`ProjectVersionKind`), a version's id (`v3`), the version file's name
// (`<project> - v3 before AI round.skycut`, the `<name> - <version>` form of `AIVersionName`), the per-project folder under the
// versions root (`<project> <8 hex>`, the hex being a hash of the project file's path, so two projects never share a list, even with
// the same name), reading a file name back, the canonical form "changed since the last version" compares, and which versions and
// folders pruning removes.
// What it doesn't: touching the disk or the project (ProjectVersionStore), deciding when a version is saved (AIRound, AIRoundVersions).
// Long-term rules: docs/architecture/project-versions.md.

enum ProjectVersionKind: String, CaseIterable, Sendable {
    case beforeRound = "before_ai_round"
    case afterRound = "after_ai_round"
    case beforeGoingBack = "before_going_back"

    /// The words in the file name. Fixed English in every app language: the name is how a version file is read back.
    var fileLabel: String {
        switch self {
        case .beforeRound: return "before AI round"
        case .afterRound: return "after AI round"
        case .beforeGoingBack: return "before going back"
        }
    }

    /// What SkyCut shows for it (a key in the string tables).
    var title: String {
        switch self {
        case .beforeRound: return "Before AI round"
        case .afterRound: return "After AI round"
        case .beforeGoingBack: return "Before going back"
        }
    }
}

/// One saved version of a project: a complete project file in the project's versions folder.
struct ProjectVersion: Identifiable, Equatable, Sendable {
    let number: Int
    /// nil: a name this SkyCut does not know (written by a later SkyCut, or renamed by hand). It can still be gone back to.
    let kind: ProjectVersionKind?
    /// When the file was written (its modification date).
    let savedAt: Date
    let url: URL

    var id: String { ProjectVersionFiles.id(number) }
}

enum ProjectVersionFiles {
    /// How many versions each project keeps: the newest ones (a project file is tens of KB).
    static let keep = 30
    /// A project's versions are deleted when SkyCut has not saved one for it in this long (the project file is never touched).
    static let staleAfter: TimeInterval = 60 * 24 * 60 * 60
    /// Long project names are cut (in UTF-8 bytes) so a version's file name stays inside the 255-byte limit.
    static let maxStemBytes = 120

    static func id(_ number: Int) -> String { "v\(number)" }

    /// The number in an id the AI or the user gives: "v3", "V3" or "3".
    static func number(fromID id: String) -> Int? {
        var text = id.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(text), number > 0 else { return nil }
        return number
    }

    /// The project's folder under the versions root: its name plus a hash of its full path (standardized, symlinks resolved —
    /// the same identity `ProjectFileIdentity.same` uses). Renaming or moving the project file starts a new folder.
    static func folderName(forProject url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let hex = SHA256.hash(data: Data(path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return shortStem(url.deletingPathExtension().lastPathComponent) + " " + hex
    }

    static func fileName(projectStem: String, number: Int, kind: ProjectVersionKind) -> String {
        AIVersionName.stem(shortStem(projectStem), version: id(number) + " " + kind.fileLabel)
            + "." + VideoEditProjectFile.fileExtension
    }

    /// Reads a version file's name back: the number after the last " - v" and, when SkyCut knows the words after it, the kind.
    /// Anything else (the project file itself, notes the user left there) is not a version.
    static func parse(fileName: String) -> (number: Int, kind: ProjectVersionKind?)? {
        guard VideoEditProjectFile.isProjectFile(URL(fileURLWithPath: fileName)) else { return nil }
        let stem = (fileName as NSString).deletingPathExtension
        guard let marker = stem.range(of: " - v", options: .backwards) else { return nil }
        let rest = stem[marker.upperBound...]
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits), number > 0 else { return nil }
        let label = rest.dropFirst(digits.count)
        guard label.isEmpty || label.first == " " else { return nil }
        let words = label.trimmingCharacters(in: .whitespaces)
        return (number, ProjectVersionKind.allCases.first { $0.fileLabel == words })
    }

    /// Which versions pruning deletes: everything but the newest `keep` (by number, the order they were saved in).
    static func pruned(_ versions: [ProjectVersion], keep: Int = keep) -> [ProjectVersion] {
        Array(versions.sorted { $0.number > $1.number }.dropFirst(max(0, keep)))
    }

    /// A project's folder is stale when its newest version is older than `staleAfter` (or it holds no version at all).
    static func isStale(newest: Date?, now: Date) -> Bool {
        guard let newest else { return true }
        return now.timeIntervalSince(newest) > staleAfter
    }

    /// The timeline exactly as a project file keeps it (written and read back with the project file's own coder): what
    /// "changed since the last version" compares, so a state is not counted as changed by what a file cannot hold (dates keep
    /// whole seconds). nil when it cannot be written.
    static func canonical(_ state: TimelineState) -> TimelineState? {
        guard let data = try? VideoEditProjectIO.makeEncoder().encode(state),
              let decoded = try? VideoEditProjectIO.makeDecoder().decode(TimelineState.self, from: data) else { return nil }
        return WebMotionProjectFiles.normalizingCacheLocations(in: decoded)
    }

    /// The timeline a version file holds, read the same way (`canonical` of what was saved). nil when it cannot be read.
    static func canonicalTimeline(ofFile url: URL) -> TimelineState? {
        guard let data = try? Data(contentsOf: url),
              let timeline = try? VideoEditProjectIO.makeDecoder().decode(VideoEditProjectFile.self, from: data).timeline else { return nil }
        return canonical(timeline)
    }

    /// The project's name, cut at a character boundary to `maxStemBytes` UTF-8 bytes; "Untitled" when nothing is left.
    private static func shortStem(_ stem: String) -> String {
        var cut = ""
        for character in ExportFileName.stem(from: stem, droppingExtension: "", fallback: "Untitled") {
            guard cut.utf8.count + String(character).utf8.count <= maxStemBytes else { break }
            cut.append(character)
        }
        return cut.trimmingCharacters(in: .whitespaces)
    }
}
