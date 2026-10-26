import Foundation

// MARK: - App 自带的资源文件在哪
//
// 管什么：`Sources/SrtFlow/Resources` 里的文件运行时去哪找。打包后资源摊平在 Contents/Resources（scripts/build-app.sh）；
// `swift run` 的时候在可执行文件旁边的 SrtFlow_SrtFlow.bundle 里。按顺序找，哪一处有用哪一处。
// **不用 `Bundle.module`**：打好的 App 里没有那个 bundle，它会直接崩（docs/architecture/ai-control-mcp.md 第四节）。
// 用它的：内置的剪辑风格卡（AIBuiltInRecipes）、导出水印的 logo（WatermarkPolicy）。
// 不管什么：文件里是什么、怎么读。

enum AppResources {
    static var directories: [URL] {
        var result: [URL] = []
        if let resources = Bundle.main.resourceURL { result.append(resources) }
        result.append(Bundle.main.bundleURL.appendingPathComponent("SrtFlow_SrtFlow.bundle", isDirectory: true))
        result.append(Bundle.main.bundleURL.appendingPathComponent("SrtFlow_SrtFlow.bundle/Contents/Resources", isDirectory: true))
        return result
    }

    /// 第一处有这个文件的地方；都没有回 nil。
    static func url(named name: String, in directories: [URL] = directories) -> URL? {
        directories.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
