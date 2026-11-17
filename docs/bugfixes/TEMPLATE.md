# <YYYY-MM-DD> <one-line title>

> Template note, drop it from the case: new cases use these English headings (since 2026-11-16, AGENTS.md「语言」). Older cases use the Chinese ones: 症状 = Symptom, 根因 = Root cause, 修复 = Fix, 验证 = Verification, 教训 / 防回归 (or 教训) = Lessons.

## Symptom

What the user saw and how to trigger it.

## Root cause

The real cause (there can be more than one). If earlier fix attempts failed, say why they
looked fixed and why they were not — this is the most valuable part of a case.

## Fix

What changed and why it was done this way. List the key files and entry points.

## Verification

How you proved it is really fixed (real-device steps / injected test / check command), and
which regression surfaces you checked.

## Lessons

What to watch for when changing related code later. If this produced a long-term constraint,
put it in `docs/architecture/` and link it from here; don't leave it only in the case.
