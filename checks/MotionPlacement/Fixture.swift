import Foundation
import SrtFlowCore
import SrtFlowMCPKit
@testable import SrtFlow

// Small deterministic pages, a registry-owned background project and real AI call/job adapters.
@MainActor final class MotionFixture {
    let project: VideoEditProject
    let root: URL
    let session = "motion-placement-check"

    static let page = #"""
    <!doctype html><html><style>html,body{margin:0;background:transparent;overflow:hidden}canvas{display:block}</style>
    <canvas id="art"></canvas><script>
    const canvas=document.getElementById('art');
    canvas.width=MOTION_RENDER.width;canvas.height=MOTION_RENDER.height;
    const ctx=canvas.getContext('2d');
    window.motion={frame(t){
      ctx.clearRect(0,0,canvas.width,canvas.height);
      ctx.fillStyle=MOTION_PARAMS.color||'#33aadd';
      ctx.fillRect(40+t*80,60,canvas.width*.5,canvas.height*.6);
      ctx.fillStyle='white';ctx.font='60px Avenir Next';
      ctx.fillText(MOTION_PARAMS.text||'MOTION',70,canvas.height*.5);
    }};
    </script></html>
    """#

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let made = OpenProjects.shared.newProject(savingAs: root.appendingPathComponent("Motion.skycut"), placement: .background) else {
            throw AIToolError(OpenProjects.shared.failure ?? "Could not create the isolated motion project")
        }
        project = made
        project.ownUndoManager.groupsByEvent = false
        project.applyDocumentRepair { $0.mainMagnet = false; $0.frameRate = .fps24 }
        project.ownUndoManager.removeAllActions()
        AISession.shared.setViewMode(.background, for: project)
    }

    var record: WebMotionClipRecord {
        .init(page: Self.page, parametersJSON: ##"{"color":"#33aadd","text":"EXPEDITION"}"##,
              name: "Synthetic Motion", parameterFields: [.init(key: "text", label: "Title"), .init(key: "color", label: "Colour", kind: .color)],
              fonts: ["Avenir Next"],
              duration: 0.5, hitTime: 0.25, width: 320, height: 180, fps: project.state.frameRate.fps)
    }

    var context: AICallContext {
        AICallContext(session: session, client: "MotionPlacementCheck", project: project.shortID, stopsWith: project.shortID)
    }

    func call(_ values: [String: JSONValue]) async throws -> AIToolResult {
        try await AICallContext.$current.withValue(context) {
            try await AIMotionTool.set(AIToolArguments(.object(values)), project)
        }
    }

    struct Answer {
        var payload: JSONValue
        var failed: Bool
        var wasJob: Bool
    }

    /// Use the same get_job endpoint the AI uses; an unfinished or missing result fails instead of being counted as passed.
    func completed(_ initial: AIToolResult) async throws -> Answer {
        guard let id = initial.payload["job_id"]?.stringValue else {
            return Answer(payload: initial.payload, failed: initial.isError, wasJob: false)
        }
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let result = try await AICallContext.$current.withValue(context) {
                try await AIExportTools.job(AIToolArguments(["job_id": .string(id), "wait_seconds": 1]))
            }
            let status = result.payload["status"]?.stringValue
            if status == "done" || status == "failed" || status == "cancelled" {
                guard let payload = result.payload["result"] else { throw AIToolError("A completed motion job did not return its result") }
                return Answer(payload: payload, failed: status != "done", wasJob: true)
            }
        }
        throw AIToolError("The motion job did not finish within the integration-check deadline")
    }

    func resetUndo() { project.ownUndoManager.removeAllActions() }
}
