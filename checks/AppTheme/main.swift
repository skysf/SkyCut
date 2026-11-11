import AppKit
import SwiftUI

// 主题的行为检查：缺省 / 坏值、持久化与隔离、原配色回退、真实 SF Symbol 可用性。
@main
struct AppThemeChecks {
    @MainActor static func main() {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        let domain = "com.srtflow.theme-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        check(AppTheme.restored(from: nil) == .forest, "fresh installations default to Forest")
        check(AppTheme.restored(from: "future-value") == .forest, "unknown themes fall back to Forest")
        check(AppTheme.allCases.map(\.rawValue) == ["forest", "classic"], "theme identities are stable")

        let store = AppThemeStore(defaults: defaults)
        check(store.theme == .forest, "the production store uses the default")
        defaults.set("keep-me", forKey: "existingPreference")
        store.setTheme(.classic)
        check(AppThemeStore(defaults: defaults).theme == .classic, "Classic survives a new store")
        check(defaults.string(forKey: "existingPreference") == "keep-me", "changing theme preserves other preferences")
        store.setTheme(.forest)
        check(AppThemeStore(defaults: defaults).theme == .forest, "Forest survives a new store")
        defaults.set("broken", forKey: AppThemePreference.storageKey)
        check(AppThemeStore(defaults: defaults).theme == .forest, "the store rejects invalid persisted values")
        let scripted = AppThemeStore(defaults: nil)
        scripted.setTheme(.classic)
        check(scripted.theme == .classic, "isolated tests can switch themes in memory")
        check(AppThemeStore(defaults: nil).theme == .forest, "isolated tests cannot persist preferences")

        let forest = AppThemePalette(theme: .forest)
        let classic = AppThemePalette(theme: .classic)
        check(forest.window == AppThemePalette.color(0xf3f0e8), "Forest matches the website ivory")
        check(forest.accent == AppThemePalette.color(0x123f32), "Forest matches the website green")
        check(forest.previewSurround == AppThemePalette.color(0xe6e5df), "the preview surround is neutral")
        check(forest.blockLabel(classic: .white) != .white, "Forest track labels stay readable on pale fills")
        check(classic.blockLabel(classic: .white) == .white, "Classic retains opaque overlay labels")
        check(classic.blockLabel(classic: .white.opacity(0.92)) == .white.opacity(0.92), "Classic retains translucent clip labels")
        let sentinel = Color.purple.opacity(0.42)
        check(classic.trackFill(index: 2, audio: true, classic: sentinel) == sentinel, "Classic retains the original fill exactly")
        check(classic.trackAccent(index: 2, audio: false, classic: sentinel) == sentinel, "Classic retains the original accent exactly")
        check(classic.blockFill(classic: sentinel, kind: .text) == sentinel, "Classic retains text-block colors")
        let video = forest.trackFill(index: 0, audio: false, classic: sentinel)
        check(video == forest.trackFill(index: 6, audio: false, classic: sentinel), "video colors wrap by stable color index")
        check(forest.trackFill(index: -1, audio: true, classic: sentinel) == forest.trackFill(index: 4, audio: true, classic: sentinel), "negative legacy indices are safe")
        check(forest.subtitle(translated: false) != forest.subtitle(translated: true), "subtitle tracks remain distinguishable")
        // 浅 / 深只有一条规矩，SwiftUI 和自建的 AppKit 面板读同一份（docs/bugfixes/2026-11-11-tooltip-dark-on-dark-in-forest-theme.md）。
        check(forest.colorScheme == .light, "Forest is always the light look")
        check(classic.colorScheme == nil, "Classic follows the system light / dark setting")
        check(forest.windowAppearance?.name == .aqua, "hand-built panels are light in Forest, whatever the system")
        check(classic.windowAppearance == nil, "hand-built panels follow the system in Classic")
        let iconBounds = CGRect(x: 0, y: 0, width: 20, height: 18)
        let magnet = TimelineMagnetSymbol().path(in: iconBounds)
        check(!magnet.isEmpty && iconBounds.contains(magnet.boundingRect), "the magnet outline fits the native toolbar icon")
        for symbol in [TimelineThemeIcons.snapping, TimelineThemeIcons.followPlayhead] {
            check(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "native symbol exists: \(symbol)")
        }
        if failures > 0 { exit(1) }
        print("PASS: theme defaults, persistence, isolation, classic colors, forest palette, light / dark rule and native toolbar symbols.")
    }
}
