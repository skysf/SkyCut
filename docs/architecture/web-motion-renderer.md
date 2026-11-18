# Web-motion renderer: a page becomes a transparent movie, outside SkyCut

> Covers: `skycut-web-motion` (the helper process that renders a motion web page), SkyCut's API for it
> (`WebMotionRenderer.render`), the page contract, the locks, the time and memory limits, the page clock, the transparent
> background, the page checks before a movie is accepted (MCP-75), versions, packaging, and the checks that pin all of it.
> Also covers MCP-74's stored source, project-relative cache and `set_motion` AI call (2026-11-17).
> The shared library and panel contract is in [motion presets](motion-presets.md).
> Its three original bundled pages use this same renderer and project/cache path; see the official-template contract there.
>
> Origin (2026-11-16/17): the web-motion probe (internal research, `2026-11-16-web-motion-probe/report.md`) showed that an
> AI-written page rendered with the Mac's own WebKit gives frame-exact, transparent titles whose text matches SkyCut's own.
> The precondition — alpha video on upper tracks, the same in preview and export — was merged as #430
> ([freeze frame 4a3](freeze-frame.md)). The user decided (「按建议」, 2026-11-16): the network lock is never relaxed;
> transparency uses the fast non-public switch with a calibration before every render and switches to the public way by
> itself when wrong; movies are ProRes 4444 until HEVC with alpha has been measured. Task G10 built the renderer.

## 1. Why a helper process

The page is code written by an AI, run on the user's Mac. WebKit has no public way to stop one page or to cap its memory:
inside SkyCut, a page stuck in `while (true) {}` could only be waited out, and the probe watched a page grow to 1.5 GB.
So pages render in a separate command-line process, `skycut-web-motion`, started per render. SkyCut can kill it at any
moment; its WebKit processes (WebContent, GPU, Networking) end with it (measured: 0.1–0.3 s later, killed or not).

- **No window, no `NSApplication`.** A run loop and windowless `WKWebView`s. Measured 2026-11-17: as fast as the probe's
  off-screen window (the probe's lightest 1080p title: 25 frames/s on one page, 66 on three), and nothing can ever appear on
  screen.
- **Command line, not XPC**: same pattern, packaging and signing as `skycut-mcp`; no launchd plist, nothing to register.
- **One render at a time** (`WebMotionRenderGate`): three helpers at once measured slower than one helper drawing on three pages.

## 2. The renderer API

`WebMotionRenderer.render(_ job: WebMotionJob, verify:) async throws -> WebMotionRender`

- `WebMotionJob`: page HTML, parameters (a JSON object), duration, output size, fps, output URL; optional layout height
  (default 1080), seed, clock epoch, page instances (default 3), sample count for "same t twice" (default 8), alpha path
  (default `.auto`), limits (default `WebMotionLimits.standard(frames:)`).
- `WebMotionRender`: the movie, the `WebMotionResult` (checks, frame hashes, alpha path and calibration, whether any frame
  is translucent, versions, timing) and the peak memory. The movie is written next to the output first; once the helper's
  checks and the caller's `verify` passed, it is renamed over whatever is at the output in one step
  (`WebMotionCacheFiles.install`, on `WebMotionCacheFiles.queue`). What was there is never removed first: a failed `verify`
  or install leaves it as it was ([case](../bugfixes/2026-11-19-web-motion-rerender-deletes-cached-movie.md)).
- Errors (`WebMotionRenderError`): `.rejected(result)` — the page failed a check or a time limit, `result.failure.message`
  is the page's own text (give it back to the AI verbatim); `.killed` — SkyCut stopped it (memory, or a helper that ignored
  its own limits); `.rendererFailed` — not the page's fault (a lock unavailable on this macOS, the encoder, a crash);
  `.invalid`, `.helperMissing`, `.cancelled` (cancelling the task kills the helper).
- Callers that run it for AI work run it inside `AIJobs` (App Nap, [AI interface (MCP) rule 59](ai-control-mcp.md)).
- The helper is found at `SRTFLOW_WEB_MOTION_HELPER` (checks), `SkyCut.app/Contents/Helpers/skycut-web-motion`, or next to
  SkyCut's own executable (`swift run` builds every product into one folder).

## 3. The page contract

| What | Rule |
| --- | --- |
| Entry point | `window.motion = { frame(t), duration?, ready? }`. `frame(t)` draws the picture for t seconds and nothing else. It may return a promise; `ready` (a promise) is awaited once after load (decode images, wait for fonts) — it must not wait on timers |
| Parameters | `window.MOTION_PARAMS`: the job's JSON object, frozen, defined before any page script |
| What is rendered | `window.MOTION_RENDER`: `{ width, height }` in CSS px, `pixelWidth`, `pixelHeight`, `fps`, `duration`, `frames` |
| Viewport | 1080 CSS px tall by default, width from the output's aspect ratio (607.5 for 1080 × 1920): SkyCut's text sizes are defined on a 1080-high canvas ([text overlays](text-overlays.md)), so a page's px match them. The page is drawn straight at the output size (vector zoom), never scaled from a bitmap |
| Fonts | The Mac's own (same as SkyCut's text). No web fonts, no images except `data:` / `blob:` |
| Pure function of t | No state carried between frames, randomness only from `Math.random` / `crypto` (seeded), CSS animations that exist at load (they run from t = 0). Frames are drawn by several page instances, out of order in the second pass |
| Not allowed | Network, files, frames, workers, eval, navigation, new windows, camera / microphone / location / clipboard / notifications, storage that survives |

## 4. The locks

Measured 2026-11-17 with a page that aims every network path at a local TCP + UDP listener (`checks/WebMotion/ReachPages.swift`).
The probe's lockdown (first four rows) let two kinds of traffic out: **WebRTC sent STUN over UDP and TURN over TCP, and
link preconnect opened TCP connections** (from `<link rel=preconnect>`, and from a clicked link even though the navigation
itself is refused) — content rules and CSP do not cover either.

| Lock | How | Closes |
| --- | --- | --- |
| Content rules | `WKContentRuleList`, one rule blocking every URL | fetch, XHR, beacon, sockets, event source, images, styles, fonts, scripts, media, frames |
| CSP in the page | `WebMotionPageHTML.locked`: Content-Security-Policy + `x-dns-prefetch-control: off` before any page markup (after a leading doctype), no line break added | the same loads in the page (each also by itself), workers, eval, form posts; violations become page errors the AI can read |
| Navigation | only the first main-frame load (`about:blank` from `loadHTMLString(_:baseURL: nil)`); later navigations and subframes cancelled; `createWebViewWith` → nil | navigation, popups, downloads, subframe loads; no file URL, no origin |
| Storage | non-persistent data store | cookies / localStorage / IndexedDB surviving a render |
| Permissions | media capture denied in the UI delegate; no geolocation or notification delegate; JS dialogs answered at once | camera, microphone, location, notifications, clipboard (no user gesture), a dialog blocking a frame |
| **WebKit feature switches** (non-public) | `Lockdown.switchOff`: `PeerConnectionEnabled`, `LinkPreconnect` (both leaked), `LinkDNSPrefetchEnabled`, `WebTransportEnabled`, `LinkPreconnectEarlyHintsEnabled`, `BeaconAPIEnabled`, each read back after setting | WebRTC (even from a fresh `about:blank` iframe realm: deleting the constructor in JS would not do), preconnect, DNS prefetch |

- **Fail closed.** A missing switch, a switch that stays on, or a rule list that does not compile refuses the render
  (`rendererFailed`). The network lock is never relaxed (user, 2026-11-16).
- DNS prefetch cannot be observed without touching the Mac's DNS (not allowed on this machine): it is locked by the switch
  and the meta tag and verified by reading the switch back, not by watching DNS.
- Pages only ever load in the helper: SkyCut's own web-motion code has no `WKWebView` (`checks/web-motion-wiring.sh`).
- What no lock can stop: a page can draw anything (a fake interface, misleading text) — a person looks at the result;
  a page can tell which fonts this Mac has (nothing leaves the Mac).
- **A page that navigates** (`location.href = …`) is refused, and WebKit then never settles `document.fonts.ready` although
  `document.fonts.status` is `loaded` (measured): the clock waits for fonts only while they are loading. Before that fix the
  render waited out its load limit and blamed "an endless loop". A navigation in `<head>` can also stop the parser: the
  page then fails "frame entry".
- Every page instance is kept until the helper exits, also one rejected while loading (released at once, WebKit tore it
  down before anything was done with it; the checks need it alive to prove nothing leaks afterwards).

## 5. Time limits

`WebMotionLimits` (defaults `standard(frames:)`): load 15 s (per page instance: load, fonts, `motion.ready`), script 4 s
(one frame's JavaScript), snapshot 15 s, total 60 s + 2 s per frame, at most 30 min. Caps: output ≤ 3840 × 2160 either
way, even sizes ≥ 16, ≤ 60 s, 1–120 fps, page ≤ 2 MB, parameters ≤ 256 KB.

- **The helper enforces them and exits.** The page's JavaScript runs in WebKit's own process, so the helper's main thread
  stays free while a page loops forever and its timers fire on time (`Deadline.within`). The probe's first version waited
  inside a task group for the stuck call and hung until the total limit.
- **SkyCut backstops a helper that does not**: no event for longer than its slowest single step allows
  (max(load, script + 2 × snapshot)) + 10 s, or past its total + 10 s → SIGKILL.
- The helper also stops when SkyCut is gone (its parent changed).
- Frames are drawn several at a time; when several fail, the earliest is reported.
- **Frames only from timing inside the caps.** `WebMotionRequest.frameCount` turns a duration and frame rate into frames
  only when both are inside the caps (`timingWithinCaps`, at most 7,200 frames) and is 0 otherwise; `problems()` refuses
  the rest in plain words. Nothing may convert duration × fps to `Int` before that check: a finite 10^20 s duration (an AI
  argument, `parameters.duration`, a damaged project record) overflowed inside validation and quit SkyCut and the helper
  ([case](../bugfixes/2026-11-19-web-motion-huge-duration-quits-app.md)). A stored frame rate outside the caps is named by
  this validation; the inspector's own message covers only its length field.

## 6. Memory

WebKit has no public per-page cap, so SkyCut watches the render every 0.25 s: the footprint (`proc_pid_rusage` physical
footprint, what Activity Monitor shows) of the helper plus the WebKit processes it reported (non-public accessors
`_webProcessIdentifier`, `_gpuProcessIdentifier`, `_networkProcessIdentifier`; a missing one is skipped), and the Mac's
pressure (`kern.memorystatus_vm_pressure_level`). `WebMotionMemoryPolicy` decides:

| Mac | Kill when |
| --- | --- |
| normal | the render uses more than its budget: min(3 GB, a quarter of memory, at least 0.5 GB) |
| warning (low memory) | the render uses more than 1 GB |
| critical (out of memory) | always: the render is the one thing SkyCut can give back right away |

Measured: the check pages (320 × 180) peak at 45–80 MB in all; the probe measured 300–400 MB at 1080p (helper 70–130,
GPU process 200–280, each page about 25). The hog check is killed at 610–770 MB against a 600 MB budget (it grows 128 MB a
frame; the watch looks every 50 ms there). After the helper ends, SkyCut waits until every reported WebKit process is really
gone (an exiting process can no longer be described while its pid still exists: that counts as not gone yet) and kills any
still running as the same process after 3 s (`WebMotionProcessTeardown`; only a process still identifiable as the same one
is ever signalled).

Real machine-wide pressure is not simulated in checks: `memory_pressure -S` would push every app on a shared Mac into
purging. The checks inject "critical" / "warning" readings and use a real hog page against a small budget.

Process discovery begins before the first calibration/load and samples the live retained-page collection every 50 ms,
including pages awaiting fonts/ready, rejected pages and replacement processes. Positive PIDs are unique and only changes
emit events; repeated sampling is not a progress heartbeat. A final scan stops discovery before `.result`, which remains
the terminal protocol line. Existing exit cleanup and test linger are not moved ahead of it.

A raw reported PID is not ownership. The parent retains its first monotonic receipt tick and retries unresolved identity
lookups on live watch ticks before measuring the real footprint. A candidate must have a positive kernel start-abstime
no later than that receipt; repeated reports never refresh the ceiling. BSD identity is read before the birth check,
and safely pinned identities remain in teardown history. Watch cancellation drains its serial handler before the final
snapshot. The ceiling guards post-receipt reuse; it does not introduce a helper-supplied process-identity protocol.
WebContent/GPU identifiers come from the view; networking comes from its configured data store only when
`_networkProcessExists` is true. The view's testing network getter can assert before first load and must not be polled:
`responds(to:)` checks selector availability, not that getter's initialized page/data-store precondition. This discovery
rule never shares stores or changes each view's nonpersistent configuration. Unavailable private getters retain their
existing reduced-coverage behavior; the public alpha path does not replace them.

`load-memory` is a separately selectable regression group: two sequential fixed 32 MiB pages use the first locked view
and an unresolved ready promise, preventing earlier calibration processes from masking missing discovery. An exact native
WebContent/held-byte/deadline probe and an observation of real live budget inputs gate the injected low budget. A finite
one-event child fixture proves nil-first identity retry during live sampling, not merely during teardown; an independent
identity owns test cleanup even on failure. Local reverse checks select this group instead of the existing 600 MiB frame
hog. See [the load-memory case](../bugfixes/2026-11-18-web-motion-load-memory-window.md).

## 7. The page clock

Before any page script runs, `PageClock.bootstrap` puts the page's time under the renderer:

- `performance.now()`, `Date.now()`, `new Date()` / `Date()` (from the job's epoch), `document.timeline.currentTime` read the
  render time;
- `setTimeout` / `setInterval` / `requestIdleCallback` run when the render time passes them, in due order, each seeing its
  due time (at most 10 000 per frame, an interval at least 1 ms); zero-delay timers from load run before the first frame;
- `requestAnimationFrame` callbacks run once per frame with the frame's time, before `frame(t)`;
- `Math.random`, `crypto.getRandomValues`, `crypto.randomUUID` come from a seeded generator re-seeded from (seed, t) at
  every frame: a frame's random numbers do not depend on what was drawn before;
- CSS animations and transitions, Web Animations and SVG (SMIL) animations are paused and set to the render time; those that
  exist when loading ends run from t = 0, later ones count from the frame that first saw them (differs per page instance:
  such a page fails "same t twice");
- errors (uncaught, unhandled rejections, thrown by `frame(t)`, blocked loads) are recorded verbatim with the frame time;
- the control object is non-writable and non-configurable.

**Rule: the takeover is written from the idea, for SkyCut** (2026-11-17). The probe tool's version was derived from
OpenFilm's code and must not be copied or adapted; the probe tool's names (`CLOCK_SHIM`, `FILM_CLOCK`) must not appear in
`Sources/` (scan guard). Not covered: `Intl` formatting of "now", a fresh iframe realm's own `Math.random` — both make a page
non-deterministic, which "same t twice" catches.

## 8. Transparent background

- **Fast path** (default): WebKit's non-public "draws background" switch, so snapshots carry alpha.
- **Calibration before every render**: a 64 × 16 page (nothing / 50 % green / opaque red / 25 % white) drawn with the same
  locked configuration and zoom; each patch must read its premultiplied value ± 3 (`WebMotionAlphaCalibration`). Wrong
  (e.g. a macOS without the switch: the clear patch reads opaque white) → `.auto` switches to the public path by itself and
  reports why; `.fast` refuses.
- **Public path**: each frame drawn over opaque black and over opaque white (an inline `!important` background on `<html>`,
  restored before the next frame); alpha = 255 − mean(W − B) over the three channels, color = B clamped to alpha
  (`WebMotionPixels.deriveAlpha`). Two snapshots a frame (0–35 % slower measured, section 11); pages must not blend against
  what is behind them (`mix-blend-mode`).
- Measured 2026-11-17: fast and public paths decode to identical frames on the check's alpha page, and differ by at most
  0 / 1 / 2 levels on the probe's three titles (the probe: 0 / 1 / 2).
- **The movie**: ProRes 4444 from premultiplied BGRA (WebKit's snapshot is already sRGB premultiplied BGRA: the copy changes
  no pixel), every buffer tagged `AlphaChannelMode = premultiplied` so AVFoundation writes the `almo` box SkyCut reads
  (`SourceAlpha`, [freeze frame 4a3](freeze-frame.md)); BT.709 color tags like `AlphaSourceCopies`. Premultiplied on purpose:
  the preview's compositor wants premultiplied sources, so these movies never need the premultiplied copy SkyCut makes for
  straight-alpha files. The helper reads the file back: alpha, premultiplied tag and frames / fps length, or the render fails.
  HEVC with alpha waits for a quality measurement.
- **A fully opaque page** (a title card on its own background): the encoder leaves an alpha that is 255 everywhere out of the
  file (measured). The helper accepts a movie without alpha only when no frame had a pixel below 255; the result says
  `transparent: false` and SkyCut reads the movie as opaque video. A translucent frame in a movie without alpha fails.

## 9. Checks before a movie is accepted (MCP-75)

| Check | Fails when |
| --- | --- |
| `loads` | load, fonts or `motion.ready` not done within the load limit; the page's WebKit process ended while loading |
| `frame_entry` | no `window.motion.frame` function |
| `same_twice` | a sample frame (8 spread evenly) drawn again, last first, on the next page instance, differs in any pixel (SHA-256) |
| `no_blank_frames` | every frame is fully transparent, or a 1–2 frame empty gap sits between drawn frames (an image or font not ready). Empty frames at the start (fade in) and end (fade out), and longer gaps, pass |
| `no_page_errors` | any error at load or while drawing (verbatim, with t); a blocked load (CSP: says what and why); the page's WebKit process ended |
| `no_timeout` | a time limit was hit (says which, at which t) |

The result lists every check (passed / failed / not reached) and the first failure with the page's own text, e.g.
`ReferenceError: Can't find variable: undefinedFunction (at frame@about:blank:2:63) (while drawing t = 0.500 s)`.

## 10. Versions and determinism

The result carries `WebMotionVersion.renderer` (bump it whenever the same page, parameters and system can draw different
pixels: clock rules, alpha handling, zoom / layout, capture, encoding), macOS version and build, and WebKit's version.
Same page + parameters + versions → the same frame hashes: two renders compared hash for hash and decoded frame for frame
in the checks. Different macOS / WebKit versions may change text pixels (probe, inferred): MCP-74 stores the versions.

Official templates are checked pages, rather than exceptions to these rules. Each shipped page is rendered completely twice in
the App-linked motion checks and every frame hash must match; the helper's six checks also run on both renders. Their small bundled
browser movies have receipts binding source HTML, default parameters and movie bytes to the actual helper result. Template changes
require regenerating the corresponding preview. Canvas backing sizes use `MOTION_RENDER.pixelWidth` / `pixelHeight`; CSS geometry
uses `width` / `height`, and device-space shadow radii/offsets scale with that ratio, so 4K output does not upscale a 1080-pixel bitmap.

The ice design sets its text/font at load and its SVG paths, clip and opacity from each requested time. Its Canvas prototype failed
frame replay on this Mac even after resetting the backing store; this observation is specific to that prototype and environment.
The accepted SVG page passes the unchanged exact comparison. See the [replay case](../bugfixes/2026-11-18-official-ice-frame-replay.md).

Official parameter checks also compare actual pixels at common times, with a lower-fps control matched to the full render.
Names, JSON values and a changed frame count alone cannot prove a visual response. Shortening a duration places its changed
fade in the shared sample range; extending a hold can legitimately preserve that range. The collision page applies its final
envelope to its canvas element after a shadowed-text alpha path failed this check; see the
[duration fade case](../bugfixes/2026-11-18-official-word-shadow-fade.md).

## 11. Speed

Measured 2026-11-17 on the M1 (8 cores, 16 GB, load 8–12 from other sessions), release build, the probe's three 1080p titles
(4 s at 24 fps = 96 frames), whole helper run including the lock, calibration, loading and the second draws:

| Title | 3 page instances | 1 page instance | public alpha path (3 instances) |
| --- | --- | --- | --- |
| light SVG with a glow | 3.6 s (48 frames/s drawing) | 5.1 s | 3.6 s |
| particles, motion blur, flash | 5.3 s (25) | 10.5 s | 6.9 s |
| three large blurs and a mask | 5.2 s (26) | 10.3 s | 6.6 s |

The probe's tool took 2.7 / 5.1 / 6.4 s with three pages at load ~30 (no checks). Renders with one and three instances are
hash-identical; fast and public alpha differ by at most 0 / 1 / 2 levels on decoded frames (the probe: 0 / 1 / 2). The public
path costs 0–35 % here, not the probe's half: the derivation is a tight loop in the release build (the debug build used by the
checks is several times slower on it). A small check page (320 × 180, 12 frames) takes about 1 s, most of it the lock, the
calibration and loading three pages.

## 12. Packaging and signing

`scripts/build-app.sh` copies `skycut-web-motion` into `SkyCut.app/Contents/Helpers/` (next to ffmpeg and `skycut-mcp`);
`scripts/signing/sign-app.sh` refuses to sign without it and signs it before the outer bundle (only through `sign-app.sh`,
[code signing](code-signing-and-permissions.md)). No entitlements: the helper needs none (no camera, no network).

## 13. Checks and guards

| Check | Pins |
| --- | --- |
| `scripts/check-web-motion.sh` (`checks/WebMotion/`) | the clock (production script driven directly in a WKWebView); normal pages pass, two renders identical, movie tagged premultiplied; alpha values, fast = public, broken fast path switches / is refused; hostile pages (loops, error, kept state, no entry, flicker, huge canvas) and an out-of-bounds request the helper refuses itself; a listener sees no connection or datagram, no file read, no permission, no surviving storage; hog killed at budget, injected pressure kills, both backstops; the check's own main thread never stalls (it stands in for SkyCut). `SRTFLOW_WEB_MOTION_CHECKS=group,…` runs some groups |
| `checks/web-motion-wiring.sh` | packaging and signing order; pages only in the helper; one HTML loader, every load locked, every configuration from `Lockdown` with its locks; the fonts rule; no probe-tool clock names; the check in check-all |
| `checks/release-signing.sh` | `sign-app.sh` signs four things (ffmpeg, `skycut-mcp`, `skycut-web-motion`, the app) |

Test-only environment variables the helper reads: `SRTFLOW_WEB_MOTION_TEST_BREAK_FAST_ALPHA=1` (skip the fast switch, as a
macOS without it would), `SRTFLOW_WEB_MOTION_TEST_LINGER=<s>` (keep the pages alive after the result, so a lock that
failed has time to leak before the process is gone), and `SRTFLOW_WEB_MOTION_TEST_LOAD_PROBE=<temporary JSON path>`
(the negative load-memory fixture uses request HTML in the first locked calibration view and records exact WebContent,
held bytes and load deadline without emitting a process event).

**Reverse verification (2026-11-17)**: each lock and rule sabotaged on its own, the relevant group run, restored.

| Sabotage | What went red |
| --- | --- |
| WebRTC switch left on | network page: 8 STUN datagrams and a TURN-over-TCP allocation reached the listener |
| link preconnect switch left on | navigation page: a bare TCP connection (a clicked link preconnects although the navigation is refused) |
| content rules and CSP both removed | 233 HTTP requests reached the listener |
| content rules removed (CSP kept) / CSP removed (rules kept) | nothing leaks either way (each blocks the HTTP paths by itself); without CSP the attempts no longer come back as page errors (red) |
| `document.fonts.ready` awaited unconditionally | the network page waits out its load limit |
| `Math.random`, timers, `requestAnimationFrame`, CSS settling, `Date` back on the wall clock | the clock harness and the pixel bands |
| no premultiplied tag; calibration that never objects; the opaque-page rule reverted | the helper's file check; the broken-fast-path switch; the opaque page |
| memory budget ignored; SkyCut never kills; no-progress backstop off | the hog; the SIGKILL and bounded-run checks; the silent fake helper |
| teardown treating an unreadable process as gone | "WebKit processes ended" |
| no per-frame or load limit | the loops are stopped only by SkyCut's backstop after 24 s |
| empty frames, same t twice, page errors or frame entry not checked | the flicker, kept-state, error and no-entry pages are accepted |

Two of these were missed by the first version of the checks, and the fixes are why the checks look as they do: the network
page also navigated (a refused navigation stops the page's pending WebRTC and preconnects before they reach the network), and a
page rejected while loading was released at once (the linger window had no page left). `checks/web-motion-wiring.sh`: ten
sabotages (copy after signing, helper unsigned or not required, a `WKWebView` in SkyCut, an unlocked load, the WebRTC switch
dropped, a switch not read back, unguarded `fonts.ready`, a probe-tool clock name, a second configuration), each red with its
own message.

## 14. Manual regression (before a release)

- [ ] Packaged app: `Contents/Helpers/skycut-web-motion` exists, is arm64, signed with the pinned certificate
      (`codesign -d -r-`), and a render from the packaged app works.
- [ ] A downloaded (quarantined) app: the helper is not killed by the system (else the error carries the fix command).
- [ ] Real memory pressure on a spare Mac: a render under "critical" is stopped and SkyCut keeps running.
- [ ] A non-Retina display (backing scale 1) and a Retina one give the same frame hashes for the same page.
- [ ] A 4K, 60 s page: total time stays within its limit; SkyCut stays responsive.

## 15. Stored motion and the AI call (MCP-74, 2026-11-17)

`EditClip.webMotion` stores the HTML, canonical JSON parameters, editable field descriptions, duration, local hit, output geometry,
declared fonts and render provenance. This is project format v36: an older app must refuse rather than discard the only source for
rebuilding a missing movie. Splitting/copying retains the full source and local hit; replacing the source with imported media clears it.
The movie is absent from the imported-media/bookmark table. See [project files](video-edit-project-file.md).

`WebMotionCache` writes `SkyCut/Motion/motion-<SHA256>.mov` beside the project, plus optional HTML, parameter and check-receipt sidecars.
The key includes the page, sorted parameters, duration/hit, output geometry/fps, renderer version, OS/build, WebKit and declared/current
font-file identities. `MOTION_PARAMS.duration` and `MOTION_PARAMS.hit` are reserved and always match the source's timing controls.
A changed input gets a new file so undo still has the previous render. A cache hit needs the movie and an accepted six-check receipt.
Every caller reuses a hit, the inspector's Re-render included (same fingerprint, same frames); only checks that compare two real
renders pass `force`. Rendering a fingerprint again (a missing or failing receipt, or `force`) never removes the movie that clips,
undo or a Save As may be reading: the system identity is compared and the receipt written in `verify`, then the movie is renamed
over the old one. The cache folder's reads and writes (receipts, the install, sidecars) run only on `WebMotionCacheFiles.queue`,
never on the main thread or in the cooperative pool.
An untitled manual project uses a temporary directory until Save/Save As carries the movie beside the project.

A carried project-relative movie wins over its former absolute path. A different OS or missing original fonts produces a warning in
`get_timeline`; UI callers use the same warning helper. It does not replace a carried movie. Fixed page fonts and editable font parameters are separate
from historical render provenance. Only an explicit re-render/input edit or missing cache renders locally. Open and runtime revalidation
run `WebMotionRecovery`; recovery changes no undo history, retains trims/transforms, and cannot land in another document. Visible missing
motion makes export fail with a readiness message, rather than silently drop the picture.

One library (`MotionPresetLibrary`) lists native presets first, bundled official web designs next, and reusable project pages last.
AI discovery is `get_timeline.motion_library`: native entries use `set_text`, web entries use `set_motion`. Web ids are `official:<name>`
or `project:<clip UUID>`; the HTML comes from the bundled source or stored record, never from an arbitrary file URL. New custom pages
become reusable project entries as soon as their clip is committed.

`set_motion` takes a template id or full page, parameters/fields, optional `clip_id`, `at` or `hit_at`, local `hit`, duration, upper track,
name and fixed fonts. Parameter changes merge top-level values and re-render the same clip identity, retaining its cut, speed and effects.
The clip's length comes from the checked movie, including rounding a requested duration to whole frames; a 0.51 s request at 24 fps is
a 0.5 s source. Parameter edits keep the existing lane, including a hidden lane, whenever the new span fits; a collision on a hidden lane
is refused rather than making the picture visible. Reusing a template for a new clip adopts the destination canvas and project fps;
editing an existing clip retains its source geometry. Generated caches cannot enter cloud upscale or its source swap: re-render the page.
`hit_at` aligns the local source hit through the clip's trim and speed; a hit outside a trimmed source is refused. An expanded whole source
may move its hit into the new range. The default track is V2, with overlap lifted by the existing import landing rule. Hidden/removed
targets become a new upper track; the helper never lands on V1.

New AI-written pages ask once in request-approval mode using the existing confirmation protocol; full access proceeds. Approval binds the
complete resolved request and document generation. A stored page's parameter edits/template reuse need no further page approval. The
network lock is identical in both modes. No script runs or render job starts before approval. `AIMotionTool` owns an `AIJobs.motion` task;
after 25 s it returns the job id and finishes through `get_job`. The complete result includes clip id, render time, six checks and
`look_times`; failures preserve the helper's original text and checks. Cancellation or a changed document/clip cannot commit stale output.
Both AI and UI use `WebMotionActions`: asynchronous rendering, then one synchronous `AIUndoGrouping.step`/`perform` commit.

For an existing clip, both request creation and service preparation capture its source lane UUID and visibility
(`WebMotionSourceLane`). Compare that context before the queued task starts rendering and after rendering/probing, as well as
clip values and document generation. A vertical-only move or hidden-state edit must not be overwritten; a reorder
of the same lane is allowed. Existing destinations are captured by UUID before queuing and resolved to their current
visible index; a removed/hidden destination uses a new upper track. New/insert targets keep their positional policy.
A successful lane-only move still notes/saves the AI round and reports `before_round_version`; `unchanged` requires
both clip values and source-lane context to match. See [the regression case](../bugfixes/2026-11-17-web-motion-render-overwrites-track-edits.md).

`scripts/check-motion-placement.sh` links real App objects in its own bundle/defaults domain and drives the real helper with small synthetic
pages. It covers placement, template reuse, parameter edits, undo/redo, approval modes, error atomicity, system/font warnings, missing
cache recovery, over-long durations / frame rates (AI calls and a reopened project) refused before any job or render, and
same-fingerprint renders that keep the cached movie (reuse, a failed install, another system identity, a Save As mid-install). `checks/MCP/motion-wiring.sh` pins router, approval, jobs, generation guards, undo, discovery and recovery; it is sourced by
`check-mcp`, including scans-only. Renderer lockdown checks remain `scripts/check-web-motion.sh`.
The timeline drop wiring guard counts `WebMotionActions` as a separate, exactly-once consumer of `mediaImportLandings`, like the
AI importer; the file drop's preview and commit must still be its only two calls. No second landing calculation is permitted.

Reverse verification (2026-11-17): the initial 72 real placement assertions pass; bypassing the clip equality gate makes the stale-render
assertion fail (1/72), and bypassing page approval makes the approval/no-token group fail (2/46 before stopping). Both production edits
were restored and the full assertions passed again. Additional regressions: a parameter edit on a hidden lane failed before the fix
(1/74), and reverting movie-based source length failed both non-grid duration assertions (2/79); both were restored to green.
The first development harness run exposed mixed incremental App objects after a
model layout change; a clean rebuild of only the App target removed that failure. This is not evidence of a source or compiler fix.

Additional manual regression before release:

- [ ] Copy a project and its `SkyCut/Motion` folder to a second Mac: the carried movie plays unchanged and the OS/font warnings appear;
      edit a parameter, re-render, and check the new lettering over the shot.
- [ ] Delete only a cached movie while its project is open: recovery restores it without a relink prompt or an undo entry; exporting
      during recovery reports that the motion is not ready.
- [ ] Save As during a render, close/reopen the destination, and confirm the movie is carried beside that project; changing/closing the
      project during a render cannot add the result to another document.

The lookup ID selects a template; a nonempty `WebMotionClipRecord.templateID` retains the source's origin.
Both UI and AI project-template reuse keep an official origin, so unchanged default names/labels still follow the UI language.
A source with no origin receives the project lookup ID; explicit new page input constructs a fresh source. Custom names/labels
and values remain authored. See the [origin regression](../bugfixes/2026-11-18-official-template-origin-on-reuse.md).

## 16. UI draft and preview boundary (2026-11-17)

The unified preset panel and web parameter form are specified in [Motion presets](motion-presets.md).
A card displays the rendered movie; no preview page executes in the App. A user tap/drop captures its document
and requested start before creating a Task (`WebMotionPresetRequest`), rather than relying only on the service's
later capture. The editor captures the original clip and source-lane context; a stale draft or another document
is rejected before helper startup. Typing stays local until Re-render succeeds through `WebMotionActions`.
Installed fonts use the existing browser, and page diagnostics retain their original text. Showing the page only
writes the stored source/parameters through queued IO and reveals the HTML in Finder.
