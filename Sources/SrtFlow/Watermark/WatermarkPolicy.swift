import Foundation

// MARK: - 导出加不加水印：只有这一处说了算
//
// 管什么：剪辑导出（界面上的导出、AI 的 export_video 都走 VideoEditExporter）要不要叠水印、叠哪一个（logo + 这一次的种子）。
// **现在（收费方案第 4 刀）默认不加**，只给测试留一个打开的办法：
//   defaults write com.srtflow.SrtFlow.beta export.testWatermark -bool true
// 授权接上之后（第 5 刀）换成服务器给的 `watermark` 开关；别处不许自己判断加不加（docs/architecture/export-watermark.md）。
// 不管什么：图、位置、滤镜图（WatermarkImage / WatermarkPlacement / WatermarkExport）。

enum WatermarkPolicy {
    static let testingKey = "export.testWatermark"

    /// 这一次导出的水印；不加回 nil。logo 读不出来时也回 nil —— 现在只有测试才加；授权接上、水印成了必须的之后，
    /// 读不出 logo 要拦住导出，不能悄悄不加（第 5 刀改）。
    static func mark(defaults: UserDefaults = .standard) -> ExportWatermark? {
        guard defaults.bool(forKey: testingKey), let logo = WatermarkImage.load() else { return nil }
        return ExportWatermark(logo: logo, seed: UInt64.random(in: .min ... .max))
    }
}
