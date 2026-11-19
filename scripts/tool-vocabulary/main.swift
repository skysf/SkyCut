import Foundation
import SrtFlowMCPKit

// Writes SkyCut's tool vocabulary (skycut-tool-vocabulary/1) to stdout: the file Sky Studio's content gate checks every
// published editing style and craft card against (MCP-62). Compiled and run only by scripts/export-tool-vocabulary.sh,
// which passes the git facts; rules in docs/architecture/ai-control-mcp.md section 4 item 32.
//
// What it writes: every tool with the schema the App checks its arguments against (MCPArgumentCheck.acceptedSchema) and
// its aliases, the names every tool takes, the guide's topics and their sections, `result_fields` (every name SkyCut's own
// text checks accept, checks/MCP/CatalogNames.swift: result fields and error codes, option lists, local voices, and the
// tool and parameter names again, so the gate never depends on rebuilding them from the schemas the way SkyCut does), the
// SkyCut version (null when none was given) and commit, and the shared rules' size. No timestamps: the same commit and
// version give the same bytes, so the gate's recorded checksum means one vocabulary.

func argument(_ name: String) -> String? {
    let all = CommandLine.arguments
    guard let index = all.firstIndex(of: name), index + 1 < all.count else { return nil }
    return all[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
    exit(1)
}

guard let commit = argument("--commit"), let commitDate = argument("--commit-date"), let dirty = argument("--dirty"),
      let rulesPath = argument("--shared-rules") else {
    fail("usage: dump --version <x.y.z or empty> --commit <sha> --commit-date <iso> --dirty true|false --shared-rules <file>")
}
let version = argument("--version").flatMap { $0.isEmpty ? nil : $0 }

// The shared rules exactly as the App reads them (AIBuiltInRecipes.sharedRules: trimmed). `in_answer_utf16` is what they add
// to one `recipes id=<style>` answer's JSON text: the "\n\n" before them plus their escaped text (ToolVocabularyChecks
// measures it on the App's own answer).
guard let rawRules = try? String(contentsOfFile: rulesPath, encoding: .utf8) else { fail("cannot read the shared rules at \(rulesPath)") }
let rules = rawRules.trimmingCharacters(in: .whitespacesAndNewlines)
guard !rules.isEmpty else { fail("the shared rules at \(rulesPath) are empty") }
let rulesInAnswer = JSONValue.string("\n\n" + rules).encodedString().utf16.count - 2

let tools = MCPToolName.allCases.sorted { $0.rawValue < $1.rawValue }
let toolEntries = tools.map { tool in
    (name: tool.rawValue, accepts: MCPArgumentCheck.acceptedSchema(for: tool), aliases: (MCPArgumentCheck.aliases[tool] ?? []).sorted())
}
let topics = MCPGuideTopics.all.map { (name: $0.name, sections: $0.sections.map(\.name)) }
let resultFields = catalogKnownNames().sorted()

func strings(_ list: [String]) -> JSONValue { .array(list.map(JSONValue.string)) }

let vocabulary: JSONValue = .object([
    "format": "skycut-tool-vocabulary/1",
    "skycut_version": version.map(JSONValue.string) ?? .null,
    "source": .object([
        "repo": "SkyCut",
        "commit": .string(commit),
        "commit_date": .string(commitDate),
        "dirty": .bool(dirty == "true"),
        "from": strings(["Sources/SrtFlowMCPKit (MCPToolName, MCPArgumentCheck, MCPGuideTopics)",
                         "checks/MCP/CatalogNames.swift (result field names)",
                         "Sources/SrtFlow/Resources/recipes-shared-rules.md (shared rules' size)"]),
        "exporter": "scripts/export-tool-vocabulary.sh"
    ]),
    "tools": .array(toolEntries.map { .object(["name": .string($0.name), "accepts": $0.accepts, "aliases": strings($0.aliases)]) }),
    "accepted_anywhere": strings(MCPArgumentCheck.anywhere.sorted()),
    "guide_topics": .array(topics.map { .object(["name": .string($0.name), "sections": strings($0.sections)]) }),
    "result_fields": strings(resultFields),
    "shared_rules": .object([
        "id": .string(MCPRecipeTools.sharedRulesID),
        "utf16": .number(Double(rules.utf16.count)),
        "in_answer_utf16": .number(Double(rulesInAnswer))
    ])
])

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
guard let data = try? encoder.encode(vocabulary) else { fail("could not encode the vocabulary") }
FileHandle.standardOutput.write(data + Data("\n".utf8))
FileHandle.standardError.write(Data("""
    tool vocabulary: \(tools.count) tools, \(topics.count) guide topics, \(resultFields.count) known names, \
    shared rules \(rules.utf16.count) UTF-16 (+\(rulesInAnswer) in a recipes answer)\n
    """.utf8))
