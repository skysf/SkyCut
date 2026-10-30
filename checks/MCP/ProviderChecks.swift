import Foundation
import SrtFlowMCPKit

// 生成类工具的「提供方」只说明去哪消费，不再决定工具能不能被发现（2026-10-30）。
// - 目录这一层：generate_media、upscale_clip 都属于 Sky Studio（2026-10-28 起，收费方案第 6 刀；云端配音也走 Sky Studio、不列工具）、说明和参数对、
//   只有它们上外面的网（openWorld）；词表和 App 的类型对账在 checks/SkyStudio/GenerationChecks.swift；
// - 那个小文件（MCPProviderMarker）：路径和 socket 同目录、读得宽（不在 / 坏了 / 有不认识的名字都当没有）、只写提供方的名字、不动没变的；
// - 协议这一层：真起小程序 —— 没配 / 配了都列全、总说明始终指向生成工具；会话中添加 / 删除 Key 不改变已经拿到的工具。
//   授权和积分仍在 App 调用时核对，不靠客户端是否重新请求 tools/list。

func runProviderChecks() {
    checkCatalog()
    checkInstructions()
    checkServerCore()
    checkMarkerFile()
    checkHelperListing()
    checkLiveChange()
}

// MARK: 目录

private func checkCatalog() {
    // 花钱的两个工具：generate_media（第 6 块）、upscale_clip（2026-10-02）；2026-10-28 起都走 Sky Studio、花积分（收费方案第 6 刀）。
    let paidTools: Set<MCPToolName> = [.generateMedia, .upscaleClip]
    checkEqual(MCPToolName.generateMedia.provider, .skystudio, "generate_media belongs to Sky Studio")
    checkEqual(MCPToolName.upscaleClip.provider, .skystudio, "upscale_clip belongs to Sky Studio")
    check(MCPToolName.allCases.filter { !paidTools.contains($0) }.allSatisfy { $0.provider == nil }, "every other tool is always listed")
    checkEqual(MCPToolName.listed(providers: []), MCPToolName.allCases, "nothing configured: generation tools are discoverable before the Key is added")
    checkEqual(MCPToolName.listed(providers: [.skystudio]), MCPToolName.allCases, "Sky Studio configured: every tool, in the catalog order")
    checkEqual(MCPToolName.listJSON.arrayValue?.count, MCPToolName.allCases.count, "the full catalog lists every tool")
    check(MCPToolName.listJSON(providers: []) == MCPToolName.listJSON(providers: [.skystudio]), "Key state never changes the catalog")

    let definition = MCPToolName.generateMedia.definition
    check(!definition.readOnly && !definition.destructive, "generate_media writes a new file but deletes nothing")
    check(definition.openWorld, "generate_media reaches out to Sky Studio")
    check(MCPToolName.getStatus.definition.readOnly && MCPToolName.getStatus.definition.openWorld, "model discovery is read-only and declares the Sky Studio query")
    check(MCPToolName.allCases.filter { !paidTools.contains($0) && $0 != .getStatus }.allSatisfy { !$0.definition.openWorld }, "every other tool stays on this Mac")
    let json = definition.json
    checkEqual(json["annotations"]?["openWorldHint"]?.boolValue, true, "openWorldHint is written from the definition")
    checkEqual(MCPToolName.setShape.definition.json["annotations"]?["openWorldHint"]?.boolValue, false, "the others say false")

    let schema = definition.inputSchema
    checkEqual(schema["required"]?.arrayValue?.compactMap(\.stringValue), ["kind", "prompt"], "kind and prompt are required")
    let properties = schema["properties"]?.objectValue ?? [:]
    // confirm_token：超了每日额度 / 价格不明时回的确认码（2026-10-17 起不在提示条上问，AI 多开方案板 9）。
    checkEqual(Set(properties.keys), ["kind", "prompt", "model", "image_context", "quality", "input_mode", "image", "last_image",
        "reference_images", "reference_videos", "reference_audio", "auto_fallback", "duration", "resolution", "aspect_ratio", "generate_audio",
        "instrumental", "lyrics", "name", "confirm_token"], "the parameters")
    checkEqual(properties["kind"]?["enum"]?.arrayValue?.compactMap(\.stringValue), MCPVocabulary.generationKinds, "kind lists the generation kinds")
    check(properties["resolution"]?["enum"] == nil && properties["aspect_ratio"]?["enum"] == nil, "model-specific sizes and shapes are not restricted by legacy enums")
    check(MCPToolName.getStatus.definition.inputSchema["properties"]?["models"] != nil, "AI can discover model limits without submitting generation")
    for field in ["reference_images", "reference_videos", "reference_audio"] { checkEqual(properties[field]?["type"]?.stringValue, "array", "\(field) preserves an ordered list") }

    let text = definition.description
    for word in ["Sky Studio", "get_job", "needs_confirmation", "confirm_token", "credits", "daily credit limit", "add_clips", "MiniMax H3", "image_to_video", "library"] {
        check(text.contains(word), "the description mentions \(word)")
    }
    check(!text.contains("fal.ai") && !text.contains("cost_usd"), "the description no longer talks about fal.ai or dollars")
    // 旁白和字幕走别的工具：说明里要指开
    check(text.contains("generate_subtitles") && text.contains("add_voiceover"), "the description points narration and subtitles at their own tools")
}

// MARK: 总说明

private func checkInstructions() {
    checkEqual(MCPInstructions.text(providers: []), MCPInstructions.text, "without a provider the instructions are the plain ones")
    check(!MCPInstructions.text.contains("fal.ai") && MCPInstructions.text.contains("generate_media") && MCPInstructions.text.contains("upscale_clip"),
          "the initial instructions always explain the paid tools")
    let withSkyStudio = MCPInstructions.text(providers: [.skystudio])
    checkEqual(withSkyStudio, MCPInstructions.text, "adding a Key does not require reloading server instructions")
    // 目录里那一行只指路：花钱怎么问、每日上限写在工具自己的说明里（上面查过 daily credit limit、credits）。
    check(withSkyStudio.contains("generate_media") && withSkyStudio.contains("upscale_clip") && withSkyStudio.contains("Sky Studio credits")
          && withSkyStudio.contains("Paid"), "a Sky Studio key lists both paid tools, paid with Sky Studio credits")
}

// MARK: 协议核心（进程内）

private func checkServerCore() {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        private var value: Set<MCPProvider> = []
        var providers: Set<MCPProvider> {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }
    let box = Box()
    let core = MCPServerCore(serverVersion: "test", providers: { box.providers })
    func names(_ outcome: MCPServerCore.Outcome) -> [String] {
        guard case .reply(let reply) = outcome else { return [] }
        return reply["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    }
    let list: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
    let initialNames = names(core.handle(list))
    check(initialNames.contains("generate_media") && initialNames.contains("upscale_clip"), "in-process: a client that caches its first list already knows both paid tools")
    box.providers = [.skystudio]
    check(names(core.handle(list)).contains("generate_media"), "in-process: the provider closure is asked on every tools/list")
    box.providers = []
    checkEqual(names(core.handle(list)), initialNames, "in-process: removing the Key keeps the tool list stable")

    check(!core.hasLegacySession, "no handshake yet")
    let initialize = core.handle(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "x"]]])
    if case .reply(let reply) = initialize {
        checkEqual(reply["result"]?["capabilities"]?["tools"]?["listChanged"]?.boolValue, true, "the handshake says the list can change")
    } else {
        check(false, "initialize was not answered")
    }
    check(core.hasLegacySession, "after the handshake the client is a legacy session (it gets list_changed)")
    checkEqual(MCPServerCore.toolListChangedNotification["method"]?.stringValue, "notifications/tools/list_changed", "the notification's method")
    check(MCPServerCore.toolListChangedNotification["id"] == nil, "a notification has no id")

    // 新一代：没有握手、没有会话；清单缓存一分钟，握手信息缓存一小时。
    let meta: JSONValue = ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]
    let modernCore = MCPServerCore(serverVersion: "test", providers: { [] })
    if case .reply(let reply) = modernCore.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/list", "params": ["_meta": meta]]) {
        checkEqual(reply["result"]?["ttlMs"]?.intValue, MCPServerCore.toolListTTLms, "a modern tools/list is cached for a short while")
        checkEqual(MCPServerCore.toolListTTLms, 60_000, "one minute")
    }
    if case .reply(let reply) = modernCore.handle(["jsonrpc": "2.0", "id": 4, "method": "server/discover", "params": ["_meta": meta]]) {
        checkEqual(reply["result"]?["ttlMs"]?.intValue, 3_600_000, "the discover answer keeps its hour")
    }
    check(!modernCore.hasLegacySession, "a modern client never becomes a legacy session")
}

// MARK: 小文件

private func checkMarkerFile() {
    let home = "/Users/tester"
    let url = MCPProviderMarker.url(bundleIdentifier: "com.example.App", home: home)
    checkEqual(url.path, "/Users/tester/Library/Application Support/com.example.App/mcp-providers.json", "the marker path")
    checkEqual(
        url.deletingLastPathComponent().path,
        URL(fileURLWithPath: MCPBridge.socketPath(bundleIdentifier: "com.example.App", home: home)).deletingLastPathComponent().path,
        "the marker sits next to the socket (one folder per app / bundle id)"
    )
    check(MCPProviderMarker.url(bundleIdentifier: "com.example.Beta", home: home) != url, "the test build has its own marker")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-marker-\(getpid())-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("nested/mcp-providers.json")
    check(MCPProviderMarker.read(at: file).isEmpty, "a missing file means nothing configured")
    checkEqual((try? MCPProviderMarker.write([.skystudio], to: file)) ?? false, true, "writing creates the folder and the file")
    checkEqual(MCPProviderMarker.read(at: file), [.skystudio], "the marker reads back")
    // 只有提供方的名字，没有别的（尤其不是 Key）
    checkEqual(String(data: (try? Data(contentsOf: file)) ?? Data(), encoding: .utf8), #"{"providers":["skystudio"]}"#, "the file holds nothing but the provider names")
    checkEqual((try? MCPProviderMarker.write([.skystudio], to: file)) ?? true, false, "writing the same thing again leaves the file alone")
    checkEqual((try? MCPProviderMarker.write([], to: file)) ?? false, true, "removing the provider rewrites it")
    try? Data(#"{"providers":["fal","skystudio"]}"#.utf8).write(to: file)
    checkEqual(MCPProviderMarker.read(at: file), [.skystudio], "legacy fal marker keeps the live Sky Studio provider")
    try? MCPProviderMarker.write([], to: file)
    check(MCPProviderMarker.read(at: file).isEmpty, "nothing configured again")
    for (content, expected) in [("not json", []), ("{}", []), (#"{"providers":"fal"}"#, []), (#"{"providers":["fal","skystudio","nobody",5]}"#, [MCPProvider.skystudio]), (#"{"providers":[]}"#, [])] {
        try? Data(content.utf8).write(to: file)
        checkEqual(MCPProviderMarker.read(at: file), Set(expected), "a marker that says \(content) is read leniently")
    }
    // 同一个 Set 写出来的文件每次都一样（排序过）
    try? MCPProviderMarker.write([.skystudio], to: file)
    let first = try? Data(contentsOf: file)
    try? FileManager.default.removeItem(at: file)
    try? MCPProviderMarker.write([.skystudio], to: file)
    checkEqual(try? Data(contentsOf: file), first, "the same providers always write the same bytes")
}

// MARK: 真起小程序

private func checkHelperListing() {
    let socket = NSTemporaryDirectory() + "srtflow-mcp-provider-check-\(getpid()).sock"
    let legacy = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check-client","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
    ]
    for providers in [Set<MCPProvider>(), [.skystudio]] {
        let (messages, _) = talkToHelper(legacy, socket: socket, providers: providers)
        let names = reply(messages, id: 2)?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        check(names.contains("generate_media") && names.contains("upscale_clip"), "helper, providers \(providers.map(\.rawValue)): both paid tools are always listed")
        checkEqual(names, MCPToolName.listed(providers: providers).map(\.rawValue), "helper, providers \(providers.map(\.rawValue)): the list order")
        let initialize = reply(messages, id: 1)?["result"]
        checkEqual(initialize?["capabilities"]?["tools"]?["listChanged"]?.boolValue, true, "helper: the handshake says the list can change")
        let instructions = initialize?["instructions"]?.stringValue ?? ""
        check(instructions.contains("generate_media"), "helper, providers \(providers.map(\.rawValue)): instructions always mention generate_media")
    }
    let modern = #"{"jsonrpc":"2.0","id":9,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"m","version":"1"}}}}"#
    let (messages, _) = talkToHelper([modern], socket: socket, providers: [.skystudio])
    let result = reply(messages, id: 9)?["result"]
    checkEqual(result?["ttlMs"]?.intValue, 60_000, "helper: a modern client caches the list for a minute")
    check((result?["tools"]?.arrayValue ?? []).contains { $0["name"]?.stringValue == "generate_media" }, "helper: a modern client sees generate_media when Sky Studio is configured")
}

// MARK: 中途添加 / 删掉 Key

/// 读小程序 stdout 的线程安全的行收集器。
private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var items: [JSONValue] = []

    func feed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if let value = try? JSONValue.decode(Data(line)) { items.append(value) }
        }
    }

    var all: [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func count(method: String) -> Int { all.filter { $0["method"]?.stringValue == method }.count }
    func reply(id: Int) -> JSONValue? { all.first { $0["id"]?.intValue == id } }

    func wait(seconds: Double, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }
}

private func startHelper(marker: URL, lines: Lines) -> (process: Process, input: FileHandle)? {
    guard let helper = ProcessInfo.processInfo.environment["SRTFLOW_MCP_HELPER"] else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: helper)
    var environment = ProcessInfo.processInfo.environment
    environment["SRTFLOW_MCP_SOCKET"] = NSTemporaryDirectory() + "srtflow-mcp-live-\(getpid()).sock"
    environment["SRTFLOW_MCP_NO_LAUNCH"] = "1"
    environment["SRTFLOW_MCP_PROVIDERS"] = marker.path
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    output.fileHandleForReading.readabilityHandler = { handle in lines.feed(handle.availableData) }
    do { try process.run() } catch {
        check(false, "could not start the helper: \(error)")
        return nil
    }
    return (process, input.fileHandleForWriting)
}

private func send(_ line: String, to input: FileHandle) {
    input.write(Data((line + "\n").utf8))
}

private func checkLiveChange() {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-mcp-live-\(getpid())-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: marker) }

    // 老一代：模拟只在开会话时加载工具的客户端；后续 Key 变化不能把工具藏掉。
    let legacy = Lines()
    guard let (process, input) = startHelper(marker: marker, lines: legacy) else { return }
    defer {
        try? input.close()
        process.terminate()
    }
    send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"live","version":"1"}}}"#, to: input)
    send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, to: input)
    send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, to: input)
    check(legacy.wait(seconds: 8) { legacy.reply(id: 2) != nil }, "live: the helper answers the handshake and the list")
    func listedNames(_ id: Int) -> [String] {
        legacy.reply(id: id)?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    }
    let cachedNames = listedNames(2)
    check(cachedNames.contains("generate_media") && cachedNames.contains("upscale_clip"), "live: the first cached list already contains generation and upscale")
    checkEqual(legacy.count(method: "notifications/tools/list_changed"), 0, "live: nothing changed, no notification")

    _ = try? MCPProviderMarker.write([.skystudio], to: marker)   // 用户在设置里存了 Key
    send(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#, to: input)
    check(legacy.wait(seconds: 8) { legacy.reply(id: 3) != nil }, "live: the client asks again")
    checkEqual(listedNames(3), cachedNames, "live: adding the Key preserves the cached list")

    _ = try? MCPProviderMarker.write([], to: marker)       // 用户删了 Key
    send(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#, to: input)
    check(legacy.wait(seconds: 8) { legacy.reply(id: 4) != nil }, "live: the client asks once more")
    checkEqual(listedNames(4), cachedNames, "live: removing the Key preserves the cached list")

    // 新一代：没有会话，不收通知（靠清单的缓存时间）。
    let marker2 = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-mcp-live2-\(getpid())-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: marker2) }
    let modern = Lines()
    guard let (process2, input2) = startHelper(marker: marker2, lines: modern) else { return }
    defer {
        try? input2.close()
        process2.terminate()
    }
    send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"m","version":"1"}}}}"#, to: input2)
    check(modern.wait(seconds: 8) { modern.reply(id: 1) != nil }, "live: a modern client is answered")
    _ = try? MCPProviderMarker.write([.skystudio], to: marker2)
    Thread.sleep(forTimeInterval: 4.5)   // 盯文件的线程每 2 秒看一次：等两轮还没有通知才算没有
    checkEqual(modern.count(method: "notifications/tools/list_changed"), 0, "live: a modern client is not sent notifications (it has no session)")
}
