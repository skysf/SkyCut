# 2026-11-26 The website's Apple touch icon showed in a black frame on iOS

## Symptom

A Home Screen bookmark of skycut.app on an iPhone or iPad showed SkyCut's icon small, inside a black frame. The
website has served this touch icon since 2026-11-05.

How it was found: the review of PR #561 measured the file and simulated how iOS renders it. Nobody saw it on a device.
- 37.6 % of the pixels of `website/public/apple-touch-icon.png` were fully transparent.
- The icon's card filled 144 of its 180 px.

## Root cause

- **How the file was made.** `website/scripts/build-favicons.mjs` scaled the app icon's 256 px image down to 180 px.
  - That image keeps macOS's icon grid: an 824 px card in a 1024 px canvas, with a transparent edge
    (`scripts/make-icon.swift`).
  - Browser tabs show that alpha, so the favicons are right with it.
- **What iOS does with it.** iOS doesn't keep a touch icon's alpha: it fills transparent pixels black and applies its
  own rounded mask. So the macOS edge turned into a black frame.
- **Why nobody noticed.** The 2026-11-05 decision reused the same transparent-edge handling for every size.
  - Nobody looked at the touch icon on iOS.
  - `website/scripts/check-seo.mjs` checked only its size and its link.

## Fix

- **The file.** `build-favicons.mjs` now builds the touch icon from the source's card.
  - `sips` crops `make-icon.swift`'s square (834 px at (94, 87)) from `packaging/icon-source-1024.png`, which has no
    alpha, and scales it to 180 px.
  - The result is an opaque RGB PNG, full-bleed on the card's warm white. iOS rounds the corners.
- **Only the touch icon changed.** The tab favicons keep the transparent edge.
- **The guard.** `check-seo.mjs` asserts that the built touch icon has no alpha channel (PNG colour type 2).

## Verification

- **The crop is exact.** It equals the source's square: the maximum difference over 2,782,224 bytes is 0.
- **The file.** 180 × 180, RGB, no alpha. `npm run build:favicons` changed only `apple-touch-icon.png`.
- **Reverse check.**
  - With the previous touch icon, `npm run check:seo` is red: `apple-touch-icon.png must have no alpha channel`
    (colour type 6).
  - With the new one it is green.
  - The 123 website tests and the build pass.
- **Not checked on a device.** I made a simulated iOS preview (black fill, then a rounded mask) for the user's review.
  - No real iPhone has shown the file yet. It goes live with the next website deploy.
  - The real-device look is on the manual list in [SkyCut 官网](../architecture/skycut-website.md).

## Lessons

- **An Apple touch icon is opaque and full-bleed.** iOS draws the shape itself and shows transparency black. A macOS
  icon with its grid edge is the wrong input. The constraint is in [SkyCut 官网](../architecture/skycut-website.md).
- **One source, many platforms.** When one artwork feeds several platforms, check each platform's own mask and
  background rules, not just the pixel sizes.
