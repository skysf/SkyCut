// DOM updates for illustrative workflows. Scene geometry and clocks live elsewhere.
import {LANGUAGE_CODES,captionIndexAt} from './showcase-media.js';
export function createShowcaseView(section, copy, sceneCopy) {
  const stage = section.querySelector('.show-stage');
  const pick = selector => section.querySelector(selector);
  const all = selector => [...section.querySelectorAll(selector)];
  const prompt = pick('[data-prompt]');
  const steps = all('[data-chat-step]');
  const phases = all('[data-phase-button]');
  const clips = all('[data-timeline-clip]');
  const assets = all('[data-asset]');
  const scripts = all('[data-script]');
  const languages = all('[data-show-language]');
  const translatedCues = all('[data-translated-cue]');
  const playhead = pick('.show-playhead');
  const thinking = pick('.show-thinking');
  const done = pick('.show-chat-done');
  const quality = pick('[data-quality]');
  const resolution = pick('[data-resolution]');
  const output = pick('[data-output-resolution]');
  const jobTitle = pick('[data-job-title]');
  const jobMeter = pick('.show-job-meter i');
  const jobPercent = pick('[data-job-percent]');
  const subtitle = pick('[data-preview-subtitle]');
  const timecode = pick('[data-timecode]');
  let selectedLanguage = null;
  let previousPrompt = '';
  function paint(frame) {
    stage.dataset.phase = frame.finished ? 'done' : String(frame.phase);
    const promptText = sceneCopy.prompt.slice(0, Math.ceil(sceneCopy.prompt.length * frame.prompt));
    if (previousPrompt !== promptText) {prompt.textContent = promptText; previousPrompt = promptText;}
    steps.forEach((step, i) => {
      step.classList.toggle('is-complete', frame.finished || i < frame.phase);
      step.classList.toggle('is-current', !frame.finished && i === frame.phase);
      step.querySelector('p').hidden = i !== frame.phase || frame.finished;
    });
    phases.forEach((button, i) => {
      button.setAttribute('aria-pressed', String(i === frame.phase));
      button.classList.toggle('is-complete', frame.finished || i < frame.phase);
    });
    thinking.querySelector('span').textContent = frame.finished ? copy.ui.complete : copy.ui.thinking;
    // Finished: the label stays at full strength, only the dots rest.
    [...thinking.querySelectorAll('i')].forEach((dot,i) => dot.style.opacity = frame.finished ? '.25' : String(.25 + .75 * Math.max(0, Math.sin(frame.time * 4 - i))));
    done.hidden = !frame.finished;
    clips.forEach((clip,i) => {clip.style.opacity = i < frame.clips ? '1' : '.08';});
    assets.forEach((asset,i) => {asset.style.opacity = i < frame.shots ? '1' : '.12';});
    scripts.forEach((script,i) => {script.style.opacity = i < frame.scriptCount ? '1' : '.12';});
    pick('[data-clip-count]').textContent = String(frame.clips);
    resolution.textContent = frame.resolution;
    const qualityText = frame.resolution.endsWith('720') ? '720p' : '1080p';
    quality.textContent = output.textContent = qualityText;
    playhead.style.left = `${frame.playhead * 94}%`;
    timecode.textContent = `0:${String(Math.floor(frame.mediaTime)).padStart(2,'0')}`;
    const amount = sceneCopy.kind === 'upscale' ? frame.enhancement : frame.progress;
    jobMeter.style.width = `${amount * 100}%`;
    jobPercent.textContent = `${Math.round(amount * 100)}%`;
    jobTitle.textContent = sceneCopy.kind === 'upscale' ? copy.ui.enhancing : copy.ui.generating;
    pick('.show-scan').style.transform = `translateX(${frame.enhancement * 100 - 50}%)`;
    const lang = selectedLanguage ?? Math.floor(frame.time/3.8)%LANGUAGE_CODES.length;
    const code = LANGUAGE_CODES[lang];
    const cueIndex = captionIndexAt(frame.mediaTime);
    subtitle.textContent = cueIndex<0?'':copy.captions[code][cueIndex];
    translatedCues.forEach((cue,i) => {cue.textContent = copy.captions[code][i];});
    const trackLanguage = pick('[data-track-language]');
    if (trackLanguage) trackLanguage.textContent = code==='zh-Hant'?'繁中':code==='zh'?'简中':code.toUpperCase();
    languages.forEach((button,i) => button.setAttribute('aria-pressed',String(i === lang)));
    const translated = pick('.show-subtitle-lane.translated');
    if (translated) translated.style.opacity = frame.translationCount ? '1' : '.1';
  }
  return {paint, selectLanguage(index) {selectedLanguage = index;}, reset() {selectedLanguage = null;}};
}
