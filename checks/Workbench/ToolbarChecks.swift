import AppKit
import SwiftUI

// 真正渲染生产徽章：底下的红 / 蓝代表分栏线与其他内容，徽章内部不得被它们染色。
@main
struct WorkbenchToolbarChecks {
    @MainActor static func main() {
        for scheme in [ColorScheme.light, .dark] {
            NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            for working in [true, false] {
                let red = pixel(under: .red, working: working, scheme: scheme)
                let blue = pixel(under: .blue, working: working, scheme: scheme)
                guard zip(red, blue).allSatisfy({ abs($0 - $1) < 0.001 }), red[3] == 1 else {
                    FileHandle.standardError.write(Data("FAIL: underlying divider bleeds through the AI badge (\(scheme), working=\(working)).\n".utf8))
                    exit(1)
                }
            }
        }
        print("PASS: rendered working/finished badge blocks underlying colors in light and dark appearances.")
    }

    @MainActor private static func pixel(under color: Color, working: Bool, scheme: ColorScheme) -> [CGFloat] {
        let renderer = ImageRenderer(content: ZStack {
            color
            AIActivityBadgeBackground(isWorking: working)
        }.frame(width: 100, height: 40).environment(\.colorScheme, scheme))
        guard let image = renderer.cgImage,
              let color = NSBitmapImageRep(cgImage: image).colorAt(x: 50, y: 20)?.usingColorSpace(.deviceRGB) else {
            fatalError("Cannot render the production AI badge")
        }
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
    }
}
