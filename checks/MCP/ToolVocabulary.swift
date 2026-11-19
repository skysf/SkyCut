import Foundation
import SrtFlowMCPKit

// MARK: - SkyCut's tool vocabulary, read the way Sky Studio's content gate reads it (skycut-tool-vocabulary/1)
//
// What it owns: the model of the vocabulary a published editing style or craft card is checked against — each tool's
// parameter names at any depth and their dotted paths (an array level adds no step), what each name takes (types, options,
// range), the names every tool takes (`project`), the guide's topics and sections, and every other name text written for
// the AI may use. It ports the reader of the content gate's checker (kept with the content, outside this repo), so
// SkyCut's own check and the gate agree on what "this name exists" means. Built from the live catalog (`live()`) or from an
// exported file (`init(exported:)`); one published entry is checked by `PublishedNameEntry`.
// What it does not own: writing the file (scripts/tool-vocabulary/main.swift via scripts/export-tool-vocabulary.sh) and
// the checks (ToolVocabularyChecks, PublishedNamesChecks). Rules: docs/architecture/ai-control-mcp.md section 4 item 32.

struct ToolVocabulary {
    static let format = "skycut-tool-vocabulary/1"

    /// One place a name is defined. A name defined in several places (`kind`, `time`) is fine when any of them fits.
    struct Spec: Equatable {
        var types: Set<String> = []
        var options: [JSONValue]?
        var minimum: Double?
        var maximum: Double?
    }

    struct Tool {
        /// Every property name at any depth.
        var params: [String: [Spec]] = [:]
        /// Dotted paths from the top; arrays add no step (`clips.sound_effect.preset`).
        var paths: [String: [Spec]] = [:]
    }

    let tools: [String: Tool]
    let anywhere: Set<String>
    let topics: [String: [String]]
    /// Every name a text may mention: tools, parameters, string options, `project`, topics, sections, result fields.
    let names: Set<String>

    init(tools list: [(name: String, accepts: JSONValue, aliases: [String])], anywhere: Set<String>,
         topics topicList: [(name: String, sections: [String])], resultFields: [String]) {
        var topics: [String: [String]] = [:]
        for topic in topicList { topics[topic.name] = topic.sections }
        // The two values of `track` that open a new track: written in parameter text, not an option list.
        var names = anywhere.union(topics.keys).union(["new_video", "new_audio"])
        topics.values.forEach { names.formUnion($0) }
        var built: [String: Tool] = [:]
        for tool in list {
            var entry = Tool()
            Self.walk(tool.accepts, prefix: "", into: &entry)
            for alias in tool.aliases {
                entry.params[alias, default: []].append(Spec(types: ["string", "number"]))
                if entry.paths[alias] == nil { entry.paths[alias] = entry.params[alias] }
            }
            names.insert(tool.name)
            for (name, specs) in entry.params {
                names.insert(name)
                specs.forEach { names.formUnion(($0.options ?? []).compactMap(\.stringValue)) }
            }
            built[tool.name] = entry
        }
        names.formUnion(resultFields)
        self.tools = built
        self.anywhere = anywhere
        self.topics = topics
        self.names = names
    }

    /// This build's vocabulary: the schema the App checks each tool's arguments against, its aliases, the guide, and every
    /// name SkyCut's own text checks accept (catalogKnownNames).
    static func live() -> ToolVocabulary {
        ToolVocabulary(
            tools: MCPToolName.allCases.map { tool in
                (tool.rawValue, MCPArgumentCheck.acceptedSchema(for: tool), (MCPArgumentCheck.aliases[tool] ?? []).sorted())
            },
            anywhere: MCPArgumentCheck.anywhere,
            topics: MCPGuideTopics.all.map { ($0.name, $0.sections.map(\.name)) },
            resultFields: Array(catalogKnownNames()))
    }

    /// An exported file read as the content gate reads it: `format` and `tools` are required, the rest may be missing.
    /// nil when the format is not this one or a tool entry lacks its name or schema.
    init?(exported file: JSONValue) {
        guard file["format"]?.stringValue == Self.format, let entries = file["tools"]?.arrayValue else { return nil }
        var list: [(name: String, accepts: JSONValue, aliases: [String])] = []
        for entry in entries {
            guard let name = entry["name"]?.stringValue, let accepts = entry["accepts"], accepts.objectValue != nil else { return nil }
            list.append((name, accepts, entry["aliases"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        }
        let topics = (file["guide_topics"]?.arrayValue ?? []).compactMap { topic -> (name: String, sections: [String])? in
            guard let name = topic["name"]?.stringValue else { return nil }
            return (name, topic["sections"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        }
        self.init(tools: list, anywhere: Set(file["accepted_anywhere"]?.arrayValue?.compactMap(\.stringValue) ?? []),
                  topics: topics, resultFields: file["result_fields"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    /// A parameter name (any depth) or a dotted path of `tool` → where it is defined; nil when the tool doesn't take it.
    /// A dotted path may start at any level (`sound_effect.preset` = `clips.sound_effect.preset`).
    func resolve(tool: String, name: String) -> [Spec]? {
        guard let info = tools[tool] else { return nil }
        if name.contains(".") {
            let hits = info.paths.filter { $0.key == name || $0.key.hasSuffix("." + name) }.flatMap(\.value)
            return hits.isEmpty ? nil : hits
        }
        if let specs = info.params[name] { return specs }
        return anywhere.contains(name) ? [Spec(types: ["string"])] : nil
    }

    private static func walk(_ schema: JSONValue, prefix: String, into tool: inout Tool) {
        if let items = schema.arrayValue {
            items.forEach { walk($0, prefix: prefix, into: &tool) }
            return
        }
        guard let object = schema.objectValue else { return }
        for (key, child) in object["properties"]?.objectValue ?? [:] {
            let spec = Spec(child)
            let path = prefix.isEmpty ? key : prefix + "." + key
            tool.params[key, default: []].append(spec)
            tool.paths[path, default: []].append(spec)
            walk(child, prefix: path, into: &tool)
        }
        for key in ["items", "anyOf", "oneOf", "allOf"] {
            if let nested = object[key] { walk(nested, prefix: prefix, into: &tool) }
        }
    }
}

extension ToolVocabulary.Spec {
    /// What one property schema takes, from itself and its anyOf / oneOf branches (an array's item options count too).
    init(_ schema: JSONValue) {
        let branches = [schema] + (schema["anyOf"]?.arrayValue ?? []) + (schema["oneOf"]?.arrayValue ?? [])
        var options: [JSONValue] = []
        for branch in branches where branch.objectValue != nil {
            switch branch["type"] {
            case .string(let kind)?: types.insert(kind)
            case .array(let kinds)?: types.formUnion(kinds.compactMap(\.stringValue))
            default: break
            }
            options += branch["enum"]?.arrayValue ?? []
            if let low = branch["minimum"]?.doubleValue { minimum = low }
            if let high = branch["maximum"]?.doubleValue { maximum = high }
            if let items = branch["items"], items.objectValue != nil { options += items["enum"]?.arrayValue ?? [] }
        }
        self.options = options.isEmpty ? nil : options
    }
}
