import Foundation

// MARK: - 导出加不加水印：只有这一处说了算
//
// 管什么：剪辑导出（界面上的导出、AI 的 export_video 都走 VideoEditExporter）要不要叠水印、叠哪一个（logo + 这一次的种子）。
// 带不带 = 授权说要带（`byLicence`：照授权拦生效时听服务器的 `watermark`，只从 SkyStudioAccount.exportsWithWatermark 来，规矩在 SkyCutGates）
// 或者测试开关开着：
//   defaults write com.srtflow.SrtFlow.beta export.testWatermark -bool true
// **要带却读不出 logo 就不导**（抛 LogoUnreadable）：水印是必须的，删掉包里的 logo 不能换来没水印的成片。
// 别处不许自己判断加不加（docs/architecture/export-watermark.md）。
// 不管什么：图、位置、滤镜图（WatermarkImage / WatermarkPlacement / WatermarkExport）、授权怎么算。

enum WatermarkPolicy {
    static let testingKey = "export.testWatermark"

    /// 要带水印、却读不出 logo：拦住这一次导出。
    struct LogoUnreadable: Error {}

    /// 带不带（导出面板上「会带水印」那一行、export_video 先告诉 AI 的那一句也问它）。
    static func required(byLicence: Bool, defaults: UserDefaults = .standard) -> Bool {
        byLicence || defaults.bool(forKey: testingKey)
    }

    /// 这一次导出的水印；不带回 nil（不带时不读 logo）。要带却读不出 logo 抛 `LogoUnreadable`。
    static func mark(
        byLicence: Bool, defaults: UserDefaults = .standard, logo: () -> WatermarkImage.Logo? = { WatermarkImage.load() }
    ) throws -> ExportWatermark? {
        guard required(byLicence: byLicence, defaults: defaults) else { return nil }
        guard let logo = logo() else { throw LogoUnreadable() }
        return ExportWatermark(logo: logo, seed: UInt64.random(in: .min ... .max))
    }
}
