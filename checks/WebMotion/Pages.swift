import Foundation

// The pages the web-motion checks render. Written for these checks (no film content): small, transparent, 1 s at 12 fps
// unless a check says otherwise. Hostile pages each try one thing the renderer must stop.

enum Pages {
    /// Text, a translucent box moving with t, a soft glow: a normal title.
    static let plain = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;background:transparent;overflow:hidden}
        #box{position:absolute;top:70px;width:60px;height:60px;border-radius:12px;background:rgba(0,180,255,0.55)}
        #glow{position:absolute;left:220px;top:40px;width:60px;height:60px;border-radius:50%;background:#fff;filter:blur(12px)}
        #title{position:absolute;left:16px;top:8px;font:700 30px Helvetica;color:#fff;letter-spacing:2px}
        </style></head><body><div id="glow"></div><div id="box"></div><div id="title">SKYCUT MOTION</div><script>
        const P = Object.assign({ travel: 200 }, window.MOTION_PARAMS || {});
        window.motion = { duration: 1, frame(t) {
          document.getElementById('box').style.left = (10 + t * P.travel) + 'px';
          document.getElementById('glow').style.opacity = String(0.4 + 0.6 * t);
        } };
        </script></body></html>
        """

    /// One 10 px box per row band, each moved 100 px per second by a different clock: performance.now, Date.now, a CSS
    /// animation that started at load, a requestAnimationFrame loop. The fifth band jumps by Math.random (seeded per t).
    static let clockBands = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;background:transparent;overflow:hidden}
        .b{position:absolute;left:0;width:10px;height:20px;background:#fff}
        @keyframes slide{from{transform:translateX(0px)}to{transform:translateX(200px)}}
        #css{top:60px;animation:slide 2s linear forwards}
        </style></head><body>
        <div class="b" id="perf" style="top:0"></div><div class="b" id="date" style="top:30px"></div>
        <div class="b" id="css"></div><div class="b" id="raf" style="top:90px"></div><div class="b" id="rand" style="top:120px"></div>
        <script>
        const epoch = Date.now();
        let stamp = 0;
        const loop = (time) => { stamp = time; requestAnimationFrame(loop); };
        requestAnimationFrame(loop);
        const $ = (id) => document.getElementById(id);
        window.motion = { duration: 1, frame(t) {
          $('perf').style.left = (performance.now() / 10) + 'px';
          $('date').style.left = ((Date.now() - epoch) / 10) + 'px';
          $('raf').style.left = (stamp / 10) + 'px';
          $('rand').style.left = Math.floor(Math.random() * 200) + 'px';
        } };
        </script></body></html>
        """

    /// The default layout (1080 CSS px tall) at a smaller output: a box at CSS (960, 540), 192×108, colored by a parameter.
    static let layout = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;background:transparent;overflow:hidden}
        #box{position:absolute;left:960px;top:540px;width:192px;height:108px}
        </style></head><body><div id="box"></div><script>
        document.getElementById('box').style.background = window.MOTION_PARAMS.color;
        window.motion = { frame() {} };
        </script></body></html>
        """

    /// Known alpha: nothing / 50 % green / opaque red / 25 % white at fixed spots, and a blurred white disc (a glow edge).
    static let alphaPatches = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;background:transparent;overflow:hidden}
        .p{position:absolute;top:20px;width:40px;height:40px}
        #disc{position:absolute;left:200px;top:80px;width:60px;height:60px;border-radius:50%;background:#fff;filter:blur(10px)}
        </style></head><body>
        <div class="p" style="left:60px;background:rgba(0,255,0,0.5)"></div>
        <div class="p" style="left:110px;background:#ff0000"></div>
        <div class="p" style="left:160px;background:rgba(255,255,255,0.25)"></div>
        <div id="disc"></div><script>window.motion = { frame() {} };</script></body></html>
        """

    static let loopInFrame = """
        <!doctype html><html><body style="margin:0;background:transparent"><div id="d" style="position:absolute;width:40px;height:40px;background:#fff"></div><script>
        window.motion = { frame(t) { if (t >= 0.5) { while (true) {} } document.getElementById('d').style.left = (t * 100) + 'px'; } };
        </script></body></html>
        """

    static let loopAtLoad = "<!doctype html><html><body><script>while (true) {}</script></body></html>"

    static let errorInFrame = """
        <!doctype html><html><body style="margin:0;background:transparent"><div style="width:40px;height:40px;background:#fff"></div><script>
        window.motion = { frame(t) { if (t >= 0.5) { undefinedFunction(); } } };
        </script></body></html>
        """

    /// Keeps a counter between frames: every page instance and every draw order gives another picture for the same t.
    static let keepsState = """
        <!doctype html><html><body style="margin:0;background:transparent"><div id="d" style="position:absolute;top:10px;width:20px;height:20px;background:#fff"></div><script>
        let x = 0;
        window.motion = { frame(t) { x += 7; document.getElementById('d').style.left = (x % 280) + 'px'; } };
        </script></body></html>
        """

    static let noFrameEntry = "<!doctype html><html><body><script>window.motion = { duration: 1 };</script></body></html>"

    /// A 40000×40000 canvas and a 60000 px body: the output size must not move and nothing may crash.
    static let hugeCanvas = """
        <!doctype html><html><body style="margin:0;background:transparent;width:60000px;height:60000px"><script>
        const c = document.createElement('canvas'); c.width = 40000; c.height = 40000;
        const g = c.getContext('2d'); document.body.appendChild(c);
        window.motion = { frame() { if (g) { g.fillStyle = '#fff'; g.fillRect(0, 0, 40000, 40000); } } };
        </script></body></html>
        """

    /// Takes 128 MB more each frame (really written), up to 1 GB.
    static let memoryHog = """
        <!doctype html><html><body style="margin:0;background:transparent"><div style="width:20px;height:20px;background:#fff"></div><script>
        const keep = [];
        window.motion = { frame() {
          if (keep.length < 8) { const a = new Uint8Array(128 * 1024 * 1024); for (let i = 0; i < a.length; i += 4096) a[i] = 1; keep.push(a); }
        } };
        </script></body></html>
        """
}
