import SwiftUI

// Shared timeline/inspector label for stored web clips. Only recognized official defaults are translated;
// locale invalidation redraws the label without changing the saved name, page or parameter values.
struct WebMotionClipName: View {
    let record: WebMotionClipRecord
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = PerfCounters.body(Self.self)
        let _ = locale.identifier
        Text(verbatim: OfficialWebMotionLabels.title(record))
    }
}
