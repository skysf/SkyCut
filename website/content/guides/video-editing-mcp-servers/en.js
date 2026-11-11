// English. Facts about other tools come from their own pages; see the sources in index.js.
export default {
  title:'Best Video Editing MCP Servers for Claude: How to Choose',
  description:'Six ways to let Claude or Codex edit video through MCP, compared by platform, where the server runs and whether you can fix the timeline by hand.',
  heading:'Video editing MCP servers for Claude and Codex: how to choose',
  answer:'There is no single best video editing MCP server. The right one depends on where you edit. If you want Claude or Codex to work inside a native Mac editor that you can also drive by hand, use SkyCut, which we make. If you already cut in DaVinci Resolve Studio, a community server drives it. If your work starts with a screen recording, Tella offers a hosted server on Mac, Windows and the web. For batch jobs on files, a skill built on FFmpeg needs no editor at all. The table below compares six options by platform, by where the server runs and by whether there is a timeline you can change yourself.',
  sections:[
    {heading:'What a video editing MCP server does',blocks:[
      'MCP (Model Context Protocol) is the standard way to give an AI assistant tools. A video editing MCP server turns an editor’s actions, such as adding a clip, trimming, adding subtitles and exporting, into tools that Claude or Codex can call. The assistant plans the edit, and the editor carries it out.',
      'The servers differ in three ways that matter in practice: which computers they run on, whether your footage stays on your machine, and whether the result is a timeline you can open and fix by hand.',
    ]},
    {heading:'Six options at a glance',blocks:[
      {table:{head:['Option','Runs on','Where the server runs','Timeline you can edit by hand'],rows:[
        ['SkyCut','Mac with Apple silicon, macOS 15 or later','Locally, built into the app','Yes, a native multitrack timeline'],
        ['Palmier Pro','Mac with Apple silicon, macOS 26','Locally, while the app is open','Yes, agents edit on the app’s timeline'],
        ['ChatCut Desktop','macOS 13 or newer and Windows 10 or newer','Locally, next to the desktop app','Yes, in the desktop app'],
        ['Tella','Mac, Windows and the web','Hosted, with a sign-in','Yes, in Tella’s editor'],
        ['DaVinci Resolve with a community server','macOS, Windows and Linux','Locally, through Resolve’s scripting API','Yes, in Resolve'],
        ['FFmpeg based skills','Any computer with FFmpeg','No server and no editor','No, each change renders a new file'],
      ]}},
      'We make SkyCut and have not benchmarked the other tools against it. The rows about them repeat what their own pages say, and the list is not a ranking.',
    ]},
    {heading:'How to choose',blocks:[
      {list:[
        '**You are on an Apple silicon Mac and want a full editor with AI on top.** SkyCut and Palmier Pro both run locally and put the assistant on a real timeline. SkyCut needs macOS 15 or later, and Palmier Pro needs macOS 26.',
        '**You need Windows or an Intel Mac.** ChatCut Desktop and DaVinci Resolve run there. SkyCut does not.',
        '**You already edit in DaVinci Resolve.** The community server drives Resolve itself, so your projects stay where they are. External scripting needs the paid Studio edition.',
        '**Your videos are screen recordings.** Tella is a screen recorder and editor, and its server also covers recording and publishing. It is hosted, so the work goes through Tella’s service.',
        '**You only need to convert, trim or caption files in bulk.** A skill that wraps FFmpeg does that from the terminal with nothing else installed.',
      ]},
    ]},
    {heading:'What to check before you commit',blocks:[
      {list:[
        '**Where your footage goes.** A local server runs on your own computer, and a hosted server works on footage held by that service. Either way, read what the app itself uploads, and remember that the assistant receives whatever the tools return.',
        '**Whether you can take over.** If the result is a timeline in an editor, you can fix one cut by hand. If the result is a rendered file, every correction is another render.',
        '**How undo works.** Ask whether the assistant’s changes land in the editor’s normal undo history, and whether you can roll back a whole session at once.',
        '**What it asks before acting.** Look for a way to make the assistant pause before it deletes files or spends money on generation.',
        '**Which assistants it supports.** SkyCut, Palmier Pro, ChatCut and Tella all name both Claude and Codex. The Resolve server’s installer can set up Claude Desktop, Claude Code and Codex CLI.',
      ]},
    ]},
    {heading:'How SkyCut answers those questions',blocks:[
      {list:[
        'The server is local and ships inside the app. Your project and footage stay on the Mac.',
        'Every tool call is one undo step, and **Undo This Round** puts the project back to how it was before the assistant started.',
        '**Ask for approval** makes the assistant pause before it goes beyond the defaults, and daily budgets cap paid generation in every mode.',
        'Setup is one button for Claude Desktop, Claude Code and Codex. The steps are in [the Claude Code guide](/en/guides/edit-video-with-claude-code/) and [the Codex guide](/en/guides/edit-video-with-codex/).',
        'AI editing is part of SkyCut Pro at {{pro.monthly}} a month or {{pro.yearly}} a year, and a 7-day Pro trial starts the first time you connect SkyCut to your Sky Studio account.',
      ]},
    ]},
  ],
  faq:[
    ['Which MCP server is best for video editing?','It depends on your computer and your editor. On an Apple silicon Mac, SkyCut and Palmier Pro give the assistant a native timeline. On Windows, look at ChatCut Desktop or DaVinci Resolve. For screen recordings, look at Tella.'],
    ['Do these work with Codex as well as Claude?','SkyCut, Palmier Pro, ChatCut and Tella name both. The community server for DaVinci Resolve can be set up for Codex CLI as well as Claude.'],
    ['Does my footage leave my computer?','SkyCut keeps your project and footage on the Mac and sends the assistant only what the tools return, such as frames and transcripts. For the other tools, a local server means the assistant reaches the editor on your own computer, and a hosted one works on footage held by that service. Check each maker’s terms for what the app itself uploads.'],
    ['Is there one for Windows?','Yes. ChatCut Desktop, Tella and DaVinci Resolve run on Windows. SkyCut runs only on Apple silicon Macs with macOS 15 or later.'],
    ['Do I need an MCP server at all?','Not for file jobs. Claude or Codex can run FFmpeg directly to trim, join and convert. An MCP server matters when you want an edit you can review and change on a timeline.'],
  ],
};
