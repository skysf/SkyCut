# 2026-11-24 A request stopped by SkyCut's daily limit read like an empty Sky Studio balance, with no way forward

## Symptom

On 2026-11-24 the user asked ChatGPT, through SkyCut's MCP, for a 6 s 360p talking-head video. Sky Studio quoted 36 credits.
SkyCut's own daily credit limit for AI was 1,000 and 988 were already used, so SkyCut stopped the request before anything was
sent. The AI told the user "only 12 credits left today, wait for the refresh". The user could not tell whether that was SkyCut's
setting or their Sky Studio balance, and was given no way to go on. The user asked for the refusal to say plainly that it is
SkyCut's daily limit, and to offer options: the AI raising it (for example to 1,500), or where to change it (SkyCut → Settings →
Sky Studio). The user also asked to check the other refusals SkyCut gives in the same way.

The paid panels had the same gap: Upscale, Design a Voice and Change Voice turned their "Spent today" line red and greyed out the
button, with nothing saying which limit it was or where to change it. A panel's job that lost the race to the limit said "Daily AI
budget reached" without numbers. The twin case, a Sky Studio balance that is too low, was said in Sky Studio's English in the
task row whatever the app's language. On upscale and change voice the AI got only that text, with no recharge address.

## Root cause

1. **The result named no system and gave the AI nothing to offer.** `SkyStudioJobGate.budgetBlocked` returned
   `daily_budget_exceeded` with the limit, the spend and the request's credits. Its `next_step` said "the daily hard budget is
   exhausted". It did not say:
   - that the budget is a SkyCut setting, not the Sky Studio balance;
   - what is left, or when it resets;
   - what value would let the request through, or the call that raises it.

   The AI filled the gap with the most common meaning of "credits left": the account balance.
2. **The way on existed but was not offered.** `set_settings daily_ai_credit_limit` already raised the limit after the user's
   approval (`AISettingsApproval`, every permission mode), but only the guide's paid topic mentioned it, and its question read
   "daily hard budget: 1000.0 -> 1500.0 credits".
3. **The panels showed the symptom, not the cause.** Their red line had the numbers but not the limit's name, path or reset, and no
   way to reach the setting. The limit's row in Settings was drawn only after a `/me` answer was stored.
4. **Each paid job said the balance its own way.** `insufficient_credits` was handled in two jobs (generation, voiceover) with a
   recharge address. The others relayed the raw text, and every task row showed it untranslated.

## Fix

- **One builder for every daily-limit refusal**, `SkyCutDailyLimit` (pure values):
  - The AI's result, through `SkyStudioJobGate.budgetBlocked` (every paid tool) and the field names it already had, adds:
    - `blocked_by: skycut_daily_credit_limit` and a `message` naming SkyCut's own limit, not the Sky Studio balance;
    - the numbers: `left_today_credits`, `resets_at` (the next local midnight, with its offset) and `resets_in_minutes`;
    - three `options`:
      - `raise_limit`: the exact `set_settings` arguments with `suggested_daily_limit_credits`, enough for this request rounded
        up to a friendly number (988 used + 36 needed suggests 1,500);
      - `change_in_settings`: `settings_path` in the app's language, plus `settings_path_english` when the app is in another
        language;
      - `wait_for_reset`;
    - a `next_step` that offers the three and keeps the rules: never raise it without the user's yes, never split the request,
      full access obeys the same limit.
  - A voiceover's missing batches keep their own outcome and retry (finished batches stay; resume with `generate_missing`).
  - The settings path is built from the string tables' own labels: the window ("Settings"), the pane (`SettingsCategory`, "Sky
    Studio") and the row ("Daily limit for AI"). In English it reads "SkyCut → Settings → Sky Studio → Daily limit for AI", in
    Chinese "SkyCut → 设置 → Sky Studio → AI 每日上限".
- **The raise still asks.** Nothing raises the limit by itself and the refusal never carries a confirm token. `set_settings` with
  the suggested value goes through `AISettingsApproval` as before; its question now names "SkyCut's daily credit limit for AI (a
  SkyCut setting at <path>, not the Sky Studio balance): 1000 -> 1500 credits a day".
- **The panels say it too.**
  - Over the limit, `DailyCreditLimitNote` replaces the "Spent today" line: which limit, the numbers, the path and "wait until
    midnight".
  - Its Change Limit… button opens Settings at the Sky Studio pane: `SettingsNavigator` uses SwiftUI's `openSettings`, and
    `SettingsWindowView` follows it.
  - A job that loses the race (`UpscaleJob`, `DesignVoiceModel`, `VoiceChangePanelModel`) and a voiceover stopped mid-way show the
    same localized line.
  - The limit's row now shows whenever a key is set.
- **The balance, said once** (`SkyStudioBalanceRefusal`, used by generate_media, upscale_clip, add_voiceover, change_voice, voice
  design and MiniMax versions, manage_characters):
  - The AI gets `blocked_by: sky_studio_balance` (the user's account, not SkyCut's limit), `balance_credits` / `needed_credits` when
    Sky Studio sent them, and `recharge_url` (Sky Studio's, else the account's). Its next step has the job's own retry, only after
    the user says they added credits.
  - The task row shows the localized line with the numbers and the path to Add Credits.
  - A voice design or MiniMax version refused for the balance now keeps its row instead of vanishing.
- **The guide's paid topic** says the limit is SkyCut's own, that `next_step` has the numbers and the options, and that a low
  balance is the user's account.

## Similar refusals

Each refusal the AI or the user can hit through SkyCut was checked for three things: does it say which system stopped it, the
numbers, and what the user can do?

| Refusal | Before | Now |
| --- | --- | --- |
| SkyCut's daily limit (every paid tool, three panels, a panel's race, a voiceover mid-way; a limit of 0) | system unnamed, no reset, no way on | fixed (above) |
| Raising the limit through set_settings | "daily hard budget: 1000.0 -> 1500.0" | fixed: names the setting, its path, whole credits |
| Sky Studio balance at `/jobs` (six paid jobs) | raw English in every row; upscale and change voice gave the AI no address | fixed (above) |
| Balance at `/quote` | not reachable: Sky Studio checks the balance at `/jobs` only | left |
| Plan, trial, entitlement, AI tools off (`SkyCutGates`), styles and craft cards, the export watermark | already said the plan, the Mac count, the URL and the Settings path | already fine |
| `price_changed` / `max_credits` | Sky Studio's own words; "quote again" | left: the action is right; the character wording on a plain generation is noted below |
| Paid draft approvals, the Trash, files outside the opened folder, character deletion, voice consent and one-time fees | each question names what, the price, the folder rule or the statement | already fine |
| Job slots, `too_many_jobs`, SkyCut's own queues | not a refusal: SkyCut waits and reports queued / queue_position | left |
| `voice_library_unavailable`, no key, the keychain, router refusals, disk space for a recording | name the system and the next step (disk space with numbers) | already fine |
| Upload too large | names Sky Studio and asks for a smaller file; no limit or size | left: Sky Studio's answer carries no limit |
| Voice, upscale and reference-image size limits, a reference recording's length | give the limit (and the size where it matters) | already fine |

## Verification

- `scripts/check-sky-studio.sh`:
  - `DailyLimitChecks`:
    - the numbers and the reset in a fixed time zone;
    - the suggested value in every step, with float noise, at the highest limit and for a request that fits;
    - every field, the three options in order, the exact `set_settings` arguments, the next step's rules, no token;
    - `budgetBlocked` and `decide` from a real store;
    - the suggested value through `AISettingsApproval` in full access: it asks, the question names the limit, path and whole
      credits, nothing changes;
    - the settings path and the panels' line read from every real string table.
  - `BalanceRefusalChecks`: the refusal found in request and job errors only; the fields, the numbers only when sent, the
    address fallback, the next step with and without an address; the line and its path in every table.
- `checks/sky-studio-wiring/daily-limit.sh`:
  - no other file builds either refusal;
  - the three panels show the note, the three race paths use the line, the note's button goes through `SettingsNavigator`, and
    the path's labels are the window's own;
  - the six jobs give the AI the balance fields and the row the user's line.
- `scripts/check-voice-recovery.sh` (real App objects against a fake Sky Studio) passes: the voiceover's budget stop, the voice
  library and change voice.
- Reverse checks, each red and then restored:
  - In `check-sky-studio.sh` (17 failures in all):
    - the suggested value unrounded;
    - the old approval wording;
    - the Chinese line removed from its table;
    - the balance's next step without "not SkyCut's daily limit".
  - In the wiring part:
    - the Upscale panel without the note;
    - the upscale job without the user's balance line;
    - the Settings window not following `SettingsNavigator`;
    - the voice library job without the balance fields.
  - The old `budgetBlocked` body turned both checks red.
- Not verified in a real window: Change Limit… opening the Sky Studio pane, and the panels' layout in each language. Both are on
  the manual list ([Sky Studio jobs](../architecture/sky-studio-jobs.md) section 11).

## Lessons

- A refusal must say which system stopped the request (a SkyCut setting, the Sky Studio account, the plan, a provider), the numbers,
  and what the user can do: who, where (the exact path in the app's own words, or the URL) and what the AI may do for them. The AI
  fills a gap with the most common meaning, and for "credits left" that is the account balance. Long-term rule:
  [AI control (MCP)](../architecture/ai-control-mcp.md) section 4 item 68 and
  [Sky Studio jobs](../architecture/sky-studio-jobs.md) section 11.
- When the way on is a call the AI can make, put the exact call in the result. A rule that lives only in the guide is not read at
  the moment it is needed.
- Two refusals that users confuse (SkyCut's limit, Sky Studio's balance) should each name the other: "not the Sky Studio
  balance", "not SkyCut's daily limit".
