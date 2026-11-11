// English. Interface names are the app's own: Add Subtitle File…, Translate All, Translate Missing & Stale, Bilingual, Export Subtitle Files.
export default {
  title:'Translate Subtitles on Mac and Show Two Languages',
  description:'Translate an SRT file or generated subtitles on your Mac, show the original and the translation together, and export each language. Free in SkyCut.',
  heading:'How to translate subtitles and make bilingual subtitles on a Mac',
  answer:'In SkyCut, add your video and its subtitle file to a project, or generate the subtitles from the speech. Open the subtitles panel, choose a **Target language** and click **Translate All**. The translation becomes a second subtitle track next to the original, and you can show either one or both on the picture. Translation runs on your Mac with Apple Translation and needs macOS 15 or later. When you are done, burn one or both languages into the video, or export a subtitle file for each language. All of this is in the Free plan. SkyCut runs only on Apple silicon Macs.',
  sections:[
    {heading:'What you need',blocks:[
      {list:[
        'A Mac with Apple silicon running macOS 15 or later. Translating does not need macOS 26. Only generating subtitles from speech does.',
        'SkyCut. The download is free, and translating by hand needs no account.',
        'Subtitles to translate: a subtitle file such as SRT, WebVTT or ASS, or subtitles that SkyCut generated from the video.',
      ]},
    ]},
    {heading:'Translate in four steps',blocks:[
      {steps:[
        ['Bring in the video and the subtitles','Create a project and drag the video in. Then use **Add Subtitle File…** to attach your subtitle file. If you have no file, generate the subtitles first, as described in [the automatic subtitles guide](/en/guides/auto-subtitles-on-mac/).'],
        ['Open the subtitles panel','Click the subtitles button in the toolbar. Its tip reads **Generate, translate, and edit subtitle tracks**.'],
        ['Choose the language','Under **Translate**, pick the **Target language**. A language marked as needing a download is fetched by macOS the first time.'],
        ['Click Translate All','The translation appears as its own subtitle track. The original is not changed.'],
      ]},
    ]},
    {heading:'Check and fix the translation',blocks:[
      {list:[
        'Machine translation gets names, jargon and jokes wrong. Read the translated track once, and click any line to rewrite it.',
        'The two tracks are independent. You can change the wording or the timing of a translated line without touching the original.',
        'When you change the original later, **Translate Missing & Stale** translates only the lines that are new or whose original changed, and leaves the rest alone.',
      ]},
    ]},
    {heading:'Show one language or two',blocks:[
      {table:{head:['You want','Set the preview track to','What you see'],rows:[
        ['The original only','**Original text**','One line of subtitles in the source language'],
        ['The translation only','**Translated text**','One line of subtitles in the target language'],
        ['Both at once','**Bilingual**','The translation directly under the original'],
      ]}},
      'In bilingual view the two lines move as one block. Drag one of them on the picture and they separate, so you can put the original at the bottom and the translation at the top, for example.',
    ]},
    {heading:'Export each language',blocks:[
      {list:[
        '**Burned in.** Tick **Burn subtitles into the video** in the export panel. The tracks that are visible are drawn onto the picture, so show both tracks for bilingual subtitles or hide one for a single language.',
        '**As files.** **Export Subtitle Files** writes one file per language next to the video. The language is part of the file name, which is how players and platforms tell the tracks apart.',
        '**Several versions.** Export the video once without burning, then export the subtitle files. One video and one file per language covers every platform that accepts subtitle files.',
      ]},
    ]},
    {heading:'Or ask an AI assistant',blocks:[
      'With SkyCut Pro, Claude or Codex can do the whole job from one request. Connect the assistant as described in [the Claude Code guide](/en/guides/edit-video-with-claude-code/).',
      {prompt:'Translate the subtitles into Spanish and Japanese, and export a subtitle file for each language.'},
      'A project keeps one translation at a time, so the assistant translates and exports one language after the other. It uses the same on-device translation as the panel.',
    ]},
    {heading:'Limits to know',blocks:[
      {list:[
        'The language pairs you can translate are the ones macOS offers on your Mac.',
        'A project holds the original and one translation at a time. For several languages, translate, export the subtitle file, then translate into the next language.',
        'Videos exported on the Free plan carry a watermark. Subtitle files have none.',
        'SkyCut is Mac only: Apple silicon and macOS 15 or later, with no Windows or Intel version.',
      ]},
    ]},
  ],
  faq:[
    ['Is translating subtitles free in SkyCut?','Yes. Translating, editing and exporting subtitles by hand is part of the Free plan and needs no account.'],
    ['Are my subtitles sent to a server?','No. Translation runs on your Mac with Apple Translation. macOS may download a language the first time.'],
    ['Can I translate an existing SRT file?','Yes. Add the video, attach the file with **Add Subtitle File…** and translate it. The timing of every line is kept.'],
    ['How do I get bilingual subtitles in the video?','Translate, show both tracks by setting the preview track to **Bilingual**, and tick **Burn subtitles into the video** when you export.'],
    ['Does it need macOS 26?','No. Translation works on macOS 15 or later. Only generating subtitles from speech needs macOS 26.'],
  ],
};
