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
            return panels[requests.count]
        }, appearDeadline: 0.5)
        let destination = ExportDestinationState(folder: initial)
        var remembered: [String] = []
        let row = VStack(alignment: .leading, spacing: 10) {
            ExportFolderRow(destination: destination, chooser: chooser) { remembered.append($0.path) }
        }.padding(16)
        let check = try CheckWindow(row, width: 550, height: 235)
        defer { check.close() }

        _ = try await check.text("Export to")
        try await choose(check, after: "Initial")
        try await eventually("The chosen folder did not reach the export destination") {
            destination.folder.path == fromPanel.path && remembered == [fromPanel.path]
        }
        guard requests == [.exportFolder(startingAt: initial)] else {
            throw CheckFailure("The folder control made the wrong request: \(requests)")
        }

        try await choose(check, after: "Chosen")
        try await eventually("The empty panel callback did not offer a fallback") { chooser.phase == .failed(.returnedAtOnce) }
        _ = try await check.text("Use This Folder")
        try check.type(fromText.path, replacing: fromPanel.path)
        try await check.click("Use This Folder")
        try await eventually("The typed fallback did not set and remember its folder") {
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

    private static func choose(_ window: CheckWindow, after folderName: String) async throws {
        let path = try await window.textBounds(folderName)
        // The icon-only folder button is the next control after the trailing end of the displayed path.
        try await window.click(CGPoint(x: path.maxX + 25, y: path.midY))
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
