#!/usr/bin/env bash
# Turn a screen recording of the running app into an optimised README GIF.
#
#   ./scripts/make-demo-gif.sh ~/Desktop/recording.mov [output.gif] [width]
#
# Recording the source clip (macOS):
#   Cmd-Shift-5 → "Record Selected Portion" → drag a box around the pet →
#   Record → do the thing → stop from the menubar. Save anywhere.
#
# Worth capturing, roughly 8-15s each:
#   * a pet pacing above the dock, turning at both ends
#   * grabbing a pet and flinging it — the throw arc and wall bounce
#   * hovering a pet so it breaks into the waving loop
#   * asking it something in chat and the jump + bubble when the turn completes
#
# Requires: ffmpeg and gifski (`brew install ffmpeg gifski`).
set -euo pipefail

SRC="${1:-}"
OUT="${2:-docs/demo.gif}"
WIDTH="${3:-720}"
FPS="${FPS:-20}"

if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
  echo "usage: $0 <recording.mov> [out.gif] [width]" >&2
  exit 1
fi
for tool in ffmpeg gifski; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing $tool — brew install $tool" >&2; exit 1; }
done

mkdir -p "$(dirname "$OUT")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "extracting frames at ${FPS}fps, ${WIDTH}px wide…"
# `-filter point`-equivalent for ffmpeg is the neighbor scaler; it keeps the
# pet's pixel art sharp instead of smearing it.
ffmpeg -hide_banner -loglevel error -i "$SRC" \
  -vf "fps=${FPS},scale=${WIDTH}:-2:flags=neighbor" \
  "$tmp/f_%05d.png"

count=$(find "$tmp" -name 'f_*.png' | wc -l | tr -d ' ')
echo "encoding $count frames…"
gifski --fps "$FPS" --width "$WIDTH" --quality 85 -o "$OUT" "$tmp"/f_*.png

echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
echo
echo "If it is over ~5MB GitHub will be slow to load it. Re-run with a smaller"
echo "width (e.g. 560) or trim the clip first:"
echo "  ffmpeg -i in.mov -ss 2 -t 8 -c copy trimmed.mov"
