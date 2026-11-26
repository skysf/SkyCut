import Foundation

// Scratch fixtures for scripts/check-move-to-applications.sh: small app bundles signed ad-hoc (a main executable, a nested
// helper, a marker resource that tells copies apart), the folders a move works in (destination, Trash, staging), and the
// command-line tools the checks use as independent witnesses (codesign, hdiutil). Everything lives under one scratch root.

struct ToolResult {
    let status: Int32
    let output: String
}

enum Tool {
    /// Runs a tool to its end and returns its exit status and combined output.
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return ToolResult(status: -1, output: "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ToolResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

enum Fixture {
    static let identifier = "com.srtflow.SrtFlow.movecheck"

    /// `<folder>/<name>.app`, signed ad-hoc inside out, with `marker` in Contents/Resources/marker.txt.
    @discardableResult
    static func app(in folder: URL, name: String = "SkyCut", marker: String) throws -> URL {
        let app = folder.appendingPathComponent(name + ".app")
        let contents = app.appendingPathComponent("Contents")
        for sub in ["MacOS", "Helpers", "Resources"] {
            try FileManager.default.createDirectory(at: contents.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleExecutable": name, "CFBundleName": name,
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: contents.appendingPathComponent("MacOS/\(name)").path)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: contents.appendingPathComponent("Helpers/helper").path)
        try Data(marker.utf8).write(to: contents.appendingPathComponent("Resources/marker.txt"))
        try Data(repeating: 7, count: 256 * 1024).write(to: contents.appendingPathComponent("Resources/payload.bin"))
        for code in [contents.appendingPathComponent("Helpers/helper"), app] {
            let signed = Tool.run("/usr/bin/codesign", ["--force", "--sign", "-", code.path])
            guard signed.status == 0 else { throw FixtureError("codesign \(code.lastPathComponent): \(signed.output)") }
        }
        return app
    }

    static func marker(of app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8)
    }

    /// `codesign --verify --deep --strict`: the witness that does not share code with AppBundleSignature.
    static func codesignVerifies(_ app: URL) -> Bool {
        Tool.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0
    }

    /// Every item of the tree, the root included (hidden files too).
    static func items(of root: URL) -> [URL] {
        var all = [root]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let next = enumerator?.nextObject() as? URL { all.append(next) }
        return all
    }

    static func setQuarantine(on root: URL) {
        let value = "0281;\(String(Int(Date().timeIntervalSince1970), radix: 16));Safari;"
        for item in items(of: root) {
            _ = value.withCString { setxattr(item.path, "com.apple.quarantine", $0, strlen($0), 0, XATTR_NOFOLLOW) }
        }
    }

    static func quarantined(in root: URL) -> [String] {
        items(of: root).filter { getxattr($0.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 }.map(\.lastPathComponent)
    }

    static func contents(of folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }
}

/// The folders one move works in: the original's folder, the destination ("Applications"), a scratch Trash and a staging
/// root (each move gets a new folder under it, and must remove it).
struct MoveScene {
    let root: URL
    let source: URL
    let applications: URL
    let trash: URL
    let staging: URL

    init(_ parent: URL, name: String) throws {
        root = parent.appendingPathComponent(name)
        source = root.appendingPathComponent("disk")
        applications = root.appendingPathComponent("Applications")
        trash = root.appendingPathComponent("Trash")
        staging = root.appendingPathComponent("staging")
        for folder in [source, applications, trash, staging] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    /// AppBundleMover against these folders; `running` names the destination paths that count as running.
    func mover(running: Set<String> = []) -> AppBundleMover {
        let trash = self.trash, staging = self.staging
        return AppBundleMover(
            destinationFolder: applications,
            isRunning: { running.contains($0.standardizedFileURL.path) },
            trash: { item in
                let target = trash.appendingPathComponent(item.lastPathComponent)
                try FileManager.default.moveItem(at: item, to: target)
                return target
            },
            makeStagingFolder: {
                let folder = staging.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                return folder
            })
    }
}

struct FixtureError: LocalizedError, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { description }
}
