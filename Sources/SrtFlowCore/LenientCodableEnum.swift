import Foundation

// 长期工程格式的枚举回退：统一编码 rawValue，未知值回退到类型自己的默认值。
// 从 App 模型移到 Core 供其值类型共用；不改变旧工程的读取语义。
public protocol LenientCodableEnum: RawRepresentable, Codable where RawValue == String {
    static var decodingFallback: Self { get }
}

public extension LenientCodableEnum {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.decodingFallback
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
