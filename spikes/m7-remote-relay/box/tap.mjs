// Spike M7's client for the far end: runs ON the relay-tty host (node 22).
//
// Speaks the same protocol as the Mac's `m7`, over either the pty-host's own
// Unix socket (length-prefixed frames, §1) or the server's WebSocket
// (unprefixed payloads), so the two ends can be compared byte for byte, and
// so the LAN-direct auth control can be run against the box's non-loopback
// address from the box itself when the Mac is not on that LAN.
//
//   RELAY_TOKEN=… node tap.mjs <probe|echo|stream|replay> (--unix PATH | --ws ws://host:port) --id ID
//        [--auth cookie|query|none] [--n N] [--seconds S] [--clamp BYTES] [--out FILE] [--wait S]
//
// Prints one JSON line to stdout; progress to stderr. Never prints the token.
import net from "node:net";
import fs from "node:fs";
import zlib from "node:zlib";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";

const args = process.argv.slice(2);
const command = args.shift();
const opt = (n, d) => { const i = args.indexOf(`--${n}`); return i >= 0 && i + 1 < args.length ? args[i + 1] : d; };
const id = opt("id", "0368d543");
const auth = opt("auth", "cookie");
const token = process.env.RELAY_TOKEN || null;
const t0 = process.hrtime.bigint();
const nowMs = () => Number(process.hrtime.bigint() - t0) / 1e6;
const log = (s) => process.stderr.write(`${nowMs().toFixed(3).padStart(10)}  ${s}\n`);
const emit = (o) => process.stdout.write(JSON.stringify({ command, id, ...o }) + "\n");
const f64be = (v) => { const b = Buffer.alloc(8); b.writeDoubleBE(v); return b; };
const resume = (off, max) => Buffer.concat([Buffer.from([0x10]), f64be(off), ...(max == null ? [] : [f64be(max)])]);

// ---- transports: both deliver (type, body) payloads and take payloads ----
function unixTransport(path) {
  const sock = net.createConnection(path);
  let pending = Buffer.alloc(0);
  const t = { send(p) { const h = Buffer.alloc(4); h.writeUInt32BE(p.length); sock.write(Buffer.concat([h, p])); }, close() { sock.destroy(); }, label: `unix:${path}` };
  sock.on("connect", () => { t.tConnected = nowMs(); t.send(t.first); t.tFirstSent = nowMs(); });
  sock.on("data", (chunk) => {
    pending = Buffer.concat([pending, chunk]);
    while (pending.length >= 4) {
      const len = pending.readUInt32BE(0);
      if (pending.length < 4 + len) break;
      const payload = pending.subarray(4, 4 + len);
      pending = pending.subarray(4 + len);
      if (len === 0) continue;
      t.onPayload(payload[0], payload.subarray(1));
    }
  });
  sock.on("close", () => t.onClosed?.({ kind: "closed" }));
  sock.on("error", (e) => t.onClosed?.({ kind: "failed", reason: e.message }));
  return t;
}

function wsTransport(base) {
  const require = createRequire(import.meta.url);
  // relay-tty's own `ws`, for the Cookie header the built-in client cannot set.
  const WebSocket = require(process.env.WS_MODULE || `${process.env.HOME}/.nvm/versions/node/v22.23.2/lib/node_modules/relay-tty/node_modules/ws`);
  let url = `${base.replace(/^http/, "ws")}/ws/sessions/${id}`;
  const headers = {};
  if (auth === "cookie" && token) headers.Cookie = `session=${token}`;
  if (auth === "query" && token) url += `?token=${encodeURIComponent(token)}`;
  const ws = new WebSocket(url, { headers });
  ws.binaryType = "nodebuffer";
  const t = { send(p) { ws.send(p); }, close() { ws.close(1000); }, label: `${url.replace(/token=[^&]*/, "token=…")} auth=${auth} token=${token ? "set" : "none"}`, upgradeStatus: 0, text: 0 };
  ws.on("open", () => { t.tConnected = nowMs(); ws.send(t.first); t.tFirstSent = nowMs(); });
  ws.on("message", (data, isBinary) => { if (!isBinary) { t.text++; return; } if (data.length) t.onPayload(data[0], data.subarray(1)); });
  ws.on("close", (code, reason) => t.onClosed?.({ kind: code === 4001 || code === 1008 ? "authRefused" : "closed", code, reason: reason.toString() }));
  ws.on("unexpected-response", (_req, res) => { t.upgradeStatus = res.statusCode; t.onClosed?.({ kind: "failed", code: 0, upgradeStatus: res.statusCode, reason: `HTTP ${res.statusCode}` }); });
  ws.on("error", (e) => { if (!t.upgradeStatus) t.onClosed?.({ kind: "failed", reason: e.message }); });
  return t;
}

const transport = opt("unix") ? unixTransport(opt("unix")) : wsTransport(opt("ws", "http://localhost:7680"));

// ---- a session over it, with the counters ----
const S = { frames: [], offset: 0, syncs: [], replay: null, replayGz: false, handshake: null, closed: null, dataBytes: 0, dataFrames: 0, hash: createHash("sha256"), onData: null };
transport.onPayload = (type, body) => {
  S.frames.push([nowMs(), type, body.length]);
  switch (type) {
    case 0x00: S.offset += body.length; S.dataBytes += body.length; S.dataFrames++; S.hash.update(body); S.onData?.(body); break;
    case 0x03: S.replay = { plain: Buffer.from(body), delta: S.offset > 0, wire: body.length }; break;
    case 0x13: { const delta = S.offset > 0; S.replayGz = true; S.replay = { plain: zlib.gunzipSync(body), delta, wire: body.length }; break; }
    case 0x11: { const v = body.readDoubleBE(0); S.offset = (v === 0 && S.offset > 0) ? 0 : v; S.syncs.push(v); if (!S.handshake) S.handshake = nowMs(); break; }
    case 0x01: S.cols = body.readUInt16BE(0); S.rows = body.readUInt16BE(2); break;
    case 0x23: S.offset = 0; break;
  }
};
transport.onClosed = (c) => { if (!S.closed) { S.closed = { ...c, at: nowMs() }; } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(cond, ms) { const end = Date.now() + ms; while (Date.now() < end) { if (cond()) return true; await sleep(2); } return cond(); }
const summary = () => ({
  path: transport.label, handshake: !!S.handshake, tSyncMs: S.handshake, tConnectedMs: transport.tConnected, frames: S.frames.map(([, t, l]) => [`0x${t.toString(16).padStart(2, "0")}`, l]),
  offset: S.offset, cols: S.cols, rows: S.rows, syncs: S.syncs, dataBytes: S.dataBytes, dataFrames: S.dataFrames,
  replayPlainBytes: S.replay?.plain.length, replayWireBytes: S.replay?.wire, replayGz: S.replayGz, replayDelta: S.replay?.delta,
  close: S.closed && `${S.closed.kind} ${S.closed.code ?? ""} ${S.closed.reason ?? ""}`.trim(), closeFinal: S.closed?.kind === "authRefused", upgradeStatus: transport.upgradeStatus ?? 0, textDropped: transport.text ?? 0,
});

switch (command) {
  case "probe": {
    transport.first = resume(0, Number(opt("clamp", 100)));
    log(`connect ${transport.label}`);
    await until(() => S.closed, Number(opt("wait", 3)) * 1000);
    for (const [t, ty, l] of S.frames) log(`+${t.toFixed(3)} 0x${ty.toString(16).padStart(2, "0")} ${l}`);
    log(S.closed ? `closed: ${JSON.stringify(S.closed)}` : "still open after wait");
    emit({ outcome: S.handshake ? "handshake" : S.closed ? "closed-before-handshake" : "no-frames", ...summary() });
    break;
  }
  case "echo": {
    transport.first = resume(0, 1024);
    if (!(await until(() => S.handshake, 15000))) { emit({ error: "no handshake", ...summary() }); process.exit(1); }
    await sleep(300);
    const n = Number(opt("n", 200)), gap = Number(opt("gap", 0.1)) * 1000;
    const samples = []; let lost = 0; let want = null, got = 0;
    S.onData = (b) => { if (want != null && b.includes(want)) { got = nowMs(); want = null; } };
    for (let i = 0; i < n; i++) {
      want = 97 + (i % 26); got = 0;
      const sent = nowMs();
      transport.send(Buffer.from([0x00, want]));
      if (await until(() => got > 0, 5000)) samples.push(got - sent); else { lost++; log(`echo ${i} lost`); }
      await sleep(gap);
    }
    samples.sort((a, b) => a - b);
    const pct = (p) => samples[Math.min(samples.length - 1, Math.round((samples.length - 1) * p))];
    const r = { n: samples.length, lost, minMs: samples[0], p50Ms: pct(0.5), p90Ms: pct(0.9), p95Ms: pct(0.95), p99Ms: pct(0.99), maxMs: samples[samples.length - 1], samplesMs: samples };
    log(`echo n=${r.n} lost=${lost} p50=${r.p50Ms?.toFixed(3)} p95=${r.p95Ms?.toFixed(3)} max=${r.maxMs?.toFixed(3)} ms`);
    emit({ ...r, ...summary() });
    break;
  }
  case "stream": {
    transport.first = resume(0, 1);
    if (!(await until(() => S.handshake, 15000))) { emit({ error: "no handshake", ...summary() }); process.exit(1); }
    const startOffset = S.offset;
    log(`handshake offset=${startOffset} replay=${S.replay?.plain.length ?? 0}B`);
    let first = 0, last = 0;
    S.onData = () => { if (!first) first = nowMs(); last = nowMs(); };
    await until(() => S.closed, Number(opt("seconds", 30)) * 1000);
    const digest = S.hash.digest("hex");
    log(`data bytes=${S.dataBytes} frames=${S.dataFrames} sha256=${digest} offset=${S.offset} span=${(last - first).toFixed(1)}ms`);
    if (opt("out")) fs.writeFileSync(opt("out"), `${digest} ${S.dataBytes}\n`);
    emit({ startOffset, endOffset: S.offset, dataSha256: digest, spanMs: last - first, ...summary() });
    break;
  }
  case "replay": {
    transport.first = resume(0);
    if (!(await until(() => S.handshake, 60000))) { emit({ error: "no handshake", ...summary() }); process.exit(1); }
    await sleep(200);
    const plain = S.replay?.plain ?? Buffer.alloc(0);
    const digest = createHash("sha256").update(plain).digest("hex");
    let lines = 0; for (const b of plain) if (b === 0x0a) lines++;
    if (opt("out")) fs.writeFileSync(opt("out"), plain);
    log(`replay plain=${plain.length}B wire=${S.replay?.wire}B gz=${S.replayGz} delta=${S.replay?.delta} lines=${lines} sha256=${digest} sync=${S.offset} in ${S.handshake.toFixed(1)}ms`);
    emit({ replaySha256: digest, replayLines: lines, ...summary() });
    break;
  }
  default:
    process.stderr.write("usage: tap.mjs <probe|echo|stream|replay> (--unix PATH | --ws URL) --id ID\n");
    process.exit(2);
}
transport.close();
process.exit(0);
