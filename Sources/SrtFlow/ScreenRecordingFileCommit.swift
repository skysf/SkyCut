import Foundation
import SrtFlowCore

// MARK: - 录完把临时文件提交到最终位置（journal 协议）
//
// 管什么：主文件、麦克风 sidecar 从隐藏的 `.partial` 临时文件变成用户看得见的文件 —— 每次 rename 之前先把意向
// （阶段 + 最终路径）持久化，之后再推进到「已提交」（docs/architecture/screen-recording-lifecycle.md「提交 journal」）。
// 不管什么：提交之前的验证（协调者先 probe 临时文件）、提交之后的回读和入轨（协调者）、崩溃恢复那一份提交（`commitRecovered`，
// which renames through the same `commitNew`）。
// 2026-10-03 从 ScreenRecordingCoordinator.swift 搬出来（那个文件超过 600 行，只许降），同时加了 AI 起的录制「从不覆盖」。
// 2026-11-19 (docs/bugfixes/2026-11-19-free-save-name-treated-as-replace-consent.md): the replacing branch is chosen by the
// person's confirmation only, never because a file is at the name; every other commit renames without replacing.

@available(macOS 15.0, *)
struct ScreenRecordingFileCommit {
    /// 提交完的样子。
    struct Committed {
        var manifest: ScreenRecordingManifest
        /// 主文件**实际**落在哪：手动的就是用户选的位置；AI 起的撞上已有文件时避让到「名字 2」。
        var mainURL: URL
        /// 麦克风 sidecar 实际落在哪（没录、或没通过校验时 nil）。
        var microphoneURL: URL?
    }

    let store: ScreenRecordingManifestStore

    /// The journal a session starts with: where its temporary and final files will be, persisted before any file is made.
    /// (Moved here from ScreenRecordingCoordinator.swift on 2026-11-19, which may only shrink.)
    static func startingManifest(for request: ScreenRecordingRequest, sessionID: UUID) -> ScreenRecordingManifest {
        ScreenRecordingManifest(
            sessionID: sessionID,
            startedAt: Date(),
            mainTemporaryPath: request.temporaryURL(for: .main).path,
            mainFinalPath: request.outputURL.path,
            micTemporaryPath: request.microphone.isEnabled
                ? request.temporaryURL(for: .microphone).path : nil,
            micFinalPath: request.microphone.isEnabled ? request.microphoneURL.path : nil
        )
    }
    let manager = FileManager.default

    /// journal 提交协议：persist 意向 → rename → persist 已提交。
    ///
    /// - Parameter commitMicrophone: sidecar 是否**已通过校验**。false 时不提交它 —— 零采样、probe 失败、writer 已知故障却仍残留的
    ///   `.m4a` 一律不能变成用户可见的损坏文件（复审四 P1-2）。
    /// - Parameter replacesExistingOutput: 主文件撞上已有文件时能不能替换。手动的在保存面板里点过「替换」；AI 起的从不覆盖：
    ///   避让后的目标**先写进 manifest、持久化，然后才动文件**（同麦克风那一路，复审二 P1-3）。
    /// - Parameter persisted: 每次持久化成功之后交出当时的 manifest（协调者据此跟着更新自己手里那份）。
    func commit(
        request: ScreenRecordingRequest, manifest start: ScreenRecordingManifest,
        commitMicrophone: Bool, replacesExistingOutput: Bool,
        persisted: (ScreenRecordingManifest) -> Void
    ) throws -> Committed {
        var manifest = start
        func persist(_ stage: ScreenRecordingManifest.CommitStage) throws {
            manifest.stage = stage
            try store.persist(manifest)          // ← 栅栏：成功返回才允许 rename
            persisted(manifest)
        }

        // 临时文件必须在。走到这里它已经被 probe 验证过了；不在就是异常，
        // **不能带着「已提交」的 stage 往下走** —— 那会让最终路径上原有的
        // 旧文件被当成本次录制导入（复审 P1-2）。
        let mainTemp = request.temporaryURL(for: .main)
        guard manager.fileExists(atPath: mainTemp.path) else {
            throw ScreenRecordingError.writerFailed(
                message: L10n("The recording file disappeared before it could be saved.")
            )
        }

        let mainURL: URL
        if replacesExistingOutput {
            // 只有手动的会走到这里：the person confirmed replacing this very file in macOS's own save window, which asks
            // only about a file that is there when it answers (SystemFileWindows.openSave).
            mainURL = request.outputURL
            try persist(.committingMain)
            if manager.fileExists(atPath: mainURL.path) {
                _ = try manager.replaceItemAt(mainURL, withItemAt: mainTemp)
            } else {
                try manager.moveItem(at: mainTemp, to: mainURL)
            }
        } else {
            // Nobody agreed to replace anything (a free name, a typed answer, the AI's session): never replaced, not even a
            // file that appears after the name was picked.
            mainURL = try Self.commitNew(mainTemp, like: request.outputURL) { target in
                manifest = manifest.retargetingMain(to: target.path)
                try persist(.committingMain)
            }
        }
        try persist(.mainCommitted)

        guard request.microphone.isEnabled, commitMicrophone else {
            // 不提交 sidecar：停在 mainCommitted 是对现场的准确描述。
            // 无效的临时文件精确删掉，别留成孤儿。
            if request.microphone.isEnabled {
                try? manager.removeItem(at: request.temporaryURL(for: .microphone))
            }
            return Committed(manifest: manifest, mainURL: mainURL, microphoneURL: nil)
        }
        let micTemp = request.temporaryURL(for: .microphone)
        guard manager.fileExists(atPath: micTemp.path) else {
            // 开了麦克风却没有 sidecar 文件：**不能推进到 allCommitted**。
            // 推进了就等于宣称两个 rename 都做完了，恢复时会照着 micFinalPath
            // 去认一个根本不存在（或不相干）的文件（复审二 P1-8）。
            // 停在 mainCommitted 是准确的描述：主文件提交了，sidecar 没有。
            return Committed(manifest: manifest, mainURL: mainURL, microphoneURL: nil)
        }

        // **先冻结最终目标、写进 manifest、持久化，然后才 rename。**
        // 顺序反了就是 journal 身份被破坏（复审二 P1-3）。Never replaced: nobody confirmed anything for the sidecar.
        let target = try Self.commitNew(micTemp, like: request.microphoneURL) { target in
            manifest = manifest.retargetingMicrophone(to: target.path)
            try persist(.committingMicrophone)
        }
        try persist(.allCommitted)
        return Committed(manifest: manifest, mainURL: mainURL, microphoneURL: target)
    }

    /// Renames `temp` to the first free name of `like`'s series ("Name", "Name 2"…) without replacing a file: each name goes
    /// into the journal first (`persistTarget`), and a name taken after that moves on to the next one — one rename that
    /// fails when the name is taken (ExclusiveInstall.renameIfFree). A drive without that rename (exFAT) gets a look, then
    /// `moveItem`, which refuses a taken name too: a file appearing in the instant between them could still be replaced. A
    /// copy can't stand in for the rename: after a crash mid-copy the journal could not tell the half-written file at the
    /// name from a finished one. Returns where the file went. Also the crash recovery's commit (`commitRecovered`).
    static func commitNew(_ temp: URL, like target: URL, persistTarget: (URL) throws -> Void) throws -> URL {
        for _ in 0..<1000 {
            let candidate = ScreenRecordingFileNaming.availableURL(like: target, isTaken: NewFileClaim.isTaken)
            try persistTarget(candidate)
            if let renamed = try ExclusiveInstall.renameIfFree(temp, to: candidate) {
                if renamed { return candidate }
            } else if !NewFileClaim.isTaken(candidate) {
                try FileManager.default.moveItem(at: temp, to: candidate)
                return candidate
            }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
    }
}
