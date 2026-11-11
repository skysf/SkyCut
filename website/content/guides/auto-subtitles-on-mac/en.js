// English. Interface names are the app's own: Generate Subtitles, Auto-detect, Lines per subtitle, Translate All, Export Subtitle Files.
export default {
  title:'Auto Subtitles on Mac: Generate, Translate, Export',
  description:'Generate subtitles from speech on your Mac, translate them, then burn them in or export SRT. SkyCut does it on the Mac, and the Free plan includes it.',
  heading:'How to add automatic subtitles to a video on a Mac',
  answer:'In SkyCut, put your video on the timeline, open the subtitles panel and click **Generate Subtitles**. SkyCut transcribes the speech on your Mac with Apple speech recognition, splits it into short readable lines and places them on a subtitle track that you can edit. You can translate that track on the same Mac, then burn the subtitles into the video or export them as subtitle files. Generating needs macOS 26, translating needs macOS 15, and SkyCut runs only on Apple silicon Macs. All of it is part of the Free plan; videos exported on Free carry a watermark.',
  sections:[
    {heading:'What you need',blocks:[
      {list:[
        'A Mac with Apple silicon. Generating subtitles from speech needs macOS 26. Translating subtitles needs macOS 15 or later.',
        'SkyCut. The download is free, and you do not need an account to generate, translate or export subtitles by hand.',
        'The speech model for the language spoken in your video. macOS downloads it the first time, so stay online for that run.',
      ]},
    ]},
    {heading:'Generate subtitles in four steps',blocks:[
      {steps:[
        ['Put the video on the timeline','Create a project and drag your video in. If the project has music or a screen recording with its own sound, that is fine. You can limit which clips are transcribed in step 3.'],
        ['Open the subtitles panel','Click the subtitles button in the toolbar. Its tip reads **Generate, translate, and edit subtitle tracks**.'],
        ['Choose the settings','Under **Generate from audio**, leave **Source language** on **Auto-detect** or pick the language yourself. **Lines per subtitle** is **1 line** by default, and you can allow **2 lines**. To transcribe only the voice, select those clips on the timeline first and tick **Only the selected clips**.'],
        ['Click Generate Subtitles','SkyCut reads the audio, transcribes it and builds the subtitles. They appear on a subtitle track, and the whole result is one undo step.'],
      ]},
    ]},
    {heading:'What the generated subtitles look like',blocks:[
      'SkyCut does more than paste the transcript onto the screen. It follows the conventions of broadcast subtitles.',
      {list:[
        'Sentences are split at natural breaks such as commas, and very short pieces are merged with their neighbor.',
        'Each subtitle is one line unless you allow two. Text that does not fit becomes the next subtitle.',
        'Punctuation at the end of a line is dropped, and commas inside a line become spaces. Question marks and quotation marks stay.',
        'Subtitles stay on screen long enough to read and do not overlap.',
        'Clips that you have hidden on the timeline are not transcribed.',
      ]},
      'Speech recognition makes mistakes, mostly with names and jargon. Click a subtitle on the timeline to fix its words or timing, or use **Edit Subtitles…** to go through them as a list.',
    ]},
    {heading:'Translate the subtitles',blocks:[
      {steps:[
        ['Pick a language','In the same panel, under **Translate**, choose the **Target language**. A language marked as needing a download is fetched by macOS the first time.'],
        ['Click Translate All','The translation appears as a second subtitle track. The original stays, so you can show the original, the translation or both. On the picture, the translation sits under the original until you drag one of them.'],
        ['Keep it in step','After you edit the original, **Translate Missing & Stale** translates only the lines that changed.'],
      ]},
      {note:'Translation runs entirely on your Mac with Apple Translation. Which language pairs are available depends on what macOS supports on your machine.'},
    ]},
    {heading:'Export: burned in or as a file',blocks:[
      {table:{head:['You want','Do this','Result'],rows:[
        ['Subtitles that are part of the picture','In the export panel, tick **Burn subtitles into the video**','One MP4 with the subtitles drawn on it. Hidden subtitle tracks are not burned.'],
        ['A subtitle file for a player or platform','In the export panel, use **Export Subtitle Files**','SRT or WebVTT files next to the video, named with their language.'],
        ['Only a subtitle file, no video','Use **Export Subtitle Files** without exporting the video','The subtitle files alone.'],
      ]}},
      'Burned-in subtitles use the font, size, outline and position set in the **Burn In Subtitles** tool, so set the look there first.',
    ]},
    {heading:'Or ask an AI assistant to do it',blocks:[
      'With SkyCut Pro you can hand the whole job to Claude or Codex. Connect the assistant once, as described in [the Claude Code guide](/en/guides/edit-video-with-claude-code/), then ask for the result.',
      {prompt:'Generate English subtitles for this project, translate them into Japanese, and export both as SRT files.'},
      'The assistant uses the same on-device recognition and translation, so the subtitles are the same ones you would get by hand.',
    ]},
    {heading:'Limits to know',blocks:[
      {list:[
        'Generating subtitles needs macOS 26. On macOS 15 you can still import a subtitle file, edit it, translate it and export.',
        'The languages you can transcribe and translate are the ones macOS offers on your Mac.',
        'Videos exported on the Free plan carry a watermark. Subtitle files are plain files and have none.',
        'SkyCut is Mac only: Apple silicon and macOS 15 or later, with no Windows or Intel version.',
      ]},
    ]},
  ],
  faq:[
    ['Is automatic subtitling free in SkyCut?','Yes. Generating, translating, editing and exporting subtitles by hand is part of the Free plan. Only the exported video carries a watermark on Free.'],
    ['Is my audio uploaded anywhere?','No. Speech recognition and translation run on your Mac. macOS may download language models the first time.'],
    ['Can I get an SRT file without exporting the video?','Yes. **Export Subtitle Files** in the export panel writes the subtitle files on their own.'],
    ['Does it work on macOS 15?','Translation, editing and export do. Generating subtitles from speech needs macOS 26.'],
    ['Can I have two languages on screen at once?','Yes. Generate the original, translate it, and show both tracks. Burning in then draws both.'],
  ],
};
