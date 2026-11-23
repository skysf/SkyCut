# Reference-image fitting (generate_media)

> Long-term constraints since 2026-11-23. The user asked that SkyCut compress an uploaded reference image, by exactly as much
> as the chosen image model's own limit requires and no more. SkyCut reads those limits from Sky Studio and fits an image
> only when it is over them.
> Not here: video, audio and document references (uploaded as they are); character photos (`SkyStudioCharacterWorkflow`,
> its own limits); the upload's retries (`SkyStudioAPI.upload`); prices ([Sky Studio jobs](sky-studio-jobs.md)).

## 1. Where the limits come from

- **Only from Sky Studio's `GET /models`, live.** Each image record's `limits.references` (background removal: its flat
  `limits`) carries `max_images`, `max_image_bytes`, `image_mime_types` and, where the provider documents them,
  `max_image_pixels`, `image_dimensions.min_side` / `max_side` and `min_image_aspect_ratio` / `max_image_aspect_ratio`.
  `fit_images: true` is the switch that lets SkyCut fit an image to them.
- **SkyCut writes none of these numbers.** A change on Sky Studio reaches every SkyCut, and every user's AI, without a
  SkyCut release. Sky Studio keeps the per-model table with each number's official source and the date it was read in its
  own repository, at `docs/agents/skycut-reference-image-limits.md`, next to the constants in
  `shared/skycutReferenceImageLimits.ts`; its contract test fails when the two disagree.
- **The AI reads the same numbers.** `get_status models=true` passes the records through unchanged (count, formats, bytes,
  pixels, `fit_images`). The generate_media guide's `inputs` section says that SkyCut fits images and what is still
  refused. There is no separate tool for this.

## 2. When SkyCut fits an image, and how far

1. **The target is the strictest limits of the chosen model and its fallbacks.** The fallbacks are the models after the chosen
   one in SkyCut's automatic order (`SkyStudioModelPolicy.ordered`) that take the same request
   (`SkyStudioModelPolicy.chain`). They exist only when the AI names no model for an ordinary generation, so a named model or
   an image operation has none. With Nano Banana 2 chosen and Seedream 5.0 Flash after it, an image is fitted to Seedream's
   30,000,000 bytes and 36,000,000 pixels. An upload made for one model therefore also suits the next default; official
   prepared references are reused across a change of model.
2. **An image that meets every limit goes up untouched**: the same file, EXIF and all.
3. **Otherwise convert, re-encode and downscale, only as far as needed:**
   - A format no model of the chain takes (HEIC, HEIF, TIFF, BMP, a still GIF) becomes PNG when it has transparency and PNG
     is taken, otherwise JPEG. A JPEG stays JPEG and a PNG stays PNG while the models take them, so a PNG keeps its alpha.
     A WebP over a limit becomes JPEG or PNG: ImageIO writes no WebP.
   - Over the pixel or side limit: scaled to just under it. Never upscaled.
   - Over the byte limit: a JPEG first tries quality 0.92, 0.86 and 0.80 at that size, then shrinks by √(limit / size) × 0.97
     a step; a PNG only shrinks.
   - The EXIF orientation is applied to the pixels and the colour profile (ICC) is kept. The copy carries no other
     metadata (no GPS).
4. **Refused, and the error names the limit:** too many images; a side below the minimum (SkyCut never upscales); an aspect
   outside the range (SkyCut does not crop); an animated GIF, PNG or WebP that would need converting; a byte limit that only
   a side below the minimum would meet. A HEIC or TIFF holding several images is fitted from its first image.
5. **An older Sky Studio** (no `fit_images`): uploads as before, and the old local refusals over a limit stand.
6. **Never fitted:** the source of an image upscale (its record has no `fit_images`: a client must never shrink what it asks
   to enlarge), and every non-image reference.

## 3. Where it happens

| Piece | Does |
| --- | --- |
| `SkyStudioReferenceFit` | Pure: reads a record's limits (only with `fit_images`), merges a chain's into the strictest, decides per image (as it is / fit / refuse), writes the notes |
| `SkyStudioModelPolicy.chain` | The chosen model and its fallbacks, from the same `accepts` test the choice used |
| `SkyStudioReferencePlan.fit` | Carries the target from the model choice (both generate tools) to the upload |
| `SkyStudioReferencePlan.problem` | On a `fit_images` model, refuses only what fitting cannot fix; other models are checked as before |
| `SkyStudioReferenceImageFit.prepare` | The file to upload: the original, or a fitted copy in a temporary folder that the caller removes after the upload. The decoding runs on `MediaReadQueue.analysis` ([blocking media reads](blocking-media-reads.md)) |
| `SkyStudioReferenceFiles.upload` | Prepares every reference before `SkyStudioAPI.upload` |
| `SkyStudioOfficialPreparation.sources` | The target is part of the prepared references' identity: a token prepared under other limits is refused ("prepare again") |
| `SkyStudioGenerateTool` | The answer's `notes` name each image that will be fitted and why, so the AI can tell the user before delivery |

## 4. Checks

- `scripts/check-sky-studio.sh`, `ReferenceFitChecks` (pure) and `ReferenceImageFitChecks` (real files written with ImageIO,
  each just above and just below its limit): which limits apply, the strictest of a chain, at / over each limit, the
  refusals and their words, the chain, the reference check, the note; the copy's bytes, size, format, alpha, upright
  orientation and P3 profile; nothing upscaled; the copy removed; the PUT to the fake Sky Studio carries the fitted bytes.
- `checks/sky-studio-wiring/reference-fit.sh`: every reference goes through `prepare` before the upload; both generate tools
  set the chain's target; the official sources carry it; no limit number is written in SkyCut's fitting code.
- Reverse checks (2026-11-23), each turning its check red: the decision without the byte limit, the merge taking the looser
  limit, the chain ignoring `accepts`, a PNG turned into JPEG, the orientation not applied, a plan asking for 1.5× (an
  upscale), the reference check refusing an oversize image on a `fit_images` model, `prepare` handing back the original of a
  file it should convert; in the wiring guard, the upload sending `file.file`, a target built without the chain and a limit
  number written into `SkyStudioReferenceFit`. ImageIO's
  thumbnail never makes a copy larger than its source; the TIFF check pins the size of a converted-only image.

## 5. Manual regression (before a release, with the user's approval: it spends credits)

- With a real key, generate an image with no model named from a 40 MB PNG photo and from an iPhone HEIC. The upload is at
  most 30,000,000 bytes and a JPEG or PNG, the answer's `notes` say so, and the result keeps the photo's orientation and
  colours.
- The same with `model: nano2` and a 20 MB JPEG: nothing is fitted (under Nano Banana 2's 30 MiB).
