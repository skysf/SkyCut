// English. Interface names are the app's own: Connect AI, Undo This Round.
export default {
  title:'How to Edit Video with Codex on a Mac',
  description:'Yes, Codex can edit video when it has an editor to control. Connect it to SkyCut on a Mac and it cuts, captions and exports on a real timeline.',
  heading:'How to edit video with Codex on a Mac',
  answer:'Codex can edit video, but not by itself: it needs a video editor it can control. On a Mac, install SkyCut, add your Sky Studio key and click **Connect** next to Codex in **Settings → Connect AI**. SkyCut adds its local MCP server to Codex’s configuration, and from then on Codex can open your footage, build and trim a timeline, add titles and subtitles and export, while you watch every change in the editor and can undo it. SkyCut runs on Apple silicon Macs with macOS 15 or later. There is no Windows or Intel version.',
  sections:[
    {heading:'Can Codex do video editing?',blocks:[
      'Codex is a coding agent. It reads files and runs commands, and it cannot watch a video or arrange clips on its own. People give it video in two ways.',
      {list:[
        '**Scripts and command line tools.** Codex writes FFmpeg commands. That works for trimming, joining and converting files, and each change renders a new file with no timeline to review.',
        '**An editor it can control through MCP.** The editor exposes its timeline as tools. Codex calls them, and the edit lands on a timeline that you can play and change by hand.',
      ]},
      'SkyCut is a native Mac video editor with an MCP server built in, so this guide takes the second route. The same setup works for Claude, described in [the Claude Code guide](/en/guides/edit-video-with-claude-code/).',
    ]},
    {heading:'What you need',blocks:[
      {list:[
        'A Mac with Apple silicon running macOS 15 or later. Features that transcribe speech, such as cutting pauses and generating subtitles, need macOS 26.',
        'SkyCut. The download is free.',
        'SkyCut Pro. AI editing is a Pro feature. A 7-day Pro trial starts the first time you connect SkyCut to your Sky Studio account, once per account and once per Mac.',
        'Codex, signed in with your own ChatGPT plan: the Codex CLI, the IDE extension or the ChatGPT desktop app. SkyCut does not include an AI subscription.',
      ]},
      {note:'A regular ChatGPT chat in the browser cannot connect. SkyCut’s MCP server runs locally on your Mac, and only a client on the same Mac can reach it.'},
    ]},
    {heading:'Connect Codex in four steps',blocks:[
      {steps:[
        ['Install SkyCut','Download SkyCut, open the disk image and drag SkyCut to Applications. The [setup guide](/en/docs/#video) has a short video of this step.'],
        ['Add your Sky Studio key','Sign in to Sky Studio, open your avatar at the top right, choose SkyCut and create a key. In SkyCut, open Settings, go to Sky Studio and paste the key. This turns on Pro and starts the trial.'],
        ['Connect Codex','Open **Settings → Connect AI** and click **Connect** next to Codex. SkyCut saves a backup of `~/.codex/config.toml`, then adds a `[mcp_servers.skycut]` table to it and allows SkyCut’s tools, so Codex does not ask for approval on every call. The Codex CLI, the IDE extension and the desktop app share this file, so all three see SkyCut.'],
        ['Start a new Codex session','Open a new session and type `/mcp`, or run `codex mcp list` in a terminal. `skycut` should be in the list. Then tell Codex which folder holds your clips.'],
      ]},
    ]},
    {heading:'Prompts for a first edit',blocks:[
      'Describe the result you want in plain language. Each of these maps to things SkyCut can do.',
      {prompt:'Open the folder ~/Movies/demo in SkyCut and tell me what is in each clip.'},
      {prompt:'Make a 60 second vertical cut for social from the two screen recordings, and keep the parts where I explain the feature.'},
      {prompt:'Cut the pauses and filler words out of the voice track, then generate subtitles.'},
      {prompt:'Add a title over the first three seconds and export a 1080p MP4 into the same folder.'},
      'Codex can also look at single frames, listen to levels, read the subtitles and inspect the exported video, so you can ask it to check its own work before you watch it.',
    ]},
    {heading:'What we measured',blocks:[
      'In our own test in October 2026 we ran Codex CLI against SkyCut with a small, fast model at low reasoning effort. One run of twelve tool calls opened a folder and a project, looked at a frame, listened to ten seconds of sound, read the subtitles, added a title, exported a 480p draft and looked at the result. It took about 60 seconds, and Codex never stopped to ask for tool approval.',
      'That test checked that the connection works from start to export. It says nothing about taste: how good the cut is depends on the model you choose and on how clearly you describe what you want.',
    ]},
    {heading:'Review and undo',blocks:[
      {list:[
        'While Codex works, SkyCut shows **AI is editing** in the toolbar and moves to each change. **Stop** halts it.',
        'Every tool call is one undo step, and **Undo This Round** puts the project back to how it was before the round started.',
        'You can edit by hand at any time and ask Codex to continue from there.',
      ]},
    ]},
    {heading:'What it costs',blocks:[
      {table:{head:['What','Price','Notes'],rows:[
        ['SkyCut Free','{{free.price}}','The full manual editor. Exports carry a watermark. No AI editing.'],
        ['SkyCut Pro','{{pro.monthly}} a month or {{pro.yearly}} a year','AI editing and exports without the watermark. Starts with a 7-day trial the first time you connect SkyCut.'],
        ['Codex','Your own ChatGPT plan','Paid to OpenAI. Not part of SkyCut.'],
        ['Cloud generation','Optional','Generated images, video, music and voices use Sky Studio credits, bought separately.'],
      ]}},
      'Prices exclude tax. See the [pricing table](/en/#pricing) for what each plan includes.',
    ]},
    {heading:'Limits to know before you start',blocks:[
      {list:[
        'Mac only: Apple silicon and macOS 15 or later. SkyCut does not run on Windows or on Intel Macs.',
        'Codex samples frames and reads transcripts through SkyCut’s tools. It does not watch the video continuously, so review the cut yourself.',
        'Your project and footage stay on your Mac. Codex receives what the tools return, such as frames and transcripts, as part of the conversation.',
      ]},
    ]},
  ],
  faq:[
    ['Can Codex edit video?','Yes, when it can control a video editor. With SkyCut connected, Codex edits on a real timeline on your Mac. On its own it can only run command line tools such as FFmpeg on files.'],
    ['Does ChatGPT in the browser work too?','No. The MCP server is local to your Mac, so you need Codex on that Mac: the CLI, the IDE extension or the desktop app.'],
    ['Should I use Codex or Claude Code?','Both connect in the same place and use the same SkyCut tools. Use the one you already pay for. We have not published a quality comparison between them.'],
    ['Is it free?','SkyCut is free to download and edit with by hand. Letting Codex edit needs SkyCut Pro at {{pro.monthly}} a month or {{pro.yearly}} a year once the 7-day trial ends, plus your own ChatGPT plan.'],
    ['Does it work on Windows?','No. SkyCut runs only on Apple silicon Macs with macOS 15 or later.'],
  ],
};
