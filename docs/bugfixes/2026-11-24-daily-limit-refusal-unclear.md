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
5. **Found in review (Codex, 2026-11-25, on the first version of this fix):**
   - "Wait for the reset" was offered when even a whole day's limit could not cover the request (a limit of 0 or 20 against 36).
   - The reset was computed as today's start plus a day, which is 01:00 after a day that skipped its midnight (America/Santiago
     2026-09-06); the ledger's next day starts at 00:00.
   - **The ledger used three clocks for one reservation**: the check, the booking and the reservation's day each read the time. A
     reservation booked a second before midnight and refunded after it was refunded from the next day: yesterday's 60 took today's
     80 down to 20, and a limit of 100 then let 50 more through. This was there before MSG1.
   - A voiceover's refused missing batches read the limit and spend after saving the recovery file, so a refund or a raised limit
     in between changed the numbers it reported.
   - Change Limit… switched the Settings window to the Sky Studio pane, which closed Design a Voice's sheet (it lives in the
     Editing pane) and lost its draft. The two sheets also put the race's line into `problem` beside the note, where it stayed after
     the limit was raised.
   - A 402 with a job id and pending billing was told "not charged" with a redo, though it may have been charged. The official
     film's retry lacked its new quote and seam review, and a MiniMax version mid-voiceover was told it could send its lines again.
   - Three inventory items needed fixing: a fee over the limit mid-voiceover offered only the skip; a reference total over its limit
     gave neither the total nor (for all files) the limit; a refused price check pointed at orders and bills that did not exist.
6. **Found in the re-check (Codex, 2026-11-25, on the second version):**
   - A late yes to the refusal's 1,000 → 1,500 after the user set 2,000 themselves skipped the token check: a value below the current
     limit never asked, so it would have set the limit back to 1,500.
   - "Today's start plus a day" was replaced by "tomorrow at this time, rounded down", which fails when tomorrow lacks this time: America/Nuuk at
     2026-03-27 23:30 reported the 29th.
   - **A refund worked its day out again from the stored moment, in the time zone of the refund.** After the Mac's time zone changed
     between booking and refund, a 60 refund cut the next day's 80 to 20 and a limit of 100 let 50 more through.
   - When a whole day was not enough, the panel line dropped used and left.
   - get_job told the AI to query the original voice change job but never asked Sky Studio. A balance error while polling an accepted
     job (no billing in it) was still called "not charged". A MiniMax version mid-voiceover, failing after a restart, was told to
     send its lines again.
   - The fee step promised another question in full access with the standing consent, where resuming builds directly. The character
     tool's refused price check still pointed at an order. Reverting the generation's price-check entry kept the guard green.
7. **Found in the third check (Codex CXM3, 2026-11-26, money items only):**
   - A 1,000 → 1,500 token was refused at 2,000, but after the user set 1,000 again it wrote 1,500: the token compared only the
     current value. A used token replayed with the same limit plus `theme=classic` wrote the theme: with nothing to approve, the
     token was never checked.
   - A reservation without a day key (a voice library order saved before keys) refunded into a day worked out in today's time zone:
     in Tokyo the next day's 80 became 20 and 50 more were let through.
   - **Already in main:** a settlement was a refund and then a booking, two writes. 60 held, 20 spent, 40 charged, killed between
     the writes: 20 on the books, the order already deleted, 70 more let through under 100.
   - The voice change: a try? on the original job's GET dropped a 402's final bill (billed 6.5, the books kept 9); without a final
     bill get_job reported a top-level credits_charged of 0 as the charge; a default result without its background released all
     9 before the job reported its failure.
   - No check went red when only the settle-date rule was reverted, or when the voice change's accepted flag was pinned to false.

## Fix

- **One builder for every daily-limit refusal**, `SkyCutDailyLimit` (pure values):
  - The AI's result, through `SkyStudioJobGate.budgetBlocked` (every paid tool) and the field names it already had, adds:
    - `blocked_by: skycut_daily_credit_limit` and a `message` naming SkyCut's own limit, not the Sky Studio balance;
    - the numbers: `left_today_credits`, `resets_at` (the first moment of the ledger's next day, with its offset) and
      `resets_in_minutes`;
    - `options`:
      - `raise_limit`: the exact `set_settings` arguments with `suggested_daily_limit_credits`, enough for this request rounded
        up to a friendly number (988 used + 36 needed suggests 1,500). It also carries SkyCut's question and a confirm_token for
        exactly that raise (below);
      - `change_in_settings`: `settings_path` in the app's language, plus `settings_path_english` when the app is in another
        language;
      - `wait_for_reset`, only when a whole day's limit covers the request;
    - a `next_step` that offers them and keeps the rules: never raise it without the user's yes, never split the request, full
      access obeys the same limit.
  - A voiceover's missing batches keep their own outcome and retry (finished batches stay; resume with `generate_missing`), and
    the numbers they were refused on (`SkyStudioVoiceBudgetProblem`).
  - The settings path is built from the string tables' own labels: the window ("Settings"), the pane (`SettingsCategory`, "Sky
    Studio") and the row ("Daily limit for AI"). In English it reads "SkyCut → Settings → Sky Studio → Daily limit for AI", in
    Chinese "SkyCut → 设置 → Sky Studio → AI 每日上限".
- **Asked once** (the user's decision on 2026-11-25, 「只问一次」). `AISettingsApproval.limitRaise` issues the question and a token
  for exactly set_settings `{daily_ai_credit_limit: value}` from this limit and permission mode, with the same identity `check()`
  computes. The user's yes to that exact value is the approval: set_settings with the token does not ask again. Any other value is
  asked by set_settings as before, in every permission mode. The token raises the limit only, is good for one call, and the refused
  request itself never gets one. The settings question names "SkyCut's daily credit limit for AI (a SkyCut setting at <path>, not
  the Sky Studio balance): 1000 -> 1500 credits a day".
- **One moment per reservation.** `SkyStudioJobGate` takes `now` once for the check, the booking and the reservation's day
  (`decide`, `reserveWithoutAsking`, `reserveReplacement`, `voiceOneTime`; `SkyStudioHeldCredits.recording` too), so a refund goes
  back to the day it was booked.
- **The panels say it too.**
  - Over the limit, `DailyCreditLimitNote` replaces the "Spent today" line with which limit and the numbers (used, the limit, left,
    needed). It also gives the path, and the reset time in the user's language when waiting helps.
  - Its Change Limit… edits the limit's own row (`SkyStudioCreditLimitRow`) in a popover, in place, so no sheet closes and no draft
    is lost. Raising the limit there enables the panel's button at once.
  - The two sheets' models leave the race to the note (no second line in `problem`). An upscale that loses the race shows the line
    in its task row, and a voiceover stopped mid-way shows it in its row.
  - The limit's row shows whenever a key is set.
- **The balance, said once** (`SkyStudioBalanceRefusal`, used by generate_media, upscale_clip, add_voiceover, change_voice, voice
  design and MiniMax versions, manage_characters):
  - The AI gets `blocked_by: sky_studio_balance` (the user's account, not SkyCut's limit), `balance_credits` / `needed_credits` when
    Sky Studio sent them, and `recharge_url` (Sky Studio's, else the account's).
  - A plain refusal was not charged, and its next step gives the job's own retry once the user says they added credits: a new
    quote, seam review and key for an official film; the caller's own step for a voice library job.
  - A refusal with a job id or billing may have been charged: the next step queries that original job and never resubmits it.
  - The task row shows the localized line with the numbers and the path to Add Credits. A voice design or MiniMax version refused
    for the balance keeps its row instead of vanishing.
- **The other refusals the review re-judged:**
  - a fee over the limit mid-voiceover offers both ways (raise the limit to be asked about the fee, or skip it);
  - reference totals give the actual total beside the limit;
  - a refused price check says nothing was submitted or charged and what to do (an update, `retry_after`, a new key) instead of
    pointing at orders.
- **The guide's paid topic** says the limit is SkyCut's own, that `next_step` has the numbers and the options (the first carries
  SkyCut's question and a confirm_token, used only after the user's yes), and that a low balance is the user's account.

- **Re-check fixes:**
  - A token is void once the limit moved: a late yes is asked again, even when it would now lower the limit
    (`AISettingsApproval.check`). The set_settings description says a raise needs the user's yes and a token, from
    needs_confirmation or the refusal.
  - The reset is the end of today's calendar day (`dateInterval(of: .day)`).
  - A reservation carries the day key it was booked on (`Reservation.dayKey`, persisted as `reservedDayKey` in voice library
    orders), and refunds and settlements use it.
  - The panel line keeps used and left when a whole day is not enough.
  - Balance refusals:
    - every paid job says whether Sky Studio had accepted the job (`refusal(of:accepted:)`);
    - get_job on a failed voice change GETs the original job and settles by its billing;
    - a voice library order keeps its caller's failure step across a restart (`failureStep`).
  - The fee step words full access with the standing consent.
  - The character tool's price check goes through `beforeSubmission`, and the guard pins both real entries.

- **Third-check fixes:**
  - The token is bound to the limit's revision (`SkyStudioSpendStore.limitRevision`): any change since its question voids it. A
    call that carries a token has it checked first. One that is not accepted asks again when the call changes the mode or the
    limit, and otherwise writes nothing and says to repeat the call without it.
  - A keyless reservation refunds or settles only into the one day the ledger proves holds it
    (`DailySpendLedger.provenDayKey`), else it leaves the books and logs it.
  - A settlement is one ledger write (`SkyStudioSpendStore.settle`). The voice library order is still deleted first: deleting it
    after the write would let a restart settle it twice.
  - A voice change's books move only by a final bill (`VoiceChangeBilling`): a refusal's bill for the original job counts, a
    top-level 0 is neither settled nor reported, and a result without its background keeps the 9 until a bill comes.
- **Fourth-check fixes (Codex CXM4, 2026-11-26):**
  - A settlement takes its caller's clock for the ledger's 40-day clean-up (`SkyStudioHeldCredits.settle(charged:now:)`). The
    settle checks used a fixed October sample but settled by this Mac's clock, so from December the clean-up would have deleted
    the sample and failed every PR.
  - get_job's `spent_today_credits` after a 402 with a final bill is read from the books after settling
    (`VoiceChangeBilling.refusalBill`). It said 9 reserved while the books held 6.5.
  - Merged with #554 (download retry): the voice change takes #554's `finalCharge` (the bill's net, else the top-level amount
    when no bill came) except a bare top-level 0, which keeps the reservation. #554's get_job re-read of a pending bill and this
    case's original-job GET for a failed change are one refresh (`refreshBill`).

## Similar refusals

Each refusal the AI or the user can hit through SkyCut was checked for three things: does it say which system stopped it, the
numbers, and what the user can do? The review re-judged three items.

| Refusal | Before | Now |
| --- | --- | --- |
| SkyCut's daily limit (every paid tool, three panels, a panel's race, a voiceover mid-way; a limit of 0) | system unnamed, no reset, no way on | fixed (above) |
| Raising the limit through set_settings | "daily hard budget: 1000.0 -> 1500.0" | fixed: names the setting, its path, whole credits; asked once from the refusal |
| Sky Studio balance at `/jobs` (six paid jobs) | raw English in every row; upscale and change voice gave the AI no address | fixed (above), and a possibly billed refusal queries the original job |
| Balance at `/quote` | not reachable: Sky Studio checks the balance at `/jobs` only | left |
| Plan, trial, entitlement, AI tools off (`SkyCutGates`), styles and craft cards, the export watermark | already said the plan, the Mac count, the URL and the Settings path | already fine |
| `price_changed` / `max_credits` | Sky Studio's own words; "quote again" | left: the action is right; the character wording on a plain generation is in the backlog |
| Paid draft approvals, the Trash, files outside the opened folder, character deletion, voice consent | each question names what, the price, the folder rule or the statement | already fine |
| A one-time fee mid-voiceover over the daily limit | taught only the skip | fixed: raise the limit and be asked, or skip |
| Job slots, `too_many_jobs`, SkyCut's own queues | not a refusal: SkyCut waits and reports queued / queue_position | left |
| `voice_library_unavailable`, no key, the keychain, router refusals, disk space for a recording | name the system and the next step (disk space with numbers) | already fine |
| A refused price check (upgrade, rate limit, key) | pointed at orders and bills that did not exist | fixed: nothing submitted; update / retry_after / new key |
| Upload too large | names Sky Studio and asks for a smaller file; no limit or size | left: Sky Studio's answer carries no limit |
| Reference totals over a model's limit | the limit only for images, nothing for all files, the seconds without the total | fixed: the actual total beside the limit |
| Voice and upscale size limits, a reference recording's length | give the limit (and the size where it matters) | already fine |

## Verification

- `scripts/check-sky-studio.sh`:
  - `DailyLimitChecks`:
    - the numbers and the reset in a fixed time zone;
    - the reset as the ledger's next day in America/Santiago around the skipped midnight (2026-09-06);
    - the suggested value in every step, with float noise, at the highest limit and for a request that fits;
    - every field and the options in order, with option (a)'s question and token;
    - no waiting option for a limit of 0 or 20 against 36;
    - `budgetBlocked` and `decide` from a real store;
    - the refusal's token: the exact raise passes with no second question, in full access too; another value is asked; it works
      once;
    - the question set_settings asks without it;
    - the settings path and both panel lines read from every real string table, with the reset time.
  - `BalanceRefusalChecks`:
    - the refusal found in request and job errors only, and whether it came before admission;
    - the fields and the numbers only when sent; the address fallback;
    - the next step with and without an address; a 402 with a job id and pending billing that queries the original job;
    - the line and its path in every table;
    - the price check's next steps.
  - `SpendChecks`: a reservation a second before midnight refunded after it goes back to its own day, the next day's 80 stays and
    its limit of 100 still refuses 50.
  - `ReferenceTotalChecks`: the actual totals in the refusals.
- `checks/sky-studio-wiring/daily-limit.sh`:
  - no other file builds either refusal, and option (a) is asked in advance;
  - the three panels show the note, whose Change Limit… is a popover with the row (nothing that switches the Settings window);
  - the two sheets leave the race to the note; the upscale race and the voiceover use the line; the voiceover reports the numbers
    read at the refusal;
  - the six jobs give the AI the balance fields and the row the user's line.

  Two older lines of `checks/sky-studio-wiring.sh` now look for the one-moment booking and the voiceover's reservation wrapper.
- `scripts/check-voice-recovery.sh` (real App objects against a fake Sky Studio):
  - `VoiceChangeBalanceChecks`, with change_voice refused at `/jobs`:
    - a plain 402: get_job names the Sky Studio account, the numbers, `recharge_url` and the retry; the reservation goes back;
      nothing is sent again; the row shows the user's line;
    - a 402 with pending billing: the reservation stays and the AI queries the original job.
  - The voiceover's budget stop offers raising (with its token) or Settings, no waiting at a limit of 0, and keeps the numbers it
    was refused on.
  - A one-time fee over the limit mid-voiceover offers both ways and builds nothing.
  - The two sheets' race checks now expect no second line.
- Reverse checks, each red and then restored exactly:
  - first round: 17 Swift failures, 4 wiring failures, and 3 real-App failures;
  - this round:
    - in `check-sky-studio.sh` (32 failures):
      - the old reset arithmetic;
      - waiting always offered;
      - the reservation's day from a second clock;
      - no question in advance;
      - every balance refusal treated as before admission;
      - the old total wording;
      - the old price-check step;
    - in the wiring part:
      - the popover removed;
      - `limitRaise` removed;
      - the race line back in `problem`;
      - the voiceover's numbers read from the live store;
    - in `check-voice-recovery.sh` (3 failures):
      - the old fee step;
      - the balance refusal ignoring admission;
      - the problem's numbers changed.
- Re-check (2026-11-25):
  - New checks:
    - America/Nuuk's reset;
    - a late token after the user set 2,000 (asked again, 2,000 stays);
    - a refund after a switch from Shanghai to Tokyo (`SpendChecks`);
    - the line with used and left;
    - a balance error for an accepted job;
    - get_job GETs the billed voice change's original job once and the refunded reservation leaves the books
      (`VoiceChangeBalanceChecks`);
    - guard lines for the price-check entries, the accepted flag, the refresh, the refund key and the fee's steps.
  - Reverse checks, each red and restored exactly:
    - in `check-sky-studio.sh` (10 failures): the round-2 reset arithmetic; refunds by date; the late-token rule removed; the line
      without used and left; the accepted flag ignored;
    - in `check-voice-recovery.sh` (2 failures): the refresh removed;
    - in the wiring part: the two price-check entries reverted; the full-access wording dropped. One guard pattern was made specific,
      because the old one matched a second, unrelated line.
- Third check (2026-11-26):
  - New checks:
    - `LimitTokenChecks`: 1,000 → 2,000 → 1,000; a used or unknown token replayed with `theme=classic`;
    - `SettleChecks`: a Tokyo settlement on the booking's day; keyless at midnight and at noon; one write;
    - `VoiceChangeSettleChecks`: a polled 402; a 402 GET with a final bill; no final bill; a result without its background;
    - guard lines for the exact accepted flag, the final-bill rule, the booking's key and the one write.
  - Reverse checks, each red and restored byte for byte:
    - in `check-sky-studio.sh` (11 failures): the revision dropped (2); the old early return (2); the settle day from the date (3);
      the keyless day from the date (3); two writes (1);
    - in `check-voice-recovery.sh` (7): accepted pinned to false (1); the try? (2); the top-level fallback (4);
    - in the wiring part: 12 lines.
- Fourth check (2026-11-26):
  - `SettleChecks` runs on three clocks: the fixed sample, today, and 120 days ago.
  - `VoiceChangeSettleChecks` checks the reply's day total after a 402 with a final bill.
  - Reverse checks:
    - a settlement without the caller's clock: 7 failures, all on the 120-days-ago clock, and the wiring guard;
    - the reply without the fresh total: 1 real-App failure.
- Not verified in a real window: the popover, the panels' layout and the reset time in each language. These are on the manual list
  ([Sky Studio jobs](../architecture/sky-studio-jobs.md) section 11).

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
- Offer only ways that work: waiting must cover the request; a retry must be the job's real one, and only when nothing may have been
  charged.
- One decision, one moment: a check, its booking and its refund read the clock once. Numbers reported later are the ones read at the
  refusal.
- An approval or a reservation carries what it was decided on (the limit's revision, the booking's day key). When that is missing,
  prove it or leave the books; never work it out again from today's state.
- Books move by a final bill only, in one write: two writes can be cut in half.
- A button in a sheet must not take away the window behind it: edit in place.
