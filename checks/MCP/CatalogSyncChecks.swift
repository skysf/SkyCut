import Foundation
import SrtFlowMCPKit

// App 升级之后，正在跑的旧小程序换上新的工具清单（MCPCatalogSync，docs/bugfixes/2026-10-14-stale-helper-tool-list.md）：
// 2026-10-06 盲测里会话是 App 升级前开的，小程序的清单停在旧版，新加的 snap / overshoot / spring 缓动一条都用不上。
// 1. 纯值：指纹对得上不换、报了别的才换；换上之后按提供方列、认新工具名、通知只给一次。
// 2. 真起小程序接一个「更新过的」假 App（回答带着另一个指纹、能给出多一个工具的清单）：第一次调用之后小程序换上它 ——
//    结果里说一句、老一代客户端收到 list_changed（只一次）、tools/list 里有新工具、调用新工具照样转给 App；
//    指纹一样的假 App：一样都不换。编法见 scripts/check-mcp.sh。

func runCatalogSyncChecks() {
    runCatalogOverrideChecks()
    runHelperCatalogChecks()
}

/// App 那份清单：编进来的全部工具，再多一个新的；指纹是另一个。
private func newerCatalog() -> JSONValue {
    var catalog = MCPCatalogSync.catalogResult().objectValue ?? [:]
    var tools = catalog["tools"]?.arrayValue ?? []
    tools.append(["name": "brand_new_tool", "description": "A tool added after this helper was built.",
                  "inputSchema": ["type": "object", "properties": [:]]])
    catalog["tools"] = .array(tools)
    catalog["fingerprint"] = "newer-app"
    return .object(catalog)
}

private func runCatalogOverrideChecks() {
    let override = MCPCatalogOverride()
    check(!override.needsRefresh(appFingerprint: nil), "an old app that sends no fingerprint changes nothing")
    check(!override.needsRefresh(appFingerprint: MCPCatalogSync.fingerprint), "the same catalog as the helper's: nothing to refresh")
    check(override.needsRefresh(appFingerprint: "newer-app"), "a different catalog: refresh")
    check(override.toolsJSON(providers: []) == nil, "before refreshing, the built-in list is used")
    check(!override.adopt(["fingerprint": "x"]), "a catalog without tools is not adopted")
    check(override.adopt(newerCatalog()), "the app's catalog is adopted")
    check(!override.needsRefresh(appFingerprint: "newer-app"), "the adopted catalog is not fetched again")
    check(override.knows("brand_new_tool") && !override.knows("no_such_tool"), "the new tool's name is known, made-up ones are not")
    let withoutKey = override.toolsJSON(providers: [])?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    let withSkyStudio = override.toolsJSON(providers: [.skystudio])?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    check(withoutKey.contains("brand_new_tool") && !withoutKey.contains("generate_media") && withSkyStudio.contains("generate_media"),
          "the adopted list still lists provider tools only when that provider is set up")
    check(override.takeRefreshNotice() && !override.takeRefreshNotice(), "the refresh is announced once")
}

/// 假 App：回答带着 `fingerprint` 这个指纹；要清单时给 `newerCatalog()`。记下收到的工具名和要了几次清单。
private final class CatalogFakeApp: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var calls: [String] = []
    private var catalogRequests = 0

    init(name: String, fingerprint: String) throws {
        path = NSTemporaryDirectory() + "srtflow-mcp-\(name)-\(getpid()).sock"
        let fd = try MCPUnixSocket.listen(path: path)
        Thread { [weak self] in
            while let client = MCPUnixSocket.accept(fd) {
                defer { close(client) }
                guard let self, let line = try? MCPUnixSocket.readLine(client),
                      let request = try? JSONDecoder().decode(MCPBridge.Request.self, from: line) else { continue }
                let response: MCPBridge.Response
                self.lock.lock()
                if request.tool == MCPBridge.catalogTool {
                    self.catalogRequests += 1
                    response = MCPBridge.Response(id: request.id, result: newerCatalog(), catalog: fingerprint)
                } else {
                    self.calls.append(request.tool)
                    response = MCPBridge.Response(id: request.id, result: MCPBridge.textResult("ok \(request.tool)"), catalog: fingerprint)
                }
                self.lock.unlock()
                if let data = try? JSONEncoder().encode(response) { try? MCPUnixSocket.writeLine(client, data) }
            }
        }.start()
    }

    var toolCalls: [String] { lock.lock(); defer { lock.unlock() }; return calls }
    var catalogs: Int { lock.lock(); defer { lock.unlock() }; return catalogRequests }
}

private func runHelperCatalogChecks() {
    let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"check"}}}"#
    // 一批按顺序做完：调用回来之后再要清单。
    let batch = "[" + [
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_status","arguments":{}}}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#,
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"brand_new_tool","arguments":{}}}"#,
        #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_status","arguments":{}}}"#
    ].joined(separator: ",") + "]"
    func flat(_ messages: [JSONValue]) -> [JSONValue] { messages.flatMap { $0.arrayValue ?? [$0] } }
    func text(_ messages: [JSONValue], _ id: Int) -> String {
        reply(flat(messages), id: .number(Double(id)))?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    }
    func names(_ messages: [JSONValue], _ id: Int) -> [String] {
        reply(flat(messages), id: .number(Double(id)))?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    }
    func changes(_ messages: [JSONValue]) -> Int {
        flat(messages).filter { $0["method"]?.stringValue == "notifications/tools/list_changed" }.count
    }

    guard let newer = try? CatalogFakeApp(name: "newer", fingerprint: "newer-app") else {
        check(false, "the updated fake app could not listen")
        return
    }
    let (messages, _) = talkToHelper([initialize, batch], socket: newer.path)
    check(text(messages, 2).contains("SkyCut was updated after this AI session started"),
          "the first call after the app was updated says the tool list was refreshed: \(text(messages, 2).prefix(160))")
    checkEqual(changes(messages), 1, "a legacy client is told once that the tool list changed")
    check(names(messages, 3).contains("brand_new_tool"), "tools/list now lists the app's new tool")
    check(text(messages, 4).hasPrefix("ok brand_new_tool"), "calling the new tool goes through to the app: \(text(messages, 4).prefix(120))")
    checkEqual(newer.toolCalls, ["get_status", "brand_new_tool", "get_status"], "the app received every call, the new tool included")
    check(!text(messages, 5).contains("SkyCut was updated"), "only the call that refreshed says so")
    checkEqual(newer.catalogs, 1, "the catalog is fetched once")

    guard let same = try? CatalogFakeApp(name: "same", fingerprint: MCPCatalogSync.fingerprint) else {
        check(false, "the same-version fake app could not listen")
        return
    }
    let (plain, _) = talkToHelper([initialize, batch], socket: same.path)
    checkEqual(same.catalogs, 0, "an app with the same catalog is not asked for it")
    checkEqual(changes(plain), 0, "nothing changed, so no list_changed")
    check(!names(plain, 3).contains("brand_new_tool"), "the built-in list is used")
    check(text(plain, 4).isEmpty || !text(plain, 4).hasPrefix("ok"), "an unknown tool is still refused when nothing was refreshed")
}
