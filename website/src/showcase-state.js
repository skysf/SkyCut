// Deterministic demo timing only. No generation, app control or remote requests.
import {SHOWCASE_MEDIA,LANGUAGE_CODES} from './showcase-media.js';
export const SHOWCASE_TIMING = {
  create: [0, 3.5, 8, 12.5, 17.5, 32.5, 39],
  upscale: [0, 3, 10, 14, 18, 23],
  translate: [0, 3, 10, 14, 19, 25],
};
const clamp = value => Math.max(0, Math.min(1, value));
export function showcaseFrame(kind, seconds) {
  const timing = SHOWCASE_TIMING[kind];
  if (!timing) throw new Error(`Unknown showcase ${kind}`);
  const count = timing.length - 2;
  const time = Math.max(0, seconds) % timing.at(-1);
  const finished = time >= timing[count];
  const phase = finished ? count - 1 : timing.findIndex((start, i) => i < count && time >= start && time < timing[i + 1]);
  const progress = clamp((time - timing[phase]) / (timing[phase + 1] - timing[phase]));
  const create = kind === 'create';
  const duration = SHOWCASE_MEDIA[kind].duration;
  const mediaTime = create ? Math.min(duration,Math.max(0,time-timing[4])) : time%duration;
  return {
    time, phase, progress, finished,
    prompt: clamp(time / 1.8),
    scriptCount: !create || phase < 1 ? 0 : phase > 1 ? 3 : Math.min(3, 1 + Math.floor(progress * 3)),
    character: create && phase >= 2,
    shots: !create || phase > 3 ? 3 : phase < 3 ? 0 : Math.min(3, 1 + Math.floor(progress * 3)),
    clips: !create ? 1 : phase > 4 || finished ? 3 : phase < 4 ? 0 : Math.min(3, 1 + Math.floor(progress * 5)),
    enhancement: kind === 'upscale' ? (phase > 1 ? 1 : phase === 1 ? progress : 0) : 0,
    resolution: kind === 'translate' || kind === 'upscale' && phase < 2 ? '1280×720' : '1920×1080',
    translationCount: kind !== 'translate' || phase < 1 ? 0 : phase > 1 ? LANGUAGE_CODES.length : Math.min(LANGUAGE_CODES.length, 1 + Math.floor(progress * LANGUAGE_CODES.length)),
    mediaTime,
    playhead: mediaTime/duration,
    transfer: !finished && phase > 0 && progress < .2 ? progress / .2 : -1,
  };
}
export function phaseTime(kind, phase) {
  const timing = SHOWCASE_TIMING[kind];
  if (!Number.isInteger(phase) || phase < 0 || phase >= timing.length - 2) throw new RangeError('Invalid phase');
  return timing[phase] + (timing[phase + 1] - timing[phase]) * .48;
}
