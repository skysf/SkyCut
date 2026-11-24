# Reference-image fitting (generate_media)

> Long-term constraints since 2026-11-23. The user asked that SkyCut compress an uploaded reference image, by exactly as much
> as the chosen image model's own limit requires and no more. SkyCut reads those limits from Sky Studio and fits an image
> only when it is over them. Since 2026-11-24 a model can also limit all the reference images of a request together, and
> SkyCut shares that total among them (section 3).
> Not here: video, audio and document references (uploaded as they are); character photos (`SkyStudioCharacterWorkflow`,
> its own limits); the upload's retries (`SkyStudioAPI.upload`); prices ([Sky Studio jobs](sky-studio-jobs.md)).

## 1. Where the limits come from

- **Only from Sky Studio's `GET /models`, live.** Each image record's `limits.references` (background removal: its flat
  `limits`) carries `max_images`, `max_image_bytes`, `image_mime_types` and, where the provider documents them,
  `max_image_pixels`, `image_dimensions.min_side` / `max_side` and `min_image_aspect_ratio` / `max_image_aspect_ratio`;
  where Sky Studio's path to the provider has a budget for the whole request, also `max_total_image_bytes` (Sky Studio PR
  #263: Seedream 5.0 Flash and Pro, 7,340,032 bytes for each image and for all of them, the budget for sending them to Ark
  inline). `fit_images: true` is the switch that lets SkyCut fit an image to them.
- **SkyCut writes none of these numbers.** A change on Sky Studio reaches every SkyCut, and every user's AI, without a
  SkyCut release. The one number the fitting code writes is SkyCut's own floor for sharing a total (section 3), a rule for a
  useful reference, not a model's limit. Sky Studio keeps the per-model table with each number's official source and the
  date it was read in its own repository, at `docs/agents/skycut-reference-image-limits.md`, next to the constants in
  `shared/skycutReferenceImageLimits.ts`; its contract test fails when the two disagree.
- **The AI reads the same numbers.** `get_status models=true` passes the records through unchanged (count, formats, bytes,
  the total, pixels, `fit_images`). The generate_media guide's `inputs` section says that SkyCut fits images only where a
  record says `fit_images`, that a fallback can tighten the limits, that a total is shared with the largest images made
  smaller first, that an image-upscale source is never shrunk, and what is still refused. There is no separate tool for this.
- **Sky Studio enforces them too.** Its `/jobs` reads every reference of an image job and refuses one over a limit, or a set
  over the total (`too_large_together`), with `invalid_request`, `reason`, `reference`, `limit`, before any slot, reservation
  or charge, so a client that does not fit (or an older SkyCut) gets a clear refusal instead of a provider failure.

## 2. When SkyCut fits an image, and how far

1. **The target is the strictest limits of the chosen model and its fallbacks.** The fallbacks are the models after the chosen
   one in SkyCut's automatic order (`SkyStudioModelPolicy.ordered`) that take the same request
   (`SkyStudioModelPolicy.chain`). They exist only when the AI names no model for an ordinary generation, so a named model or
   an image operation has none. With Nano Banana 2 chosen and Seedream 5.0 Flash after it, an image is fitted to Seedream's
   7,340,032 bytes and 36,000,000 pixels, and the set to its total (section 3). An upload made for one model therefore also
   suits the next default; official prepared references are reused across a change of model. Fitting is the chosen model's
   switch (`fit_images` on the first record; without it, uploads stay as before), but every model of the chain that publishes
   reference limits bounds the copy, `fit_images` or not (`SkyStudioReferenceFit(limitsOf:)`): a fallback that took the
   original must take the copy too (Codex review of #551: a fallback without `fit_images` was left out, and a 368,991-byte
   JPEG went up as a 3,119,736-byte PNG over its 1,000,000).
2. **An image that meets every limit goes up untouched**: the same bytes, EXIF and all, from its snapshot (item 5).
3. **Otherwise convert, re-encode and downscale, only as far as needed:**
   - A format some model of the chain does not take (HEIC, HEIF, TIFF, a still GIF; BMP, which no record lists since Sky
     Studio PR #263 sends Seedream's references inline) becomes PNG when it has transparency and PNG is taken, otherwise
     JPEG. A JPEG stays JPEG and a PNG stays PNG while the models take them, so a PNG keeps its alpha. A WebP over a limit
     becomes JPEG or PNG: ImageIO writes no WebP.
   - The copy has an exact integer size (`SkyStudioReferenceFit.size`): the long side rounded down, the short side rounded
     to keep the shape, then nudged a pixel so the final width / height stays inside the aspect range (a 16:1 picture never
     becomes 16.005:1) and every pixel limit holds. Over the pixel or side limit it is scaled to just under it. Never
     upscaled.
   - Over the byte limit: a JPEG first tries quality 0.92, 0.86 and 0.80 at that size; then the largest size that fits is
     searched (an estimate from √(limit / size), then halving the gap to within 1 %), so the copy keeps as much resolution as
     the limit allows. A PNG only changes size.
   - The EXIF orientation is applied to the pixels and the colour profile (ICC) is kept. The copy carries no other
     metadata (no GPS).
4. **Refused, and the error names the limit:** too many images (with no model named, the error lists each model's own
   limit, `SkyStudioModelPolicy.refusal`); a side below the minimum (SkyCut never upscales); an aspect outside the range
   (SkyCut does not crop); an animated GIF, PNG or WebP that would need converting; a byte limit that only a side below the
   minimum would meet. A HEIC or TIFF holding several images is fitted from its first image. A refusal at upload time is a
   `SkyStudioReferenceFitFailure`: get_job gets its English, the cloud task row the user's words
   (`SkyStudioReferenceFitWords`, localized: `status.issue` is drawn verbatim).
5. **What was checked is what goes up.** Before an image is measured it is copied as it is (a snapshot, alone in a folder
   of its own so it keeps the file's name; APFS clones it), and the measurement, the decision, any copy and the upload all use
   that snapshot, never the user's path again. The plan was measured before the quote, so a path rewritten in between is
   judged (and fitted) as it is at preparation, and one that is no longer an image is refused; a path rewritten during
   preparation or upload changes nothing (Codex review of #551: a file replaced after the first PUT sent 8,110,710 bytes over
   a 7,340,032 total, and a TIFF went up labelled image/png).
6. **An older Sky Studio** (no `fit_images`): uploads as before, and the old local refusals over a limit stand.
7. **Never fitted:** the source of an image upscale (its record has no `fit_images`: a client must never shrink what it asks
   to enlarge), and every non-image reference.

## 3. A total for all the images (since 2026-11-24)

1. **Which total.** `max_total_image_bytes` when a record publishes it; absent means no total, as before. Like every other
   limit it is the strictest of the chosen model and its fallbacks (`SkyStudioReferenceFit.strictest`). It counts the image
   references of one request: `image` and `reference_images`, not videos, audio or documents.
2. **Each image first meets its own limits** (section 2). If the uploads then pass the total together, SkyCut decides with
   **real encoded sizes**, measured again after every step, and stops as soon as the set fits (`SkyStudioReferenceTotal.share`
   with `SkyStudioReferenceSetImage`; Codex review of #551: a cap split before encoding shrank a PNG the JPEG's real re-encode
   had already made room for, and the 512 px copy taken as an image's smallest refused a set that fitted at full size):
   - **Full size first.** The largest image takes its next full-size step: a PNG written again (no pixel lost; once, and only
     while its upload is the user's own bytes), or a JPEG's next lower quality (0.92, 0.86, 0.8, after whatever its own
     fitting already used). A step is kept only when it is smaller.
   - **Then sizes.** The largest image that can still shrink comes down to the common cap, the largest c with Σ min(size, c)
     within what is left (`SkyStudioReferenceTotal.level`), as large as c allows (the byte search of section 2 at quality
     0.8), and the cap is computed again from the new sizes.
   - Every copy is made **from the snapshot** (one lossy step, not a copy of a copy). An image never asked to step goes up as
     it was (its snapshot, or its copy for its own limits), byte-identical. JPEG stays JPEG and PNG stays PNG with its alpha
     unless a model refuses the format; the shape and orientation are kept; nothing is upscaled.
3. **SkyCut's floor** (user, 2026-11-24: keep it). A copy made for the total keeps a long side of at least 512 px, exactly
   (half a pixel over in the scale, so rounding never lands on 511; an image already smaller keeps its size), and JPEG
   quality 0.8 (`SkyStudioReferenceTotal.floorEdge`, `SkyStudioReferenceImageFit.floorScale`). Below it a reference loses most
   of its detail, so SkyCut refuses rather than go there; it is SkyCut's own quality rule, not a model limit. An image whose
   floor copy is still over the cap keeps whichever of its copies is smallest (a PNG at its floor can be larger than at full
   size) and comes down no further; the others share what is left. The byte search tries the floor itself last, so a cap the
   floor copy fits is always met.
4. **A set that cannot be met is refused before anything is uploaded**: when nothing can come down any more and the set is
   still over, a `SkyStudioReferenceFitFailure` with `tooLargeTogether` names the combined limit, the floor and the files
   (get_job: English; the task row: `SkyStudioReferenceFitWords`, localized). Nothing was sent or charged. The official
   preparation (`prepare_references=true`) keeps its row in the same words and gives get_job a next step
   (`SkyStudioReferenceFitFailure.preparedNextStep`).
5. **All references are prepared before the first upload** (`SkyStudioReferenceImageFit.prepare` with the plan's files):
   the set is only known whole. Every snapshot and copy is removed after the upload, and when preparing stops (a refusal, a
   cancel), the ones already made are removed too.
6. **The tool's answer says so first.** When the measured images look over the total (an estimate: a copy's exact size is
   known only once written), `notes` gets a line with the total, the floor and that the originals stay unchanged.
7. **Without `fit_images`** a record's total is checked like its other limits: a set whose measured images pass it is
   refused at the reference check (`SkyStudioReferencePlan.problem`).
8. **A character's views count too.** Sky Studio adds a character's views to the request's references, and `/jobs` counts
   them toward the total; SkyCut cannot shrink them and does not know their bytes, so it shares the total among the user's
   own images only (user, 2026-11-24: it stays so; the generate_media guide says it). A Seedream request with a character and
   large images can still be refused by `/jobs` (`too_large_together`), before any charge: the task row then shows the
   localized line with Sky Studio's `limit`, and get_job a next step that says nothing was submitted or charged and what to
   change (fewer or smaller images, fewer character views, another model), instead of the generic "query this original job"
   (`SkyStudioJobFailure.limit`, `SkyStudioReferenceFitFailure.togetherNextStep`).

## 4. Where it happens

| Piece | Does |
| --- | --- |
| `SkyStudioReferenceFit` | Pure: reads a record's limits (only with `fit_images`), merges a chain's into the strictest, decides per image (as it is / fit / refuse), the exact size of a copy, the byte search with its floor, the notes |
| `SkyStudioReferenceTotal` | Pure: how a set shares a total by real sizes (full-size steps, then sizes to the common cap, largest first; false for a set that cannot be met) and SkyCut's floor |
| `SkyStudioReferenceSetImage` | One image of the set for the total: its full-size steps and its shrink to a cap, encoded for real from its snapshot; keeps a copy only when smaller |
| `SkyStudioReferenceFitFailure`, `SkyStudioReferenceFitWords` | A refusal with its file, models and limit: the AI's English, and the user's words for the task row |
| `SkyStudioModelPolicy.chain`, `.refusal` | The chosen model and its fallbacks, from the same test the choice used; when no model takes the request, each model's own reason |
| `SkyStudioReferencePlan.fit` | Carries the target from the model choice (both generate tools) to the upload |
| `SkyStudioReferencePlan.problem` | On a `fit_images` model, refuses only what fitting cannot fix; other models are checked as before |
| `SkyStudioReferenceImageFit.prepare` | The files to upload for a set: a snapshot of each image, measured, uploaded as it is or replaced by a fitted copy, all in a temporary folder that the caller empties after the upload; then `shareTotal` for a total. The decoding runs on `MediaReadQueue.analysis` ([blocking media reads](blocking-media-reads.md)) |
| `SkyStudioReferenceFiles.upload` | Prepares every reference of the request, then uploads each with `SkyStudioAPI.upload` |
| `SkyStudioOfficialPreparation.sources` | The target is part of the prepared references' identity: a token prepared under other limits is refused ("prepare again") |
| `SkyStudioGenerateTool` | The answer's `notes` name each image that will be fitted and why, so the AI can tell the user before delivery |

## 5. Checks

- `scripts/check-sky-studio.sh`, `ReferenceFitChecks` (pure) and `ReferenceImageFitChecks` (real files written with ImageIO,
  each just above and just below its limit): which limits apply (also on Sky Studio's own records, a fixture of #263's
  catalog: `checks/SkyStudio/Fixtures/models-reference-images-2026-11-24.json`, the records of #262 with each
  `limits.references` from #263's `skycutReferenceImageCatalogLimits`), the strictest of a chain, at / over each limit, the
  refusals and their words, the chain, the exact size (16:1 stays 16:1, one row over 36 MP lands just under), the reference
  check, the refusal that lists each model's limit, the note; the copy's bytes, size, format, alpha, upright orientation and
  P3 profile; a 16:1 PNG over its byte limit stays 16:1 and loses no more width than the limit needs; a file rewritten after
  the quote is measured again; nothing upscaled; the copy removed; the PUT to the fake Sky Studio carries the fitted bytes.
- `ReferenceTotalChecks` (the total, pure): the record's total read, absent, the smaller of two, part of the identity, shown
  to the AI as published; every model of the chain bounding the copy (a fallback without `fit_images`; fitting the chosen
  model's switch; a JPEG turned into PNG only because a model refuses JPEG); the exact floor (561 × 480 at 512 × 438); the
  common cap; sharing with synthetic images: nothing asked within the total, the largest's full-size step first and nothing
  else once the set fits, ten PNGs that fit once one is written again at full size (8,625 bytes against 86,493 at its floor),
  a larger rewrite dropped, two equal images sharing equally, one held at its floor, an animation that cannot come down, a
  set that cannot be met; the byte search's floor; the note; the reference check with and without `fit_images`; the refusal,
  the official preparation's next step, a `/jobs` `too_large_together` refusal's `limit` and next step, and the guide's
  clause.
- `ReferenceTotalImageChecks` (the total, real files): one image over the total alone, exactly at it; a JPEG whose quality
  step makes the set fit while the PNG beside it goes up byte-identical; a PNG saved without filters written again at full
  size (no pixel lost) while the other PNG stays byte-identical; three whose sum is over (the small one byte-identical, the
  set within the total, alpha and shape kept, nothing under a 512 px long side, the large photo's own-limit copy replaced and
  removed, the originals unchanged); an image held at its floor at exactly 512 × 438 while the other pays; a set that cannot
  be met (refused with the combined limit and the user's file names, nothing left behind); a fallback without `fit_images`
  bounding a JPEG converted for a PNG-only model; a quality step that comes out larger not kept; a file replaced (larger,
  then by a TIFF) after the check and after the first PUT, whose upload is still the checked bytes, labelled as checked, the
  PUTs within the total; a refusal mid-set removing the snapshot and copy already made; no total, a stable copy.
- `checks/sky-studio-wiring/reference-fit.sh`: every reference goes through `prepare` before the upload, the whole set before
  the first upload and never one file alone; each image is copied (a snapshot) before it is measured and measured from it,
  never from the user's path; a set with a total goes through `SkyStudioReferenceTotal.share` with real copies; both generate
  tools set the chain's target and list each model's reason when none takes the request; the official sources carry the
  target; a fitting failure reaches the task row in the user's words, in the official preparation too (with its next step); a
  `/jobs` `too_large_together` refusal gets the user's words and its own next step; no limit number is written in SkyCut's
  fitting code (`SkyStudioReferenceTotal` and `SkyStudioReferenceSetImage` included).
- Reverse checks (2026-11-23), each turning its check red: the decision without the byte limit, the merge taking the looser
  limit, the chain ignoring `accepts`, a PNG turned into JPEG, the orientation not applied, a plan asking for 1.5× (an
  upscale), the reference check refusing an oversize image on a `fit_images` model, `prepare` handing back the original of a
  file it should convert, the size without its aspect nudge, the byte search without its refinement (and the old step-down
  estimate of √(limit / size) × 0.97 capped at 0.95 without it), `prepare` without the second measurement, the refusal
  without each model's reason; in the wiring guard, the upload sending `file.file`, a target
  built without the chain, a limit number written into `SkyStudioReferenceFit` and the task row left in English. ImageIO's
  thumbnail never makes a copy larger than its source; the TIFF check pins the size of a converted-only image.
- Reverse checks for the total (2026-11-24, and again after the Codex review of #551), each turning its check red: the chain
  dropping the total, taking the looser one or leaving out a fallback without `fit_images`; fitting not the chosen model's
  switch; the record's total not read; the identity without the total; the set skipping the total pass; no full-size stage,
  or full-size steps the smallest first; one cap split up front and not measured again; a larger step kept; no lossless PNG
  step; the floor not exact (511 × 437); the byte search not clamped to its floor, or never trying the floor last; an image
  that fits uploaded from the user's path; unused snapshots, a replaced own-limit copy or a refused set's copies left behind;
  a `/jobs` refusal's `limit` not read, or its next step without "nothing was submitted or charged"; the guide without the
  combined limit; the reference check ignoring a total without `fit_images`; the note without its total line; in the wiring
  guard, the upload preparing each file alone, the set without its total pass, an image measured from the user's path, the
  official preparation without its row, the run without its `too_large_together` next step, and a limit number in
  `SkyStudioReferenceTotal`.

## 6. Manual regression (before a release, with the user's approval: it spends credits)

- With a real key, generate an image with no model named from a 40 MB PNG photo and from an iPhone HEIC. The upload is at
  most 7,340,032 bytes (Seedream's limit, the default chain's strictest) and a JPEG or PNG, the answer's `notes` say so, and
  the result keeps the photo's orientation and colours.
- The same with `model: nano2` and a 20 MB JPEG: nothing is fitted (under Nano Banana 2's 30 MiB).
- `model: seedream5-flash` with three 5 MB JPEG photos and a small PNG logo: the uploads together are at most 7,340,032
  bytes, the logo goes up unchanged, the `notes` say the set is shared, and the job is not refused with
  `too_large_together`.
- The same with a character (`character_id`) and images close to the total: if `/jobs` refuses `too_large_together` (the
  character's views count there), the task row shows the localized line with the limit and get_job's next step says nothing
  was submitted or charged and what to change.
