import AppKit
import SwiftUI
@testable import SrtFlow

// The row uses the actual destination state and the same chooser it uses in the export sheet.
@MainActor enum ExportFolderGUI {
    static func check(_ root: URL) async throws {
        let initial = root.appendingPathComponent("Initial")
        let fromPanel = root.appendingPathComponent("Chosen")
        let fromText = root.appendingPathComponent("Typed")
        for folder in [initial, fromPanel, fromText] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let panels = [FolderPanel(response: [fromPanel]), FolderPanel(response: [])]
        var requests: [FileWindowRequest] = []
        let chooser = SystemFileChooser(makePanel: { request in
            defer { requests.append(request) }
            return panels[min(requests.count, panels.count - 1)]
        }, appearDeadline: 0.5)
        let destination = ExportDestinationState(folder: initial)
        var remembered: [String] = []
        let row = VStack(alignment: .leading, spacing: 10) {
            ExportFolderRow(destination: destination, chooser: chooser) { remembered.append($0.path) }
        }.padding(16)
        let check = try CheckWindow(row, width: 550, height: 235)
        defer { check.close() }

        let first = try await check.trailingButton(onRow: "Export to")
        try await check.click(first)
        do {
            try await check.wait("the chosen folder to reach the export destination") {
                destination.folder.path == fromPanel.path && remembered == [fromPanel.path]
            }
        } catch {
            throw CheckFailure("\(error). Click at \(first), requests \(requests), phase \(chooser.phase), "
                + "destination \(destination.folder.path), report \(String(describing: destination.report)).")
        }
        guard requests == [.exportFolder(startingAt: initial)] else {
            throw CheckFailure("The folder control made the wrong request: \(requests)")
        }

        try await check.click(check.trailingButton(onRow: "Export to"))
        try await check.wait("the empty panel callback to offer a fallback") { chooser.phase == .failed(.returnedAtOnce) }
        _ = try await check.text("Use This Folder")
        try check.type(fromText.path, replacing: fromPanel.path)
        try await check.click("Use This Folder")
        try await check.wait("the typed fallback to set and remember its folder") {
            destination.folder.path == fromText.path && chooser.phase == .idle && remembered == [fromPanel.path, fromText.path]
        }
        let occupied = fromText.appendingPathComponent("Cut.mp4")
        try Data("existing".utf8).write(to: occupied)
        guard case .askToReplace(let target) = await destination.exportDecision(stem: "Cut", pathExtension: "mp4"),
              target.path == occupied.path, try Data(contentsOf: occupied) == Data("existing".utf8) else {
            throw CheckFailure("The export decision did not name the existing file in the selected folder")
        }
        print("GUI export folder: picked in the panel, then recovered a failing panel with a typed path")
    }

}

@MainActor private final class FolderPanel: FileChooserPanel {
    let response: [URL]
    var isVisible: Bool { false }
    var frame: NSRect { .zero }

    init(response: [URL]) { self.response = response }

    func begin(_ completion: @escaping ([URL]?) -> Void) { completion(response) }

    func cancel() {}
}
