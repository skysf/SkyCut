# 2026-11-17 `look` silently took minutes, the calls behind it were dropped and its result was lost

## Symptom

From the production feedback (to-do item MCP-1, high priority), seen by both AI teams that cut the South Pole trailers on 2026-11-13
and again by the web-motion probe on 2026-11-16:

- Team A sent two 12-frame timeline looks in parallel on its project. Both went past 120 s. One came back "SkyCut did not get to this
  call within 2 min (calls before it were still running …). It was dropped and will not run", the other "SkyCut is still working on this
  call after 2 min (it is busy, not frozen). It may still finish", and its result never arrived. A later 4-frame look was queued for
  2 minutes and dropped too. Single-frame looks returned in seconds and `get_status` answered at once the whole time.
- Team B (a background project, 12 frames on a 0.81× `fit=fill focus=center` clip): "still working after 2 min"; a later 4-frame look
  was dropped after another 2 minutes; later the same frames came back in seconds.
- The web-motion probe (machine load 25–150 on 8 cores, about 10 GB of swap): a look took 0.5–2 minutes; of two looks sent at once,
  the second was dropped.

Each team lost 4–6 minutes, could not tell a hang from a queue, and could not cancel.

## Root cause

Reproduced on 2026-11-17 with an isolated test App (`scripts/gui-smoke/sky-studio/run.sh` with its own bundle id and port, a fake
Sky Studio) driven by the real `skycut-mcp` helper: two AI sessions, each with a 61 s project of 34 clips cut from one-keyframe 1080p
files (like the generated footage: of five practice files probed, three have a single keyframe in 5–6.5 s), one clip slowed to 0.81×
with `fit=fill focus=center`. Phase timings came from temporary probes in the App (not committed).

1. **A look held its project's line until its last frame was rendered.** The router serializes every call that touches a project in
   one line (`project:<id>`), reads included (so that a look sent after an edit sees the edit). A second look sent in parallel by the
   same session therefore waited for the whole first look: its queue wait was 4.77 s, exactly the first look's running time, and it
   answered after 8.2 s instead of 4.8 s. Any edit sent after a look waited the same way.
2. **The helper stops waiting after 120 s, whatever the call** (`MCPCallWait.giveUpAfter`, built for a frozen App). A call still waiting
   in its line is then dropped and never runs; a call already running keeps running in the App, but its answer is written into a
   closed connection and is lost. For a look, "it may still finish … check with get_timeline" is no help: a look changes nothing, its
   picture is simply gone. Reproduced with the helper's give-up shortened to 6 s (`SRTFLOW_MCP_GIVE_UP_SECONDS`): of two parallel
   12-frame looks, the second was told "still working on this call after 6 s … It may still finish"; the App finished it at 7.7 s and
   its answer went nowhere.
3. **Two sessions' reads never queued behind each other in the router**, contrary to both teams' guess: different projects are
   different lines (measured queue wait: 0 ms). They do share the decoder, GPU and CPU: two sessions' 12-frame looks at the same moment
   took 6.6 s each instead of 4 s.
4. **Where the time goes.** On this Mac at load 6–14, a 12-frame timeline look took about 4 s: decoding each requested frame from the
   clip's only keyframe, 150–400 ms per frame (most of it); Vision, 50–150 ms per frame; building and validating the composition,
   4–35 ms; waiting for `MediaReadQueue.analysis`, 0 ms. All of it scales with the load: when other sessions' builds pushed the load to
   55–80 during this investigation, the same 12-frame look took 20 s. The teams' 2–4 minute looks were this work slowed further by two AI
   teams (and their exports and inspections) in one App on a busy Mac. That part is inferred, not reproduced: the stall log starts on
   2026-11-16 and the unified log has nothing left from 2026-11-13.

Together: a slow (not frozen) look held its project's line, the calls behind it reached the helper's fixed 120 s and were dropped, the
look itself reached 120 s and its result was lost, and nothing told the AI whether a call was queued or running or let it cancel one.

## Fix

- **The router's lines** (`AICallLines`, new) replace its queue tails: the same lines and order, and two more things: a call can let its
  line go before it is done, and for a waiting call the lines tell its position and which call holds the line.
- **A look lets its line go once it has read the project** (`AICallLines.letGo()` in `AILookTool` for the timeline and a file,
  `AILookFiles`, `AILookText`, each after its last read of the project and before its first await): looks no longer wait for each other
  and edits sent after a look do not wait for its frames. `shots=true` keeps the line (`AILookShots` reads the project at its end).
- **A look not done within 25 s becomes a job** (`AILookCall`, new; the router sends `look` through it): done in time, the answer is
  exactly as before; otherwise the call answers with `job_id` and status `running`, or `queued` with `queue_position` and `waiting_for`
  (for example "edit_clips from this AI session, running for 26 s"), and the look goes on. Its answer becomes the job's `result` and
  get_job brings the picture (`AIJobs` kind `look`; `Job.inLine` feeds the queued fields to get_job and get_status). cancel_job or the
  user's Stop: still queued, it never starts; running, its task is cancelled and the look stops at the next frame
  (`Task.checkCancellation()` in `AIFrameComposer` and the look loops). Another session cannot cancel it.
- The sidebar row says "Waiting in line" for a queued look job. The look card says "Slow looks return job_id" (same length: the tool
  catalog does not grow); the guide's `look` topic has a new `slow_looks` section and the get_job / cancel_job topics a sentence each.

The lasting rules are in [AI interface (MCP)](../architecture/ai-control-mcp.md) section 4, items 3 and 12.

## Verification

- `scripts/check-look-jobs.sh` (new, real App objects, synthetic one-keyframe clips): the lines keep joining order across several lines,
  let a read go early, report positions and the holder, and ignore a let-go before the turn; two sessions each send two 12-frame looks
  at once and every one answers within 25 s with its picture or with a job whose get_job brings it, none dropped; a look behind an edit
  becomes a queued job (positions 1 and 2, `waiting_for` names the edit), runs after it and get_job returns its 12 frames and picture;
  cancelled while queued it never starts; cancelled while running it stops; another session cannot cancel it; an edit behind a look
  gets its turn before the look's frames are done.
- `checks/MCP/router-wiring.sh`: the router sends `look` through `AILookCall` after joining its lines, the lines replace the old tails,
  and each way of looking lets go only after its last read of the project (shots never).
- Real App and helper after the fix (same isolated App, two sessions): four 12-frame looks at once (two per session) all answered with
  their pictures in 11.4–11.8 s at load 8–13; an edit sent right after a look returned in 0.0 s while the look took 5.1 s; two looks
  sent behind a 60 s `edit_clips` (`fit=fill` on 34 clips) answered at 25.5–25.7 s as queued jobs (positions 1 and 2,
  "edit_clips from this AI session, running for 26 s"); `cancel_job` on the second answered "Cancelled while waiting in line; this look
  never started" and it stayed cancelled; get_job on the first came back done with its 12 frames and the picture.
- Reverse verification (2026-11-17, each breakage on its own or as listed, the real guard run, then the fix restored and the guard green
  again):

  | Temporarily broken | Red |
  | --- | --- |
  | timeline look without `AICallLines.letGo()` | `check-look-jobs`: the edit behind the look waited for its frames; `check-mcp --scans-only` exit 1 (no let-go before the first await) |
  | the let-go moved after the frames are composed | `check-mcp --scans-only` exit 1 |
  | the router sends look through the plain queue (`if call.tool == .look && false`) | `check-mcp --scans-only` exit 1 (look must go through AILookCall) |
  | `text_scan` reads `project.state` after letting go | `check-mcp --scans-only` exit 1 |
  | `AILookShots` lets go | `check-mcp --scans-only` exit 1 (shots keeps the line) |
  | get_job's queued branch for look jobs removed (`AIJobs.json`) | `check-look-jobs`: 4 failures (status, positions 1 and 2, waiting_for, get_job while queued) |
  | cancelling a running look no longer cancels its task | `check-look-jobs`: the look did not stop (cancelled 0, finished 1) |
  | the gate lets a cancelled queued look start | `check-look-jobs`: the cancelled look started |
  | no job at all: the call waits for the look however long it takes | `check-look-jobs` never ends: the look behind the held edit never answers, the 240 s watchdog stops it, exit 1 |

  The `check-look-jobs` breakages of rows 1, 6, 7 and 8 ran together in one build (each failure names its own case; 7 failures, exit 1);
  the last row is a build of its own. The scan rows each ran on their own. Before the fix, `scripts/check-look-jobs.sh` does not compile (`AICallLines`, `AILookCall` are new), so the table is
  the evidence that each assertion depends on the fix.

## Lessons

- A line that holds readers until they are done turns "slow" into "dropped": a read lets go once it has taken what it needs from the
  project.
- The helper's 120 s is a wall for every call. Work that can take longer must hand over a job id well before it (export, shots and
  inspect_video already did; look now does).
- "It may still finish" only helps a call whose effect can be checked afterwards; a read's result has to be kept somewhere the AI can
  fetch it.
- When a fault cannot be reproduced at full size (here: the load of two teams on 2026-11-13), reproduce the mechanism at small size
  (a shortened give-up) and measure where the time goes, so the fix does not depend on the guess.
