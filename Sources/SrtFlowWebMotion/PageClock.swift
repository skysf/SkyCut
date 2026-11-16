import Foundation
import SrtFlowWebMotionKit

// MARK: - The page clock takeover (the scripts put into every page before its own)
//
// The rule: a page is a picture of the render time t and nothing else. Before any page script runs, the clock script
// replaces every way a page can see real time or real randomness, and puts the page's time under the renderer:
// - `performance.now()`, `Date.now()` / `new Date()` / `Date()`, `document.timeline.currentTime` read the render time
//   (Date counts from the request's epoch);
// - `requestAnimationFrame` callbacks, `setTimeout` / `setInterval` / `requestIdleCallback` timers run when the render
//   time passes them, in due order, never on the wall clock;
// - `Math.random`, `crypto.getRandomValues`, `crypto.randomUUID` come from a seeded generator re-seeded from (seed, t)
//   at every frame, so a frame's random numbers do not depend on which frames were drawn before;
// - CSS animations and transitions, Web Animations and SVG (SMIL) animations are paused and set to the render time.
//   An animation that exists when the page finishes loading runs from t = 0; one started later counts from the frame
//   that first saw it (which differs between page instances: such a page fails "same t twice").
// It also records the page's errors (uncaught errors, unhandled rejections, blocked loads) for the checks, and exposes
// the renderer's control object as a non-writable, non-configurable property.
//
// Written from scratch for SkyCut from that idea (2026-11-17, task G10). The probe tool's version was derived from
// OpenFilm's code and must not be copied or adapted (impl brief G10; shared rules).
// docs/architecture/web-motion-renderer.md「页面时钟」.

enum PageClock {
    static let controlName = "__SKYCUT_MOTION_CLOCK__"

    /// The clock and error capture, injected at document start in the page's world, main frame only.
    static func bootstrap(seed: UInt32, epochMilliseconds: Double) -> String {
        clockSource
            .replacingOccurrences(of: "__CONTROL__", with: controlName)
            .replacingOccurrences(of: "__SEED__", with: String(seed))
            .replacingOccurrences(of: "__EPOCH__", with: String(Int64(epochMilliseconds.rounded(.down))))
    }

    /// `window.MOTION_PARAMS` (the request's parameters) and `window.MOTION_RENDER` (what is being rendered), frozen.
    static func parameters(for request: WebMotionRequest) -> String {
        let literal = (try? JSONEncoder().encode(request.parametersJSON)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"{}\""
        let render = """
            { width: \(request.layoutWidth), height: \(request.layoutHeight), pixelWidth: \(request.width), \
            pixelHeight: \(request.height), fps: \(request.fps), duration: \(request.duration), frames: \(request.frameCount) }
            """
        return """
            (() => {
              const freeze = (value) => {
                if (value && typeof value === 'object') { Object.values(value).forEach(freeze); Object.freeze(value); }
                return value;
              };
              const define = (name, value) => Object.defineProperty(window, name,
                { value: freeze(value), writable: false, configurable: false, enumerable: true });
              define('MOTION_PARAMS', JSON.parse(\(literal)));
              define('MOTION_RENDER', \(render));
            })();
            """
    }

    /// Body for `callAsyncJavaScript` after the page loaded: fonts, `motion.ready`, then what the renderer validates.
    static let finishLoadingCall = "return await window.\(controlName).finishLoading();"

    /// Body for `callAsyncJavaScript` drawing one frame (arguments `t`, `backdrop`). Returns the errors of this frame.
    static let drawFrameCall = "return await window.\(controlName).drawFrame(t, backdrop);"

    /// Body for `callAsyncJavaScript` changing the opaque backdrop of the public alpha path (argument `backdrop`).
    static let setBackdropCall = "window.\(controlName).setBackdrop(backdrop); return null;"

    private static let clockSource = #"""
    (() => {
      'use strict';
      if (Object.prototype.hasOwnProperty.call(window, '__CONTROL__')) return;
      const SEED = __SEED__ >>> 0;
      const EPOCH = __EPOCH__;
      const MAX_ERRORS = 20;
      const MAX_TIMER_CALLS = 10000;
      let nowMs = 0;

      // ---- errors the checks report verbatim
      const errors = [];
      const text = (value) => {
        if (value instanceof Error) {
          const where = String(value.stack || '').split('\n')[0];
          return String(value) + (where ? ' (at ' + where + ')' : '');
        }
        if (typeof value === 'string') return value;
        try { return JSON.stringify(value); } catch (error) { return String(value); }
      };
      const report = (message) => { if (errors.length < MAX_ERRORS) errors.push(String(message).slice(0, 2000)); };
      const takeErrors = () => errors.splice(0, errors.length);
      addEventListener('error', (event) => {
        if (!(event instanceof ErrorEvent)) return;
        report(event.message + (event.lineno ? ' (line ' + event.lineno + ', column ' + event.colno + ')' : ''));
      }, true);
      addEventListener('unhandledrejection', (event) => report('Unhandled promise rejection: ' + text(event.reason)));
      addEventListener('securitypolicyviolation', (event) => {
        const what = event.blockedURI === 'eval' ? 'eval / new Function' : (event.blockedURI || 'a resource');
        report('Blocked: the page tried to use ' + what + ' (' + event.effectiveDirective + '). '
          + 'SkyCut motion pages cannot use the network, other files, frames, workers or eval.');
      });

      // ---- seeded randomness, re-seeded from (seed, t) at every frame
      let state = 0;
      const mix = (value) => {
        let x = value >>> 0;
        x = Math.imul(x ^ (x >>> 16), 0x85ebca6b);
        x = Math.imul(x ^ (x >>> 13), 0xc2b2ae35);
        return (x ^ (x >>> 16)) >>> 0;
      };
      const reseed = (key) => {
        const low = key % 4294967296;
        const high = Math.floor(key / 4294967296);
        state = mix(SEED ^ mix(low ^ mix(high + 0x9e3779b9)));
      };
      const nextWord = () => { state = (state + 0x9e3779b9) >>> 0; return mix(state); };
      reseed(4294967295);
      Math.random = function random() { return nextWord() / 4294967296; };
      if (typeof Crypto !== 'undefined') {
        const realGetRandomValues = Crypto.prototype.getRandomValues;
        Crypto.prototype.getRandomValues = function getRandomValues(array) {
          if (!ArrayBuffer.isView(array) || array instanceof DataView || array instanceof Float32Array
              || array instanceof Float64Array || array.byteLength > 65536) {
            return realGetRandomValues.call(this, array);
          }
          const bytes = new Uint8Array(array.buffer, array.byteOffset, array.byteLength);
          for (let i = 0; i < bytes.length; i += 4) {
            const word = nextWord();
            for (let k = 0; k < 4 && i + k < bytes.length; k += 1) bytes[i + k] = (word >>> (8 * k)) & 255;
          }
          return array;
        };
        if (typeof Crypto.prototype.randomUUID === 'function') {
          Crypto.prototype.randomUUID = function randomUUID() {
            const b = this.getRandomValues(new Uint8Array(16));
            b[6] = (b[6] & 0x0f) | 0x40;
            b[8] = (b[8] & 0x3f) | 0x80;
            const hex = Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
            return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join('-');
          };
        }
      }

      // ---- what time it is
      try { Object.defineProperty(performance, 'now', { value: function now() { return nowMs; }, configurable: true, writable: true }); }
      catch (error) {}
      const RealDate = Date;
      const dateNow = function now() { return Math.floor(EPOCH + nowMs); };
      const VirtualDate = new Proxy(RealDate, {
        apply() { return new RealDate(dateNow()).toString(); },
        construct(target, args, newTarget) { return Reflect.construct(target, args.length ? args : [dateNow()], newTarget); },
        get(target, key) { return key === 'now' ? dateNow : Reflect.get(target, key); },
      });
      try { RealDate.prototype.constructor = VirtualDate; } catch (error) {}
      window.Date = VirtualDate;
      for (const name of ['AnimationTimeline', 'DocumentTimeline']) {
        const proto = window[name] && window[name].prototype;
        if (proto && Object.getOwnPropertyDescriptor(proto, 'currentTime')) {
          try { Object.defineProperty(proto, 'currentTime', { get() { return nowMs; }, configurable: true }); } catch (error) {}
        }
      }

      // ---- timers that wait for the render time
      const timers = new Map();
      let nextTimerId = 1;
      const addTimer = (fn, delay, args, repeat) => {
        if (typeof fn !== 'function') {
          report('setTimeout / setInterval with a string is not supported in SkyCut motion pages (no eval).');
          return 0;
        }
        const id = nextTimerId;
        nextTimerId += 1;
        const wait = Math.max(0, Number(delay) || 0);
        timers.set(id, { due: nowMs + wait, fn, args, every: repeat ? Math.max(1, wait) : 0 });
        return id;
      };
      const clearTimer = function clearTimeout(id) { timers.delete(id); };
      window.setTimeout = function setTimeout(fn, delay, ...args) { return addTimer(fn, delay, args, false); };
      window.setInterval = function setInterval(fn, delay, ...args) { return addTimer(fn, delay, args, true); };
      window.clearTimeout = clearTimer;
      window.clearInterval = clearTimer;
      window.requestIdleCallback = function requestIdleCallback(fn) {
        return addTimer(() => fn({ didTimeout: false, timeRemaining: () => 0 }), 0, [], false);
      };
      window.cancelIdleCallback = clearTimer;
      const runTimers = (target) => {
        for (let calls = 0; ; calls += 1) {
          let pickId = 0;
          let pick = null;
          for (const [id, timer] of timers) {
            if (timer.due <= target && (pick === null || timer.due < pick.due || (timer.due === pick.due && id < pickId))) {
              pick = timer;
              pickId = id;
            }
          }
          if (pick === null) return;
          if (calls >= MAX_TIMER_CALLS) {
            report('More than ' + MAX_TIMER_CALLS + ' timer callbacks were due before one frame; the rest were skipped.');
            return;
          }
          nowMs = pick.due;
          if (pick.every) pick.due += pick.every; else timers.delete(pickId);
          try { pick.fn.apply(window, pick.args); } catch (error) { report(text(error) + ' (in a timer callback)'); }
        }
      };

      // ---- animation frames
      let frameCallbacks = [];
      let nextFrameId = 1;
      window.requestAnimationFrame = function requestAnimationFrame(fn) {
        const id = nextFrameId;
        nextFrameId += 1;
        frameCallbacks.push({ id, fn });
        return id;
      };
      window.cancelAnimationFrame = function cancelAnimationFrame(id) {
        frameCallbacks = frameCallbacks.filter((entry) => entry.id !== id);
      };
      if ('webkitRequestAnimationFrame' in window) {
        window.webkitRequestAnimationFrame = window.requestAnimationFrame;
        window.webkitCancelAnimationFrame = window.cancelAnimationFrame;
      }

      // ---- declarative animations follow the render time
      const animationStarts = new WeakMap();
      const settle = () => {
        if (typeof document.getAnimations === 'function') {
          for (const animation of document.getAnimations()) {
            let start = animationStarts.get(animation);
            if (start === undefined) { start = nowMs; animationStarts.set(animation, start); }
            try { animation.pause(); animation.currentTime = Math.max(0, nowMs - start); } catch (error) {}
          }
        }
        for (const svg of document.querySelectorAll('svg')) {
          if (svg.ownerSVGElement || typeof svg.pauseAnimations !== 'function') continue;
          try { svg.pauseAnimations(); svg.setCurrentTime(nowMs / 1000); } catch (error) {}
        }
      };

      // ---- the public alpha path's opaque backdrop (an inline !important background on <html>, restored after)
      let savedStyle;
      const setBackdrop = (color) => {
        const root = document.documentElement;
        if (savedStyle === undefined) savedStyle = root.getAttribute('style');
        root.style.setProperty('background', color, 'important');
      };
      const clearBackdrop = () => {
        if (savedStyle === undefined) return;
        const root = document.documentElement;
        if (savedStyle === null) root.removeAttribute('style'); else root.setAttribute('style', savedStyle);
        savedStyle = undefined;
      };

      // ---- what the renderer calls
      const advance = (seconds) => {
        const target = seconds * 1000;
        reseed(Math.round(seconds * 1e6));
        runTimers(target);
        nowMs = target;
        const due = frameCallbacks;
        frameCallbacks = [];
        for (const entry of due) {
          try { entry.fn.call(window, nowMs); } catch (error) { report(text(error) + ' (in a requestAnimationFrame callback)'); }
        }
      };
      const finishLoading = async () => {
        runTimers(0);
        // Only wait while fonts are really loading: after a page tried to navigate (location.href = …, refused),
        // document.fonts.ready never settles although status is 'loaded' (WebKit, measured 2026-11-17).
        try {
          if (document.fonts && document.fonts.status !== 'loaded') await document.fonts.ready;
        } catch (error) { report(text(error)); }
        const motion = window.motion;
        if (motion && motion.ready && typeof motion.ready.then === 'function') {
          try { await motion.ready; } catch (error) { report('motion.ready failed: ' + text(error)); }
        }
        settle();
        await null;
        const ready = window.motion;
        return {
          errors: takeErrors(),
          hasFrame: !!(ready && typeof ready.frame === 'function'),
          duration: ready && typeof ready.duration === 'number' ? ready.duration : null,
          width: window.innerWidth, height: window.innerHeight, ratio: window.devicePixelRatio,
        };
      };
      const drawFrame = async (seconds, backdrop) => {
        clearBackdrop();
        advance(seconds);
        try {
          const motion = window.motion;
          if (!motion || typeof motion.frame !== 'function') throw new TypeError('window.motion.frame is not a function');
          const pending = motion.frame(seconds);
          if (pending && typeof pending.then === 'function') await pending;
        } catch (error) {
          report(text(error) + ' (while drawing t = ' + seconds.toFixed(3) + ' s)');
        }
        settle();
        await null;
        await null;
        if (typeof backdrop === 'string') setBackdrop(backdrop);
        return takeErrors();
      };
      Object.defineProperty(window, '__CONTROL__', {
        value: Object.freeze({ finishLoading, drawFrame, setBackdrop }),
        writable: false, configurable: false, enumerable: false,
      });
    })();
    """#
}
