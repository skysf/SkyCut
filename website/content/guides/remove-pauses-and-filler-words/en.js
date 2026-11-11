// English. Linkage is the app's own name for the toolbar switch.
export default {
  title:'Remove Pauses and Filler Words from Video with AI on Mac',
  description:'Ask Claude or Codex to cut the long pauses, ums and repeated words out of a talking video. SkyCut makes the cuts on a real timeline you can review.',
  heading:'How to remove pauses and filler words from a video with AI on a Mac',
  answer:'Connect Claude or Codex to SkyCut and ask it to cut the pauses and filler words out of your talking clip. SkyCut transcribes the speech on your Mac, shortens every pause that is longer than the length you name, removes words such as um and uh and words said twice in a row, and closes the gaps on the timeline. The whole cut is one undo step. This is an AI feature, so it needs SkyCut Pro, and because it relies on speech transcription it needs macOS 26. SkyCut runs only on Apple silicon Macs.',
  sections:[
    {heading:'What you need',blocks:[
      {list:[
        'A Mac with Apple silicon running macOS 26. SkyCut itself runs on macOS 15 or later, but transcribing speech needs macOS 26.',
        'SkyCut Pro. AI editing is a Pro feature. A 7-day Pro trial starts the first time you connect SkyCut to your Sky Studio account, once per account and once per Mac.',
        'Claude Code, Claude Desktop or Codex connected to SkyCut. The setup takes a few minutes and is described in [the Claude Code guide](/en/guides/edit-video-with-claude-code/) and [the Codex guide](/en/guides/edit-video-with-codex/).',
      ]},
    ]},
    {heading:'Ask for the cut',blocks:[
      {steps:[
        ['Put the talking clip on the main video track','Create a project and drag the clip in. The speech cut works on one talking clip on the main track at a time.'],
        ['Tell the assistant what to remove','Say how long a pause may be, and whether filler words and repeated words should go. One sentence is enough.'],
        ['Let it transcribe and cut','The first time, SkyCut transcribes the clip on your Mac, which takes a moment. Then the assistant makes the cut, and the timeline closes up.'],
        ['Play it back','Listen to the result. If a cut feels tight, press ⌘Z or ask the assistant to leave longer pauses.'],
      ]},
      {prompt:'Remove the pauses longer than 0.6 seconds and the filler words from the interview clip.'},
      {prompt:'Also cut the words I say twice in a row.'},
      {prompt:'Cut out the part where I restart the sentence about pricing.'},
      {prompt:'Keep only the three strongest sentences for a 20 second teaser.'},
    ]},
    {heading:'What SkyCut does with the request',blocks:[
      {list:[
        '**Pauses.** Every pause longer than the length you name is shortened, and a short breath is left in its place, a quarter of a second unless you ask for another length.',
        '**Filler words.** Words such as um and uh, and their Chinese counterparts, are cut using the transcript.',
        '**Repeats.** A word said twice in a row is cut down to one.',
        '**Clean cut points.** A cut that would land in the middle of a word is moved into the nearest pause that SkyCut measured in the sound, and the assistant is told which cuts moved.',
        '**The timeline closes up.** The clip becomes pieces placed back to back, the clips after it move left, and its linked sound is cut with it.',
      ]},
    ]},
    {heading:'What happens to subtitles, titles and music',blocks:[
      'With **Linkage** on, which is the default, everything that sits on the clip follows it.',
      {table:{head:['On the timeline','After the cut'],rows:[
        ['A subtitle over speech that stays','Moves with its words and shrinks to the speech that is left'],
        ['A subtitle whose speech was mostly removed','Removed with it'],
        ['A title or sound effect on a removed part','Removed with it'],
        ['Music that runs across several clips','Stays where it is'],
      ]}},
      'With Linkage off, the other tracks stay where they are. Generate the subtitles again after the cut.',
    ]},
    {heading:'Check the cuts',blocks:[
      {list:[
        'Ask the assistant to check its own work. SkyCut can test every cut on the main track and report whether it sits in a pause or on speech, and suggest a better point.',
        'Fix a single cut by hand: drag the edge of a piece on the timeline, then carry on.',
        'Nothing touches your source file. The cuts live in the project, and one press of ⌘Z brings the clip back.',
      ]},
      {prompt:'Check every cut on the main track and fix any that land on a word.'},
    ]},
    {heading:'Limits to know',blocks:[
      {list:[
        'It needs SkyCut Pro and macOS 26. Without them you can still split and delete by hand on the timeline.',
        'The transcript drives the cut, and speech recognition makes mistakes. A mumbled filler can be missed, so listen once before you publish.',
        'It works in the languages that macOS can transcribe on your Mac.',
        'Music mixed into the same clip as the voice is cut together with it. Keep music on its own track.',
        'SkyCut is Mac only: Apple silicon and macOS 15 or later, with no Windows or Intel version.',
      ]},
    ]},
  ],
  faq:[
    ['Can I remove pauses without an AI assistant?','You can split the clip and delete the pauses by hand on the timeline, which is part of the Free plan. Removing them automatically goes through the AI tools and needs SkyCut Pro.'],
    ['Does it work with Chinese speech?','Yes. The filler word list covers English and Chinese, and pauses are measured from the sound in any language.'],
    ['Is my audio uploaded?','Transcription runs on your Mac. The assistant receives the transcript and what the tools return as part of your conversation.'],
    ['Will my subtitles stay in sync?','With Linkage on, subtitles follow their words through the cut. With it off, generate them again afterwards.'],
    ['Does it change my original video file?','No. The cuts are edits in the project, and you can undo them.'],
  ],
};
