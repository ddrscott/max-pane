#!/usr/bin/env python3
"""
Fixture HTTP server for the M1 WebKit spike.

Serves a set of NON-TRIVIAL pages (real Bootstrap CSS, real highlight.js,
real marked.js, thousands of DOM nodes, real PNG images) so that the
WKWebView memory numbers reflect realistic page weight rather than
about:blank.

Binds the same content on N consecutive ports so we can probe whether
WebKit's process-per-site coalescing keys on port as well as host.

Usage: uv run serve.py --base-port 8801 --ports 20
"""
import argparse
import hashlib
import io
import os
import random
import struct
import sys
import threading
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")

WORDS = ("lane pane strip webkit process pool viewport reflow ordinal ledger "
         "snapshot evict rehydrate parented unparented render suspend resume "
         "terminal relay session scrollback project root git directory keyed "
         "identity search gather sidebar fullscreen portrait column infinite").split()


def lorem(rng, n):
    return " ".join(rng.choice(WORDS) for _ in range(n)).capitalize() + "."


def png_noise(w, h, seed):
    """Generate a real PNG of photographic-ish weight (noise compresses poorly)."""
    rng = random.Random(seed)
    raw = bytearray()
    for _y in range(h):
        raw.append(0)  # filter type 0
        raw.extend(rng.randbytes(w * 3))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))


HEAD = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title}</title>
<link rel="stylesheet" href="/assets/bootstrap.min.css">
<link rel="stylesheet" href="/assets/highlight.css">
<style>
body{{font-family:-apple-system,system-ui,sans-serif;padding:16px}}
.card{{margin-bottom:12px}}
pre code{{font-family:"JetBrains Mono",ui-monospace,monospace;font-size:12px}}
.thumb{{width:100%;height:auto;border-radius:0}}
</style></head><body>
"""

TAIL = """
<script src="/assets/lodash.min.js"></script>
<script src="/assets/marked.min.js"></script>
<script src="/assets/highlight.min.js"></script>
<script>
  document.querySelectorAll('pre code').forEach(function(b){ try{ hljs.highlightElement(b);}catch(e){} });
  window.__pageStats = { nodes: document.querySelectorAll('*').length };
</script>
</body></html>
"""

CODE_SAMPLE = """func reparent(_ pane: WebPane, into lane: LaneView) {
    let t0 = CACurrentMediaTime()
    CATransaction.begin()
    CATransaction.setCompletionBlock { record(CACurrentMediaTime() - t0) }
    lane.addSubview(pane.webView)
    pane.webView.frame = lane.bounds
    CATransaction.commit()
}
struct Ledger { var lanes: [Lane]; var panes: [Pane] }
extension Ledger { func evictCandidates(beyond d: Int) -> [PaneID] { ... } }
"""


def page_doc(n, rng):
    out = [HEAD.format(title=f"Docs page {n}")]
    out.append(f'<nav class="navbar navbar-expand-lg bg-body-tertiary"><span class="navbar-brand">Fixture Docs #{n}</span></nav>')
    out.append('<div class="container"><div class="row"><div class="col-9">')
    for s in range(24):
        out.append(f'<h2 id="s{s}">{lorem(rng, 4)}</h2>')
        for p in range(4):
            out.append(f"<p>{lorem(rng, 45)}</p>")
        out.append('<pre><code class="language-swift">' + CODE_SAMPLE.replace("<", "&lt;") + "</code></pre>")
        out.append('<table class="table table-sm"><thead><tr><th>Key</th><th>Value</th><th>Notes</th></tr></thead><tbody>')
        for r in range(8):
            out.append(f"<tr><td>{lorem(rng,1)}</td><td>{rng.randint(1,9999)}</td><td>{lorem(rng,6)}</td></tr>")
        out.append("</tbody></table>")
    out.append('</div><div class="col-3"><ul class="list-group">')
    for s in range(24):
        out.append(f'<li class="list-group-item"><a href="#s{s}">{lorem(rng,3)}</a></li>')
    out.append("</ul></div></div></div>")
    out.append(TAIL)
    return "".join(out)


def page_feed(n, rng):
    out = [HEAD.format(title=f"Feed page {n}")]
    out.append('<div class="container"><div class="row">')
    for c in range(12):
        img = f"/img/{(n * 37 + c) % 12}.png"
        out.append(f'''<div class="col-6"><div class="card">
<img class="thumb" src="{img}" width="420" height="236" alt="">
<div class="card-body"><h5 class="card-title">{lorem(rng,6)}</h5>
<p class="card-text">{lorem(rng,40)}</p>
<span class="badge text-bg-secondary">{lorem(rng,1)}</span></div></div></div>''')
    out.append("</div></div>")
    out.append(TAIL)
    return "".join(out)


def page_repo(n, rng):
    out = [HEAD.format(title=f"repo/fixture-{n}")]
    out.append(f'<div class="container"><h1>fixture-org/fixture-{n}</h1>')
    out.append('<table class="table table-hover"><tbody>')
    for f in range(60):
        out.append(f'<tr><td><a href="#">{lorem(rng,1)}.swift</a></td><td>{lorem(rng,8)}</td><td>{rng.randint(1,400)} min ago</td></tr>')
    out.append("</tbody></table>")
    for b in range(10):
        out.append('<pre><code class="language-swift">' + (CODE_SAMPLE * 3).replace("<", "&lt;") + "</code></pre>")
    out.append("</div>")
    out.append(TAIL)
    return "".join(out)


ANIM_BODY = """
<div class="container">
<h1>Animated instrument page {n}</h1>
<div id="spinner" style="width:120px;height:120px;background:#E85D00;animation:spin 1s linear infinite"></div>
<style>@keyframes spin{from{transform:rotate(0)}to{transform:rotate(360deg)}}</style>
<canvas id="cv" width="400" height="200"></canvas>
<p>raf: <span id="rafout">0</span></p>
</div>
<script>
// Page-world animation, startable/stoppable from native via window.__anim so
// that the "quiescent" idle-CPU window is not polluted by a 60 fps canvas.
(function(){
  var c = document.getElementById('cv'), ctx = c.getContext('2d'), i = 0, on = true;
  function draw(){
    if (!on) return;
    i++;
    ctx.fillStyle = '#111'; ctx.fillRect(0,0,400,200);
    ctx.fillStyle = '#E85D00'; ctx.fillRect((i*3)%380, 80, 20, 40);
    document.getElementById('rafout').textContent = i;
    requestAnimationFrame(draw);
  }
  window.__anim = {
    stop: function(){ on = false; document.getElementById('spinner').style.animationPlayState='paused'; return 'stopped'; },
    start: function(){ if(on) return 'already'; on = true; document.getElementById('spinner').style.animationPlayState='running'; requestAnimationFrame(draw); return 'started'; },
    count: function(){ return i; }
  };
  requestAnimationFrame(draw);
})();
</script>
"""


def page_anim(n, rng):
    return HEAD.format(title=f"Anim {n}") + ANIM_BODY.replace("{n}", str(n)) + TAIL


BUILDERS = {"doc": page_doc, "feed": page_feed, "repo": page_repo, "anim": page_anim}
_cache = {}
_lock = threading.Lock()


def build(kind, n):
    key = (kind, n)
    with _lock:
        if key in _cache:
            return _cache[key]
    rng = random.Random(hash(key) & 0xFFFFFFFF)
    body = BUILDERS[kind](n, rng).encode()
    with _lock:
        _cache[key] = body
    return body


_imgcache = {}


def img(n):
    with _lock:
        if n in _imgcache:
            return _imgcache[n]
    data = png_noise(420, 236, n)
    with _lock:
        _imgcache[n] = data
    return data


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, body, ctype, cache=False):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "public, max-age=3600" if cache else "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        p = self.path.split("?")[0]
        try:
            if p.startswith("/assets/"):
                name = os.path.basename(p)
                with open(os.path.join(ASSETS, name), "rb") as f:
                    data = f.read()
                ct = "text/css" if name.endswith(".css") else "application/javascript"
                return self._send(data, ct, cache=True)
            if p.startswith("/img/"):
                n = int(os.path.basename(p).split(".")[0])
                return self._send(img(n), "image/png", cache=True)
            parts = [x for x in p.split("/") if x]
            if len(parts) == 2 and parts[0] in BUILDERS:
                return self._send(build(parts[0], int(parts[1])), "text/html; charset=utf-8")
            if p == "/health":
                return self._send(b"ok", "text/plain")
        except Exception as e:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode())
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-port", type=int, default=8801)
    ap.add_argument("--ports", type=int, default=20)
    a = ap.parse_args()
    servers = []
    for i in range(a.ports):
        s = ThreadingHTTPServer(("127.0.0.1", a.base_port + i), H)
        s.daemon_threads = True
        t = threading.Thread(target=s.serve_forever, daemon=True)
        t.start()
        servers.append(s)
    print(f"fixtures on 127.0.0.1:{a.base_port}..{a.base_port + a.ports - 1}", flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
