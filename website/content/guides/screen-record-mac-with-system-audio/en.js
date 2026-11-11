// English. Labels match ScreenRecordingSetupView and the editor's controls.
export default {
  title:'Record Mac Screen with System Audio, Then Edit It',
  description:'Record a display, window or region with computer audio in SkyCut, add an optional microphone track, then trim the recording on the same Mac timeline.',
  heading:'How to record your Mac screen with system audio and edit it',
  answer:'In SkyCut, open your video project, click **Record Screen** and leave **Computer audio** on. Choose a display, a window or a custom region, then start recording. Add **Microphone** if you also want narration: it is saved separately and lands on its own linked audio track. After you click **Stop** and the file finishes saving, the recording is added to the project’s timeline, ready to trim. Manual recording and editing work on the Free plan. The recording file itself has no SkyCut watermark; a video exported from the edited timeline on Free does. SkyCut requires an Apple silicon Mac with macOS 15 or later.',
  sections:[
    {heading:'What you need before recording',blocks:[
      {list:[
        'SkyCut on an Apple silicon Mac with macOS 15 or later. There is no Windows or Intel version.',
        'The project you want the recording to join. Open it in **Edit Video** before you start, and save the project so you can return to the edit.',
        'Screen recording permission when macOS asks, and microphone permission only if you turn the microphone on.',
        'A destination with enough free space. **Save to → Choose…** lets you choose it before recording. SkyCut remembers the last recording folder; the initial fallback is Downloads.',
      ]},
      'Manual recording does not need Pro or a connected AI assistant. Capture and manual editing happen on the Mac. The app interface supports English, Simplified Chinese and Spanish.',
    ]},
    {heading:'Choose computer sound, your voice, or both',blocks:[
      {table:{head:['You want','Settings in Audio'],rows:[
        ['The Mac’s sound without your narration','Leave **Computer audio** on and **Microphone** off.'],
        ['Your narration without the Mac’s sound','Turn **Computer audio** off, turn **Microphone** on and select a **Device**.'],
        ['The Mac’s sound and your narration','Turn both on and choose the microphone. Wear headphones: SkyCut does not cancel echo.'],
      ]}},
      '**Computer audio** is on by default and includes sound SkyCut itself is playing. Pause the editor preview if you do not want it in the recording. Microphone audio is a separate file and a separate timeline track, so you can change narration volume without changing the captured computer sound.',
    ]},
    {heading:'Record into your project in five steps',blocks:[
      {steps:[
        ['Set the project frame rate','Use the frame-rate menu beside the playback controls before recording. The recording follows this rate; it is not a separate setting in the recording sheet.'],
        ['Open Record Screen','Click the recording icon in the editor’s top toolbar. In **Record**, choose **Entire display**, **A window** or **Custom region**. For a region, choose the aspect ratio you need.'],
        ['Set sound, pointer and destination','Check **Computer audio**, the optional **Microphone** and its **Device**. Choose **Show pointer** and **Show clicks** as needed, then check **Save to**.'],
        ['Start and choose the source','Click **Start Recording**. For a display or window, choose it in the macOS source picker. For a custom region, drag on one display and press Return to confirm; Escape cancels. Follow any permission prompt, then wait for the countdown and recording timer.'],
        ['Stop and let the file finish','Click **Stop** on the floating controls and wait for finalizing to finish. A normal completed recording is appended to the main video track of the project where you started. The optional microphone is placed on a new, aligned linked audio track. The completion notice gives the saved path and target project.'],
      ]},
      {note:'The floating recording controls are excluded from the capture. Do a short test and play it back before a long lesson: verify the intended picture, computer sound and microphone separately.'},
    ]},
    {heading:'Trim and polish without moving to another editor',blocks:[
      {steps:[
        ['Remove setup and waiting','Drag a clip edge to trim the start or end. For a passage in the middle, select the clip, place the playhead and use **Split at Playhead** or ⌘B at each boundary, then delete the unwanted piece. Check the linked microphone after the edit.'],
        ['Balance the sound','Adjust the recording clip’s volume for computer audio and the microphone track’s volume for narration. Play a section where both overlap and listen for echo or an overpowering background.'],
        ['Add a title or subtitles','Add the title you need. For speech subtitles, see [the automatic subtitles guide](/en/guides/auto-subtitles-on-mac/). Generating them from audio requires macOS 26; recording itself works on macOS 15.'],
        ['Export the edited version','Open **Export…**, check whether you are exporting the full timeline or only selected clips, choose the destination and review the displayed output dimensions. Watch and listen to the exported file, not just the preview.'],
      ]},
      'Keep the source recording and, if used, its separate microphone file with the project. Saving a project preserves the edit; exporting a video makes a finished viewing copy.',
    ]},
    {heading:'What Free includes and where the watermark appears',blocks:[
      {table:{head:['Output or action','Free plan'],rows:[
        ['The original screen recording file','Included; the recorder does not add a SkyCut watermark.'],
        ['Recording, trimming and manual timeline editing','Included.'],
        ['A video exported from the edited timeline','Included, with a Sky Studio watermark.'],
        ['AI control of the editor and watermark-free timeline export','Requires Pro.'],
      ]}},
      'Pro costs {{pro.monthly}} a month or {{pro.yearly}} a year in US dollars, before tax. You do not need it to follow the manual recording and editing steps above. To let an assistant handle the edit, start with [the Claude Code guide](/en/guides/edit-video-with-claude-code/).',
    ]},
    {heading:'If sound or the recording is missing',blocks:[
      {table:{head:['What happened','What to check'],rows:[
        ['The picture is present but computer sound is missing','Check that **Computer audio** was on and that the intended app was actually producing sound. Inspect the completion notice for an audio warning, then make a short new test.'],
        ['There is no microphone track','Check **Microphone**, the selected **Device** and macOS microphone permission. Denied microphone access does not prevent the screen capture itself.'],
        ['Permission was granted but capture still will not start','Follow SkyCut’s permission message and quit and reopen the app after authorization. If access is still unavailable, use the app’s guidance; repeatedly toggling the macOS switch is not a reliable repair.'],
        ['The recording stopped with an issue','Read the completion notice. If a usable partial file is offered, **Add to timeline** imports it and **Keep file only** leaves it on disk. A failed recording is not proof that a usable file exists.'],
      ]}},
      'The completion notice identifies the actual project and saved files. **Show in Finder** locates a saved file; **Open recorded project** returns to its project when that project is still open. Use those details if you have several projects open.',
    ]},
    {heading:'Finish with a short playback check',blocks:[
      'For a lesson or demo, record a short sample with computer sound and narration, check the two audio sources, then record the full take. Trim and balance it on the same timeline, and check the final export. That keeps the capture, corrections and delivery in one editing workflow.',
      'If a low-resolution video inside the recording needs enhancement, [the 4K upscaling guide](/en/guides/upscale-video-to-4k-on-mac/) explains the separate cloud process, credit charges and limits.',
    ]},
  ],
  faq:[
    ['Can I record Mac system audio for free in SkyCut?','Yes. Manual screen recording with computer audio is included in Free, along with manual editing. The original recording is not watermarked by the recorder; a video exported from the edited timeline on Free has a watermark.'],
    ['Can I record system sound and my microphone together?','Yes. Turn on **Computer audio** and **Microphone**, then select the input device. The microphone is saved separately and lands on a linked audio track. Use headphones because SkyCut does not cancel echo.'],
    ['Does recording require macOS 26?','No. SkyCut screen recording works on Apple silicon Macs with macOS 15 or later. Generating subtitles from speech is a separate feature that needs macOS 26.'],
    ['Where does the recording go when I stop?','It is saved to the destination chosen before recording, and a normal completed recording is appended to the starting project’s main video track. The completion notice shows the path and actual project.'],
    ['Does SkyCut record sound it is playing itself?','Yes, when **Computer audio** is on. Pause the preview or other SkyCut playback if you do not want that sound captured.'],
    ['Will deleting a piece of the timeline delete my recording file?','Removing a clip or trimming it changes the edit rather than deleting the source file. Keep the recording and its microphone file available so the project can continue to read them.'],
  ],
};
