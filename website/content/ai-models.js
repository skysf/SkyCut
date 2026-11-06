// Sky Studio /models 的 2026-11-07 快照 只列 SkyCut 目录 不扩展到 Studio 网站的全部模型
// 来源 revision 099d92b4237e20f93c351ee00dc6d48e521f26ba 详见官网架构文档
const model=(id,title,kinds)=>({id,title,kinds});
const video=(id,title)=>model(id,title,['text_to_video','image_to_video']);
export const cloudModelGroups=[
  {id:'images',models:[model('seedream5-flash','Seedream 5.0 Flash',['image']),model('nano2','Nano Banana 2',['image'])]},
  {id:'background',models:[model('ideogram-remove-background','Ideogram Remove Background',['image'])]},
  {id:'video',models:[
    video('minimax-h3','Minimax H3'),video('gemini-omni-1.1-flash','Gemini Omni 1.1 Flash'),
    video('veo-fast','Veo 3.1 Fast'),video('veo-pro','Veo 3.1 Pro'),video('seedance-2-pro','Seedance 2.0 Pro'),video('seedance-2-5','Seedance 2.5'),
    model('wan-3.0-text-to-video','Wan 3.0 Text to Video',['text_to_video']),
    model('wan-3.0-image-to-video','Wan 3.0 Image to Video',['image_to_video']),
    model('wan-3.0-reference-to-video','Wan 3.0 Reference to Video',['image_to_video']),
  ]},
  {id:'lipsync',models:[
    model('heygen-v3-lipsync-speed','HeyGen v3 Lipsync Speed',['lipsync']),
    model('heygen-v3-lipsync-precision','HeyGen v3 Lipsync Precision',['lipsync']),
    model('minimax-h3-max-lip-sync','MiniMax H3 Max Lip Sync (Image to Video)',['lipsync']),
  ]},
  {id:'music',models:[model('lyria-3-pro','Lyria 3 Pro',['music'])]},
  {id:'narration',models:[model('eleven-v4','Eleven v4 narration',['voice'])]},
  {id:'effects',models:[model('sonilo-sfx','Sonilo sound effects',['sound_effect'])]},
  {id:'cloning',models:[model('zonos2','Zonos 2 voice clone',['voice_clone'])]},
  {id:'upscale',models:[model('topaz-starlight','Topaz Starlight',['upscale']),model('bytedance-upscaler-pro','ByteDance Upscaler Pro',['upscale'])]},
];
export const localVoiceLanguages=['zh','en','ja','es','fr','it','pt','hi'];
export const localVoiceRoles=8;
export const soundEffectPresets=['whoosh','swoosh','suction','riser','downlifter','impact','boom','hit','pop','click','tick','ding','sparkle','beep','glitch','shutter'];
