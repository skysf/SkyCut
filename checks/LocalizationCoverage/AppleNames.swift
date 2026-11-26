import Foundation

// **Apple's names in zh-Hans**: the Simplified Chinese table names macOS apps and places the way Apple's own
// Simplified Chinese does: 访达, never "Finder" (user, 2026-11-26: 「中文里面不叫Finder，叫访达」). Every Chinese
// name below is the one macOS 26.5's own zh_CN tables use (Finder, System Settings and its panes). Only zh-Hans:
// Apple's Traditional Chinese, Spanish and Japanese keep "Finder". docs/architecture/localization.md, section 1.
// The table half of the coverage check is in Tables.swift; main.swift runs this.

/// The table these names apply to.
let appleNamesLanguage = "zh-Hans"

/// English names that must not stay in a zh-Hans value, each with Apple's Simplified Chinese name.
/// A name inside a path or an identifier (`/Applications/…`, `AIFinderSelection`) isn't prose and is skipped.
let appleEnglishNames: [(name: String, chinese: String)] = [
    ("Finder", "访达"),
    ("System Settings", "系统设置"),
    ("System Preferences", "系统设置"),
    ("Privacy & Security", "隐私与安全性"),
    ("Screen & System Audio Recording", "录屏与系统录音"),
    ("Language & Region", "语言与地区"),
    ("Applications", "应用程序"),
    ("Downloads", "下载"),
    ("Trash", "废纸篓"),
    ("Preview", "预览"),
    ("Terminal", "终端"),
    ("Keychain Access", "钥匙串访问"),
]

/// Chinese spellings that aren't Apple's: the pane name SkyCut used until 2026-11-26, macOS 12's name for
/// System Settings, and Windows' name for the Trash.
let nonAppleChineseNames: [(name: String, chinese: String)] = [
    ("屏幕与系统音频录制", "录屏与系统录音"),
    ("系统偏好设置", "系统设置"),
    ("回收站", "废纸篓"),
]

/// Deliberate exceptions, by key: a value that has to quote one of the names above as it is (an English-only
/// system window, say) lists the name here with the reason. None so far.
let appleNameExceptions: [String: Set<String>] = [:]

/// Each entry's key and the line it starts on, read from the raw file: the parsed table has no line numbers.
func entryLines(inRawTableAt path: String) -> [(key: String, line: Int)] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    let regex = try! NSRegularExpression(pattern: #"^"((?:[^"\\]|\\.)*)"\s*="#, options: [.anchorsMatchLines])
    let ns = text as NSString
    var entries: [(key: String, line: Int)] = []
    var line = 1
    var counted = 0
    regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
        guard let match else { return }
        let skipped = NSRange(location: counted, length: match.range.location - counted)
        line += ns.substring(with: skipped).filter { $0 == "\n" }.count
        counted = match.range.location
        entries.append((unescaped(ns.substring(with: match.range(at: 1))), line))
    }
    return entries
}

/// Fails each zh-Hans value that names a macOS app or place other than the way Apple's Chinese does,
/// with the file, the line and the name to use. Returns how many failed.
func appleNameFailures(tables: [String], resources: String) -> Int {
    let cwd = FileManager.default.currentDirectoryPath + "/"
    let english = appleEnglishNames.map { rule in
        (rule, try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_/])"
            + NSRegularExpression.escapedPattern(for: rule.name) + "(?![A-Za-z0-9_/])"))
    }
    var failures = 0
    var checked = 0
    for file in tables {
        let path = "\(resources)/\(appleNamesLanguage).lproj/\(file)"
        let shown = path.hasPrefix(cwd) ? String(path.dropFirst(cwd.count)) : path
        guard let parsed = table(at: path) else {
            print("FAIL \(shown) can't be read, so its Apple names weren't checked")
            failures += 1
            continue
        }
        let entries = entryLines(inRawTableAt: path)
        // Every entry has to be reached line by line, or a value this scan misses would pass unread.
        if Set(entries.map(\.key)) != Set(parsed.keys) {
            print("FAIL \(shown): \(Set(entries.map(\.key)).count) entries read line by line but \(parsed.count) in the table, so the Apple-names scan misses some")
            failures += 1
        }
        for (key, line) in entries {
            guard let value = parsed[key] else { continue }
            checked += 1
            let allowed = appleNameExceptions[key] ?? []
            let whole = NSRange(location: 0, length: (value as NSString).length)
            var found = english.filter { $0.1.firstMatch(in: value, range: whole) != nil }.map(\.0)
            found += nonAppleChineseNames.filter { value.contains($0.name) }
            for rule in found where !allowed.contains(rule.name) {
                print("FAIL \(shown):\(line): \"\(rule.name)\" → Apple's Chinese name is \(rule.chinese)  (key \"\(key.prefix(70))\")")
                failures += 1
            }
        }
    }
    if failures == 0 {
        print("All \(checked) \(appleNamesLanguage) values name macOS apps and places the way Apple does (\(appleEnglishNames.count + nonAppleChineseNames.count) names checked).")
    }
    return failures
}
