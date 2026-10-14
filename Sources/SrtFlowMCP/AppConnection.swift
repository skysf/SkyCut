import Foundation
import SrtFlowMCPKit

// MARK: - 找到 SrtFlow、把一次工具调用交给它
//
// 管什么：小程序在哪个 App 里（从自己的路径往上找 .app）、那个 App 的 socket 在哪、
// 没开就用 `open -g` 把它拉起来（不抢前台）、等它开始听、把请求交过去、把回答拿回来。
// 不管什么：MCP 协议（MCPServerCore）、工具怎么做（App）。
//
// App 卡住时怎么等、怎么说在 CallWaiter（分段等、探一下主线程、放弃时让 App 也放弃）。
//
// 测试用的四个环境变量（不设就完全不生效）：
// - SRTFLOW_MCP_SOCKET：直接连这个 socket（自检里的假 App）；
// - SRTFLOW_MCP_NO_LAUNCH：连不上就报错，不去拉起 App；
// - SRTFLOW_MCP_APP：App 的路径（小程序不在 .app 里、从 .build 直接跑的时候）；
// - SRTFLOW_MCP_PROVIDERS：「配了哪些生成提供方」那个小文件的路径（自检里造一个临时的）。

struct AppConnection {
    let appURL: URL?
    let bundleIdentifier: String
    let socketPath: String
    /// 配好了哪些生成提供方（App 在 fal 的 Key 添加 / 删除时写的小文件，MCPProviderMarker）。
    let providersURL: URL
    let appVersion: String
    let mayLaunch: Bool
    /// 这个会话在剪哪一个工程：每次调用带上，App 发现开着的不是它就不做（几个 AI 会话共用一个 App，`MCPSessionProject`）。
    let sessionProject = MCPSessionProject()
    /// 等回答、探 App 还活着没有（App 卡死时别让 AI 干等两分钟、只拿到一句看不懂的错）。
    let waiter: CallWaiter
    /// App 升级过、这个会话里跑的还是旧的小程序时，换上的 App 那份工具清单（`MCPCatalogSync`）。
    let catalog = MCPCatalogOverride()

    /// 从小程序自己的位置找到它所在的 App：`X.app/Contents/Helpers/srtflow-mcp`。
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppConnection {
        let appURL = environment["SRTFLOW_MCP_APP"].map { URL(fileURLWithPath: $0) } ?? enclosingApp()
        let bundle = appURL.flatMap { Bundle(url: $0) }
        let bundleID = bundle?.bundleIdentifier ?? "com.srtflow.SrtFlow"
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let socketPath = environment["SRTFLOW_MCP_SOCKET"] ?? MCPBridge.socketPath(bundleIdentifier: bundleID)
        return AppConnection(
            appURL: appURL,
            bundleIdentifier: bundleID,
            socketPath: socketPath,
            providersURL: environment["SRTFLOW_MCP_PROVIDERS"].map { URL(fileURLWithPath: $0) }
                ?? MCPProviderMarker.url(bundleIdentifier: bundleID),
            appVersion: version,
            mayLaunch: environment["SRTFLOW_MCP_NO_LAUNCH"] == nil,
            waiter: CallWaiter(socketPath: socketPath, environment: environment)
        )
    }

    private static func enclosingApp() -> URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        var url = executable.deletingLastPathComponent()
        // 最多往上找四层：Helpers → Contents → X.app。
        for _ in 0..<4 {
            if url.pathExtension == "app" { return url }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: 一次调用

    func call(tool: String, arguments: JSONValue, client: String?) -> JSONValue {
        // 上一个调用等到 App 卡死了：还卡着就别发、别再干等，当场说。
        if let refusal = waiter.refusalIfStillFrozen() { return MCPBridge.textResult(refusal, isError: true) }
        let request = sessionProject.stamp(MCPBridge.Request(tool: tool, arguments: arguments, client: client))
        do {
            let payload = try JSONEncoder().encode(request)
            let (fd, launched) = try connectOrLaunch()
            defer { close(fd) }
            MCPUnixSocket.setTimeouts(fd, seconds: 120)
            try MCPUnixSocket.writeLine(fd, payload)
            let line: Data
            switch try waiter.waitForAnswer(fd, callID: request.id) {
            case .answer(let data):
                line = data
            case .gaveUp(let message):
                return MCPBridge.textResult(message, isError: true)
            case .closed:
                return MCPBridge.textResult(
                    "SrtFlow closed the connection without answering (it may have quit). Try again.", isError: true
                )
            }
            let response = try JSONDecoder().decode(MCPBridge.Response.self, from: line)
            sessionProject.note(tool: tool, response: response)
            var result = response.result
            // App 的清单和编进这个小程序的不一样（App 升级了、会话还是升级前开的）：换上 App 那份，这一次的结果里说一句。
            if catalog.needsRefresh(appFingerprint: response.catalog), let fresh = fetchCatalog(), catalog.adopt(fresh) {
                result = MCPBridge.addingNote(MCPCatalogSync.refreshedNote, to: result)
            }
            // 刚把 App 拉起来：AI 之前打开的工程、文件夹都不在了，先说一句，不然它只看到「文件不存在」「没有这个 id」
            //（2026-10-02 南极工程：用户关了窗口 = App 退出，下一次调用拉起来的是空的 Untitled）。
            return launched ? MCPBridge.addingNote(MCPBridge.relaunchNote, to: result) : result
        } catch let failure as ConnectionFailure {
            return MCPBridge.textResult(failure.message, isError: true)
        } catch {
            return MCPBridge.textResult("Could not talk to SrtFlow: \(error)", isError: true)
        }
    }

    /// 向 App 要它的工具清单（`MCPBridge.catalogTool`，App 在收发线程上当场回）。要不到就是 nil，照旧用编进来的。
    private func fetchCatalog() -> JSONValue? {
        guard let fd = try? MCPUnixSocket.connect(path: socketPath) else { return nil }
        defer { close(fd) }
        MCPUnixSocket.setTimeouts(fd, seconds: 5)
        let request = MCPBridge.Request(tool: MCPBridge.catalogTool, arguments: [:], client: nil)
        guard let payload = try? JSONEncoder().encode(request), (try? MCPUnixSocket.writeLine(fd, payload)) != nil,
              let line = try? MCPUnixSocket.readLine(fd),
              let response = try? JSONDecoder().decode(MCPBridge.Response.self, from: line) else { return nil }
        return response.result
    }

    private struct ConnectionFailure: Error {
        let message: String
    }

    /// 连上正在跑的 SrtFlow；没开就拉起来再连。`launched`：这次是不是拉起来的。
    private func connectOrLaunch() throws -> (fd: Int32, launched: Bool) {
        if let fd = try? MCPUnixSocket.connect(path: socketPath) { return (fd, false) }
        guard mayLaunch else {
            throw ConnectionFailure(message: "SrtFlow is not running. Ask the user to open SrtFlow.")
        }
        try launchApp()
        // 冷启动要把 SwiftUI 窗口和引擎都拉起来，给足时间；一般两三秒就开始听了。
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            if let fd = try? MCPUnixSocket.connect(path: socketPath) { return (fd, true) }
        }
        throw ConnectionFailure(message: """
            SrtFlow did not start answering within 45 seconds. If an older SrtFlow without AI support is open, \
            ask the user to quit it; otherwise ask them to open SrtFlow and try again.
            """)
    }

    /// `open -g`：在后台启动，不把用户正在打字的对话窗口挤下去。窗口由 App 自己在
    /// 开始剪的时候摆到前面来（不抢键盘，`AIEditorPresenter`）。
    private func launchApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let appURL {
            process.arguments = ["-g", "-a", appURL.path]
        } else {
            process.arguments = ["-g", "-b", bundleIdentifier]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ConnectionFailure(message: "Could not start SrtFlow: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ConnectionFailure(message: "Could not start SrtFlow (open exited with \(process.terminationStatus)).")
        }
    }
}
