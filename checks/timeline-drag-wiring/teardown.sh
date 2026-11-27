#!/usr/bin/env bash
# A section of checks/timeline-drag-wiring.sh: taking the timeline's view tree down.
#
# Not run on its own: timeline-drag-wiring.sh sources it and shares fail / require_func / extract_func and the path variables
# (VIEW, DRAG, GEOMETRY). Moved out of the main file, which is on the line baseline and may only shrink
# (docs/architecture/coding-standards.md). The rule: docs/architecture/timeline-drag-gestures.md §5c. The behaviour itself is
# checked by scripts/check-e2e-gui.sh (checks/E2EGUI/TimelineTeardown.swift).

# ── 7. 自动滚动的心跳必须有取消兜底 ────────────────────────────────────
grep -q 'deinit' "$DRAG" || fail "TimelineAutoScroller 没有 deinit 兜底，timer 可能永远留在 RunLoop 上"
grep -q 'dismantleNSView' "$GEOMETRY" || fail "滚动视图参照物没有 dismantleNSView：视图树拆掉后心跳还在跑"
grep -q 'onDisappear' "$VIEW" || fail "时间线没有 onDisappear：视图消失时自动滚动不会停"

# ── 7b. Taking the timeline down publishes nothing (2026-11-27) ───────────────
# dismantleNSView runs inside NSHostingView.deinit -> GraphHost.invalidate(). A publish there can reach the header column and
# the ruler (they observe `offset`) while SwiftUI holds exclusive access, and Swift aborts with "Fatal access conflict"
# (docs/bugfixes/2026-11-27-timeline-teardown-publishes-scroll-offset.md).
# require_func reports a missing target with `fail` inside `$(…)`, a subshell, so that FAILED=1 is lost: every block below
# counts the miss itself (`else FAILED=1`).
if BODY="$(require_func 'static func dismantleNSView(' "$GEOMETRY")"; then
  grep -q 'onDetach?()' <<<"$BODY" \
    || fail "dismantleNSView no longer lets go through onDetach (TimelineScrollGeometry.detach, which publishes nothing)"
  grep -q 'onAttach?(' <<<"$BODY" \
    && fail "dismantleNSView calls onAttach again: attaching writes offset, a publish inside SwiftUI's teardown"
else
  FAILED=1
fi
WRITES_OFFSET='(^|[^A-Za-z0-9_])offset[[:space:]]*=([^=]|$)'
if BODY="$(require_func 'func detach(owner: VideoEditProject)' "$GEOMETRY")"; then
  grep -qE "${WRITES_OFFSET}|objectWillChange" <<<"$BODY" \
    && fail "TimelineScrollGeometry.detach writes offset or publishes: it runs inside SwiftUI's teardown"
else
  FAILED=1
fi
# A probe that loses its scroll view (it left the tree) calls attach(nil): that must be the same detach, before any write.
if BODY="$(require_func 'func attach(_ scrollView: NSScrollView?, owner: VideoEditProject)' "$GEOMETRY")"; then
  # `|| true`: under pipefail a grep that finds nothing would end the whole script here, silently.
  TO_DETACH="$(grep -n 'guard let scrollView else { return detach(owner: owner) }' <<<"$BODY" | head -1 | cut -d: -f1 || true)"
  FIRST_WRITE="$(grep -nE "${WRITES_OFFSET}" <<<"$BODY" | head -1 | cut -d: -f1 || true)"
  if [ -z "${TO_DETACH}" ] || { [ -n "${FIRST_WRITE}" ] && [ "${FIRST_WRITE}" -lt "${TO_DETACH}" ]; }; then
    fail "TimelineScrollGeometry.attach(nil) does not go to detach before writing offset: a probe leaving the tree would publish"
  fi
else
  FAILED=1
fi
