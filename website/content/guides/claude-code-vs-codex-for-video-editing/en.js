// English. Numbers are from our own run on 2026-11-11; see index.js.
export default {
  title:'Claude Code vs Codex for Video Editing: What We Measured',
  description:'We ran the same eight editing tasks in SkyCut with Claude Code and with Codex. Both finished all eight. Here are the times, the tool calls and the limits.',
  heading:'Claude Code vs Codex for video editing: what we measured',
  answer:'Both work. We gave Claude Code and Codex the same eight editing tasks in SkyCut, and each finished all eight with the same result in the project. Both stopped to ask before spending credits and before deleting a file. The difference in our run was time: the eight tasks took Claude Code about 14 minutes in total and Codex about 24 minutes, with Codex set to its highest reasoning effort. On the longest task, a 30 second promo, the two took the same time. This was one run each on test footage, so it shows that both can drive the editor. It does not show which one makes the nicer cut.',
  sections:[
    {heading:'What we tested',blocks:[
      {list:[
        '**When.** 11 November 2026, as part of our own checks on SkyCut’s AI tools.',
        '**Claude Code.** Version 2.1.322 with its default model at the time, `claude-opus-5-5`.',
        '**Codex.** Version 0.167.0 with `gpt-6.1-sol` at maximum reasoning effort.',
        '**The tasks.** Eight requests in plain language on the same starting project, each started from a clean copy.',
        '**The footage.** Short test clips, not real material. Paid generation went to a stand-in service, so no real images were made.',
        '**How often.** One run per assistant. A second run could come out differently.',
      ]},
    ]},
    {heading:'The eight tasks, side by side',blocks:[
      {table:{head:['Task','Claude Code','Codex'],rows:[
        ['Change two titles at once','31 s, 13 tool calls','66 s, 16 tool calls'],
        ['Replace the narration and resync the pictures','53 s, 20 calls','156 s, 30 calls'],
        ['Inspect the cuts for sound problems','55 s, 18 calls','152 s, 22 calls'],
        ['Export a quick review copy','37 s, 10 calls','101 s, 12 calls'],
        ['Make a vertical version','48 s, 16 calls','91 s, 20 calls'],
        ['Build a 30 second promo','568 s, 97 calls','567 s, 70 calls'],
        ['Generate a cover image, asking before spending','44 s, 14 calls','253 s, 28 calls'],
        ['Delete a file, asking first','25 s, 8 calls','83 s, 10 calls'],
      ]}},
      'In total, Claude Code needed about 14 minutes and 196 tool calls, and Codex needed about 24 minutes and 208 tool calls. SkyCut refused two of Claude Code’s calls in the promo task, and Claude Code corrected both on the next call. It refused none of Codex’s.',
    ]},
    {heading:'What was the same',blocks:[
      {list:[
        '**The result.** After every task, the project on disk matched what the task asked for, with both assistants.',
        '**The rules.** Both stopped and asked before spending credits on a cover image whose size the request had left open, and before moving a file to the Trash. Neither went around SkyCut to change footage from the terminal.',
        '**The promo length.** Both delivered a timeline and an exported file of exactly 30.0 seconds.',
        '**Honesty about the footage.** Asked for a vertical version, both said that the test clips had no person in them and centered the picture.',
      ]},
    ]},
    {heading:'What was different',blocks:[
      {list:[
        '**Time on short tasks.** Claude Code finished the seven short tasks in 25 to 55 seconds each. Codex took 66 to 253 seconds. Codex was running at maximum reasoning effort, which is slower by design, so a lower setting would change this.',
        '**The long task.** For the promo the two were level at about nine and a half minutes, although Claude Code made 97 tool calls and Codex 70.',
        '**The style.** Asked for a promo, Claude Code chose SkyCut’s sci-fi editing style and Codex chose the product promo style. Both said which style they used.',
        '**The cover image.** In one of two samples, Codex made a low-cost draft before it stopped to ask about the larger size. SkyCut allows low-cost drafts without asking, so this was within the rules.',
      ]},
    ]},
    {heading:'What this does not tell you',blocks:[
      {list:[
        'Which assistant has the nicer taste. The footage was test material, and we did not judge the look of the cuts.',
        'How either behaves on your footage, on a long project, or with another model or setting.',
        'How they compare next month. Both products change often, and these numbers describe one day.',
      ]},
      'We publish them because they are what we have, and because both assistants passed.',
    ]},
    {heading:'Which one should you use',blocks:[
      {list:[
        'Use the one you already pay for. Both connect in **Settings → Connect AI** and use the same SkyCut tools.',
        'If you want short requests to come back quickly, Claude Code was faster in our run.',
        'If you already work in Codex, nothing in our run is a reason to switch.',
      ]},
      'Setup for each is in [the Claude Code guide](/en/guides/edit-video-with-claude-code/) and [the Codex guide](/en/guides/edit-video-with-codex/). AI editing needs SkyCut Pro at {{pro.monthly}} a month or {{pro.yearly}} a year, and a 7-day Pro trial starts the first time you connect SkyCut to your Sky Studio account. SkyCut runs only on Apple silicon Macs with macOS 15 or later, with no Windows or Intel version.',
    ]},
  ],
  faq:[
    ['Is Claude Code or Codex better for video editing?','In our test both finished the same eight tasks with the same results. Claude Code was faster on short tasks, and the two were level on the long one. We did not measure which makes the nicer cut.'],
    ['How many times did you run the test?','Once per assistant, on test footage, on 11 November 2026. Treat the numbers as an example, not a benchmark.'],
    ['Why was Codex slower?','We ran Codex at maximum reasoning effort, which takes longer on every step. We did not test lower settings.'],
    ['Do both follow SkyCut’s confirmation rules?','Yes. Both stopped to ask before spending credits on an image whose size was left open, and before deleting a file.'],
    ['Can I use both with the same SkyCut?','Yes. Connect each one in **Settings → Connect AI**. They use the same tools and the same project.'],
  ],
};
