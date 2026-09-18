#!/bin/bash
# Spike M7 — the measurements, in the order the report presents them.
#
#   ./run.sh                          # everything below out/<stamp>/
#
# Needs: `ssh yorkshire-wsl` (the relay-tty host, its server running with
# `--tunnel` in tmux and logging to ~/relay-server.log), the tunnel URL, node
# 22 on the box, and relay-pty-host on this Mac for the local control.
# The token is read over ssh into the environment at run time and never
# written anywhere; the JSON lines this leaves behind carry `token=set`, not
# the token.
set -euo pipefail
cd "$(dirname "$0")"
BOX=${BOX:-yorkshire-wsl}
TUNNEL=${TUNNEL:-https://yourslug.relaytty.com}
OUT=${1:-out/$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"/{auth,echo,exact,paste,agent}
swift build -c release 2>&1 | tail -1
M7=.build/release/m7
export RELAY_TOKEN
RELAY_TOKEN=$(ssh "$BOX" 'grep -o "callback?token=[A-Za-z0-9._-]*" ~/relay-server.log | tail -1 | cut -d= -f2')
PORT=$(ssh "$BOX" 'python3 -c "import json,os;print(json.load(open(os.path.expanduser(\"~/.config/relay-tty/server.json\")))[\"url\"].rsplit(\":\",1)[1])"')
scp -q box/tap.mjs "$BOX:~/m7-tap.mjs"
ssh "$BOX" 'mkdir -p ~/m7out'
{ sw_vers; uname -m; sysctl -n machdep.cpu.brand_string; swiftc --version | head -1; ssh "$BOX" 'uname -a; node --version; export PATH=$HOME/.nvm/versions/node/v22.23.2/bin:$PATH; relay --version'; } >"$OUT/environment.txt" 2>&1

spawn() {  # spawn <json-args> -> session id, through the tunnel with the cookie
  curl -s --max-time 15 -H "Cookie: session=$RELAY_TOKEN" -H "Content-Type: application/json" \
    -d "{\"command\":\"bash\",\"args\":$1,\"cwd\":\"/home/spierce\",\"cols\":80,\"rows\":24}" \
    "$TUNNEL/api/sessions" | python3 -c "import json,sys; print(json.load(sys.stdin)['session']['id'])"
}
onbox() { ssh "$BOX" "export PATH=\$HOME/.nvm/versions/node/v22.23.2/bin:\$PATH; export RELAY_TOKEN='$RELAY_TOKEN'; $*"; }

# §4 auth on the wire — tunnel from here, LAN address and Unix socket from the box
for a in cookie none query; do
  "$M7" probe --base "$TUNNEL" --id 0368d543 --auth $a --wait 3 --clamp 100 >"$OUT/auth/tunnel-$a.json" 2>"$OUT/auth/tunnel-$a.log" || true
done
RELAY_TOKEN=x.y.z "$M7" probe --base "$TUNNEL" --id 0368d543 --auth cookie --wait 3 --clamp 100 >"$OUT/auth/tunnel-cookie-wrong.json" 2>&1 || true
for a in cookie none query; do
  onbox "node ~/m7-tap.mjs probe --ws http://192.168.68.56:$PORT --id 0368d543 --auth $a" >"$OUT/auth/lan-$a.json" 2>/dev/null || true
done
onbox "RELAY_TOKEN=x.y.z node ~/m7-tap.mjs probe --ws http://192.168.68.56:$PORT --id 0368d543 --auth cookie" >"$OUT/auth/lan-cookie-wrong.json" 2>/dev/null || true
onbox "node ~/m7-tap.mjs probe --ws http://127.0.0.1:$PORT --id 0368d543 --auth none" >"$OUT/auth/loopback-none.json" 2>/dev/null || true

# §2 keystroke echo — a `cat` session on the box, and one here under a private HOME
CAT=$(spawn '["-lc","cat"]'); sleep 1
ssh -f -N -L "$PORT:localhost:$PORT" "$BOX"
"$M7" echo --base "$TUNNEL" --id "$CAT" --auth cookie --n 200 >"$OUT/echo/tunnel.json" 2>"$OUT/echo/tunnel.log"
"$M7" echo --base "http://localhost:$PORT" --id "$CAT" --auth none --n 200 >"$OUT/echo/ssh-forward.json" 2>"$OUT/echo/ssh-forward.log"
onbox "node ~/m7-tap.mjs echo --ws http://192.168.68.56:$PORT --id $CAT --auth cookie --n 200" >"$OUT/echo/box-lan-ws.json" 2>/dev/null
onbox "node ~/m7-tap.mjs echo --ws http://127.0.0.1:$PORT --id $CAT --auth none --n 200" >"$OUT/echo/box-loopback-ws.json" 2>/dev/null
onbox "node ~/m7-tap.mjs echo --unix ~/.relay-tty/sockets/$CAT.sock --id $CAT --n 200" >"$OUT/echo/box-unix.json" 2>/dev/null
mkdir -p /tmp/m7h   # SUN_LEN: the socket path must stay short
(cd /tmp && HOME=/tmp/m7h nohup relay-pty-host a7000001 80 24 /tmp bash -lc cat >/tmp/m7h/ptyhost.log 2>&1 &); sleep 1
"$M7" echo --unix /tmp/m7h/.relay-tty/sockets/a7000001.sock --id a7000001 --n 200 >"$OUT/echo/mac-unix.json" 2>"$OUT/echo/mac-unix.log"

# §1 byte-exactness — 100 000 lines live on three paths at once, then the replay of them
GEN=$(spawn '["-lc","read -r x; seq 1 100000; sleep 1800"]')
onbox "node ~/m7-tap.mjs stream --unix ~/.relay-tty/sockets/$GEN.sock --id $GEN --seconds 45" >"$OUT/exact/box-unix.json" 2>/dev/null &
sleep 1; "$M7" stream --base "http://localhost:$PORT" --id "$GEN" --auth none --seconds 44 >"$OUT/exact/ssh-forward.json" 2>/dev/null &
sleep 2; "$M7" stream --base "$TUNNEL" --id "$GEN" --auth cookie --seconds 40 --trigger '\r' >"$OUT/exact/tunnel.json" 2>/dev/null
wait
"$M7" replay --base "$TUNNEL" --id "$GEN" --auth cookie --out "$OUT/exact/replay-tunnel.bin" >"$OUT/exact/replay-tunnel.json" 2>/dev/null
onbox "node ~/m7-tap.mjs replay --unix ~/.relay-tty/sockets/$GEN.sock --id $GEN --out ~/m7out/replay-box.bin; sha256sum ~/m7out/replay-box.bin" >"$OUT/exact/replay-box-unix.txt" 2>/dev/null

# §6 paste past 1 022 bytes — a raw-mode reader, so the line discipline's 4 095 is not in the way
for N in 1023 4096 65536; do
  S=$(spawn "[\"-lc\",\"stty raw -echo; head -c $N > /home/spierce/m7out/paste-$N.bin; stty sane; echo done; sleep 600\"]"); sleep 1
  "$M7" paste --base "$TUNNEL" --id "$S" --auth cookie --bytes $N >"$OUT/paste/tunnel-$N.json" 2>/dev/null
  onbox "sha256sum ~/m7out/paste-$N.bin; stat -c %s ~/m7out/paste-$N.bin" >>"$OUT/paste/box.txt"
done

# §5 SESSION_UPDATE — a `cat` whose comm name is `claude`, told to block and unblock
onbox 'cp /bin/cat ~/m7out/claude'
FAKE=$(spawn '["-li","-c","/home/spierce/m7out/claude; exit $?"]'); sleep 2
FILL=$(python3 -c "print(('filler ' * 10 + '\\\\r') * 60)")
for i in 1 2 3 4 5 6; do
  "$M7" watch --base "$TUNNEL" --id "$FAKE" --auth cookie --seconds 8 --type 'Do you want to proceed?\r' --after 2 >"$OUT/agent/blocked-$i.json" 2>"$OUT/agent/blocked-$i.log"
  "$M7" watch --base "$TUNNEL" --id "$FAKE" --auth cookie --seconds 7 --type "$FILL" --after 1 >"$OUT/agent/unblock-$i.json" 2>"$OUT/agent/unblock-$i.log"
done
echo "done: $OUT  (§3 reconnect is by hand: see README.md)"
