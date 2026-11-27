# 2026-11-27 Taking the timeline down published its scroll offset: windows whose root is the timeline aborted

## Symptom

- Off-screen renderers aborted when they closed a window whose root view was the timeline (lane U2's state renderer, which
  then kept every such window open until it exited; review FBG1's 100-line probe):
  `Simultaneous accesses to …, but modification requires exclusive access … Fatal access conflict detected.`, with the stack
  `NSHostingView.deinit` → `GraphHost.invalidate()` → `AG::Graph::invalidate_subgraphs` → `PlatformViewChild.destroy()` →
  `TimelineScrollViewAccessor.dismantleNSView` → `TimelineScrollGeometry.attach(nil)` → `offset.setter` (`@Published`) →
  `AttributeInvalidatingSubscriber.invalidateAttribute()` → `GraphHost.asyncTransaction`.
- SkyCut's own project windows did not abort: 17 real closes on macOS 26.5.2 (the close button, `set_view background`,
  `close_project`, with and without AppKit's event loop, claiming key or not) all survived. But every one of them published
  the same way from the same place; they survived only because of the order in which SwiftUI took the window's views down.
  SkyCut supports macOS 15.0 and later; no other macOS version was tried.

## Root cause

- `dismantleNSView` let go of the scroll view through `attach(nil)`, which wrote `offset = .zero`. A `@Published` write sends
  `objectWillChange` at once. `dismantleNSView` runs inside the hosting view's graph invalidation: `GraphHost.invalidate()`
  holds a modifying access while it destroys the platform views, and a subscriber of the same graph that is still connected
  (the header column and the ruler observe `offset`) answers through `GraphHost.asyncTransaction`, which reads the same
  storage. Swift's exclusivity check aborts the process.
- Whether a subscriber is still connected at that moment depends only on SwiftUI's teardown order. In the full editor
  (`ProjectWindowRoot` → `VideoEditView`) both subscribers were gone before the accessor was dismantled; with the timeline as
  the hosting view's root, or in the probe's `VStack`, they were not (9 of 10 timeline-only windows aborted; the 10th
  published and survived).
- Why the first look suggested a leak instead: a closed window stays alive until SkyCut's next event, because AppKit keeps
  the last event (`NSApp.currentEvent`, and the main window toolbar's last validation event), and that event points at the
  closed window. In a background smoke run no new event arrives, so nothing was released and the teardown never ran; the
  next event released all of it. Not a leak, but it hid the teardown from the October multi-window smokes.

## Fix

- `TimelineScrollGeometry.detach(owner:)` removes the bounds observer, the scroll view and the project's `live` entry, and
  publishes nothing. `attach(nil)` (the probe leaving the tree) goes to it before any write, and `dismantleNSView` calls it
  through `onDetach`. `offset` keeps its last value: nothing reads it once the tree is gone, and the next `attach` publishes
  the real one (`Sources/SrtFlow/VideoEditTimelineScrollGeometry.swift`).
- Nothing else changed: `offsetX` / `offsetY` still read the scroll view live (the
  [marquee case](2026-09-18-marquee-anchored-at-stale-scroll-offset.md)), and the zoom anchor still reads the timeline's own
  scroll geometry. The three other `dismantleNSView`s in `Sources/` (the tooltip anchor, the pinch bridge, the web-motion
  hover player) publish nothing.

## Verification

- `scripts/check-e2e-gui.sh`, case `checks/E2EGUI/TimelineTeardown.swift`. With no AppKit event loop, only an autorelease
  pool still holds a closed window: its hosting view goes about 0.3 s after the close, and the case polls for that. It
  closes a project window the way `set_view background` does, a window whose root is the timeline, and the first project's
  window with its close button. Each time it requires the hosting view released, the geometry no longer registered, and
  nothing published by the geometry from the close on. Counting the publishes keeps the case red on a macOS whose teardown
  order would not abort. Main: red (the project window published once; run alone, the timeline-only window aborted once and
  published once in two runs). With the fix: green in every run (9 before the save step below was added: 7 by the author,
  2 in the first review; 3 of 3 of the final case).
- The same suite now has to print `GUI E2E: every case ran`. Its process has no `NSApp.run`: the main loop is the Swift
  runtime's `CFRunLoopRun`, which exits with status 0 once the main run loop is stopped. A close that has to save first makes
  `windowShouldClose` answer false, and `-[NSButtonCell performClick:]` then waits in a nested AppKit event loop that also
  stops the main loop: in 4 of 4 such runs the suite ended halfway with status 0 and passed. That setup is red now. The case
  also saves the project, and requires `flushToFile()` to return `.saved`, before its close-button close: until review FBC1
  that step depended on the background step's save (`VideoEditView.onDisappear`) finishing first, by about 0.6 s here.
- `checks/timeline-drag-wiring/teardown.sh` (a scan): `dismantleNSView` lets go through `onDetach`, `detach` writes no
  `offset` and sends nothing, `attach(nil)` reaches `detach` before any write. Main: red on all four. A single `offset = .zero`
  put into `detach`: red. A target renamed (`attach(_:owner:)`'s label, `detach(owner:)`): red; before review FBC1 that
  printed ✗ and stayed green, because `require_func` reports a miss with `fail` inside `$(…)`, so each block now counts it
  itself. With the fix: green.
- In the real App (in-process smoke, step 1 of this work): the deinit runs from `-[NSApplication run]`'s autorelease pool at
  the next event, the teardown published, nothing aborted. Evidence was kept outside the repository.

## Lessons

- A representable never publishes from `dismantleNSView`, nor from anything it calls: that code runs inside SwiftUI's
  teardown, and whether a publish there aborts is only SwiftUI's teardown order. Rule:
  [timeline drag gestures §5c](../architecture/timeline-drag-gestures.md).
- "It does not crash in the App" can be luck of the view tree. A second host of the same view (a renderer, a check) is the
  cheap way to see it, and a check should count the publishes rather than wait for the abort.
- To see whether a closed window is released, give AppKit one more event (or run without its event loop): until then its
  record of the last event keeps the window.
- A check process whose main loop is the Swift runtime's can end with status 0 halfway (here: AppKit's nested event loop in
  `performClick:`, when a close has to save first): make it print a completion line and require it, and don't let a step
  depend on another step's asynchronous work having finished.
