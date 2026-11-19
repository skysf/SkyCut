import Foundation
import SrtFlowMCPKit

// MARK: - A music model's length rules, read from `/models` (Sky Studio contract "Music length", 2026-11-19; MCP-18)
//
// What it covers: each music record's `length` block (approximate or exact, automatic length or not, default, min / max / step,
// typical error); an asked length rounded to the model's step; the length sent when the AI names none; and why a model cannot
// take an ask, in plain words (outside its range, no automatic length, not exact, instrumental only).
// Model choice walks the catalog in the server's order and takes the first music model with no problem here
// (`SkyStudioModelPolicy.problem`), so a short or exact cue goes to the exact-length model and a song or an automatic length stays
// on the first one (Lyria). No range and no model id is written in SkyCut: a catalog from before 2026-11-19 has no `length`, and
// its `params.duration` (["auto", 60, 180]) stands in.
// Not: quoting (`/quote`), the delivered length (`SkyStudioGenerationDuration`), video lengths (`SkyStudioModelPolicy`).
struct SkyStudioMusicLength: Equatable, Sendable {
    /// `exact`: the file is made the length asked. Otherwise the model reads the length from its prompt (`approximate`).
    var exact: Bool
    /// The model can choose its own length (`duration` left out, `auto` or null).
    var auto: Bool
    /// The length sent when none is asked; nil when the model then chooses (an automatic default).
    var defaultSeconds: Double?
    var minSeconds: Double
    var maxSeconds: Double
    var stepSeconds: Double
    var typicalErrorSeconds: Double?

    init(exact: Bool, auto: Bool, defaultSeconds: Double?, minSeconds: Double, maxSeconds: Double, stepSeconds: Double = 1,
         typicalErrorSeconds: Double? = nil) {
        self.exact = exact
        self.auto = auto
        self.defaultSeconds = auto ? nil : defaultSeconds
        self.minSeconds = minSeconds
        self.maxSeconds = maxSeconds
        self.stepSeconds = stepSeconds > 0 ? stepSeconds : 1
        self.typicalErrorSeconds = typicalErrorSeconds
    }

    /// nil when the record says nothing usable about length: then SkyCut sends whole seconds as asked and Sky Studio judges.
    init?(model: SkyStudioModel) {
        guard model.kind == "music" else { return nil }
        if let block = model.metadata["length"], let low = block["min_seconds"]?.doubleValue, let high = block["max_seconds"]?.doubleValue,
           low > 0, high >= low {
            self.init(exact: block["control"]?.stringValue == "exact", auto: block["auto"]?.boolValue ?? false,
                      defaultSeconds: block["default"]?.doubleValue ?? model.defaults["duration"]?.doubleValue,
                      minSeconds: low, maxSeconds: high, stepSeconds: block["step_seconds"]?.doubleValue ?? 1,
                      typicalErrorSeconds: block["typical_error_seconds"]?.doubleValue)
            return
        }
        // A catalog from before the `length` block: `params.duration` is ["auto", min, max] (Lyria) or [min, max].
        guard let range = model.params["duration"]?.arrayValue else { return nil }
        let numbers = range.compactMap(\.doubleValue)
        guard numbers.count == 2, numbers[0] > 0, numbers[1] >= numbers[0] else { return nil }
        self.init(exact: false, auto: range.contains("auto"), defaultSeconds: model.defaults["duration"]?.doubleValue,
                  minSeconds: numbers[0], maxSeconds: numbers[1])
    }

    /// An asked length in the model's steps (whole seconds for Lyria, 0.1 s for the exact-length model), as Sky Studio rounds it.
    func rounded(_ seconds: Double) -> Double {
        let units = (seconds / stepSeconds).rounded()
        let digits = min(6, max(0, Int((-log10(stepSeconds)).rounded(.up))))
        let scale = pow(10, Double(digits))
        return (units * stepSeconds * scale).rounded() / scale
    }

    /// Why this model cannot make the ask; nil when it can. `seconds`: the asked length (nil: none); `automatic`: the AI asked for
    /// `auto` or null; `exactWanted`: exact_length=true.
    func problem(seconds: Double?, automatic: Bool, exactWanted: Bool, title: String) -> String? {
        let range = "\(Self.text(minSeconds))–\(Self.text(maxSeconds)) s"
        if automatic && !auto { return "\(title) has no automatic length: give duration in seconds, \(range)." }
        if exactWanted && !exact {
            let error = typicalErrorSeconds.map { " (it lands within about \(Self.text($0)) s)" } ?? ""
            return "\(title) only aims at a length\(error), so it cannot promise an exact one."
        }
        guard let seconds else { return nil }
        let value = rounded(seconds)
        guard value < minSeconds || value > maxSeconds else { return nil }
        return "\(title) makes \(range)\(auto ? " or chooses its own length" : ""); \(Self.text(seconds)) s is outside that."
    }

    /// Why `model` cannot take the ask (vocals, then length); nil for a model that can, or one that is not music.
    static func problem(model: SkyStudioModel, ask: SkyStudioGeneration.Ask) -> String? {
        guard model.kind == "music" else { return nil }
        if ask.exactLength && ask.duration == nil { return "exact_length=true needs duration: the length in seconds." }
        if ask.instrumental == false, model.params["instrumental"]?.arrayValue?.contains(.bool(false)) == false {
            return "\(model.title) makes instrumental music only (no vocals or lyrics)."
        }
        return SkyStudioMusicLength(model: model)?.problem(seconds: ask.duration, automatic: ask.smartDuration,
                                                           exactWanted: ask.exactLength, title: model.title)
    }

    /// When no music model takes the ask: each one's reason in the server's order (each said once) and where the lengths are listed.
    /// nil when some model has no music reason (it fails for something else, which the caller reports).
    static func refusal(_ models: [SkyStudioModel], ask: SkyStudioGeneration.Ask) -> String? {
        let reasons = models.map { problem(model: $0, ask: ask) }
        guard !models.isEmpty, reasons.allSatisfy({ $0 != nil }) else { return nil }
        var said: [String] = []
        for reason in reasons.compactMap({ $0 }) where !said.contains(reason) { said.append(reason) }
        return "No music model takes this request. " + said.joined(separator: " ")
            + " get_status models=true lists each music model's length."
    }

    /// The length SkyCut sends for music: the asked seconds in the model's steps; with none asked, the model's own default unless it
    /// chooses its own length. nil = leave `duration` out. Without a model (nothing to read): whole seconds, the model decides.
    static func seconds(for ask: SkyStudioGeneration.Ask, model: SkyStudioModel?) -> Double? {
        let length = model.flatMap(SkyStudioMusicLength.init(model:))
        if let asked = ask.duration { return length?.rounded(asked) ?? asked.rounded() }
        return ask.smartDuration ? nil : length?.defaultSeconds
    }

    /// "12", "12.3", "0.05": seconds without trailing zeros.
    static func text(_ seconds: Double) -> String {
        var value = String(format: "%.2f", seconds)
        while value.contains("."), value.hasSuffix("0") { value.removeLast() }
        if value.hasSuffix(".") { value.removeLast() }
        return value
    }
}
