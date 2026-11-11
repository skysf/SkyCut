// English. Interface names are the app's own: Editing & Voices, New Voice…, Design Voice…, Change Voice…, Record Now, Choose a File.
export default {
  title:'AI Voiceover in Your Own Voice on Mac: Clone and Change',
  description:'Create a voice from a short recording in SkyCut, then have AI read your script in it or change the voice of a clip. What it needs and what it costs.',
  heading:'How to make an AI voiceover in your own voice on a Mac',
  answer:'In SkyCut, open **Settings → Editing & Voices** and create a voice from a recording of yourself talking. Thirty seconds to a minute works well. After that you can use the voice in two ways. Right-click a clip and choose **Change Voice…** to replace the speech in it with your voice, or connect Claude or Codex and ask for a voiceover that reads your script in your voice. Voices are kept in your Sky Studio account and the audio is made in the cloud, so both uses spend Sky Studio credits, and SkyCut shows the price before each paid step. SkyCut runs only on Apple silicon Macs with macOS 15 or later.',
  sections:[
    {heading:'What you need',blocks:[
      {list:[
        'A Mac with Apple silicon running macOS 15 or later, and SkyCut.',
        'A Sky Studio account connected in **Settings → Sky Studio**. The voice library lives in that account.',
        'Sky Studio credits. They are bought separately, and yearly Pro includes some each paid year.',
        'A recording of one person talking, without background music. It must be your own voice, or the speaker must have given you permission.',
        'For AI voiceovers from a script: SkyCut Pro and a connected assistant. Changing the voice of a clip works from the app on any plan.',
      ]},
    ]},
    {heading:'Create your voice',blocks:[
      {steps:[
        ['Open the voice library','Go to **Settings → Editing & Voices** and find **Voices**. Click **New Voice…**.'],
        ['Record or choose a file','Click **Record Now** to use the Mac’s microphone, or **Choose a File** to pick audio or video of the person talking. Thirty seconds to a minute works well, ten seconds of clear speech is the minimum, and a sample is at most three minutes. If the file is longer, SkyCut picks a good part and lets you play it.'],
        ['Check the language and confirm your right to the voice','SkyCut detects the language spoken and you can correct it. Tick the box that says you have the right to use this voice. Without it nothing is uploaded.'],
        ['Click Create','The voice appears in your library with a sample you can play. Creating a voice from a recording is free.'],
      ]},
      {note:'No recording to start from? **Design Voice…** makes a new voice from a description such as a warm narrator, for a one-time fee that is shown before you confirm. **Browse Preset Voices…** lets you listen to the ready-made voices.'},
    ]},
    {heading:'Two ways to use the voice',blocks:[
      {table:{head:['You have','Use','Where','Plan'],rows:[
        ['A clip where someone already speaks','**Change Voice…** replaces that speech with your voice','Right-click the clip','Any plan'],
        ['A written script and no recording','An AI voiceover reads the script in your voice','Ask Claude or Codex','SkyCut Pro'],
      ]}},
      'Both are made by Sky Studio in the cloud and spend credits. The price appears before the job starts, and a job that fails is refunded.',
    ]},
    {heading:'Change the voice of a clip',blocks:[
      {steps:[
        ['Right-click the clip','Choose **Change Voice…**. The clip needs sound and must not be muted.'],
        ['Pick a voice','Choose one of your voices. SkyCut shows the price for this clip.'],
        ['Confirm','Sky Studio separates the speech from the background and gives the speech the voice you picked.'],
        ['Check the result','The new voice and the background arrive on two new audio tracks. The original sound is muted, not deleted, and ⌘Z undoes the whole change.'],
      ]},
      'A long clip may be over the length that one change accepts. SkyCut tells you, and you can split the clip and change each part.',
    ]},
    {heading:'Have AI read a script in your voice',blocks:[
      'With SkyCut Pro, connect Claude or Codex as described in [the Claude Code guide](/en/guides/edit-video-with-claude-code/), then ask for the voiceover by naming your voice.',
      {prompt:'Add a voiceover that reads this script in my voice Sky, and add subtitles for it.'},
      {prompt:'Replace the narration on the second clip with the same lines in my voice, and keep the timing of the pictures.'},
      'The assistant gets a price for the whole script before it starts, places each line on the timeline, and can add subtitles that match the script. If you do not name a voice, it uses the default preset voice.',
    ]},
    {heading:'What it costs',blocks:[
      {table:{head:['Step','Cost'],rows:[
        ['Creating a voice from a recording','Free'],
        ['Designing a voice from a description','A one-time fee in credits, shown before you confirm'],
        ['Changing the voice of a clip','Credits for each change, shown after you pick a voice'],
        ['An AI voiceover from a script','Credits for the script, quoted before the job starts'],
        ['SkyCut Pro, needed for AI voiceovers','{{pro.monthly}} a month or {{pro.yearly}} a year'],
      ]}},
      'Some voiceovers need an extra version of your voice to be built first, which has a one-time fee. SkyCut asks before it builds one. A 7-day Pro trial starts the first time you connect SkyCut to your Sky Studio account.',
    ]},
    {heading:'Consent and limits',blocks:[
      {list:[
        'Only create a voice from your own recording or with the speaker’s permission. SkyCut asks you to confirm this for every recording.',
        'Your recording is uploaded to Sky Studio and stays in your account until you delete the voice.',
        'A voice sounds closest in the language of its recording. You can add a recording in another language to the same voice.',
        'Listen to every result before you publish. Names and unusual words can be read wrongly.',
        'SkyCut is Mac only: Apple silicon and macOS 15 or later, with no Windows or Intel version.',
      ]},
    ]},
  ],
  faq:[
    ['How long a recording do I need?','Thirty seconds to a minute of one person talking works well. Ten seconds of clear speech is the minimum, and a sample is at most three minutes.'],
    ['Is creating a voice free?','Creating a voice from a recording is free. Using it costs Sky Studio credits, and SkyCut shows the price before each paid step.'],
    ['Do I need SkyCut Pro?','Not for the voice library or for **Change Voice…**, which work from the app on any plan. An AI voiceover from a script goes through the AI tools and needs Pro.'],
    ['Can I use someone else’s voice?','Only with their permission. SkyCut asks you to confirm that you have the right to use the voice before it uploads a recording.'],
    ['Does it replace my original sound?','No. **Change Voice…** mutes the original and adds the new voice and the background on new tracks, and you can undo it.'],
  ],
};
