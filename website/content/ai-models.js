// Sky Studio /models 的快照 只列 SkyCut 目录 不扩展到 Studio 网站的全部模型
// 与角色功能共用同一发布快照 来源合同见官网架构文档
// 2026-11-10 按 Sky Studio PR #245 的 head 更新 Omni 换成 1.2 Veo 3.1 Pro 下架（写这一版时 #245 还没合并）
export const skyStudioRevision='86b797a9c935c3499674fce33525ab0255527745';
export const skyStudioApiSource=`https://github.com/skysf/skystudio-aigc-app/blob/${skyStudioRevision}/docs/agents/skycut-api.md`;
const model=(id,title,kinds,operation)=>({id,title,kinds,...(operation?{operation}:{})});
const video=(id,title)=>model(id,title,['text_to_video','image_to_video']);
export const cloudModelGroups=[
  {id:'images',models:[
    model('seedream5-flash','Seedream 5.0 Flash',['image']),model('nano2','Nano Banana 2',['image']),
    model('nano2-lite','Nano Banana 2 Lite',['image']),model('nano-banana-pro','Nano Banana Pro',['image']),
    model('gpt-image-2','GPT Image 2',['image']),model('seedream5-pro','Seedream 5.0 Pro',['image']),
  ]},
  {id:'imageAngle',models:[model('qwen-angles','Qwen Angles',['image'],'camera_angle')]},
  {id:'imageUpscale',models:[model('image-upscale','Image Upscale',['image'],'upscale')]},
  {id:'background',models:[model('ideogram-remove-background','Ideogram Remove Background',['image'])]},
  {id:'video',models:[
    video('minimax-h3','Minimax H3'),video('gemini-omni-1.2-flash','Gemini Omni 1.2 Flash'),
    video('veo-fast','Veo 3.1 Fast'),video('seedance-2-pro','Seedance 2.0 Pro'),video('seedance-2-5','Seedance 2.5'),
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
