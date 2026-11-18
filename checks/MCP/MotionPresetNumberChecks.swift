import Foundation
import SrtFlowMCPKit

// Native numeric titles must survive the real set_text mutation path. Compare the whole roll so a fallback default
// cannot pass by retaining only its displayed final value; the fixtures never need an App window or user project.
func runMotionPresetNumberChecks() {
    for style in NumberRollStyle.allCases {
        for hiddenBacking in [false, true] {
            do {
                let fixture = try NumberPresetFixture(style: style, hiddenBacking: hiddenBacking)
                numberPresetReapplyChecks(fixture)
                numberPresetCounterConversionChecks(fixture)
                numberPresetAnimationChecks(fixture)
            } catch {
                check(false, "numeric preset fixture \(style), backing=\(hiddenBacking): \(error)")
            }
        }
        numberPresetCounterControl(style)
    }
}

private struct NumberPresetFixture {
    var state: TimelineState
    var titleID: UUID
    var smallID: UUID
    var roll: NumberRoll
    var hit: Double
    var length: Double

    init(style: NumberRollStyle, hiddenBacking: Bool) throws {
        var state = TimelineState()
        state.canvasRatio = .wide16x9
        let roll = NumberRoll(from: -1250.5, to: 98765.25, fractionDigits: 2, groupsThousands: false,
                              prefix: "~ ", suffix: " km²", style: style, duration: 1.75, delay: 0.4)
        let added = try AIOverlayEdits.text(args(["text": "IGNORED ORIGINAL WORDS", "number": numberArguments(roll),
                                                 "start": 5.25, "duration": 4.5]), at: 0, in: &state)
        let built = try AIOverlayEdits.text(args(["text_id": .string(added.id.uuidString), "motion_preset": "frame_reveal",
                                                 "small_text": "FROM"]), at: 0, in: &state)
        guard let members = MotionPresetGroups.members(ofText: built.id, in: state), let small = members.small else {
            throw AIToolError("The numeric preset fixture did not create its title and small line")
        }
        checkEqual(members.anchorText?.number, roll, "a plain numeric overlay becomes a native numeric title without losing any roll field")
        if hiddenBacking {
            _ = try AIOverlayEdits.text(args(["text_id": .string(added.id.uuidString), "text": "HIDDEN BACKING WORDS"]),
                                       at: 0, in: &state)
            checkEqual(state.textOverlays.first { $0.id == added.id }?.settledText, roll.settledText,
                       "ordinary set_text backing words remain hidden while the title has a number")
        }
        self.state = state; self.roll = roll; self.titleID = added.id; self.smallID = small.id
        self.hit = members.hit; self.length = members.end - members.hit
    }
}

private func numberArguments(_ roll: NumberRoll) -> JSONValue {
    ["from": .number(roll.from), "to": .number(roll.to), "decimals": .number(Double(roll.fractionDigits)),
     "thousands": .bool(roll.groupsThousands), "prefix": .string(roll.prefix), "suffix": .string(roll.suffix),
     "style": .string(roll.style.rawValue), "seconds": .number(roll.duration), "delay": .number(roll.delay)]
}

private func numberPresetReapplyChecks(_ fixture: NumberPresetFixture) {
    let edits: [(String, [String: JSONValue])] = [
        ("same preset", ["motion_preset": "frame_reveal"]),
        ("other preset", ["motion_preset": "focus_pull"]),
        ("implicit small text", ["small_text": "UPDATED CREDIT"]),
        ("implicit small placement", ["small_text_below": true]),
        ("partial suffix", ["motion_preset": "focus_pull", "number": ["suffix": " MI"]])
    ]
    for (name, values) in edits {
        for addressSmall in [false, true] {
            var state = fixture.state
            var call = values
            call["text_id"] = .string((addressSmall ? fixture.smallID : fixture.titleID).uuidString)
            let kind = values["motion_preset"]?.stringValue.flatMap(MotionPresetKind.init(rawValue:)) ?? .frameReveal
            let small = values["small_text"]?.stringValue ?? "FROM"
            let below = values["small_text_below"]?.boolValue ?? false
            do {
                let changed = try AIOverlayEdits.text(args(call), at: 0, in: &state)
                var expected = fixture.roll
                if name == "partial suffix" { expected.suffix = " MI" }
                assertNumericPreset(changed, state: state, fixture: fixture, roll: expected, kind: kind, small: small, below: below,
                                    context: "\(name), addressed small=\(addressSmall)")
                // Repeating the same preset exercises reconstruction after its first normalization as well.
                let repeated = try AIOverlayEdits.text(args(["text_id": .string(fixture.titleID.uuidString),
                                                             "motion_preset": .string(kind.rawValue)]),
                                                      at: 0, in: &state)
                assertNumericPreset(repeated, state: state, fixture: fixture, roll: expected, kind: kind, small: small, below: below,
                                    context: "repeated \(name)")
            } catch {
                check(false, "numeric \(name), addressed small=\(addressSmall), \(fixture.roll.style): \(error)")
            }
        }
    }
    var sequence = fixture.state
    do {
        for kind in [MotionPresetKind.focusPull, .frameReveal, .focusPull, .frameReveal] {
            let result = try AIOverlayEdits.text(args(["text_id": .string(fixture.titleID.uuidString),
                                                       "motion_preset": .string(kind.rawValue)]), at: 0, in: &sequence)
            assertNumericPreset(result, state: sequence, fixture: fixture, roll: fixture.roll, kind: kind,
                                context: "numeric round trip to \(kind.rawValue)")
        }
    } catch { check(false, "numeric frame/focus round trip: \(error)") }
}

private func assertNumericPreset(_ result: AIOverlayEdits.Text, state: TimelineState, fixture: NumberPresetFixture,
                                 roll: NumberRoll, kind: MotionPresetKind, small: String = "FROM", below: Bool = false, context: String) {
    let members = MotionPresetGroups.members(ofText: result.id, in: state)
    let title = members?.anchorText
    checkEqual(members?.kind, kind, "\(context): the requested preset is actually selected")
    checkEqual(members?.small?.text, small, "\(context): the requested small words take effect")
    checkEqual(members?.small?.motionPreset?.role, below ? .smallBelow : .smallAbove,
               "\(context): the requested small-line placement takes effect")
    checkEqual(title?.number, roll, "\(context): the complete NumberRoll is retained")
    checkEqual(title?.settledText, roll.settledText, "\(context): numeric content stays visible instead of backing words")
    check(title?.isBlank == false, "\(context): the numeric title remains renderable")
    checkEqual(title?.text, "", "\(context): ignored backing words are not reconstructed as an ordinary title")
    checkEqual(result.id, fixture.titleID, "\(context): the anchor title id stays stable")
    check(abs((members?.hit ?? -1) - fixture.hit) < 0.000001
            && abs((members.map { $0.end - $0.hit } ?? -1) - fixture.length) < 0.000001,
          "\(context): group hit and length stay stable")
    checkEqual(state.textOverlays.count, 2, "\(context): old title/small members do not accumulate")
}

private func numberPresetCounterConversionChecks(_ fixture: NumberPresetFixture) {
    for suffixOnly in [false, true] {
        var state = fixture.state
        var call: [String: JSONValue] = ["text_id": .string(fixture.smallID.uuidString), "motion_preset": "title_counter", "text": "DISTANCE"]
        var expected = fixture.roll
        if suffixOnly { call["number"] = ["suffix": " MI"]; expected.suffix = " MI" }
        do {
            let result = try AIOverlayEdits.text(args(call), at: 0, in: &state)
            let members = MotionPresetGroups.members(ofText: result.id, in: state)
            checkEqual(members?.text(.counter)?.number, expected,
                       "a small member's title_counter conversion finds and retains the group's numeric title")
            checkEqual(members?.anchorText?.text, "DISTANCE", "title_counter uses the explicitly supplied title")
            checkEqual(result.id, fixture.titleID, "counter conversion returns the original anchor title id")
            checkEqual(state.textOverlays.count, 2, "counter conversion keeps only its title and counter")
        } catch {
            check(false, "small-member counter conversion suffixOnly=\(suffixOnly), \(fixture.roll.style): \(error)")
        }
    }
    var refused = fixture.state
    checkThrows("numeric title_counter conversion still requires new title words") {
        _ = try AIOverlayEdits.text(args(["text_id": .string(fixture.smallID.uuidString), "motion_preset": "title_counter"]),
                                   at: 0, in: &refused)
    }
    checkEqual(refused, fixture.state, "a missing-title refusal keeps the original numeric group intact")
}

private func numberPresetAnimationChecks(_ fixture: NumberPresetFixture) {
    var state = fixture.state
    do {
        let result = try AIOverlayEdits.text(args(["text_id": .string(fixture.titleID.uuidString), "motion_preset": "focus_pull",
            "animation_in": "fade", "animation_out": "wipe", "animation_in_duration": 0.21, "animation_out_duration": 0.32,
            "animation_intensity": 0.55, "emphasis": "breathe"]), at: 0, in: &state)
        assertNumericPreset(result, state: state, fixture: fixture, roll: fixture.roll, kind: .focusPull, context: "same-call explicit animation")
        let animation = MotionPresetGroups.members(ofText: result.id, in: state)?.anchorText?.animation
        checkEqual(animation?.entrance, .fade, "same-call explicit entrance wins over the preset default")
        checkEqual(animation?.exit, .wipe, "same-call explicit exit wins over the preset default")
        checkEqual(animation?.entranceDuration, 0.21, "same-call entrance duration stays")
        checkEqual(animation?.exitDuration, 0.32, "same-call exit duration stays")
        checkEqual(animation?.intensity, 0.55, "same-call animation intensity stays")
        checkEqual(animation?.emphasis, .breathe, "same-call emphasis stays")
    } catch { check(false, "numeric preset explicit animation: \(error)") }
}

private func numberPresetCounterControl(_ style: NumberRollStyle) {
    var state = TimelineState()
    let roll = NumberRoll(from: -12.5, to: 3456.75, fractionDigits: 2, groupsThousands: false,
                          prefix: "~ ", suffix: " km", style: style, duration: 1.7, delay: 0.25)
    do {
        let added = try AIOverlayEdits.text(args(["text": "DISTANCE", "motion_preset": "title_counter", "number": numberArguments(roll)]),
                                          at: 2, in: &state)
        let repeated = try AIOverlayEdits.text(args(["text_id": .string(added.id.uuidString), "motion_preset": "title_counter"]),
                                             at: 0, in: &state)
        let members = MotionPresetGroups.members(ofText: repeated.id, in: state)
        checkEqual(members?.text(.counter)?.number, roll, "ordinary title_counter retains its dedicated full roll")
        checkEqual(members?.anchorText?.text, "DISTANCE", "ordinary title_counter retains its title words")
    } catch { check(false, "ordinary title_counter control: \(error)") }
}
