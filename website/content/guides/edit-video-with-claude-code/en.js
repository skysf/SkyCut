// English. Interface names are the app's own: Connect AI, Undo This Round, Ask for approval, Full access.
export default {
  title:'How to Edit Video with Claude Code on a Mac',
  description:'Claude Code cannot open a video editor by itself. Connect it to SkyCut on a Mac and it cuts, captions and exports on a real timeline you can review.',
  heading:'How to edit video with Claude Code on a Mac',
  answer:'Claude Code can edit video once it has an editor to drive. On a Mac, install SkyCut, add your Sky Studio key, and click **Connect** next to Claude Code in SkyCut’s settings. Claude then works on a real multitrack timeline through SkyCut’s local MCP server: it looks at your footage, cuts the pauses out of speech, adds titles and subtitles, and exports the result, while you watch each change and can adjust or undo it. SkyCut runs on Apple silicon Macs with macOS 15 or later. There is no Windows or Intel version.',
  sections:[
    {heading:'What Claude Code can and cannot do with video',blocks:[
      'Claude Code is an AI agent that works in your terminal. It reads files and runs commands, but it has no way to watch a video, hear its sound or arrange clips. To edit, it needs a tool that does those things for it. There are two kinds.',
      {list:[
        '**Command line tools.** Claude writes FFmpeg commands or runs a skill that wraps them. This suits file jobs such as trimming, joining and converting. Each change renders a new file, and there is no timeline for you to open and fix by hand.',
        '**A video editor that Claude can control.** The editor exposes its timeline through MCP (Model Context Protocol), the standard way to give an AI assistant tools. Claude calls those tools, and every edit lands on a timeline that you can play, scrub and change yourself.',
      ]},
      'SkyCut is the second kind: a native Mac video editor with an MCP server built in. The rest of this guide uses it.',
    ]},
    {heading:'What you need',blocks:[
      {list:[
        'A Mac with Apple silicon (M1 or later) running macOS 15 or later. Features that transcribe speech, such as cutting pauses and generating subtitles, need macOS 26.',
        'SkyCut. The download is free.',
        'SkyCut Pro. AI editing is a Pro feature. A 7-day Pro trial starts the first time you connect SkyCut to your Sky Studio account, once per account and once per Mac.',
        'Claude Code, installed and signed in with your own Claude plan. SkyCut does not include an AI subscription.',
      ]},
      {note:'Claude Desktop and Codex connect in the same place and work the same way. A regular ChatGPT chat in the browser cannot connect, because SkyCut’s MCP server runs locally on your Mac.'},
    ]},
    {heading:'Set it up in five steps',blocks:[
      {steps:[
        ['Install SkyCut','Download SkyCut, open the disk image and drag SkyCut to Applications. The [setup guide](/en/docs/#video) has a short video of this step.'],
        ['Add your Sky Studio key','Sign in to Sky Studio, open your avatar at the top right, choose SkyCut and create a key. In SkyCut, open Settings, go to Sky Studio and paste the key. This is what turns on Pro and starts the trial.'],
        ['Connect Claude Code','In SkyCut, open **Settings → Connect AI** and click **Connect** next to Claude Code. SkyCut registers its MCP server with Claude Code by running `claude mcp add` for you, and allows SkyCut’s tools so Claude does not stop to ask permission for each one.'],
        ['Start a new Claude Code session','Claude Code loads MCP servers when a session starts. Open a new session and type `/mcp`. You should see `skycut` in the list.'],
        ['Point Claude at your footage','Tell Claude which folder holds your clips and what you want to make. SkyCut opens that folder, and new files such as exports are saved there.'],
      ]},
    ]},
    {heading:'Prompts for a first edit',blocks:[
      'You talk to Claude in plain language. These prompts each map to things SkyCut can do, and you can run them one after another on the same project.',
      {prompt:'Open the folder ~/Movies/interview in SkyCut. Look at every clip and tell me what is in each one.'},
      {prompt:'Start a 16:9 project and build a rough cut from the three strongest takes.'},
      {prompt:'Remove the long pauses and the filler words from the talking head clip.'},
      {prompt:'Generate English subtitles, then add a Spanish translation as a second track.'},
      {prompt:'Add a title that reads Antarctica over the first three seconds, then export a 1080p MP4.'},
      'Claude can also frame a subject, cut music to the beat, layer and animate clips, add narration and inspect the finished video for problems. If you would rather not describe every step, ask for an editing style such as documentary or vlog and let it plan the cut.',
    ]},
    {heading:'Review what Claude did',blocks:[
      'This is the reason to use a real editor. While Claude works, SkyCut shows **AI is editing** in the toolbar and moves to each change as it happens. You can press **Stop** at any moment.',
      {list:[
        'Every tool call is one undo step, so ⌘Z walks back through Claude’s edits one at a time.',
        'When Claude finishes, **Undo This Round** puts the project back to how it was before the round started.',
        'Nothing is locked. Drag a clip, retime a subtitle or change a title by hand, then ask Claude to carry on from there.',
        'SkyCut has two permission modes. **Ask for approval** pauses before Claude goes beyond the defaults, for example before it deletes a file. **Full access** proceeds and reports what it did. Daily budgets for paid generation apply in both.',
      ]},
    ]},
    {heading:'What it costs',blocks:[
      {table:{head:['What','Price','Notes'],rows:[
        ['SkyCut Free','{{free.price}}','The full manual editor. Exports carry a watermark. No AI editing.'],
        ['SkyCut Pro','{{pro.monthly}} a month or {{pro.yearly}} a year','AI editing and exports without the watermark. Starts with a 7-day trial the first time you connect SkyCut.'],
        ['Claude Code','Your own Claude plan','Paid to Anthropic. Not part of SkyCut.'],
        ['Cloud generation','Optional','Generated images, video, music and voices use Sky Studio credits, bought separately.'],
      ]}},
      'Prices exclude tax. The full list of what each plan includes is on the [pricing table](/en/#pricing).',
    ]},
    {heading:'Limits to know before you start',blocks:[
      {list:[
        'Mac only: Apple silicon and macOS 15 or later. SkyCut does not run on Windows or on Intel Macs.',
        'Claude does not watch your video the way you do. It samples frames, listens to levels and reads transcripts through SkyCut’s tools, so check the cut before you publish it.',
        'Your project and footage stay on your Mac, but Claude receives what the tools return, such as frames and transcripts, as part of your conversation.',
      ]},
    ]},
    {heading:'Other ways to edit video with Claude',blocks:[
      'SkyCut is not the only route, and the right one depends on the job.',
      {list:[
        '**FFmpeg based skills.** Open source skills for Claude Code wrap FFmpeg and Whisper and run from the terminal. They are a good fit for batch jobs on files and need no editor. There is no timeline to review.',
        '**MCP servers for other editors.** A community project controls DaVinci Resolve through its scripting API. It runs on macOS, Windows and Linux, and external scripting needs the paid Studio edition of Resolve.',
      ]},
      'Choose SkyCut when you are on a Mac and want Claude to work in an editor that you can also drive by hand.',
    ]},
  ],
  faq:[
    ['Can Claude Code edit video by itself?','No. Claude Code works with text and commands. It needs FFmpeg or a video editor it can control, such as SkyCut, to change a video.'],
    ['Does this work with Claude Desktop or Codex?','Yes. **Settings → Connect AI** in SkyCut has a Connect button for Claude Desktop, Claude Code and Codex. Other clients work if they support local stdio MCP servers.'],
    ['Is it free?','SkyCut is free to download and edit with by hand. Letting Claude edit needs SkyCut Pro at {{pro.monthly}} a month or {{pro.yearly}} a year once the 7-day trial ends, plus your own Claude plan.'],
    ['Does it work on Windows?','No. SkyCut runs only on Apple silicon Macs with macOS 15 or later.'],
    ['Does my footage get uploaded?','SkyCut edits on your Mac and keeps the project there. Claude receives what the tools return for your request, such as frames and transcripts.'],
  ],
};
