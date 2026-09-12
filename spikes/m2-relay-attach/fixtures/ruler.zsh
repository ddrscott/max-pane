#!/bin/zsh
# Full-screen ruler with known column positions, for cell-accurate reflow checks.
#   row 0        : "SIZE <cols>x<rows> gen=<n> winch=<w>"
#   row 1        : column ruler - char at column j is ((j+1) % 10), last column '#'
#   rows 2..r-2  : '|' at column 0 and at column c-1
#   row r-1      : '=' repeated, 'E' in the last column
# Redraw is driven both by SIGWINCH (TRAPWINCH) and by a 100 ms stty poll, so the
# test does not depend on zsh's signal handling; `winch=` reports which fired.
emulate -L zsh
gen=0
winch=0
need=1
last=""
TRAPWINCH() { winch=$((winch+1)); need=1 }

draw() {
  local c=$1 r=$2 i line
  gen=$((gen+1))
  printf '\033[H\033[2J'
  printf 'SIZE %dx%d gen=%d winch=%d\n' $c $r $gen $winch
  line=""
  for (( i=1; i<c; i++ )); do line+="$(( i % 10 ))"; done
  line+="#"
  printf '%s' "$line"
  for (( i=3; i<r; i++ )); do
    printf '\033[%d;1H|\033[%d;%dH|' $i $i $c
  done
  printf '\033[%d;1H' $r
  line=""
  for (( i=1; i<c; i++ )); do line+="="; done
  line+="E"
  printf '%s' "$line"
  printf '\033[1;1H'
}

while true; do
  size=$(stty size 2>/dev/null)
  if [[ "$size" != "$last" ]]; then last=$size; need=1; fi
  if (( need )); then
    need=0
    draw ${size##* } ${size%% *}
  fi
  sleep 0.1
done
