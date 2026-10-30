import Foundation

// MARK: - 云端任务的归属、媒体类型与工程分组（纯值）
// 起任务时固定「哪个工程的哪一次打开」，切窗口、换工程都不能改归属。
// 不持有工程或播放器；关闭后的任务保留名字快照，打开按钮必须另向注册表核对代号。
struct CloudTaskOwner: Equatable {
    let generation: Int
    let token: String
    let shortID: String
    let title: String
}

enum CloudTaskMediaKind: String, CaseIterable {
    case video, audio, image

    var systemImage: String {
        switch self {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        }
    }

    var title: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        case .image: return "Image"
        }
    }
}

struct CloudTaskGroup: Identifiable, Equatable {
    let owner: CloudTaskOwner
    let summary: CloudTaskSummary
    var id: Int { owner.generation }
}

struct CloudTaskGrouping: Equatable {
    struct Entry {
        let owner: CloudTaskOwner
        let task: CloudTaskSummary.Entry
    }

    let groups: [CloudTaskGroup]
    let summary: CloudTaskSummary

    init(entries: [Entry]) {
        // 按首次出现的次序分组；进度变化不重排，展开中的工程不会跳位置。
        var owners: [CloudTaskOwner] = []
        var grouped: [Int: [CloudTaskSummary.Entry]] = [:]
        for entry in entries {
            if grouped[entry.owner.generation] == nil { owners.append(entry.owner) }
            grouped[entry.owner.generation, default: []].append(entry.task)
        }
        groups = owners.map { CloudTaskGroup(owner: $0, summary: CloudTaskSummary(entries: grouped[$0.generation] ?? [])) }
        summary = CloudTaskSummary(entries: entries.map(\.task))
    }

    func group(for generation: Int) -> CloudTaskGroup? {
        groups.first { $0.owner.generation == generation }
    }
}
