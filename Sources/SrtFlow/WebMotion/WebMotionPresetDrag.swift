import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SrtFlowCore
import SrtFlowWebMotionKit

// A project-template card's payload. Only the timeline's existing drop router receives it; the page never runs in this process.
enum WebMotionPresetDrag {
    static let typeIdentifier = "com.srtflow.motion-preset"
    static let type = UTType(exportedAs: typeIdentifier, conformingTo: .data)

    struct Pending {
        var templateID: String
        var duration: Double
        var generation: Int
    }
    @MainActor static var pending: Pending?
    @MainActor private static var endTask: Task<Void, Never>?
    @MainActor private static var keyMonitor: Any?
    @MainActor private static var token = 0

    @MainActor
    static func itemProvider(templateID: String, record: WebMotionClipRecord, project: VideoEditProject) -> NSItemProvider {
        finish()
        token += 1
        let current = token
        pending = Pending(templateID: templateID, duration: record.duration, generation: project.documentGeneration)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { MainActor.assumeIsolated { finish() } }
            return event
        }
        // A canceled drag may never reach the timeline. Keep exit/re-entry live, then release this small session after mouse-up.
        endTask = Task { @MainActor in
            while !Task.isCancelled, token == current {
                try? await Task.sleep(for: .milliseconds(100))
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    // AppKit dispatches the successful drop first; the delayed cleanup cannot steal its captured request.
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled, token == current else { return }
                    if NSEvent.pressedMouseButtons & 1 == 0 { finish(); return }
                }
            }
        }
        return NSItemProvider(item: templateID as NSString, typeIdentifier: typeIdentifier)
    }

    @MainActor
    static func finish() {
        endTask?.cancel()
        endTask = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        pending = nil
    }
}

// The preview and commit share this landing. Incompatible/lower rows start at the lowest visible upper track and collisions lift up.
struct WebMotionPresetDropPlan: Equatable {
    var start: Double
    var duration: Double
    var target: TrackDropTarget
    var rowY: Double = 0
    var rowHeight: Double = TimelineDropPlaceholder.newLaneHeight
    var guides: [Double] = []
    var end: Double { start + duration }

    static func resolve(time: Double, duration: Double, target: TrackDropTarget?, state: TimelineState) -> Self? {
        guard time.isFinite, time >= 0, duration.isFinite, duration > 0 else { return nil }
        let upper: TrackDropTarget
        switch target {
        case .overlay(let index)? where state.overlayTracks.indices.contains(index) && !state.overlayTracks[index].isHidden:
            upper = .overlay(index)
        case .newOverlayTop?: upper = .newOverlayTop
        case .insertOverlay(let index)? where (0...state.overlayTracks.count).contains(index): upper = .insertOverlay(at: index)
        default:
            upper = state.overlayTracks.firstIndex(where: { !$0.isHidden }).map(TrackDropTarget.overlay) ?? .newOverlayTop
        }
        guard let landing = state.mediaImportLandings([.init(duration: duration, isAudio: false)], firstStart: time,
                                                     preferring: upper).first else { return nil }
        return Self(start: landing.start, duration: landing.duration, target: landing.target)
    }
}

struct WebMotionPresetDropDelegate: DropDelegate {
    let project: VideoEditProject
    let pps: Double
    let rowLayouts: [TimelineRowLayout]
    let geometry: TimelineScrollGeometry
    let autoScroller: TimelineAutoScroller
    let viewport: CGSize
    @Binding var preview: WebMotionPresetDropPlan?

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [WebMotionPresetDrag.type]) }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated { preview = plan(at: info.location) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            let next = plan(at: info.location)
            preview = next
            autoScroll(contentX: info.location.x, contentY: info.location.y)
            return DropProposal(operation: next == nil ? .forbidden : .copy)
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            preview = nil
            autoScroller.stop()
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            defer {
                preview = nil
                WebMotionPresetDrag.finish()
                autoScroller.stop()
            }
            guard let pending = WebMotionPresetDrag.pending, let plan = plan(at: info.location) else { return false }
            let request = WebMotionPresetRequest(templateID: pending.templateID, at: plan.start,
                                                 preferring: plan.target, project: project)
            let rendering = L10n("Rendering motion…")
            project.notice = rendering
            Task {
                let model = WebMotionPresetModel(project: project)
                let added = await model.add(request)
                guard project.isCurrentGeneration(request.generation) else { return }
                if !added, let error = model.error { project.notice = error }
                else if project.notice == rendering { project.notice = nil }
            }
            return true
        }
    }

    @MainActor
    private func plan(at location: CGPoint) -> WebMotionPresetDropPlan? {
        guard let pending = WebMotionPresetDrag.pending, project.isCurrentGeneration(pending.generation), pps > 0,
              let record = try? MotionPresetLibrary.template(pending.templateID, in: project.state) else { return nil }
        let duration = FrameGrid(fps: record.fps).time(ofFrame: WebMotionRequest.frameCount(duration: record.duration, fps: record.fps))
        let row = rowLayouts.first { location.y >= $0.minY && location.y <= $0.maxY }
        let requested = row?.spec.slot.map(TrackDropTarget.init)
        let snapped = project.importFirstStart(anchor: .pointer(max(0, location.x / pps)), firstDuration: duration)
        guard var next = WebMotionPresetDropPlan.resolve(time: snapped.start, duration: duration,
                                                        target: requested, state: project.state) else { return nil }
        next.guides = snapped.guides
        if case .overlay(let index) = next.target,
           let row = rowLayouts.first(where: { $0.spec.slot == .overlay(index) }) {
            next.rowY = row.minY
            next.rowHeight = row.maxY - row.minY
        } else {
            let top = rowLayouts.first { $0.spec.slot != nil }?.minY ?? (rowLayouts.last?.maxY ?? 30)
            next.rowY = TimelineDropPlaceholder.newLaneY(above: top)
        }
        return next
    }

    @MainActor
    private func autoScroll(contentX: Double, contentY: Double) {
        let viewportX = contentX - geometry.offsetX
        autoScroller.update(pointer: CGPoint(x: viewportX, y: 0), viewport: CGSize(width: viewport.width, height: 0)) {
            preview = plan(at: CGPoint(x: viewportX + geometry.offsetX, y: contentY))
        }
    }
}
