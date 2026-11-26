import Foundation
import Security

// Scratch fixtures for scripts/check-app-update.sh: small app bundles signed ad-hoc with a version, a build and a marker
// resource that tells copies apart; read-only disk images holding one (built with the real hdiutil, attached with -nobrowse
// at scratch mount points only); the loopback server's folder; and the command-line tools the checks use as independent
// witnesses (codesign, hdiutil). Everything lives under one scratch root, removed by the script.

enum UpdateFixture {
    static let identifier = "com.srtflow.SrtFlow.updatecheck"
    /// What the checks verify copies against instead of the running app's designated requirement: an ad-hoc build's is its
    /// own code hash, which no other build satisfies (the Developer ID's names the team: the manual two-build test).
    static func identifierRequirement() -> SecRequirement {
        var requirement: SecRequirement?
        SecRequirementCreateWithString("identifier \"\(identifier)\"" as CFString, [], &requirement)
        return requirement!
    }

    /// `<folder>/<name>.app`, signed ad-hoc inside out (a helper in Contents/Helpers like skycut-mcp), with `marker`.
    @discardableResult
    static func app(in folder: URL, name: String = "SkyCut", version: String, build: String = "1", marker: String,
                    identifier: String = identifier) throws -> URL {
        let app = folder.appendingPathComponent(name + ".app")
        let contents = app.appendingPathComponent("Contents")
        for sub in ["MacOS", "Helpers", "Resources"] {
            try FileManager.default.createDirectory(at: contents.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleExecutable": name, "CFBundleName": name, "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version, "CFBundleVersion": build,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: contents.appendingPathComponent("MacOS/\(name)").path)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: contents.appendingPathComponent("Helpers/helper").path)
        try Data(marker.utf8).write(to: contents.appendingPathComponent("Resources/marker.txt"))
        try Data(repeating: 9, count: 512 * 1024).write(to: contents.appendingPathComponent("Resources/payload.bin"))
        for code in [contents.appendingPathComponent("Helpers/helper"), app] {
            let signed = Tools.run("/usr/bin/codesign", ["--force", "--sign", "-", code.path])
            guard signed.status == 0 else { throw AppUpdateError("codesign \(code.lastPathComponent): \(signed.output)") }
        }
        return app
    }

    static func marker(of app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8)
    }

    /// `codesign --verify --deep --strict`: the witness that shares no code with AppBundleSignature.
    static func codesignVerifies(_ app: URL) -> Bool {
        Tools.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0
    }

    /// A compressed read-only HFS+ image like SkyCut's installer: the app at its top and a link to /Applications.
    static func image(of app: URL, at dmg: URL, extraApp: URL? = nil) throws {
        let content = dmg.deletingPathExtension().appendingPathExtension("content")
        try? FileManager.default.removeItem(at: content)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: app, to: content.appendingPathComponent(app.lastPathComponent))
        if let extraApp {
            try FileManager.default.copyItem(at: extraApp, to: content.appendingPathComponent("Another.app"))
        }
        try FileManager.default.createSymbolicLink(atPath: content.appendingPathComponent("Applications").path,
                                                   withDestinationPath: "/Applications")
        let made = Tools.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", content.path, "-fs", "HFS+",
                                                  "-volname", "SkyCutUpdateCheck", "-format", "UDZO", "-ov", dmg.path])
        try? FileManager.default.removeItem(at: content)
        guard made.status == 0 else { throw AppUpdateError("hdiutil create: \(made.output)") }
    }

    static func sha256(_ file: URL) -> String { AppUpdateDigest.sha256(of: file) ?? "" }

    static func size(_ file: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? -1
    }

    /// A feed's JSON for `version`, naming `url` with `size` and `sha` (the fields scripts/write-update-feed.sh writes).
    static func feedJSON(version: String, build: String = "1", minimum: String = "15.0", url: String, size: Int64, sha: String,
                         notes: [String: [String]] = ["en": ["One", "Two"], "zh-Hans": ["一", "二"]],
                         extra: [String: Any] = [:]) -> Data {
        var object: [String: Any] = [
            "schema": 1, "bundle_id": "com.srtflow.SrtFlow", "version": version, "build": build, "minimum_macos": minimum,
            "dmg_url": url, "dmg_size": size, "dmg_sha256": sha, "notes": notes,
        ]
        object.merge(extra) { _, new in new }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func contents(of folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }
}

struct ToolOutput {
    let status: Int32
    let output: String
}

enum Tools {
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> ToolOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return ToolOutput(status: -1, output: "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ToolOutput(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// Something is mounted at this point: its device differs from its parent folder's.
    static func isMounted(_ point: URL) -> Bool { AppUpdateStager.isMountPoint(point) }
}

/// The loopback HTTP server the script started (python3's http.server on 127.0.0.1, serving `folder`).
struct LoopbackServer {
    let base: URL
    let folder: URL

    func url(_ path: String) -> URL { base.appendingPathComponent(path) }

    func put(_ data: Data, at path: String) throws {
        let file = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func copy(_ file: URL, to path: String) throws {
        let target = folder.appendingPathComponent(path)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: file, to: target)
    }

    /// The source a test hook pointing at this server would give.
    func source(_ path: String) -> AppUpdateFeed.Source { AppUpdateFeed.Source.resolve(override: url(path).absoluteString) }
}
