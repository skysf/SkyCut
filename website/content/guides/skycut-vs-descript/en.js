// English comparison: both products have AI assistance and manual timeline editing.
export default {
  title:'SkyCut vs Descript: AI Editing and Timeline Workflows',
  description:'Compare SkyCut and Descript by transcript editing, timeline control, AI assistants, media handling and plan limits, with reasons to choose each.',
  heading:'SkyCut vs Descript: which editing workflow fits?',
  answer:'Consider Descript if you want speech-led editing through a transcript, with scenes, an editable timeline and its built-in Underlord assistant. Consider SkyCut if you want your Claude or Codex to operate a native Mac multitrack timeline that you can inspect and change by hand. Both offer AI assistance and manual editing; Descript also offers API and MCP access. The decision is about the working environment, media workflow and allowances, not whether only one product has AI. SkyCut is our product, requires Apple silicon and macOS 15 or later, and puts a watermark on Free video exports. It does not suit a requirement for a free, watermark-free Windows editor.',
  sections:[
    {heading:'What this comparison can tell you',blocks:[
      'SkyCut is a product of this article’s publisher. We have not run a comparative test against Descript, and this is not a ranking. Descript facts below come from its own official product pages and help guides; the recommendations are our interpretation of those workflows.',
      'We make no claims about which transcribes more accurately, edits faster or produces a better story. For those questions, use the same sample recording in both and review the result. This page helps you decide what to try and what to check.',
    ]},
    {heading:'The differences at a glance',blocks:[
      {table:{head:['Question','SkyCut','Descript'],rows:[
        ['Where can I use it?','Native Mac app; Apple silicon and macOS 15 or later; no Windows or Intel version','macOS and Windows desktop apps, plus a web editor'],
        ['What drives the edit?','Multitrack timeline; manual tools or instructions to your Claude/Codex','Transcript-led editing with scenes, layers and a timeline'],
        ['Can I adjust timing by hand?','Yes, in the same timeline the assistant edits','Yes, its timeline supports timing, layers and audio alignment'],
        ['How does AI connect?','Built-in local MCP server, used by an external assistant; Pro required','Built-in Underlord; API and MCP entry points also offered'],
        ['What happens to imported media?','Project and footage stay on the Mac; assistant tool results and cloud generation have separate data flows','The documented import process uploads files into the project'],
        ['What does free mean?','Manual editing with watermarked video export; AI editing and watermark-free export need Pro','Free tier with allowances; watermark-free export and resolution depend on the plan'],
        ['How is paid usage structured?','Pro subscription; external assistant fees and cloud generation credits are separate','Per-person subscriptions with media-hour and AI-credit allowances'],
      ]}},
      'This is a comparison of documented behavior, not a claim that either product has only one editing mode. In particular, Descript does have a timeline, and both products can be used with AI assistants.',
    ]},
    {heading:'Editing words and asking an assistant are different actions',blocks:[
      'In Descript’s documented text workflow, deleting or rearranging transcript passages changes the media. Correcting a transcription mistake is a separate operation. That distinction matters when a technical term is misspelled: you may want to fix the word without cutting the sentence. Descript also lets you refine the result in its timeline.',
      'In SkyCut, you can ask Claude or Codex to inspect footage, propose cuts and make timeline changes. The assistant plans the operation and calls the editor’s tools. A request is not an accuracy guarantee: review the selected passages and the resulting cuts before exporting.',
      'These are reasons to try different workflows, not evidence that one needs no review. For an interview, check the meaning of the retained answers; for a lesson, check that a removed pause did not also remove a useful demonstration.',
    ]},
    {heading:'Both have AI assistance, with different entry points',blocks:[
      'Descript’s Underlord is built into its editing workflow. Its official API page also describes connecting through Claude/MCP to trigger imports and edits, with a CLI and HTTP API available. Do not choose SkyCut on the assumption that Descript cannot work with an external assistant.',
      'SkyCut’s local MCP server ships inside the Mac app. Claude or Codex calls its editing tools against an open project, and you can take over on that project’s timeline. Each tool change is undoable; **Undo This Round** returns the project to its state before that round of assistant work. Setup is covered in [the Claude Code guide](/en/guides/edit-video-with-claude-code/) and [the Codex guide](/en/guides/edit-video-with-codex/).',
      'If you already have an assistant you want to keep using on a Mac timeline, that is a reason to evaluate SkyCut. If a transcript-led workspace and an integrated assistant fit how you edit, that is a reason to evaluate Descript. We have not tested parity between their MCP tools.',
    ]},
    {heading:'Media handling, subtitles and costs to check',blocks:[
      {list:[
        '**Media handling.** Descript documents uploading imported media. SkyCut keeps projects and source footage on the Mac, but the external assistant receives tool outputs such as frames and transcripts. Cloud generation sends inputs to a service. Read the terms for the specific services you use rather than treating a local editor as fully offline AI.',
        '**Subtitles.** SkyCut generates speech subtitles on-device with macOS 26 and translates supported language pairs on macOS 15 or later. Manual subtitle work is included in Free. Check each product’s exact support for your spoken language, names and terminology with your own recording.',
        '**SkyCut billing.** Pro is {{pro.monthly}} a month or {{pro.yearly}} a year in US dollars, before tax. It includes AI control and watermark-free video export. You supply Claude or Codex; assistant fees and cloud generation credits are separate. Free videos carry a Sky Studio watermark.',
        '**Descript billing.** Its pricing page separates per-person subscriptions, media hours and AI credits. Check the current allowance and export conditions for the plan you intend to use. A monthly editing subscription does not mean unlimited AI usage.',
        '**Trying SkyCut.** A 7-day Pro trial starts the first time you connect SkyCut to your Sky Studio account, once per account and once per Mac. The interface supports English, Simplified Chinese and Spanish.',
      ]},
    ]},
    {heading:'Conclusion: choose where you want to revise',blocks:[
      'Try Descript first when the transcript is the center of your editing and its integrated workflow matches your work. Try SkyCut when you want your Claude or Codex operating a local Mac timeline and want to correct the same project by hand. If Windows is required, SkyCut is not an option. If free watermark-free video output is required, SkyCut Free is not an option.',
      'Before committing, use a short interview in both: cut one passage, correct one word, add a title, undo a change and export. Record the corrections and allowances you actually used. For a wider set of options, see [AI video editors for Mac](/en/guides/ai-video-editors-for-mac/).',
    ]},
  ],
  faq:[
    ['Does Descript have a timeline, or only a text editor?','It has both. Descript’s official timeline guide describes adjusting timing, visual layers and audio alignment alongside the script workflow.'],
    ['Can Descript work with Claude or MCP?','Yes. Its official API page describes a Claude/MCP connection for triggering imports and edits. This article does not claim SkyCut is the only option for assistant-driven editing.'],
    ['Is SkyCut an offline version of Descript?','No. They have different editing workflows. SkyCut’s project and footage stay on the Mac, but external assistants and cloud generation still involve network services and their own data flows.'],
    ['Which is more accurate or faster?','We have not compared them on the same media, so we cannot make that claim. Try your actual recording, verify the words and cuts, and record how much correction each workflow needs.'],
    ['Can I use SkyCut for free without a watermark?','Manual editing is free, but Free video exports have a watermark. Pro is required for AI editing and watermark-free video output. There is no Windows or Intel Mac version.'],
    ['Can I move an existing Descript project straight into SkyCut?','This comparison has not tested project interchange and makes no compatibility promise. Preserve the original project and source media; a rendered video is different from an editable project.'],
  ],
};
