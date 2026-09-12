#!/bin/zsh
# Full-screen ruler with known column positions, for cell-accurate reflow checks.
# Row 0: "SIZE <cols>x<rows> gen=<n>"
# Row 1: ruler — char at column j is ((j+1) % 10) as a digit, except the LAST column is '#'
# Row 2..r-2: left edge '|' at col 0, right edge '|' at col c-1
# Row r-1: c copies of '=' with 'E' in the last column
gen=0
draw() {
  local c=$COLUMNS r=$LINES i line
  gen=$((gen+1))
  printf '\033[H\033[2J'
  printf 'SIZE %dx%d gen=%d\n' $c $r $gen
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
TRAPWINCH() { draw }
draw
while true; do read -t 0.2 -k 1 _ 2>/dev/null; done
