import Foundation

// MARK: - 剪辑风格：一份配方卡（纯值）
//
// 管什么：一张配方卡长什么样、.md 文件怎么读成它、它怎么写回 .md；内置的和用户的怎么合成一份清单、按名字怎么找
// （`AIRecipeCatalog`）。文件开头几行 `key: value`（夹在两行 `---` 之间），下面是正文 —— 内置的五张（App 资源里的
// recipe-*.md）和用户存的（~/Library/Application Support/SrtFlow/Recipes/*.md）是同一种格式。
// Styles published on Sky Studio (2026-11-19, SS5 plan 5.1) join the same list between the presets and the user's own; they
// carry a version and no body here (the text is read when asked, SkyStudioStyleLibrary), and none of the user's files can shadow one.
// A header may also say `music: expected` or `music: optional` (2026-11-20): every preset says which; only a preset's is read, by
// inspect_video (AIDeliveryStyleMusic).
// 不管什么：从哪读、往哪写（AIRecipeStore）、给 AI 的工具（AIRecipeTools）。
// 产品决定见 docs/plans/2026-09-27-mcp.md 第 39–41 条，中文稿见 docs/plans/2026-09-28-mcp-recipes.md。

struct AIRecipe: Equatable, Sendable {
    enum Source: String, Sendable {
        /// App 自带的五张。
        case builtIn = "built_in"
        /// Published on Sky Studio, read with SkyCut Pro or the trial (SS5 plan 5.1).
        case skyStudio = "sky_studio"
        /// 用户自己存的。
        case user = "yours"
        /// 用户改过的内置那一张（和内置同一个 id，盖住它；删掉它内置的就回来）。
        case customized = "yours_replacing_built_in"
    }

    var id: String
    var title: String
    /// 一句「什么时候用」：AI 按它挑。
    var useFor: String
    var body: String
    var source: Source
    /// A Sky Studio style's current version (`1.0`); presets and the user's styles have none.
    var version: String? = nil
    /// The header's `music`: `expected` = true, `optional` = false, absent or anything else = nil. A film cut in a preset that
    /// expects music and has none at all gets inspect_video's suspect instead of its grey hint (AIDeliveryStyleMusic).
    var expectsMusic: Bool? = nil

    /// 读一份 .md。开头没有 `---` 那一段也照收：标题取第一个「# 」标题，没有就用文件名，id 用文件名。
    /// 正文空的不算一张卡（nil）。
    static func parse(_ text: String, fileName: String, source: Source) -> AIRecipe? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        var fields: [String: String] = [:]
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[first].trimmingCharacters(in: .whitespaces) == "---",
           let close = lines[(first + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[(first + 1)..<close] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "_")
                fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            lines.removeSubrange(0...close)
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let stem = (fileName as NSString).deletingPathExtension
        let heading = lines.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        let id = fields["id"].flatMap(slug) ?? slug(stem) ?? stem
        let title = [fields["title"], heading, stem].compactMap { $0 }.first { !$0.isEmpty } ?? id
        let music: Bool? = ["expected": true, "optional": false][fields["music"]?.lowercased() ?? ""]
        return AIRecipe(id: id, title: title, useFor: fields["use_for"] ?? fields["when"] ?? "", body: body, source: source,
                        expectsMusic: music)
    }

    /// 写回文件的样子（`parse` 读得回来）。
    var fileText: String {
        func oneLine(_ text: String) -> String {
            text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        }
        let music = expectsMusic.map { "music: \($0 ? "expected" : "optional")\n" } ?? ""
        return "---\nid: \(id)\ntitle: \(oneLine(title))\nuse_for: \(oneLine(useFor))\n\(music)---\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    /// 名字 → id（也是文件名）：小写、空白换成短横，只留字母（任何文字）、数字和短横，去掉文件名里不能有的字符。
    /// 「课程推广」照样是「课程推广」；一个能用的字都没有是 nil。
    static func slug(_ name: String) -> String? {
        var result = ""
        for character in name.lowercased() {
            if character.isLetter || character.isNumber {
                result.append(character)
            } else if character == "-" || character == "_" || character.isWhitespace {
                if !result.isEmpty, result.last != "-" { result.append("-") }
            }
        }
        while result.last == "-" { result.removeLast() }
        guard !result.isEmpty else { return nil }
        return String(result.prefix(60))
    }
}

/// 内置的和用户的合成一份清单：用户的和内置同一个 id 就盖住内置的那张（记成 customized）；内置的按固定顺序在前，
/// then Sky Studio's in the order Sky Studio lists them, 用户自己的按标题排在后面。A Sky Studio style can't be shadowed (SS5 plan
/// 5.2): a file of the user's with its id or title is left out (`hiddenBySkyStudio`, listed in Settings with a rename hint); a
/// Sky Studio style with a preset's id is left out, so a preset's id always means the preset.
struct AIRecipeCatalog: Sendable {
    let recipes: [AIRecipe]
    /// The user's own styles a Sky Studio style of the same id or title hides.
    let hiddenBySkyStudio: [AIRecipe]

    /// 内置五张的顺序（`recipes` 列出来就是这个顺序）。
    static let builtInOrder = ["product-promo", "cinematic-opening", "sci-fi", "documentary", "daily-vlog"]

    init(builtIn: [AIRecipe], user: [AIRecipe], skyStudio: [AIRecipe] = []) {
        let userByID = Dictionary(user.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let builtInIDs = Set(builtIn.map(\.id))
        let sortedBuiltIn = builtIn.sorted {
            (Self.builtInOrder.firstIndex(of: $0.id) ?? .max, $0.id) < (Self.builtInOrder.firstIndex(of: $1.id) ?? .max, $1.id)
        }
        var merged = sortedBuiltIn.map { recipe -> AIRecipe in
            guard var own = userByID[recipe.id] else { return recipe }
            own.source = .customized
            return own
        }
        let server = skyStudio.filter { !builtInIDs.contains($0.id) }
        merged += server
        let own = user.filter { !builtInIDs.contains($0.id) }
        let hidden = own.filter { mine in server.contains { $0.id == mine.id || Self.sameTitle($0.title, mine.title) } }
        merged += own.filter { mine in !hidden.contains { $0.id == mine.id } }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        recipes = merged
        hiddenBySkyStudio = hidden
    }

    /// 按 id 或标题找（不分大小写；名字先换成 id 再比）。A title Sky Studio uses finds the Sky Studio style first.
    func find(_ name: String) -> AIRecipe? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        let id = AIRecipe.slug(wanted)
        return recipes.first { $0.id == id || $0.id == wanted }
            ?? recipes.first { $0.source == .skyStudio && Self.sameTitle($0.title, wanted) }
            ?? recipes.first { Self.sameTitle($0.title, wanted) }
    }

    private static func sameTitle(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
