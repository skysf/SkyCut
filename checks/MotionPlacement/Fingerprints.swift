import Foundation
import SrtFlowWebMotionKit
@testable import SrtFlow

// Cache identities are compared against deliberately different inputs and synthetic machine versions.
@MainActor func runMotionFingerprintChecks() throws {
    var record = WebMotionClipRecord(page: "<canvas/>", parametersJSON: #"{"z":{"b":2,"a":1},"a":"title"}"#,
                                    duration: 0.5, width: 320, height: 180, fps: 24)
    let system = WebMotionVersions(renderer: 1, macOS: "26.5.2", macOSBuild: "25F1", webKit: "620.1")
    let fingerprint = try WebMotionCache.fingerprint(record, versions: system)
    record.parametersJSON = #"{ "a": "title", "z": {"a":1,"b":2} }"#
    motionRequire(try WebMotionCache.fingerprint(record, versions: system) == fingerprint,
                  "object key order and whitespace do not create another movie")
    let changes: [(String, (inout WebMotionClipRecord) -> Void)] = [
        ("page", { $0.page += "different" }), ("parameters", { $0.parametersJSON = #"{"a":"another title"}"# }),
        ("duration", { $0.duration = 1 }), ("hit", { $0.hitTime = 0.25 }), ("width", { $0.width = 640 }),
        ("height", { $0.height = 360 }), ("fps", { $0.fps = 30 })
    ]
    for (name, change) in changes {
        var changed = record; change(&changed)
        motionRequire(try WebMotionCache.fingerprint(changed, versions: system) != fingerprint, "\(name) changes the movie's fingerprint")
    }
    let systems: [(String, (inout WebMotionVersions) -> Void)] = [
        ("renderer", { $0.renderer += 1 }), ("macOS", { $0.macOS = "27.0" }),
        ("OS build", { $0.macOSBuild += "a" }), ("WebKit", { $0.webKit += ".1" })
    ]
    for (name, change) in systems {
        var changed = system; change(&changed)
        motionRequire(try WebMotionCache.fingerprint(record, versions: changed) != fingerprint, "\(name) changes the movie's fingerprint")
    }
    motionRequire(try WebMotionCache.fingerprint(record, versions: system, fonts: ["font-revision-2"]) != fingerprint,
                  "a changed font identity changes the movie's fingerprint")
    var reserved = record
    reserved.hitTime = 0.25
    reserved.parametersJSON = #"{"duration":99,"hit":99}"#
    let normalized = WebMotionParameters.object(try WebMotionParameters.normalized(reserved).parametersJSON)
    motionRequire(normalized["duration"] == 0.5 && normalized["hit"] == 0.25,
                  "the page receives the record's duration and hit rather than conflicting parameter values")
    var malformed = record
    malformed.parametersJSON = "not JSON"
    do {
        _ = try WebMotionParameters.normalized(malformed)
        motionRequire(false, "a malformed stored parameter object must be rejected")
    } catch {
        motionRequire(true, "malformed parameters are not silently replaced with an empty object")
    }
    var carried = record
    carried.provenance = .init(fingerprint: fingerprint, renderer: system.renderer, macOS: system.macOS,
                               macOSBuild: system.macOSBuild, webKit: system.webKit, fonts: ["Synthetic Missing Font"])
    let warnings = WebMotionEnvironment.warnings(for: carried, versions: .init(renderer: 2, macOS: "27", macOSBuild: "other", webKit: "new"),
                                                 installed: [])
    motionRequire(warnings.count == 2 && warnings.contains { $0.contains("Synthetic Missing Font") },
                  "another OS and a missing font each warn without discarding the carried movie")
    motionRequire(carried.provenance?.fingerprint == fingerprint, "portability warnings do not rewrite render provenance")
    motionRequire(WebMotionEnvironment.warnings(for: carried, versions: system, installed: ["Synthetic Missing Font"]).isEmpty,
                  "matching system and installed fonts need no portability warning")
    var state = TimelineState()
    state.canvasRatio = .tall9x16
    state.frameRate = .fps60
    var clip = EditClip(sourceURL: URL(fileURLWithPath: "/tmp/synthetic-motion.mov"), sourceDuration: record.duration)
    clip.webMotion = record
    state.insertLane(audio: false, at: 0, clips: [clip])
    let copied = try MotionPresetLibrary.template("project:\(clip.id.uuidString.lowercased())", in: state)
    motionRequire(copied.width == 1080 && copied.height == 1920 && copied.fps == 60 && copied.page == record.page,
                  "a reused template renders for the destination canvas and project frame rate while retaining its page")
}
