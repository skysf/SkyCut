import Foundation

// MARK: - 声音库的收费单：在建的那几单落盘，SkyCut 重启之后接着跟到底
//
// 管什么（docs/architecture/voice-library.md 第十节第 11 条；案例 docs/bugfixes/2026-11-11-voice-library-job-after-restart.md）：
// 设计声音、建 MiniMax 版这两种一次性费用（SkyStudioVoiceLibraryJob）从起任务那一刻（预留已经记上了本机的账）到有结局，在 UserDefaults
// 里留一条：预留了多少、记在哪一天、Sky Studio 的任务号（受理了才有）、做完时给 AI 的下一步。SkyCut 中途退出，重启之后：
// - **读到 Key 的时候**（启动、回到 SkyCut、每小时，SkyStudioAccount）和**同一件事又要问 / 记账之前**（SkyStudioVoiceOneTimeStep、
//   SkyStudioVoiceFallbackFee；任务自己起手是最后一道）调 `resume`：这把 Key 名下、这次运行里还没人跟、有任务号的那几单接着跟
//   （只 GET、不再交），按原来那一笔结账——做完按实收、没做成退回，**一单只记一次**；同一件事再点头时跟着它（不问、不预留、不交）。
// - **没有任务号的**（交的那一刻断了 / 退出了：服务器收没收不知道）：那一笔照旧算花了（结果不明的留在账上），记录留着；同一件事之后
//   再交、被 Sky Studio 受理时并进来（`accept`：服务器对同一个声音 + 语言开着的建单回的就是原来那一单、只扣一次，两笔只留早先那一笔）。
// - 两天以前的不再跟（早过了那一天的额度，服务器上的那一单也早有结局了）：记录丢掉，账不动。
// 写盘的顺序让出事时只会多算、不会少算或结两次：先存记录再交；先删记录再改账；并进来的先写记录再退那一笔。全部记录是一个键、一次写盘。
// 存的是 Key 的 SHA-256（认是不是同一把 Key），不存 Key。
// 不管什么：跟的那一单（SkyStudioVoiceLibraryJob）、账本和每日额度（SkyStudioSpendStore；账只经 SkyStudioHeldCredits 动）。

@MainActor
enum SkyStudioVoiceLibraryOrders {
    /// 身份类的键名照旧用 SrtFlow 前缀（docs/architecture/product-name.md）。
    static let defaultsKey = "SrtFlow.skystudio.voiceLibraryOrders.v1"
    /// 多久以前预留的不再跟。
    static let maxAge: TimeInterval = 2 * 86_400

    /// 一单：按它的 idempotency_key 记。
    struct Record: Codable, Equatable {
        /// AIJobs.Kind：voice_design / voice_enroll。
        var kind: String
        /// Key 的 SHA-256：只用同一把 Key 接着跟（别的账户的单问不到）。
        var account: String
        var request: SkyStudioJobRequest
        var reservedCredits: Double
        var reservedDay: Date
        /// Sky Studio 受理了（回了任务号）才有。
        var jobID: String?
        var nextStep: String
    }

    /// 此刻盘上的全部记录（每次现读：重启之后的新对象读到的就是这一份）。
    static var records: [String: Record] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
    }

    static func account(_ key: String) -> String { SkyStudioCharacterCache.digest(key) }

    /// 交之前存一条（预留已经记上了）。
    static func save(_ record: Record) {
        var all = records
        all[record.request.idempotencyKey] = record
        write(all)
    }

    /// 这一单有结局了、账要按它改：先删记录，之后才改账。
    static func remove(_ order: String) {
        var all = records
        guard all.removeValue(forKey: order) != nil else { return }
        write(all)
    }

    /// 受理了：记下任务号。同一件事早先那一单（没有任务号，或者就是这个任务号）并进来——它的那一笔归这一单结，回它
    /// （调用方退掉自己那一笔）。一次写盘。
    static func accept(_ order: String, jobID: String, sameOrder: (Record) -> Bool) -> Record? {
        var all = records
        guard all[order] != nil else { return nil }
        let earlier = all.first { $0.key != order && ($0.value.jobID == nil || $0.value.jobID == jobID) && sameOrder($0.value) }
        all[order]?.jobID = jobID
        if let earlier {
            all[earlier.key] = nil
            all[order]?.reservedCredits = earlier.value.reservedCredits
            all[order]?.reservedDay = earlier.value.reservedDay
        }
        write(all)
        return earlier?.value
    }

    /// 服务器上这一单还没有结局、本机也没把它结掉：记录和那一笔都留着，读到 Key / 同一件事再来时接着跟、那时再结。
    /// 没受理：只有交的回答丢了（断网）算——收没收不知道。受理了：除了服务器给了结局（没做成、退了、找不到这一单、回的不像话）都算。
    static func unresolved(_ error: SkyStudioJobError, accepted: Bool) -> Bool {
        guard accepted else {
            if case .request(.network) = error { return true }
            return false
        }
        switch error {
        case .failed, .stopped(.nothingCharged), .stopped(.characterContinuing), .notSubmitted, .badAnswer:
            return false
        case .request(.server(let server)):
            return server.code != "not_found"
        case .request(.network), .request(.badAnswer), .timedOut, .stopped(.alreadyStarted), .stopped(.unknown):
            return true
        }
    }

    /// 接着跟这把 Key 名下、这次运行里还没人跟、有任务号的那几单；太久以前的丢掉（账不动）。回接着跟起来的任务。
    @discardableResult
    static func resume(key: String, api: SkyStudioAPI, now: Date = Date()) -> [AIJobs.Job] {
        var all = records
        let stale = all.filter { now.timeIntervalSince($0.value.reservedDay) > maxAge }.map(\.key)
        if !stale.isEmpty {
            stale.forEach { all[$0] = nil }
            write(all)
        }
        let account = account(key)
        var followed: [AIJobs.Job] = []
        for record in all.values where record.account == account {
            guard let jobID = record.jobID, let kind = AIJobs.Kind(rawValue: record.kind),
                  let identity = SkyStudioVoiceLibraryJob.identity(kind, request: record.request, key: key),
                  SkyStudioVoiceLibraryJob.running(identity) == nil else { continue }
            followed.append(SkyStudioVoiceLibraryJob(resuming: record, kind: kind, identity: identity, jobID: jobID, key: key, api: api).follow())
        }
        return followed
    }

    private static func write(_ value: [String: Record]) {
        guard !value.isEmpty else { return UserDefaults.standard.removeObject(forKey: defaultsKey) }
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }
}
