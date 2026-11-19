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
            try await ExportFolderGUI.check(root)
            try await VersionsGUI.check(project("versions", in: root))
            try await MotionGUI.native(project("native-motion", in: root))
            try await MotionGUI.web(project("web-motion", in: root), page: page)
        } catch {
            FileHandle.standardError.write(Data("SkyCut GUI E2E failed: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }

    @MainActor private static func project(_ name: String, in root: URL) async throws -> VideoEditProject {
        guard let project = await OpenProjects.shared.createProject(
            savingAs: root.appendingPathComponent(name).appendingPathExtension("skycut"), placement: .background
        ) else { throw CheckFailure(OpenProjects.shared.failure ?? "Could not create \(name)") }
        return project
    }
}
