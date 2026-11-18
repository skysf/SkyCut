import Foundation

// MARK: - Split the export's audio configuration by any key, so a group of clips can be rendered as one stem (pure)
//
// Owns: every track of `AudioEngineConfig` split into one track per key (the same fader, the same segments in the same order),
// so the split tracks still add up to exactly the export's mix — a track only sums its segments and multiplies by its fader
// (AudioTrackRenderer; a sound scene belongs to its segment). Each wanted key becomes one `AudioStemLayer` (its split tracks),
// the shape AudioStemRender / MixMeasurement take. Keys that are not wanted stay in the configuration (they are part of the mix)
// without a layer.
// Used by the second-tier delivery checks: role groups (AIDeliverySoundLevels) and one sound against everything else
// (AIDeliveryLinger). Not here: rendering or measuring (AudioStemRender, MixMeasurement).

enum DeliveryStemSplit {
    static func split<Key: Hashable>(
        _ config: AudioEngineConfig, wanted: [Key], name: (Key) -> String, key: (AudioEngineConfig.Segment) -> Key
    ) -> (config: AudioEngineConfig, layers: [(key: Key, layer: AudioStemLayer)]) {
        var tracks: [AudioEngineConfig.Track] = []
        var indices: [Key: [Int]] = [:]
        for track in config.tracks {
            var order: [Key] = []
            var groups: [Key: [AudioEngineConfig.Segment]] = [:]
            for segment in track.segments {
                let group = key(segment)
                if groups[group] == nil { order.append(group) }
                groups[group, default: []].append(segment)
            }
            for group in order {
                indices[group, default: []].append(tracks.count)
                tracks.append(AudioEngineConfig.Track(name: track.name, meterKey: track.meterKey, fader: track.fader,
                                                      segments: groups[group] ?? []))
            }
        }
        let layers = wanted.compactMap { group in
            indices[group].map { (key: group, layer: AudioStemLayer(name: name(group), tracks: $0)) }
        }
        return (AudioEngineConfig(tracks: tracks, master: config.master, duration: config.duration), layers)
    }
}
