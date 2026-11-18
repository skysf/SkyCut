import Foundation

// MARK: - Music: where it stops by itself and comes back, and where it ends (pure)
//
// What this owns: the 0.1 s levels of one piece (MusicLevels) → the stops (MCP-43: "where the piece stops by itself", the
// stretch an editor puts a cut from quiet to loud on) and the end of its own sound.
// What it does not own: the levels and accents themselves (MusicLevels, MusicAccents), what the AI reads (AIMusicShapeReport).
//
// The rules (docs/architecture/listening-engine.md section 9), all relative to the piece's playing level, so a quiet piece is
// read the same way as a loud one:
// - Quiet = more than 20 dB under the playing level.
// - A stop: quiet for at least 0.5 s, at least 40 dB under somewhere inside (the music really stops: on the four generated
//   tracks of the production research the gaps between staccato hits sit 22–35 dB under, the breaks 44–91 dB under), with
//   music before and after it. It runs from the first quiet step to where the music comes back: the accent that brings it back
//   when one falls within 0.2 s of the first loud step, otherwise that step's start.
// - Quiet before any music is the intro, not a stop; quiet to the end is the ending: the end is where it starts. A piece loud up
//   to its last step ends at the end of its samples.

enum MusicStops {
    static let quietBelow = 20.0
    static let deepBelow = 40.0
    static let shortest = 0.5
    /// How far after the first loud step the accent that brings the music back may fall.
    static let comebackReach = 0.2

    static func find(_ levels: MusicLevels, accents: [MusicShape.Accent]) -> (stops: [MusicShape.Stop], end: Double?) {
        guard let playing = levels.playing else { return ([], nil) }
        let decibels = levels.decibels
        let step = MusicLevels.step
        let quiet = decibels.map { $0 < playing - quietBelow }
        guard let lastLoud = quiet.lastIndex(of: false) else { return ([], nil) }
        let end = Double(lastLoud + 1) * step
        var stops: [MusicShape.Stop] = []
        var index = quiet.firstIndex(of: false) ?? quiet.count
        while index <= lastLoud {
            guard quiet[index] else { index += 1; continue }
            var after = index
            while after <= lastLoud, quiet[after] { after += 1 }
            let run = index..<after
            if Double(run.count) * step >= shortest - 1e-9, (decibels[run].min() ?? 0) <= playing - deepBelow {
                let back = Double(after) * step
                let comeback = accents.first { $0.time >= back - step && $0.time <= back + comebackReach }
                stops.append(MusicShape.Stop(from: Double(index) * step, to: comeback?.time ?? back))
            }
            index = after
        }
        return (stops, end)
    }
}
