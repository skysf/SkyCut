import Foundation

// macOS's sound classifier through SoundLabelScores (listen describe=true). Invariants only: the labels themselves belong to
// Apple's model and may change between macOS versions (on macOS 26.5 a 55 Hz drone scored "music 0.88, synthesizer 0.87").
// Compiled and run by scripts/check-sound-labels.sh.

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL [line \(line)] \(message)")
    }
}

/// 3 s of a low drone (55 Hz and its harmonics), 3 s of white noise, 3 s of a major chord.
func syntheticSound(rate: Double) -> [Float] {
    var state: UInt64 = 17
    return (0 ..< Int(9 * rate)).map { index in
        let t = Double(index) / rate
        if t < 3 { return Float(0.3 * (sin(2 * .pi * 55 * t) + 0.5 * sin(2 * .pi * 110 * t) + 0.25 * sin(2 * .pi * 165 * t))) }
        if t < 6 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return 0.4 * (Float(state >> 40) / Float(1 << 24) * 2 - 1)
        }
        return Float(0.2 * (sin(2 * .pi * 440 * t) + sin(2 * .pi * 554.4 * t) + sin(2 * .pi * 659.3 * t)))
    }
}

let rate = 48_000.0
do {
    let windows = try SoundLabelScores.classify(syntheticSound(rate: rate), sampleRate: rate)
    check(windows.map(\.start) == [0, 3, 6] && windows.allSatisfy { abs($0.duration - 3) < 0.01 },
          "one window per 3 s (\(windows.map(\.start)), \(windows.map(\.duration)))")
    check(windows.allSatisfy { window in
        !window.labels.isEmpty && window.labels.allSatisfy { (0 ... 1).contains($0.score) }
            && zip(window.labels, window.labels.dropFirst()).allSatisfy { $0.score >= $1.score }
    }, "every window has labels, each with its own score in 0…1, strongest first")
    check(windows.contains { $0.labels.filter { $0.score >= 0.05 }.count >= 2 },
          "more than one label scores in a window: each label's own score, not one verdict")
    check(Set(windows.flatMap { $0.labels.map(\.name) }).count > 10, "the classifier's many labels all come back, not only the top one")
    for window in windows {
        print("   \(window.start) s: " + window.labels.prefix(4).map { "\($0.name) \(String(format: "%.2f", $0.score))" }.joined(separator: ", "))
    }
} catch {
    check(false, "the sound classifier did not run: \(error)")
}
do {
    let short = try SoundLabelScores.classify([Float](repeating: 0, count: Int(rate)), sampleRate: rate)
    check(short.allSatisfy { $0.duration > 0 }, "a sound shorter than a window does not break the classifier (\(short.count) windows)")
} catch {
    check(false, "short-sound classification failed: \(error)")
}

print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
