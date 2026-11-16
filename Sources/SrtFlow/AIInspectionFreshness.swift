import Foundation

// MARK: - 查的成片是不是改之前导的（MCP-65）
//
// 管什么：inspect_video 给了 file 时，看工程在这个文件做出来之后又改过没有；改过就在结果最前面（`attention`）先说一句，
// 免得 AI 改完没重新导出、查的是旧片子还报「一切正常」（照 OpenFilm 的思路：比两样东西的时间）。
// - 文件什么时候做的：它的创建时间（导出开始写的那一刻；没有就用修改时间）。SkyCut 导出从不覆盖，每次都是新文件。
// - 工程最后什么时候改的：工程不记改动的时刻，只有存盘的时刻 —— 改了以后 2 秒自动存（`scheduleAutosave`），所以
//   「没存的改动」就是这两秒里的；存好了，最后一次改动在最后一次存盘之前、差不到这 2 秒。中间差不出先后的（`slack`）不说；
//   没存过盘的工程（没有 `documentURL`）判断不了，也不说。
// - 改行高这类不改画面的也会存盘：会多说一句（宁可叫 AI 多导一次）。
// 纯值的比较在 `verdict`，读文件和工程的时刻在 `note`。合同见 docs/architecture/finished-video-inspection.md。

enum AIInspectionFreshness {
    /// 自动保存在改动后多少秒落盘（`scheduleAutosave` 的 2 秒）再加一点余量。
    static let slack = 3.0

    enum Verdict: Equatable {
        case newer
        /// 工程在文件做出来以后又改过：`changedBy` 是能确定的最晚的那一刻。
        case older(changedBy: Date)
        case unknown
    }

    /// `made`：文件做出来的时刻；`saved`：工程文件最后存盘的时刻（没存过 nil）；`unsaved`：有没存的改动；`now`：现在。
    static func verdict(made: Date, saved: Date?, unsaved: Bool, now: Date) -> Verdict {
        guard let saved else { return .unknown }
        // 没存的改动就在最近这几秒；存好的，最后一次改动不早于存盘前 `slack` 秒。
        let changedAtLeast = unsaved ? now.addingTimeInterval(-slack) : saved.addingTimeInterval(-slack)
        if changedAtLeast > made { return .older(changedBy: changedAtLeast) }
        let changedAtMost = unsaved ? now : saved
        return changedAtMost <= made ? .newer : .unknown
    }

    /// 给 AI 的那一句（只在确定改过时有）。
    @MainActor
    static func note(file: URL, project: VideoEditProject, now: Date = Date()) -> String? {
        let values = try? file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        guard let made = values?.creationDate ?? values?.contentModificationDate else { return nil }
        let saved = project.documentURL.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        guard case .older = verdict(made: made, saved: saved, unsaved: project.hasUnsavedChanges, now: now) else { return nil }
        let clock = DateFormatter()
        clock.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "This file was made at \(clock.string(from: made)), but the project changed after that: it is not the current cut. "
            + "Export again and inspect the new file; findings below describe the old file."
    }
}
