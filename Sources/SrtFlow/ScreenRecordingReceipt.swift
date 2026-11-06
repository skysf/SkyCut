import Foundation
import SrtFlowMCPKit

// 录屏收尾的不可变回执：界面、Stop、get_job / get_status 和会话附言共用；不操作窗口或媒体。
struct ScreenRecordingReceipt: Equatable {
    enum Status: String { case done, failed, cancelled }

    enum Stop: String {
        case controlPanel = "control_panel", mcp = "record_screen", duration, quit
        case sourceCancelled = "source_picker_cancelled"
        case activity = "ai_activity_stop", cancelJob = "cancel_job"
        case streamError = "stream_error", lowDisk = "low_disk_space", writerError = "writer_error", setupError = "setup_error"

        var by: String {
            switch self {
            case .controlPanel, .quit, .activity, .sourceCancelled: return "user"
            case .mcp, .cancelJob: return "ai"
            case .duration, .streamError, .lowDisk, .writerError, .setupError: return "automatic"
            }
        }
    }

    struct File: Equatable {
        var url: URL
        var kind = "video"
        var usable = true
        var temporary = false
        var unavailable = false
    }

    struct Clip: Equatable {
        var id: String
        var track: String
    }

    var id: String
    var jobID: String
    var ownerSession: String?
    var status: Status
    var stop: Stop
    var projectID: String
    var projectName: String
    var projectGeneration: Int
    var background: Bool
    var files: [File] = []
    var clips: [Clip] = []
    var duration: Double?
    var width: Int?
    var height: Int?
    var reason: String?
    var waitingForDecision = false
    var incomplete = false
    var began = false

    var video: File? { files.first { $0.kind == "video" && $0.usable } }
    var addedToTimeline: Bool { !clips.isEmpty }

    var json: JSONValue {
        var value: [String: JSONValue] = [
            "recording_id": .string(id), "job_id": .string(jobID), "kind": "screen_recording",
            "status": .string(status.rawValue), "recording": false,
            "stopped_by": .string(stop.by), "stop_method": .string(stop.rawValue),
            "project": .string(projectID), "project_name": .string(projectName), "project_background": .bool(background),
            "added_to_timeline": .bool(addedToTimeline), "clip_ids": .array(clips.map { .string($0.id) }),
            "clips": .array(clips.map { ["id": .string($0.id), "track": .string($0.track)] }),
            "retained_files": .array(files.map {
                ["file": .string($0.url.path), "kind": .string($0.kind), "usable": $0.unavailable ? .null : .bool($0.usable),
                 "temporary": .bool($0.temporary), "availability": .string($0.unavailable ? "unavailable" : "present")]
            }),
            "message": .string(message)
        ]
        if let video { value["file"] = .string(video.url.path) }
        if let mic = files.first(where: { $0.kind == "microphone" && $0.usable }) { value["microphone_file"] = .string(mic.url.path) }
        if let duration { value["duration"] = .number((duration * 1000).rounded() / 1000) }
        if let width { value["width"] = .number(Double(width)) }
        if let height { value["height"] = .number(Double(height)) }
        if let reason { value["reason"] = .string(reason) }
        if incomplete { value["incomplete"] = .string(reason ?? "The recording is incomplete.") }
        if waitingForDecision { value["waiting_for_decision"] = true }
        return .object(value)
    }

    var message: String {
        var parts = ["Screen recording \(jobID) has stopped (\(stop.by), \(stop.rawValue))."]
        if let reason { parts.append(reason) }
        for file in files {
            if file.unavailable { parts.append("Recording location unavailable; could not check: \(file.url.path)."); continue }
            let label = file.usable ? (file.temporary ? "Usable temporary file" : "Saved file") : "Unreadable file left behind"
            parts.append("\(label): \(file.url.path).")
        }
        if files.allSatisfy({ !$0.usable && !$0.unavailable }) { parts.append("No usable recording file was kept.") }
        if addedToTimeline {
            let where_ = clips.map { "\($0.track) clip \($0.id)" }.joined(separator: ", ")
            parts.append("Added to project \(projectID) (\(projectName)): \(where_).")
        } else {
            parts.append(waitingForDecision ? "Waiting for the user's decision before adding it to the timeline." : "Not added to the timeline.")
        }
        if background { parts.append("This project is in the background with no window; the user can open it from the recording notice.") }
        return parts.joined(separator: " ")
    }
}
