import Foundation
import SrtFlowCore

// 只验录屏账本的磁盘合同与构建隔离，不启动捕获、不读用户的 Application Support。

// MARK: - manifest 持久化栅栏

func checkManifestStore(manifest: ScreenRecordingManifest) {
    checkManifestIsolation()
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("srtflow-manifeststore-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ScreenRecordingManifestStore(directory: dir)

    do {
        checkEqual(try store.load(), nil, "空目录 load 返回 nil")
        try store.persist(manifest)
        // **持久化栅栏的意义**：persist 成功返回后，manifest 已通过原子 rename
        // 进入文件系统命名空间 —— 这里绕开 store、直接从磁盘路径读原始字节验证，
        // 证明它不是停留在某个进程内缓存里（UserDefaults 的问题正在于此：
        // 内存立即生效、磁盘异步落盘）。进程级崩溃（含 kill -9）不能撤销
        // 已完成的 rename，所以栅栏对 App 崩溃威胁模型成立。
        let raw = try Data(contentsOf: store.fileURL)
        let decoded = try JSONDecoder().decode(ScreenRecordingManifest.self, from: raw)
        checkEqual(decoded, manifest, "persist 返回后磁盘上立即是完整 manifest")

        // 推进 stage 再 persist：读回的是最新的
        var advanced = manifest
        advanced.stage = .allCommitted
        try store.persist(advanced)
        checkEqual(try store.load()?.stage, .allCommitted, "覆盖写后读回最新阶段")

        try store.clear()
        checkEqual(try store.load(), nil, "clear 后 load 返回 nil")
        try store.clear()   // 幂等
        check(true, "clear 幂等")

        // 损坏文件要抛错（调用方如实报告，不许退回 glob）
        try Data("not json".utf8).write(to: store.fileURL)
        var threw = false
        do { _ = try store.load() } catch { threw = true }
        check(threw, "损坏的 manifest 文件 load 要抛错，不能静默当没有")

        // **「有没有账」必须用文件存在性判定，不能用「能不能解码」。**
        //
        // 这是「下一次录制会不会覆盖上一份账」的唯一防线：用
        // `try? load() != nil` 的话，一份损坏的 JSON 会被读成「没有账本」，
        // 紧接着的 persist() 就把它盖掉了，上一段录制的唯一索引随之消失
        // （复审三 P1-2）。解码失败同样是 unsettled，**不允许 fail-open**。
        check(store.fileExists, "损坏的 manifest 仍然算「有账」")
        check((try? store.load()) == nil, "同一份文件确实解不出来（否则上一条无意义）")

        try store.clear()
        check(!store.fileExists, "清掉之后才算没有账")
    } catch {
        check(false, "store 自检异常：\(error)")
    }
}

private func checkManifestIsolation() {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("srtflow-manifest-isolation-\(UUID().uuidString)")
    defer { try? manager.removeItem(at: root) }
    let identities = [
        "com.srtflow.SrtFlow", "com.srtflow.SrtFlow.beta",
        "com.srtflow.SrtFlow.dev", "com.srtflow.SrtFlow.smoke.123"
    ]

    do {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        // 模拟仍在写盘的旧版本：账本及两条临时媒体都不能被新版本当成崩溃残留。
        let legacy = ScreenRecordingManifestStore(directory: root.appendingPathComponent("SrtFlow"))
        let oldRecording = try recordingFixture(in: root, name: "legacy")
        try legacy.persist(oldRecording)
        let legacyBytes = try Data(contentsOf: legacy.fileURL)

        var recordings: [ScreenRecordingManifest] = []
        for identity in identities {
            let store = ScreenRecordingManifestStore(applicationSupport: root, bundleIdentifier: identity)
            check(!store.fileExists, "\(identity)：旧共用账本不阻塞新录制")
            checkEqual(try store.load(), nil, "\(identity)：启动不读取旧账本或别的构建的账本")
            let recording = try recordingFixture(in: root, name: identity)
            try store.persist(recording)
            recordings.append(recording)
            // 路径期望独立给出，再从磁盘解码，不拿被测 store 的 fileURL 自证。
            let expected = root.appendingPathComponent(identity).appendingPathComponent("active-recording-manifest.json")
            checkEqual(store.fileURL, expected, "\(identity)：账本在完整 bundle id 下，与 mcp.sock 同目录")
            checkEqual(try JSONDecoder().decode(ScreenRecordingManifest.self, from: Data(contentsOf: expected)), recording,
                       "\(identity)：写盘不覆盖别的身份")
        }

        for (index, identity) in identities.enumerated() {
            // 同一身份重启仍能找回自己的账；别的身份清账之后也能找回。
            let restarted = ScreenRecordingManifestStore(applicationSupport: root, bundleIdentifier: identity)
            checkEqual(try restarted.load(), recordings[index], "\(identity)：恢复只看到自己仍在写的会话")
            try restarted.clear()
            checkEqual(try restarted.load(), nil, "\(identity)：只清掉自己的账")
            for other in identities.indices where other > index {
                let untouched = ScreenRecordingManifestStore(applicationSupport: root, bundleIdentifier: identities[other])
                checkEqual(try untouched.load(), recordings[other], "\(identity) 清账不动 \(identities[other])")
            }
        }

        checkEqual(try Data(contentsOf: legacy.fileURL), legacyBytes, "旧共用账本原字节保留，不迁移、不删除")
        for recording in [oldRecording] + recordings {
            for path in recording.temporaryPaths {
                checkEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("still recording".utf8),
                           "启动 / 写盘 / 清账不碰别的会话仍在写的临时媒体")
            }
        }
    } catch {
        check(false, "构建身份隔离自检异常：\(error)")
    }
}

private func recordingFixture(in root: URL, name: String) throws -> ScreenRecordingManifest {
    let main = root.appendingPathComponent("\(name).partial.mov")
    let microphone = root.appendingPathComponent("\(name).partial.m4a")
    try Data("still recording".utf8).write(to: main)
    try Data("still recording".utf8).write(to: microphone)
    return ScreenRecordingManifest(
        sessionID: UUID(), startedAt: Date(), mainTemporaryPath: main.path,
        mainFinalPath: root.appendingPathComponent("\(name).mov").path,
        micTemporaryPath: microphone.path, micFinalPath: root.appendingPathComponent("\(name).m4a").path
    )
}
