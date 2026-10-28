import Foundation

// MARK: - 一单 Sky Studio 的活交上了没有、任务号是多少
//
// 管什么：交上之后积分就扣了（没做成服务器退），所以任务要分清「没交上就停了 / 出错了」（退回本机的账）和「交上之后停不下来 / 断了」
// （不退，成品照样进作品库）；任务号报给 AI（get_job 的 skystudio_job_id），对账、找客服时说得出是哪一单。
// 等的回调在别的线程上，带锁。upscale（UpscaleJob）和生成（SkyStudioGenerationRun）共用。
// 不管什么：交、等、停（SkyStudioJobRun）；账（SkyStudioHeldCredits）。

final class SkyStudioSubmission: @unchecked Sendable {
    private let lock = NSLock()
    private var id: String?
    /// 交上了没有。
    var value: Bool { lock.lock(); defer { lock.unlock() }; return id != nil }
    /// Sky Studio 的任务号，交上了才有。
    var jobID: String? { lock.lock(); defer { lock.unlock() }; return id }
    func mark(_ jobID: String) { lock.lock(); id = jobID; lock.unlock() }
}
