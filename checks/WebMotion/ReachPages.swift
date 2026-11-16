import Foundation

// Pages that try to reach outside the page: the network (every way known on 2026-11-17, all aimed at the check's local
// listener), the Mac's files, and the permissions / storage a page could ask for. They report what happened through
// their own error text ("SUMMARY {…}", the side channel every page has: SkyCut returns page errors verbatim).

enum ReachPages {
    /// Everything fires while loading (a page rejected at load must still have tried everything: the check keeps the
    /// helper alive a little after the result, `SRTFLOW_WEB_MOTION_TEST_LINGER`).
    static func network(port: UInt16) -> String {
        let base = "http://127.0.0.1:\(port)"
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <link rel="preconnect" href="\(base)"><link rel="dns-prefetch" href="//127.0.0.1:\(port)">
            <link rel="prefetch" href="\(base)/prefetch"><link rel="preload" as="image" href="\(base)/preload.png">
            <link rel="stylesheet" href="\(base)/style.css">
            <style>@import url("\(base)/import.css"); body{background-image:url("\(base)/bg.png")}
            @font-face{font-family:X;src:url("\(base)/font.woff2")} .f{font-family:X}</style>
            <script src="\(base)/script.js"></script>
            <meta http-equiv="refresh" content="1;url=\(base)/refresh">
            </head><body style="margin:0;background:transparent"><span class="f">x</span>
            <img src="\(base)/img.png"><video src="\(base)/v.mp4" autoplay muted></video><audio src="\(base)/a.mp3" autoplay></audio>
            <object data="\(base)/object"></object><embed src="\(base)/embed"><iframe src="\(base)/iframe"></iframe>
            <svg><image href="\(base)/svg.png" width="9" height="9"/></svg>
            <form id="form" action="\(base)/form" method="post"><input name="a" value="b"></form>
            <a id="link" href="\(base)/link" ping="\(base)/ping">x</a>
            <script>
            const B = '\(base)';
            const tryIt = (f) => { try { const r = f(); if (r && r.catch) r.catch(() => {}); } catch (e) {} };
            tryIt(() => fetch(B + '/fetch'));
            tryIt(() => fetch(B + '/keepalive', { method: 'POST', keepalive: true, body: 'x' }));
            tryIt(() => { const x = new XMLHttpRequest(); x.open('GET', B + '/xhr'); x.send(); });
            tryIt(() => new WebSocket('ws://127.0.0.1:\(port)/ws'));
            tryIt(() => new EventSource(B + '/events'));
            tryIt(() => navigator.sendBeacon(B + '/beacon', 'x'));
            tryIt(() => new FontFace('Y', 'url(' + B + '/fontface.woff2)').load());
            tryIt(() => { const i = new Image(); i.src = B + '/image.png'; });
            tryIt(() => window.open(B + '/popup'));
            tryIt(() => new Worker(URL.createObjectURL(new Blob(["fetch('" + B + "/worker')"]))));
            tryIt(() => typeof WebTransport === 'function' && new WebTransport('https://127.0.0.1:\(port)/wt'));
            tryIt(() => {
              const P = window.RTCPeerConnection || window.webkitRTCPeerConnection;
              if (!P) return;
              const pc = new P({ iceServers: [{ urls: 'stun:127.0.0.1:\(port)' },
                { urls: 'turn:127.0.0.1:\(port)?transport=tcp', username: 'u', credential: 'c' }] });
              pc.createDataChannel('d');
              return pc.createOffer().then((o) => pc.setLocalDescription(o));
            });
            tryIt(() => { const f = document.createElement('iframe'); document.body.appendChild(f);
              const R = f.contentWindow && f.contentWindow.RTCPeerConnection; if (!R) return;
              const pc = new R({ iceServers: [{ urls: 'stun:127.0.0.1:\(port)' }] }); pc.createDataChannel('d');
              return pc.createOffer().then((o) => pc.setLocalDescription(o)); });
            tryIt(() => document.getElementById('form').submit());
            tryIt(() => document.getElementById('link').click());
            tryIt(() => { location.href = B + '/navigate'; });
            window.motion = { frame(t) { tryIt(() => fetch(B + '/frame?t=' + t)); } };
            </script></body></html>
            """
    }

    /// Tries to read a file through every loader; a read that succeeds puts the file's token into the error text.
    static func files(secret: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="file://\(secret)"></head>
        <body style="margin:0;background:transparent"><object data="file://\(secret)"></object>
        <iframe src="file://\(secret)"></iframe><script>
        const U = 'file://\(secret)';
        const asPromise = (f) => new Promise((ok, no) => { try { f(ok, no); } catch (e) { no(e); } });
        const attempts = {
          fetch: () => fetch(U).then((r) => r.text()),
          xhr: () => asPromise((ok, no) => { const x = new XMLHttpRequest(); x.open('GET', U);
            x.onload = () => ok(x.responseText); x.onerror = () => no(new Error('error')); x.send(); }),
          image: () => asPromise((ok, no) => { const i = new Image(); i.onload = () => ok('loaded'); i.onerror = () => no(new Error('error')); i.src = U; }),
          font: () => new FontFace('Z', 'url(' + U + ')').load().then(() => 'loaded'),
        };
        window.motion = {
          frame() {},
          ready: Promise.all(Object.entries(attempts).map(([name, f]) => Promise.resolve().then(f)
            .then((v) => [name, 'read:' + String(v).slice(0, 200)], (e) => [name, 'blocked:' + (e && e.name || e)])))
            .then((rows) => { throw new Error('SUMMARY ' + JSON.stringify(Object.fromEntries(rows))); }),
        };
        </script></body></html>
        """
    }

    /// Camera, microphone, location, clipboard, notifications, storage. `token` is written to localStorage; a later
    /// render that sees the previous token means storage persisted.
    static func access(token: String) -> String {
        """
        <!doctype html><html><body style="margin:0;background:transparent"><script>
        const media = (kind) => () => navigator.mediaDevices
          ? navigator.mediaDevices.getUserMedia({ [kind]: true }).then(() => 'granted')
          : Promise.reject(new Error('no mediaDevices'));
        const attempts = {
          camera: media('video'),
          microphone: media('audio'),
          location: () => new Promise((ok, no) => navigator.geolocation
            ? navigator.geolocation.getCurrentPosition(() => ok('granted'), (e) => no(new Error('code ' + e.code)), { timeout: 300 })
            : no(new Error('no geolocation'))),
          clipboard: () => navigator.clipboard ? navigator.clipboard.readText().then((v) => 'granted ' + v) : Promise.reject(new Error('no clipboard')),
          notifications: () => typeof Notification === 'undefined' ? Promise.reject(new Error('no Notification'))
            : Notification.requestPermission().then((p) => { if (p === 'granted') return p; throw new Error(p); }),
          storage: () => { const before = localStorage.getItem('skycut-check'); localStorage.setItem('skycut-check', '\(token)');
            throw new Error('before=' + before); },
        };
        window.motion = {
          frame() {},
          ready: Promise.all(Object.entries(attempts).map(([name, f]) => Promise.resolve().then(f)
            .then((v) => [name, 'granted:' + String(v).slice(0, 80)], (e) => [name, 'blocked:' + (e && e.message || e)])))
            .then((rows) => { throw new Error('SUMMARY ' + JSON.stringify(Object.fromEntries(rows))); }),
        };
        </script></body></html>
        """
    }

    /// The `{…}` after "SUMMARY " in any of the page's errors.
    static func summary(in errors: [String]) -> [String: String]? {
        for error in errors {
            guard let start = error.range(of: "SUMMARY ")?.upperBound, let open = error[start...].firstIndex(of: "{"),
                  let close = error.lastIndex(of: "}"), open < close else { continue }
            let json = String(error[open...close])
            if let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String] { return object }
        }
        return nil
    }
}
