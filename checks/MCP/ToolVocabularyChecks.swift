import Foundation
import SrtFlowMCPKit

// MARK: - The exported tool vocabulary is this build's (MCP-62)
//
// scripts/check-mcp.sh runs scripts/export-tool-vocabulary.sh before this binary and passes the file in
// SRTFLOW_TOOL_VOCABULARY, so the file a release hands to ops is made and checked on every PR. It must have exactly the
// format's keys; every tool once, with the schema and aliases the App checks arguments against; `project`; the guide's
// topics and sections in order; `result_fields` = every name SkyCut's own text checks accept (catalogKnownNames); a reader
// of the file (the content gate's, ported in ToolVocabulary) accepts exactly the names this build accepts; the VERSION it
// was given; and the shared rules' size as the App's own recipes answer measures it. Rules: ai-control-mcp.md 4 item 32.

func runToolVocabularyChecks() {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["SRTFLOW_TOOL_VOCABULARY"], !path.isEmpty, let data = FileManager.default.contents(atPath: path),
          let file = try? JSONValue.decode(data) else {
        check(false, "SRTFLOW_TOOL_VOCABULARY is the JSON scripts/export-tool-vocabulary.sh wrote (check-mcp.sh exports it first)")
        return
    }
    checkEqual(file.objectValue?.keys.sorted() ?? [], ["accepted_anywhere", "format", "guide_topics", "result_fields", "shared_rules",
                                                       "skycut_version", "source", "tools"], "the exported vocabulary has the format's keys")
    checkEqual(file["format"]?.stringValue, ToolVocabulary.format, "the exported vocabulary names its format")
    let version = environment["VERSION"].flatMap { $0.isEmpty ? nil : $0 }
    checkEqual(file["skycut_version"], version.map(JSONValue.string) ?? .null,
               "the exported vocabulary carries the VERSION it was given, null without one")
    sourceChecks(file["source"])
    exportedToolChecks(file)
    exportedNameChecks(file)
    sharedRulesChecks(file["shared_rules"])
}

private func strings(_ list: [String]) -> JSONValue { .array(list.map(JSONValue.string)) }

private func sourceChecks(_ source: JSONValue?) {
    checkEqual(source?.objectValue?.keys.sorted() ?? [], ["commit", "commit_date", "dirty", "exporter", "from", "repo"],
               "the export says where it came from")
    checkEqual(source?["repo"]?.stringValue, "SkyCut", "the export names its repo")
    let commit = source?["commit"]?.stringValue ?? ""
    check(commit.count == 40 && commit.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "the export records the full commit (got \(commit))")
    check(!(source?["commit_date"]?.stringValue ?? "").isEmpty, "the export records the commit's date")
    check(source?["dirty"]?.boolValue != nil, "the export says whether its sources had uncommitted changes")
    checkEqual(source?["exporter"]?.stringValue, "scripts/export-tool-vocabulary.sh", "the export names the script that wrote it")
}

private func exportedToolChecks(_ file: JSONValue) {
    let entries = file["tools"]?.arrayValue ?? []
    checkEqual(entries.map { $0["name"]?.stringValue ?? "?" }, MCPToolName.allCases.map(\.rawValue).sorted(),
               "the export lists every tool once, sorted by name")
    for entry in entries {
        guard let name = entry["name"]?.stringValue, let tool = MCPToolName(rawValue: name) else { continue }
        checkEqual(entry.objectValue?.keys.sorted() ?? [], ["accepts", "aliases", "name"], "\(name)'s entry has its name, schema and aliases")
        check(entry["accepts"] == MCPArgumentCheck.acceptedSchema(for: tool),
              "\(name)'s exported schema is the one the App checks its arguments against (MCPArgumentCheck.acceptedSchema)")
        checkEqual(entry["aliases"], strings((MCPArgumentCheck.aliases[tool] ?? []).sorted()), "\(name)'s exported aliases")
    }
    checkEqual(file["accepted_anywhere"], strings(MCPArgumentCheck.anywhere.sorted()), "the export lists the names every tool takes")
    let topics = JSONValue.array(MCPGuideTopics.all.map { .object(["name": .string($0.name), "sections": strings($0.sections.map(\.name))]) })
    check(file["guide_topics"] == topics, "the export lists the guide's topics and their sections, in the guide's order")
}

private func exportedNameChecks(_ file: JSONValue) {
    let fields = file["result_fields"]?.arrayValue?.compactMap(\.stringValue) ?? []
    checkEqual(fields, Array(Set(fields)).sorted(), "result_fields are sorted, each once")
    let known = catalogKnownNames()
    checkEqual(known.subtracting(fields).sorted(), [], "result_fields have every name SkyCut's own text checks accept (catalogKnownNames)")
    checkEqual(Set(fields).subtracting(known).sorted(), [], "result_fields have only names SkyCut's own text checks accept")
    guard let reader = ToolVocabulary(exported: file) else {
        check(false, "the content gate's reader (ToolVocabulary) reads the export")
        return
    }
    let live = ToolVocabulary.live()
    checkEqual(reader.names.subtracting(live.names).sorted(), [], "a reader of the export accepts no name this build doesn't")
    checkEqual(live.names.subtracting(reader.names).sorted(), [], "a reader of the export accepts every name this build does")
    checkEqual(Set(reader.tools.keys), Set(live.tools.keys), "a reader of the export knows every tool")
    for (name, tool) in live.tools {
        let read = reader.tools[name]
        check(read?.params.keys.sorted() == tool.params.keys.sorted() && read?.paths.keys.sorted() == tool.paths.keys.sorted(),
              "a reader of the export finds \(name)'s parameters and dotted paths")
    }
}

/// The shared rules' size is measured on the App's own answers: a style read with the rules minus the same style without
/// them is what the rules add (`in_answer_utf16`), so the gate can add it to a style's own answer size.
private func sharedRulesChecks(_ entry: JSONValue?) {
    let resources = URL(fileURLWithPath: "Sources/SrtFlow/Resources", isDirectory: true)
    let rules = AIBuiltInRecipes.sharedRules(from: [resources])
    checkEqual(entry?["id"]?.stringValue, MCPRecipeTools.sharedRulesID, "the export names the shared rules' id")
    checkEqual(entry?["utf16"]?.intValue, rules.utf16.count, "the export gives the shared rules' size as the App reads them")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-vocabulary-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let builtIn = AIBuiltInRecipes.load(from: [resources])
    guard let style = builtIn.first?.id else {
        check(false, "a built-in style to measure the shared rules on")
        return
    }
    func answerSize(_ shared: String) -> Int {
        let reply = try? AIRecipeTools.recipes(args(["id": .string(style)]), store: AIRecipeStore(directory: folder),
                                                builtIn: builtIn, sharedRules: shared)
        return reply?.payload.encodedString().utf16.count ?? 0
    }
    let added = answerSize(rules) - answerSize("")
    check(added > rules.utf16.count, "the shared rules add their escaped text to a recipes answer (measured \(added))")
    checkEqual(entry?["in_answer_utf16"]?.intValue, added, "the export gives what the shared rules add to one recipes answer")
    print("MCP tool vocabulary: \(MCPToolName.allCases.count) tools, \(MCPGuideTopics.all.count) guide topics, "
        + "\(catalogKnownNames().count) known names; shared rules \(rules.utf16.count) UTF-16, +\(added) in a recipes answer.")
}
