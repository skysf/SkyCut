import AppKit
import Foundation
@testable import SrtFlow

@main enum E2EEditorGUI {
    @MainActor static func main() async {
        do {
            guard let domain = Bundle.main.bundleIdentifier, domain.hasPrefix("com.srtflow.e2egui"),
                  CommandLine.arguments.count == 3 else { throw CheckFailure("GUI check requires its isolated bundle and fixtures") }
            NSApplication.shared.setActivationPolicy(.accessory)
            AppLanguageStore.shared.language = .english
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let page = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
            note("Starting export folder")
            try await ExportFolderGUI.check(root)
            note("Starting Versions")
            try await VersionsGUI.check(project("versions", in: root))
            note("Starting native motion")
            try await MotionGUI.native(project("native-motion", in: root))
            note("Starting web motion")
            try await MotionGUI.web(project("web-motion", in: root), page: page)
            note("Starting timeline teardown")
            try await TimelineTeardownGUI.check(window: project("teardown-window", in: root), root: project("teardown-root", in: root))
        } catch {
            FileHandle.standardError.write(Data("SkyCut GUI E2E failed: \(error)\n".utf8))
            exit(1)
        }
        // The only success: the Swift runtime also exits 0 when something stops the main run loop mid-suite.
        print(completionLine)
        exit(0)
    }

    /// scripts/check-e2e-gui.sh requires this exact line.
    static let completionLine = "GUI E2E: every case ran"

    @MainActor private static func project(_ name: String, in root: URL) async throws -> VideoEditProject {
        guard let project = await OpenProjects.shared.createProject(
            savingAs: root.appendingPathComponent(name).appendingPathExtension("skycut"), placement: .background
        ) else { throw CheckFailure(OpenProjects.shared.failure ?? "Could not create \(name)") }
        return project
    }
}
