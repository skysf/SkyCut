// 四语言共用的功能行与授权差异 文案和样式不在这里 来源供测试和文档核对 不展示给访客
const row=(id,sources,free='included',pro='included')=>({id,sources,free,pro});
const architecture=name=>`docs/architecture/${name}.md`;
export const featureGroups=[
  {id:'pro',rows:[
    row('aiEditing',[architecture('ai-control-mcp'),'Sources/SrtFlowMCPKit/MCPToolCatalog.swift','Sources/SrtFlow/SkyStudio/SkyCutGates.swift'],'unavailable','ai'),
    row('watermark',[architecture('sky-studio-account')],'watermarked','clean'),
    row('cloudAI',[architecture('sky-studio-jobs')],'unavailable','cloudAI'),
    row('annualCredits',['docs/plans/2026-10-27-paid-plans-and-sky-studio-key.md'],'none','annualCredits'),
  ]},
  {id:'editing',rows:[
    row('multitrack',[architecture('video-tracks'),architecture('clip-animation')]),
    row('timeline',[architecture('timeline-drag-gestures'),architecture('timeline-clipboard'),architecture('timeline-linkage')]),
    row('speed',[architecture('timeline-drag-gestures'),'Sources/SrtFlow/VideoEditFreezeFrame.swift']),
    row('projects',[architecture('video-edit-project-file'),architecture('open-projects'),architecture('optimized-media')]),
  ]},
  {id:'picture',rows:[
    row('transform',[architecture('preview-free-transform')]),
    row('animation',[architecture('clip-animation'),architecture('keyframe-animation'),architecture('video-fades')]),
    row('transitions',[architecture('transition-handles')]),
    row('color',[architecture('filters')]),
    row('covers',[architecture('cover-blur-mosaic')]),
  ]},
  {id:'graphics',rows:[
    row('text',[architecture('text-overlays')]),
    row('textAnimation',[architecture('text-overlays')]),
    row('shapes',[architecture('shapes')]),
  ]},
  {id:'sound',rows:[
    row('audioEdit',[architecture('audio-waveform'),architecture('audio-volume-curve'),architecture('audio-fades')]),
    row('mixing',[architecture('audio-mixer')]),
    row('scenes',[architecture('sound-scenes')]),
    row('library',['Sources/SrtFlow/AudioLibraryPanel.swift']),
  ]},
  {id:'subtitles',rows:[
    row('subtitleEdit',['README.md',architecture('subtitle-track-visibility-and-layout')]),
    row('subtitleStyle',[architecture('subtitle-track-visibility-and-layout'),'README.md']),
  ]},
  {id:'tools',rows:[
    row('recording',['README.md',architecture('screen-recording-lifecycle')]),
    row('compression',['README.md',architecture('export-settings')]),
    row('subtitleTools',['README.md']),
  ]},
  {id:'export',rows:[
    row('videoExport',[architecture('export-settings'),'Sources/SrtFlowCore/VideoEncodeSettings.swift']),
    row('audioExport',[architecture('export-settings'),architecture('export-audio-mixdown')]),
    row('subtitleExport',[architecture('export-settings')]),
  ]},
];
// 本机计算不扣积分 入口是否能直接点和 MCP 授权是两回事
export const localModelRows=[
  row('speech',['Sources/SrtFlow/SubtitleGen/SpeechTranscriptionService.swift'],'localUI','localBoth'),
  row('translation',['Sources/SrtFlow/SubtitleGen/SubtitleTranslationService.swift'],'localUI','localBoth'),
  row('vision',['Sources/SrtFlow/AIVision.swift'],'unavailable','localAI'),
  row('shots',['Sources/SrtFlow/AIShotScan.swift','Sources/SrtFlow/AIShotDetector.swift'],'unavailable','localAI'),
  row('kokoro',['Sources/SrtFlow/AIVoiceRole.swift','Sources/SrtFlow/KokoroVoiceSettingsRow.swift'],'unavailable','localAI'),
  row('synth',['Sources/SrtFlow/SoundEffects/SoundEffectPreset.swift',architecture('sound-effect-synth')],'unavailable','localAI'),
];
