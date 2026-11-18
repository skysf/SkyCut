import SwiftUI

// Constructs the delegates behind the timeline's single drop destination. Geometry is shared; each payload owns its own preview.
@MainActor
enum TimelineDropRouterFactory {
    static func make(project: VideoEditProject, pps: Double, rows: [TimelineRowSpec], geometry: TimelineScrollGeometry,
                     autoScroller: TimelineAutoScroller, viewport: CGSize, dwell: TimelineSeamDwell,
                     openSeam: Binding<TimelineSeam?>, files: Binding<MediaFileDropPlan?>, filter: Binding<FilterDropPlan?>,
                     audio: Binding<AudioLibraryDropPlan?>, transition: Binding<TransitionDropPreview?>,
                     motion: Binding<WebMotionPresetDropPlan?>, contentWidth: Double) -> TimelineDropRouter {
        let layouts = VideoEditTimelineView.layouts(of: rows, open: openSeam.wrappedValue)
        let main = layouts.first { $0.spec.slot == .main && !$0.spec.isHidden }
        return TimelineDropRouter(
            files: MediaFileDropDelegate(project: project, pps: pps, rows: rows, geometry: geometry,
                                         autoScroller: autoScroller, viewport: viewport, dwell: dwell,
                                         openSeam: openSeam, preview: files),
            filter: FilterDropDelegate(project: project, pps: pps, rowLayouts: layouts, geometry: geometry,
                                      autoScroller: autoScroller, viewport: viewport, preview: filter),
            audio: AudioLibraryDropDelegate(project: project, pps: pps, rows: rows, geometry: geometry,
                                            autoScroller: autoScroller, viewport: viewport, dwell: dwell,
                                            openSeam: openSeam, preview: audio),
            transition: TransitionDropDelegate(project: project, pps: pps, geometry: geometry,
                                               autoScroller: autoScroller, viewport: viewport, preview: transition),
            motion: WebMotionPresetDropDelegate(project: project, pps: pps, rowLayouts: layouts, geometry: geometry,
                                                 autoScroller: autoScroller, viewport: viewport, preview: motion),
            mainRow: main.map { $0.minY...$0.maxY }, contentWidth: contentWidth)
    }
}
