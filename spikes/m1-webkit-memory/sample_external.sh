#!/usr/bin/env bash
# External cross-check of the in-app numbers. Samples ps RSS for the spike app
# and every WebKit helper that is NOT in the baseline pid list, every INTERVAL
# seconds, to a CSV. Run concurrently with the spike.
#   ./sample_external.sh <app-pid> <baseline-pids-comma-sep> <out.csv> <interval> <duration>
set -euo pipefail
APP_PID="$1"; BASELINE="${2:-}"; OUT="$3"; INT="${4:-10}"; DUR="${5:-600}"
echo "ts,pid,kind,rss_kb,vsz_kb,pcpu,comm" > "$OUT"
END=$(( $(date +%s) + DUR ))
while [ "$(date +%s)" -lt "$END" ]; do
  kill -0 "$APP_PID" 2>/dev/null || break
  TS=$(date +%s)
  ps -A -o pid=,rss=,vsz=,%cpu=,comm= | while read -r pid rss vsz pcpu comm; do
    kind=""
    case "$comm" in
      *com.apple.WebKit.WebContent*) kind="WebContent" ;;
      *com.apple.WebKit.Networking*) kind="Networking" ;;
      *com.apple.WebKit.GPU*)        kind="GPU" ;;
      *M1Spike*)                     kind="app" ;;
      *) continue ;;
    esac
    if [ "$kind" != "app" ] && [ -n "$BASELINE" ]; then
      case ",$BASELINE," in *",$pid,"*) continue ;; esac
    fi
    echo "$TS,$pid,$kind,$rss,$vsz,$pcpu,$comm" >> "$OUT"
  done
  sleep "$INT"
done
