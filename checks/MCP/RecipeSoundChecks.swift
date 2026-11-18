import Foundation
import SrtFlowMCPKit

// The text returned by recipes must teach the same bed decision the production cut planner implements.
func runRecipeSoundChecks() {
    let resources = URL(fileURLWithPath: "Sources/SrtFlow/Resources", isDirectory: true)
    let shared = AIBuiltInRecipes.sharedRules(from: [resources])
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("srtflow-recipe-sound-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let reply = try? AIRecipeTools.recipes(args(["id": "shared-rules"]), store: AIRecipeStore(directory: folder),
                                          builtIn: AIBuiltInRecipes.load(from: [resources]), sharedRules: shared)
    let text = reply?.payload["text"]?.stringValue ?? ""
    let cuts = text.components(separatedBy: "## Cuts\n").dropFirst().first?.components(separatedBy: "\n## ").first ?? ""
    check(cuts.contains("raised first") && cuts.contains("6 dB") && cuts.contains("louder side"),
          "recipes teaches raising the bed first toward the louder side, within 6 dB")
    check(cuts.contains("volume limit") && cuts.contains("only"), "recipes reserves side attenuation for what the bed's volume limit leaves uncovered")
    check(cuts.contains("set_transition sound=bed"), "recipes sends the bed policy through the production tool")
    check(!cuts.contains("both sides dipped toward it"), "recipes no longer teaches unconditional dipping of both sides")
}
