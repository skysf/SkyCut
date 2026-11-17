import Foundation

// MARK: - One open project's saved versions: save one when the project changed, list them, go back to one
//
// What it covers: where the versions live (`root`, one folder per project file), writing a version (only when the timeline differs
// from the project's latest version; never for an empty timeline or a never-saved project), keeping the newest 30, deleting the
// folders of projects that got no version for 60 days (once per run), the list the Versions sheet shows (`versions`, newest first),
// and going back to a version as one undo step after saving the state being left.
// A version is a complete project file written by the same `VideoEditProjectIO.save` as the project (format version, media
// bookmarks) and read back by the same `load` (format gate and migrations, the four relinking layers, image stills).
// What it doesn't: deciding when to save (AIRound, AIRoundVersions), names and pruning rules (ProjectVersionFiles), the sheet.
// Long-term rules: docs/architecture/project-versions.md.

@MainActor
final class ProjectVersionStore: ObservableObject {
    /// One store per open project (short id); forgotten when the project closes (`AISession.forgetRound`).
    private static var stores: [String: ProjectVersionStore] = [:]

    static func `for`(_ project: VideoEditProject) -> ProjectVersionStore {
        if let store = stores[project.shortID] { return store }
        let store = ProjectVersionStore(project: project)
        stores[project.shortID] = store
        return store
    }

    static func forget(_ project: VideoEditProject) {
        stores[project.shortID] = nil
    }

    /// Every project's versions: `~/Library/Application Support/SrtFlow/Versions` (an identity name, so it stays SrtFlow:
    /// docs/architecture/product-name.md). Checks point it elsewhere with `SRTFLOW_VERSIONS_ROOT`; script-driven runs (in-process
    /// smoke, the performance bench) get a folder of their own in the temporary directory, so they never write into the user's.
    nonisolated static var root: URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["SRTFLOW_VERSIONS_ROOT"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        if environment[PerfCounters.smokeScriptKey] != nil || environment[PerfCounters.outputKey] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("SkyCut versions \(getpid())", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SrtFlow/Versions", isDirectory: true)
    }

    /// The project's versions, newest first, as `refresh` last read them (every save refreshes it).
    @Published private(set) var versions: [ProjectVersion] = []

    private weak var project: VideoEditProject?
    /// The newest version's canonical timeline, so "changed since the last version" does not read the file every time.
    private var latest: (url: URL, canonical: TimelineState)?
    /// The age sweep runs once per run of SkyCut, at the first version written.
    private static var swept = false

    private init(project: VideoEditProject) {
        self.project = project
    }

    /// This project's folder, or nil while it has never been saved (a version is kept per project file).
    var folder: URL? {
        project?.documentURL.map { Self.root.appendingPathComponent(ProjectVersionFiles.folderName(forProject: $0), isDirectory: true) }
    }

    func refresh() {
        let next = folder.map(Self.read) ?? []
        if next != versions { versions = next }
    }

    // MARK: Saving

    enum Saved: Equatable {
        /// A new file.
        case written(ProjectVersion)
        /// The timeline already is the newest version: nothing written.
        case unchanged(ProjectVersion)
        case notSaved(NotSaved)

        var version: ProjectVersion? {
            switch self {
            case .written(let version), .unchanged(let version): return version
            case .notSaved: return nil
            }
        }
    }

    enum NotSaved: Equatable {
        /// The project has no file yet, so it has no place for versions.
        case untitled
        /// Nothing on the timeline: nothing to keep.
        case empty
        /// Writing failed (full disk, no permission); the message says why.
        case failed(String)
    }

    /// Saves `state` as a version of the project unless it equals the newest one. Synchronous on the main actor like `saveNow`.
    @discardableResult
    func save(_ state: TimelineState, kind: ProjectVersionKind) -> Saved {
        guard let project, let folder else { return .notSaved(.untitled) }
        guard !state.isEmpty else { return .notSaved(.empty) }
        guard let canonical = ProjectVersionFiles.canonical(state) else { return .notSaved(.failed("the timeline could not be written")) }
        let existing = Self.read(folder)
        if let newest = existing.first, canonicalTimeline(of: newest) == canonical { return .unchanged(newest) }
        let number = (existing.first?.number ?? 0) + 1
        let url = folder.appendingPathComponent(ProjectVersionFiles.fileName(projectStem: project.projectName, number: number, kind: kind))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try VideoEditProjectIO.save(state, to: url, knownRecords: project.mediaRecords, rowHeights: project.rowHeights)
        } catch {
            return .notSaved(.failed(error.localizedDescription))
        }
        latest = (url, canonical)
        let version = Self.read(folder).first { $0.number == number }
            ?? ProjectVersion(number: number, kind: kind, savedAt: Date(), url: url)
        for old in ProjectVersionFiles.pruned(existing + [version]) where old.url != url {
            try? FileManager.default.removeItem(at: old.url)
        }
        sweepOnce(keeping: folder)
        refresh()
        return .written(version)
    }

    private func canonicalTimeline(of version: ProjectVersion) -> TimelineState? {
        if let latest, latest.url == version.url { return latest.canonical }
        guard let canonical = ProjectVersionFiles.canonicalTimeline(ofFile: version.url) else { return nil }
        latest = (version.url, canonical)
        return canonical
    }

    // MARK: Going back

    struct WentBack: Equatable {
        let version: ProjectVersion
        /// The version that holds the state the project was in just before (new, or the newest one when it already was that).
        let savedBefore: ProjectVersion?
        /// false: the project already was that version (nothing restored, no undo step).
        let changed: Bool
    }

    enum GoBackError: Error, Equatable {
        case unknown(requested: String, allowed: [String])
        case unreadable(String, reason: String)
        /// The project's content was replaced (another file opened into it) while the version was loading.
        case projectChanged
    }

    /// Puts the whole project back to a saved version as one undo step (Command-Z returns). The state being left is saved as a
    /// version first. Media that moved since are found by the version's own media records (the four layers of `load`, then the
    /// project's running relink); image stills whose cache was cleared are converted again.
    func goBack(to requested: String) async throws -> WentBack {
        refresh()
        guard let project, let number = ProjectVersionFiles.number(fromID: requested),
              let version = versions.first(where: { $0.number == number }) else {
            throw GoBackError.unknown(requested: requested, allowed: versions.map(\.id))
        }
        let generation = project.documentGeneration
        let url = version.url
        let loaded: VideoEditProjectIO.LoadResult
        do {
            // Like opening a project: relinking may search folders, so not on the main thread.
            loaded = try await Task.detached(priority: .userInitiated) { try VideoEditProjectIO.load(from: url) }.value
        } catch {
            throw GoBackError.unreadable(version.id, reason: error.localizedDescription)
        }
        guard project.isCurrentGeneration(generation) else { throw GoBackError.projectChanged }
        let leaving = project.state
        guard loaded.timeline != leaving else { return WentBack(version: version, savedBefore: nil, changed: false) }
        let savedBefore = save(leaving, kind: .beforeGoingBack).version
        // The version's media records go into the project's table (paths it does not know yet), so a file that moved since can
        // still be followed by its bookmark when the project relinks after the rebuild.
        for (path, record) in loaded.records where project.mediaRecords[path] == nil { project.mediaRecords[path] = record }
        // Restored as is, like "Undo This Round": not through `perform`, whose magnet and linkage would change the version.
        // Its own undo group: the restore lands after an await, never inside a user event.
        AIUndoGrouping.step(project.effectiveUndoManager) { project.restoreTimeline(loaded.timeline) }
        if !loaded.stillsToRegenerate.isEmpty {
            let stills = loaded.stillsToRegenerate
            let current = project.documentGeneration
            project.trackImportTask(Task { await project.regenerateStills(stills, generation: current) })
        }
        return WentBack(version: version, savedBefore: savedBefore, changed: true)
    }

    // MARK: Disk

    /// The versions in a folder, newest first. Files that are not versions are left alone and not listed.
    nonisolated static func read(_ folder: URL) -> [ProjectVersion] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        )) ?? []
        var seen = Set<Int>()
        return files.compactMap { url -> ProjectVersion? in
            guard let parsed = ProjectVersionFiles.parse(fileName: url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return ProjectVersion(number: parsed.number, kind: parsed.kind, savedAt: values.contentModificationDate ?? .distantPast, url: url)
        }
        .sorted { $0.number != $1.number ? $0.number > $1.number : $0.url.path < $1.url.path }
        .filter { seen.insert($0.number).inserted }
    }

    private func sweepOnce(keeping folder: URL) {
        guard !Self.swept else { return }
        Self.swept = true
        Self.sweep(root: Self.root, keeping: folder, now: Date())
    }

    /// Deletes the version files in every project folder under `root` whose newest version is stale, then the folder if that
    /// left it empty. Only version files are ever deleted, and only one level below `root`.
    nonisolated static func sweep(root: URL, keeping folder: URL?, now: Date) {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for candidate in folders where candidate.standardizedFileURL != folder?.standardizedFileURL {
            guard (try? candidate.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let versions = read(candidate)
            guard ProjectVersionFiles.isStale(newest: versions.map(\.savedAt).max(), now: now) else { continue }
            for version in versions { try? manager.removeItem(at: version.url) }
            if (try? manager.contentsOfDirectory(atPath: candidate.path))?.isEmpty == true { try? manager.removeItem(at: candidate) }
        }
    }
}
