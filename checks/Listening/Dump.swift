import Foundation

// `--dump <目录>`：把对账的输入写出来给 Python 版读（小端 float32，一个信号一个文件，加一份 manifest.json 说哪个是哪个）。
// 只在重算对照值时用（docs/architecture/listening-engine.md「和 Python 版对」）；CI 不跑这一步。

enum ListeningDump {
    static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest: [[String: Any]] = []
        for item in ListeningParity.estoiCases() {
            try save(item.clean, "estoi_\(item.name)_clean.f32", in: directory)
            try save(item.mix, "estoi_\(item.name)_mix.f32", in: directory)
            manifest.append(["kind": "estoi", "name": item.name, "rate": item.rate,
                             "clean": "estoi_\(item.name)_clean.f32", "mix": "estoi_\(item.name)_mix.f32"])
        }
        let masker = ListeningParity.maskerCase()
        try save(masker.clean, "masker_clean.f32", in: directory)
        var layers: [[String: String]] = []
        for layer in masker.layers {
            try save(layer.samples, "masker_\(layer.id).f32", in: directory)
            layers.append(["id": layer.id, "file": "masker_\(layer.id).f32"])
        }
        manifest.append(["kind": "masker", "name": masker.name, "rate": masker.rate, "clean": "masker_clean.f32", "layers": layers])
        for (name, samples) in featureSignals() {
            try save(samples.map { Float($0) }, "features_\(name).f32", in: directory)
            manifest.append(["kind": "features", "name": name, "rate": SourceSoundFeatures.sampleRate, "file": "features_\(name).f32"])
        }
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: directory.appendingPathComponent("manifest.json"))
        print("✓ 写好了 \(manifest.count) 个案子：\(directory.path)")
    }

    private static func save(_ samples: [Float], _ name: String, in directory: URL) throws {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }   // arm64 本来就是小端
        try data.write(to: directory.appendingPathComponent(name))
    }
}
