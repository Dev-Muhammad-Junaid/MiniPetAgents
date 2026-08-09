#!/usr/bin/env bash
# Regenerate the sprite artwork used in README.md from locally installed
# petdex packs (~/.codex/pets/<slug>/spritesheet.webp).
#
# These are renders of the sprite sheets themselves — they show what the pets
# look like and which animation rows the app drives. They are NOT screenshots
# of the running app; see scripts/make-demo-gif.sh for that.
#
# Requires: ImageMagick 7 (`brew install imagemagick`).
set -euo pipefail

PETS_DIR="${HOME}/.codex/pets"
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docs"
mkdir -p "$OUT_DIR"

# petdex sheets are 8 columns x 9 rows. Frame size is derived per sheet so the
# script keeps working if a pack ships a different resolution.
COLS=8
ROWS=9

# row:name:frameCount:durationMs — the canonical petdex animation table,
# mirrored from PetPack.swift.
STATES=(
  "0:idle:6:1100"
  "1:run-right:8:1060"
  "2:run-left:8:1060"
  "3:waving:4:700"
  "4:jumping:5:840"
  "5:failed:8:1220"
  "6:waiting:6:1010"
  "7:running:6:820"
  "8:review:6:1030"
)

# ImageMagick on macOS often has no default font configured; point it at a
# system face if one is available, otherwise fall back to unlabelled output.
LABEL_FONT=""
for f in /System/Library/Fonts/Helvetica.ttc /System/Library/Fonts/Geneva.ttf; do
  [ -f "$f" ] && { LABEL_FONT="$f"; break; }
done

sheet_for() { echo "${PETS_DIR}/$1/spritesheet.webp"; }

frame_w() { magick identify -format '%w' "$1" | awk -v c=$COLS '{print int($1/c)}'; }
frame_h() { magick identify -format '%h' "$1" | awk -v r=$ROWS '{print int($1/r)}'; }

# crop <sheet> <row> <col> <out>
crop() {
  local sheet=$1 row=$2 col=$3 out=$4
  local fw fh
  fw=$(frame_w "$sheet"); fh=$(frame_h "$sheet")
  magick "$sheet" -crop "${fw}x${fh}+$((col * fw))+$((row * fh))" +repage \
    -background none "$out"
}

# ---------------------------------------------------------------- running GIF
# Every installed pet, side by side, playing its run-right cycle.
build_running_gif() {
  local tmp; tmp=$(mktemp -d)
  local slugs=() s
  for s in "$@"; do
    [ -f "$(sheet_for "$s")" ] && slugs+=("$s")
  done
  if [ ${#slugs[@]} -eq 0 ]; then
    echo "none of the requested packs are installed in $PETS_DIR" >&2
    return 1
  fi
  echo "run-right strip: ${slugs[*]}"

  local i
  for i in $(seq 0 7); do            # 8 frames in the run-right row
    local parts=()
    for s in "${slugs[@]}"; do
      crop "$(sheet_for "$s")" 1 "$i" "$tmp/${s}_$i.png"
      parts+=("$tmp/${s}_$i.png")
    done
    magick "${parts[@]}" +append -background none "$tmp/strip_$i.png"
  done

  # 1060ms / 8 frames ≈ 13 centiseconds per frame. No `-layers optimize` here:
  # on mostly-transparent frames it re-crops each frame to its bounding box and
  # collapses the animation canvas down to a single sprite's width.
  # `-filter point` = nearest neighbour. Anything smoother turns crisp pixel
  # art into mush. `-colors` keeps the committed asset small.
  magick -delay 13 -loop 0 "$tmp/strip_"*.png \
    -filter point -resize "${GIF_WIDTH}x" \
    -background none -dispose previous -colors 96 \
    "$OUT_DIR/pets-running.gif"
  rm -rf "$tmp"
  echo "wrote $OUT_DIR/pets-running.gif ($(du -h "$OUT_DIR/pets-running.gif" | cut -f1))"
}

# ------------------------------------------------------------ state reference
# One pet, first frame of each of the nine animation rows, labelled.
build_state_sheet() {
  local slug=${1:-}
  if [ -z "$slug" ]; then
    slug=$(basename "$(find "$PETS_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)")
  fi
  local sheet; sheet=$(sheet_for "$slug")
  [ -f "$sheet" ] || { echo "no sheet for $slug" >&2; return 1; }
  echo "state reference: $slug"

  local tmp; tmp=$(mktemp -d)
  local entry row name parts=()
  for entry in "${STATES[@]}"; do
    IFS=: read -r row name _ _ <<< "$entry"
    crop "$sheet" "$row" 0 "$tmp/s_$row.png"
    magick "$tmp/s_$row.png" -background none -gravity south -splice 0x28 \
      ${LABEL_FONT:+-font "$LABEL_FONT"} \
      -pointsize 17 -fill '#8b8b8b' -annotate +0+4 "$name" "$tmp/l_$row.png"
    parts+=("$tmp/l_$row.png")
  done
  magick "${parts[@]}" +append -background none "$OUT_DIR/sprite-states.png"
  rm -rf "$tmp"
  echo "wrote $OUT_DIR/sprite-states.png"
}

# Committed README art is deliberately limited to packs whose designs are
# original rather than depictions of named, copyrighted characters — petdex
# hosts plenty of the latter, and this repo should not redistribute them.
# Override by passing slugs: ./make-sprite-demo.sh my-pet another-pet
# Native sheet width for two pets. Scale in whole multiples only — pixel art
# smears at fractional ratios even with nearest neighbour.
GIF_WIDTH="${GIF_WIDTH:-384}"
DEFAULT_PETS=(bitboy noir-webling)

if [ $# -gt 0 ]; then
  build_running_gif "$@"
  build_state_sheet "$1"
else
  build_running_gif "${DEFAULT_PETS[@]}"
  build_state_sheet "${DEFAULT_PETS[1]}"
fi
