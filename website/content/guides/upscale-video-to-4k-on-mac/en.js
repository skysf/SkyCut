// English. Upscale is a paid cloud job even when started manually on Free.
export default {
  title:'Upscale Video to 4K on Mac: A SkyCut Guide',
  description:'Upscale video to 4K with SkyCut and Sky Studio. Check credits, the 30-second and 30 fps limits, then compare the result and verify output size.',
  heading:'How to upscale a video to 4K on a Mac',
  answer:'In SkyCut, put a video on the timeline, right-click its clip and choose **Upscale…**. Pick a source range, select **4K** and a model offered for it, then check the quoted Sky Studio credits and output dimensions before starting. Manual upscaling is available on the Free plan, but the cloud processing spends Sky Studio credits. Work with source ranges of at most 30 seconds, including any extra handles, and source video no higher than 30 fps. When a manually started job finishes, compare the result and choose **Replace Clip** if you want it on the timeline. A 4K upscaled file and a 4K timeline export are separate steps: check the canvas and export size too. SkyCut requires Apple silicon and macOS 15 or later.',
  sections:[
    {heading:'What you need',blocks:[
      {list:[
        'SkyCut on an Apple silicon Mac with macOS 15 or later. There is no Windows or Intel version.',
        'A Sky Studio account connected in **Settings → Sky Studio**, with credits available for the quote.',
        'An internet connection: the selected source range, including extra handles, is uploaded to Sky Studio for processing.',
        'A video clip on the timeline. This command is for video, not still images or audio-only clips. Keep the original file available.',
      ]},
      'You can use the manual controls on Free. AI control through Claude or Codex needs Pro. The app interface supports English, Simplified Chinese and Spanish. Models and offers are loaded from Sky Studio, so use the choices actually shown in your app.',
    ]},
    {heading:'Check the limits before paying',blocks:[
      {table:{head:['Check','What it means'],rows:[
        ['Length: up to 30 seconds per job','The source range counts, including extra frames before and after it. Split longer uses into shorter clips.'],
        ['Frame rate: at most 30 fps','This applies to the source video. Changing only the project frame rate does not convert a 60 fps source. Prepare a compatible copy first.'],
        ['Range and speed','A retimed clip is charged and checked by the seconds of source footage used, not just its visible timeline duration.'],
        ['4K and actual dimensions','Check the width and height shown for the quote. Aspect ratio, model support and the service’s pixel limits can affect the delivered dimensions.'],
        ['Credits','The app quotes the selected range, target and model before you start. Pro does not make cloud upscaling unlimited or free.'],
      ]}},
      {note:'More output pixels are not proof that lost detail has been recovered correctly. Compare faces, small text, edges and movement with the source before using the result.'},
    ]},
    {heading:'Start a manual upscale in five steps',blocks:[
      {steps:[
        ['Choose the video clip','Select it on the timeline. Right-click and choose **Upscale…**, or open **Upscale…** in the clip inspector.'],
        ['Check What to upscale','Choose **This clip only**, **Whole file**, or, when the source is used more than once, **Longest use in this project (recommended)**. The default can cover another, longer use of the same source. Inspect the displayed duration rather than assuming only the clicked clip will be processed.'],
        ['Select 4K and a supported model','Set **Target resolution** to **4K** and choose an available model. Read any reason a row cannot run, including excessive length, frame rate, unsupported target or scale factor. Short extra handles may be included for later trimming.'],
        ['Review the quote and start','Check the credit amount, output dimensions and destination filename. The button shows **Upscale · … credits**. Starting authorizes that quote. Check the amount again if you change the range or model.'],
        ['Follow the task to completion','The task shows preparation, upload, queue, processing and download progress. Keep an eye on the app’s task entry. The estimate shown is not a promised processing time.'],
      ]},
      'Processing creates a separate file. In the manual workflow, finishing the cloud job does not by itself replace your timeline clip.',
    ]},
    {heading:'Compare, then decide whether to replace',blocks:[
      {steps:[
        ['Inspect the moving result','Use **Wipe** or **Side by side**, and check at **100%** or **200%** rather than only fitting the whole frame into a small window. Play motion as well as checking a still. The comparison plays sound from the original.'],
        ['Replace or keep the original','**Replace Clip** changes the source for covered uses of that original in this project; more than the clicked clip can be affected. **Keep Original** leaves the timeline unchanged and keeps the upscaled file on disk.'],
        ['Keep a way back','Replacement is undoable. On an enhanced clip, **Revert to Original** points it back to the source, which must still exist. **Try Another Model…** starts a new choice and a new quote, not a free retry.'],
      ]},
      'The result is normally saved beside the original, with dimensions and model in its filename. If that folder cannot be written, the app falls back to the project folder and then Downloads. Check the saved path and play that actual file to verify dimensions and restored original audio; the comparison’s original audio is not a check of the new file’s sound.',
    ]},
    {heading:'Keep the upscaled file at 4K when editing and exporting',blocks:[
      {table:{head:['You need','Use this result'],rows:[
        ['Only the enhanced video range','Use the saved upscaled file after checking it. It contains the processed source range and may include handles; it is not a render of the whole edited project.'],
        ['An edited 4K deliverable','Check that the project canvas follows 4K footage and that the export does not downscale it. A 4K asset alone does not set every project to 4K.'],
      ]}},
      {steps:[
        ['Check the first main-track clip','With **Auto** canvas, SkyCut follows the first main-track clip’s dimensions. If a lower-resolution clip is first, enhancing a later clip will not raise the canvas. For a separate 4K edit, a new project with the enhanced file first makes this explicit.'],
        ['Choose Auto and inspect the canvas size','Use the aspect-ratio menu beside the playback controls and choose **Auto**. Check the displayed width and height. The fixed aspect-ratio presets currently use 1080-class dimensions; they do not have a separate 4K size control.'],
        ['Check the export dimensions','In **Export… → Resolution**, choose **Same as project** and confirm the displayed dimensions meet your delivery requirements. The export resolution control only reduces size; selecting a cap cannot enlarge a smaller canvas. Play the final file after export.'],
      ]},
    ]},
    {heading:'Credits, cancellation and watermarks',blocks:[
      {table:{head:['Question','Behavior'],rows:[
        ['What do I pay?','Sky Studio credits for the chosen range, model and target. Check the current quote in the app before starting.'],
        ['Can I cancel?','Cancellation is available while the job is queued. Once processing has started, it cannot be cancelled; credits are spent and the result still goes to your Sky Studio library.'],
        ['What if the job fails?','Sky Studio refunds failed jobs. Check the task’s actual status and charge rather than assuming closing a panel cancelled it.'],
        ['Does Free add a watermark?','SkyCut does not add its timeline-export watermark to the upscaled asset itself. A later edited-timeline export on Free has a Sky Studio watermark.'],
      ]}},
      'The app records the actual charge when the task finishes. Keep the task details if you need to check a charge. Selecting another model or starting again is another paid operation with its own quote.',
    ]},
    {heading:'Or ask an AI assistant to do it',blocks:[
      'With SkyCut Pro, a connected Claude or Codex can request the same upscale operation. Setup is in [the Claude Code guide](/en/guides/edit-video-with-claude-code/). Pro costs {{pro.monthly}} a month or {{pro.yearly}} a year in US dollars, before tax; cloud credits and your external assistant service are separate.',
      {prompt:'Inspect this clip’s source duration, frame rate and dimensions. Check them against the 30-second and 30 fps limits. Do not call upscale_clip or start any paid task.'},
      'For an exact quote you can review before authorizing payment, use the manual panel above. The AI upscale tool can start paid work within the configured permissions and budget; do not assume every call first stops for a chat confirmation. Completed AI-started jobs automatically replace eligible timeline sources without waiting for the manual comparison decision. Review the result and use undo or the original-source controls if needed.',
    ]},
    {heading:'Finish by checking the file you will deliver',blocks:[
      'Start with one short compatible range, read its quote, compare the processed result and keep the original. For an edited 4K delivery, verify the Auto canvas and the output dimensions as well. Judge the result by the actual exported file, including its motion and sound.',
      'If you are making a screen-based lesson, [record the screen with system audio](/en/guides/screen-record-mac-with-system-audio/) first, then decide which short video passages need enhancement. You do not need to upscale an entire lesson to improve one clip.',
    ]},
  ],
  faq:[
    ['Is video upscaling free in SkyCut?','The manual controls work on Free, but processing spends Sky Studio credits quoted before starting. A Pro subscription is separate from these cloud charges.'],
    ['Can I upscale a whole hour-long video at once?','No. This workflow handles up to 30 seconds of source video per job, including extra handles. Split longer uses and check the source duration shown in the panel.'],
    ['Can I send a 60 fps video if my project is 30 fps?','No. The source limit is 30 fps, and a project-rate change alone does not convert the source file. Prepare a compatible copy before submitting.'],
    ['Why is my export still 1080p after upscaling?','The enhanced source and the project canvas are separate. Fixed aspect-ratio presets use 1080-class sizes. Auto follows the first main-track clip, so verify that clip, the canvas dimensions and **Same as project** in export.'],
    ['Will the original be overwritten?','The upscale creates a separate file. Manual jobs wait for **Replace Clip** before changing eligible timeline sources, and you can revert while the original file is available. AI-started jobs replace eligible sources automatically after completion.'],
    ['Can I cancel after processing starts?','No. Only queued jobs can be cancelled. Once processing starts, the credits are spent and the result still goes to the Sky Studio library. Check the real task status before retrying.'],
  ],
};
