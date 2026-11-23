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
   suits the next default; official prepared references are reused across a change of model.
2. **An image that meets every limit goes up untouched**: the same file, EXIF and all.
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
5. **Measured again at upload time.** The plan was measured before the quote; `prepare` reads the file's size and header
   again, so a path rewritten in between is judged (and fitted) as it is now, and one that is no longer an image is refused.
6. **An older Sky Studio** (no `fit_images`): uploads as before, and the old local refusals over a limit stand.
7. **Never fitted:** the source of an image upscale (its record has no `fit_images`: a client must never shrink what it asks
   to enlarge), and every non-image reference.

## 3. A total for all the images (since 2026-11-24)

1. **Which total.** `max_total_image_bytes` when a record publishes it; absent means no total, as before. Like every other
   limit it is the strictest of the chosen model and its fallbacks (`SkyStudioReferenceFit.strictest`). It counts the image
   references of one request: `image` and `reference_images`, not videos, audio or documents.
2. **Each image first meets its own limits** (section 2). If the uploads then pass the total together, SkyCut finds one
   common cap: the largest with Σ min(size, cap) within the total (`SkyStudioReferenceTotal.level`). Every image over the cap
   is written again **from its original** (one lossy step, not a copy of a copy), as large as the cap allows, with the same
   steps as section 2 (JPEG quality 0.92, 0.86, 0.8, then the largest size within 1 %). Every image at or under the cap goes
   up as it was: the original file, or its copy for its own limits, byte-identical. So the largest come down first, and only
   as far as the set needs. JPEG stays JPEG, PNG stays PNG with its alpha, the shape and orientation are kept, nothing is
   upscaled.
3. **SkyCut's floor.** A copy made for the total keeps a long side of at least 512 px (an image already smaller keeps its
   size) and JPEG quality 0.8 (`SkyStudioReferenceTotal.floorEdge`, `SkyStudioReferenceImageFit.floorScale`). Below it a
   reference loses most of its detail, so SkyCut refuses rather than go there; it is SkyCut's own quality rule, not a model
   limit. An image whose smallest allowed copy is still over the cap is held at that copy (or as it is when that copy would
   not be smaller: an animation, a PNG already under 512 px), and the others share what is left
   (`SkyStudioReferenceTotal.share`; each pass holds at least one more image, so at most one pass per image). The smallest
   copy is decoded and resampled exactly as the byte search does it, and the search tries the floor itself last, so a cap
   the floor copy fits is always met.
4. **A set that cannot be met is refused before anything is uploaded**: when the held copies alone pass the total, a
   `SkyStudioReferenceFitFailure` with `tooLargeTogether` names the total, the floor and the files (get_job: English; the
   task row: `SkyStudioReferenceFitWords`, localized). Nothing was sent or charged. The AI tells the user to send fewer or
   smaller images.
5. **All references are prepared before the first upload** (`SkyStudioReferenceImageFit.prepare` with the plan's files):
   the set is only known whole. Every copy is removed after the upload, and when preparing stops (a refusal, a cancel), the
   copies already made are removed too.
6. **The tool's answer says so first.** When the measured images look over the total (an estimate: a copy's exact size is
   known only once written), `notes` gets a line with the total, the floor and that the originals stay unchanged.
7. **Without `fit_images`** a record's total is checked like its other limits: a set whose measured images pass it is
   refused at the reference check (`SkyStudioReferencePlan.problem`).
8. **A character's views count too.** Sky Studio adds a character's views to the request's references, and `/jobs` counts
   them toward the total; SkyCut cannot shrink them and does not know their bytes, so it shares the total among the user's
   own images only. A Seedream request with a character and large images can still be refused by `/jobs`
   (`too_large_together`), before any charge.

## 4. Where it happens

| Piece | Does |
| --- | --- |
| `SkyStudioReferenceFit` | Pure: reads a record's limits (only with `fit_images`), merges a chain's into the strictest, decides per image (as it is / fit / refuse), the exact size of a copy, the byte search with its floor, the notes |
| `SkyStudioReferenceTotal` | Pure: how a set shares a total (the common cap, the images held at their smallest copy, or nil for a set that cannot be met) and SkyCut's floor |
| `SkyStudioReferenceFitFailure`, `SkyStudioReferenceFitWords` | A refusal with its file, models and limit: the AI's English, and the user's words for the task row |
| `SkyStudioModelPolicy.chain`, `.refusal` | The chosen model and its fallbacks, from the same test the choice used; when no model takes the request, each model's own reason |
| `SkyStudioReferencePlan.fit` | Carries the target from the model choice (both generate tools) to the upload |
| `SkyStudioReferencePlan.problem` | On a `fit_images` model, refuses only what fitting cannot fix; other models are checked as before |
| `SkyStudioReferenceImageFit.prepare` | The files to upload for a set: the originals, or fitted copies in a temporary folder that the caller removes after the upload; then `shareTotal` for a total (`smallestCopy` at `floorScale`). The decoding runs on `MediaReadQueue.analysis` ([blocking media reads](blocking-media-reads.md)) |
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
- `ReferenceTotalChecks` (the total): the record's total read, absent, the smaller of two, part of the identity, shown to the
  AI as published; the common cap; a set within the total untouched (nothing encoded to find out), only the largest brought
  down, two over sharing one cap, an image held at its smallest copy, one that cannot come down at all, a set that cannot be
  met; the byte search never below its floor, giving up at it, and finding the floor copy after a long plateau; the note; the
  reference check with and without `fit_images`; the refusal's words. Real files: one image over the total alone, exactly at
  it; three whose sum is over (the small one byte-identical, the two large within the cap, the PNG with its alpha and shape
  and at least 90 % of the cap, no copy under a 512 px long side, the large photo's own-limit copy replaced and removed, the
  originals unchanged); a PNG under the floor that keeps its size while the other image pays; a set that cannot be met
  (refused with the total, the floor and the files, no copy left) and the same set with room for its smallest copies (shared,
  none under the floor); a 900 × 600 image's smallest copy at exactly 512 × 341, and the search landing on that very copy
  when capped at its bytes (a PNG and a 1600 × 1200 JPEG); a refusal mid-set removing the copy already made; no total,
  nothing shared.
- `checks/sky-studio-wiring/reference-fit.sh`: every reference goes through `prepare` before the upload and is measured
  again there, the whole set before the first upload and never one file alone, and a set with a total goes through
  `SkyStudioReferenceTotal.share`; both generate tools set the chain's target and list each model's reason when none takes
  the request; the official sources carry the target; a fitting failure reaches the task row in the user's words; no limit
  number is written in SkyCut's fitting code (`SkyStudioReferenceTotal` included).
- Reverse checks (2026-11-23), each turning its check red: the decision without the byte limit, the merge taking the looser
  limit, the chain ignoring `accepts`, a PNG turned into JPEG, the orientation not applied, a plan asking for 1.5× (an
  upscale), the reference check refusing an oversize image on a `fit_images` model, `prepare` handing back the original of a
  file it should convert, the size without its aspect nudge, the byte search without its refinement (and the old step-down
  estimate of √(limit / size) × 0.97 capped at 0.95 without it), `prepare` without the second measurement, the refusal
  without each model's reason; in the wiring guard, the upload sending `file.file`, a target
  built without the chain, a limit number written into `SkyStudioReferenceFit` and the task row left in English. ImageIO's
  thumbnail never makes a copy larger than its source; the TIFF check pins the size of a converted-only image.
- Reverse checks for the total (2026-11-24), each turning its check red: the chain dropping the total or taking the looser
  one; the record's total not read; the set skipping the total pass; an equal split instead of the largest first; no pixel
  floor; refusing instead of holding an image at its smallest copy; the byte search not clamped to its floor, or never
  trying the floor last; no cleanup when a set is refused, or the replaced own-limit copy left behind; the reference check
  ignoring a total without `fit_images`; the note without its total line; the identity without the total; the smallest
  copy decoded another way than the byte search (red only on a large JPEG, whose small thumbnail ImageIO decodes another
  way: 119,884 bytes against the search's 119,636; a PNG gives the same pixels both ways, and a first check that only asked
  for some copy within those bytes stayed green); in the wiring guard, the upload preparing each file alone, the set
  without its total pass and a limit number in `SkyStudioReferenceTotal`.

## 6. Manual regression (before a release, with the user's approval: it spends credits)

- With a real key, generate an image with no model named from a 40 MB PNG photo and from an iPhone HEIC. The upload is at
  most 7,340,032 bytes (Seedream's limit, the default chain's strictest) and a JPEG or PNG, the answer's `notes` say so, and
  the result keeps the photo's orientation and colours.
- The same with `model: nano2` and a 20 MB JPEG: nothing is fitted (under Nano Banana 2's 30 MiB).
- `model: seedream5-flash` with three 5 MB JPEG photos and a small PNG logo: the uploads together are at most 7,340,032
  bytes, the logo goes up unchanged, the `notes` say the set is shared, and the job is not refused with
  `too_large_together`.
