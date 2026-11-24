# 2026-11-24 Review rounds: the baseline behind the risk-based policy

> On 2026-11-24 the user chose review rounds by risk ([Code review rounds](../testing/code-review.md)) and asked for a way
> to judge later whether it works. This report holds the numbers behind that choice, counted the way that doc counts, so the
> changes after it can be compared; the revisit point's tally is added here as a dated section.
> Sources: the coordinator's review reports CXU1, CXU2, CXI1–CXI3, its smoke reports SMK1, SMK1b, SMK2, SMK3 and the workers'
> reports UP1, IMG1–IMG3 (`impl-briefs/status/` on the coordinator's Mac, not in the repository); commit and merge times
> from GitHub. Times are UTC, on 2026-11-23 unless marked.

## 1. The changes

| Change | PRs | What | First commit → merge |
| --- | --- | --- | ---: |
| UP1 | SkyCut #549 | Retry an upload the network breaks; say plainly when it broke | 6.3 h |
| IMG1 | Sky Studio #262, SkyCut #550 | Publish each image model's reference-image limits; fit images to them before upload | 6.1 h, 6.7 h |
| IMG2 | Sky Studio #263 | A fal refusal ends the job with a refund; inline Seedream references for Flash and Pro; GPT Image 2's 25 MB | 1.2 h |
| IMG3 | SkyCut #551 | Share a model's total for all reference images among them | 9.2 h |

## 2. Findings per review round

Counted as [Code review rounds](../testing/code-review.md) section 4 says: one finding per point the reviewer asks to fix,
one severity each.

| Round | Change | Serious | User-visible | Edge | Guard | All |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| CXU1, first | #549 | 0 | 2 | 2 | 2 | 6 |
| CXI1, first | #262 + #550 | 2 | 2 | 2 | 1 | 7 |
| CXI2, first | #263 | 3 | 0 | 0 | 1 | 4 |
| CXI3, first | #551 | 0 | 2 | 5 | 0 | 7 |
| **First rounds** | | **5** | **6** | **9** | **4** | **24** |
| CXU2, fix round 2 | #549 | 0 | 1 | 3 | 1 | 5 |

- **Every serious finding came from a first round**: limits not enforced before charging (#262), the wrong aspect after
  fitting (#550), a partial refund that never happened, a refund stuck in review, and a web regression (all three #263).
- The brief that set the policy put the first rounds at "about 19 issues"; counted point by point they hold 20 defects and
  4 guard gaps.
- **The one second round** (CXU2, on #549's fixes) found 5 more: 1 user-visible (the "file too large" case had no
  upload-specific words) and 4 edge cases or guard gaps. None was serious.

The findings, as the reviews reported them:

- **CXU1 (#549)**
  1. Edge: a 403 whose error body stalled was retried, and the second PUT's 200 was taken as success.
  2. Edge: a certificate failure while re-signing was still retried, `upload_attempts` counted the re-signs as PUTs, and an
     address of unknown expiry was reused.
  3. User-visible: a certificate failure on the first PUT left an English task row, and a direct 403 sent the AI to query a
     job that was never submitted.
  4. User-visible: the official film's `prepare_references` put a dropped upload only in `get_job`; the task row vanished
     without a localized message.
  5. Guard: the checks covered only a complete 403 answer and a successful re-sign.
  6. Guard: the packaging guard stayed green without the refusal's `exit 1`, and the debug-hook check flaked once.
- **CXI1 (#262, #550)**
  1. Serious (#262): the generation entry checked a reference's URL, type and count but not the image, so in a local
     simulation a 30,000,001-byte PNG passed the checks for a Seedream job; the upscale endpoint's own limits were not all
     published.
  2. Edge (#262): a BMP that Seedream Flash accepts was transcoded anyway.
  3. Serious (#550): a 16:1 image over the byte limit came out at 16.0053 and failed the same validator.
  4. Edge (#550): the size measured for the quote was reused at upload, so a file changed in between was still sent as it
     was.
  5. User-visible (#550): the guide overstated the fitting (`fit_images`, fallbacks, the upscale exception), and a 15-image
     request with no model named no limit.
  6. Guard: the checks missed the server-side image test and the output-aspect boundary.
  7. User-visible (#550): a fitting failure reached the native task row in English.
- **CXI2 (#263)**
  1. Serious: a two-step Camera Angle plan refused at step 2 kept all 16 credits instead of refunding the unused 8.
  2. Serious: a fal 422 after one failed database read left 30 credits in `pending_review`.
  3. Serious: a web regression. With the inline budget spent, the code still read every reference, and one stalled storage
     read timed out Flash and Pro before any request reached Ark; main sent the request and succeeded.
  4. Guard: the tests missed the three failures above and two inline-budget boundaries.
- **CXI3 (#551)**
  1. Edge: a fallback model that publishes a total but omits `fit_images` was left out when the limits were combined.
  2. Edge: a set of ten PNGs that could fit was refused (the encode at a 512 px long side was taken as the smallest).
  3. Edge: images shrank more than needed (shares fixed before encoding, rounding at the pixel floor).
  4. Edge: a file replaced between two PUTs made the uploaded total exceed the limit.
  5. User-visible: the official film's `prepare_references` failure reached `get_job` only in English, and the task row
     vanished.
  6. User-visible: the guide promised each model's limit in the errors, and left out that a character's views count toward
     the server's total.
  7. Edge: a PNG replaced by a TIFF between PUTs went up labelled `image/png`, also for models without a total.
- **CXU2 (#549's fix round 2)**
  1. Edge: a 403 with only headers and a stalled body was still retried (the guard always sent 1 KiB of body first).
  2. Edge: a 307 or 308 redirect to a 403 sent two full PUTs and counted one.
  3. User-visible: a 413 from `/uploads`, or a ticket without an address, skipped the upload-specific words, and the
     official film's task row lost its issue on those paths.
  4. Guard: the wiring guard stayed green with the unsubmitted job's `next_step` removed.
  5. Edge: a debug-only fault hook busy-waited up to 5 s (about 5 CPU seconds) and swallowed the cancellation.

## 3. What the real smokes found

| Smoke | Ran on | Provider spend (cap) |
| --- | --- | --- |
| SMK1 | a debug build from SkyCut main with #549 and #550, Sky Studio production with #262 | about USD 0.24 (USD 3) |
| SMK1b | the same, Seedream reference sizes | at most USD 0.07 (USD 1) |
| SMK2 | the same build, Sky Studio production with #263 | at most about USD 0.26 (USD 2) |
| SMK3 | a debug build from SkyCut main with #551, Sky Studio production with #263 | about USD 0.02 (USD 1) |

Three things no review could have found, because they are facts of the live providers:

1. **fal's real per-file limit for GPT Image 2 is 25,000,000 bytes**, below the 31,457,280 that Sky Studio published, so
   every reference fitted to the published number failed at fal (SMK1). #263 publishes and enforces 25,000,000.
2. **Ark gives up downloading a reference from Sky Studio's storage after about 15–21 s**: 8 of 11 Seedream 5.0 Flash runs
   in 42 minutes timed out, at every size from 1.6 to 11.6 MB (SMK1, SMK1b). #263 sends them inline instead, up to 7 MiB
   in all.
3. **Inline Seedream requests are slow at some hours**: one 7.3 MB reference took 193–218 s on Flash in three runs and 112 s
   on Pro (SMK2); three references of 7.3 MB together took 23 s about two hours later (SMK3).

The smokes also found three things a review could in principle have caught, none of them a serious issue in these changes'
own code:

- SMK1: Sky Studio held a definite fal 422 as `provider_uncertain`, keeping 30 test credits in review although fal billed
  nothing. The code is older than these PRs; #263 fixed it, and CXI2 found the gap left in that fix (finding 2).
- SMK2: a `/jobs` refusal with nothing charged got the generic next step; #551 made that path rare.
- SMK3: the first reply for a set that could not fit announced an 8-credit reservation that was never made (minor, in the
  coordinator's backlog).

## 4. Time per round

"Head" is the commit time of the round's last commit (GitHub); "brief" and "verdict" are the creation times of the review's
brief and report files on the coordinator's Mac. "Not recorded": no Codex review, and the reports do not say who read the
diff.

| Change | Round | Checked by | Head | Brief | Verdict | Next push or merge | Hours |
| --- | --- | --- | --- | --- | --- | --- | ---: |
| #549 | 1, first | Codex CXU1 | 07:52 | 08:23 | 08:39 | 09:16 | 1.4 |
| #549 | 2, fix | Codex CXU2 | 09:16 | 12:00 | 12:17 | 12:48 | 3.5 |
| #549 | 3, fix | coordinator | 12:48 | – | – | a follow-up 13:24, merged 14:07 | 1.3 |
| #262 | 1, first | Codex CXI1 | 07:38 | 12:02 | 12:18 | 12:43 | 5.1 |
| #262 | 2, fix | not recorded | 12:43 | – | – | merged 13:42 | 1.0 |
| #550 | 1, first | Codex CXI1 | 08:17 | 12:02 | 12:18 | 13:08 | 4.8 |
| #550 | 2, fix | not recorded | 13:08 | – | – | main merged in and a follow-up 14:09, merged 14:39 | 1.5 |
| #263 | 1, first | Codex CXI2 | 16:17 | 16:30 | 16:44 | 17:16 | 1.0 |
| #263 | 2, fix | not recorded | 17:16 | – | – | merged 17:29 | 0.2 |
| #551 | 1, first | Codex CXI3 | 17:19 | 17:49 | 18:05 | 01:40 (11-24) | 8.3 |
| #551 | 2, fix | coordinator | 01:40 (11-24) | – | – | merged 02:04 (11-24) | 0.4 |

- **Codex's own review took 13–16 minutes every time**, from its brief to its report (CXI1's report was still edited
  until 19 minutes).
- **Most of a reviewed round's hours were around the review**: from the round's head to the review's brief took 13 minutes
  to 4.4 hours, and the fix after the verdict 25–50 minutes, once 7.6 hours (#551's fix waited overnight for two of the
  user's decisions).
- **CXU2's round took 3.5 hours**: 2.7 waiting for the review to start, 16 minutes of review, 31 minutes of fixing.
- **The rounds without a Codex review took 0.2–1.5 hours** from their head to the merge, CI and the merge slot included.

## 5. What the policy changes against this baseline

- **#549's round 2** changed upload retries, their messages, the packaging refusal and checks. Under the policy it would
  most likely have been a coordinator read instead of CXU2, whose 5 findings included nothing serious.
- **#262's round 2** (each reference checked before a slot, reservation or charge) and **#263's round 2** (a partly refused
  plan keeps the share of the calls used and refunds the rest) touched money. Under the policy each gets a second Codex
  review; here both merged without one, 1.0 and 0.2 hours after the fix.
- **#549's round 3, #550's round 2 and #551's round 2** touched neither money nor data. The policy leaves them to the
  coordinator, who read #549's and #551's (UP1, IMG3).
- **Later findings so far (2026-11-24)**: none is a money or data issue in these changes' own code. The one money issue
  the smokes found, the held fal 422, was in older Sky Studio code.
