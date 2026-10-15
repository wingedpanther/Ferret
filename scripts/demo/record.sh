#!/bin/zsh
# Records the Ferret demo: build/demo/ferret-demo.mp4 (1920×1080) and ferret-demo.gif (960 wide).
# Uses only ~/ferret-demo (made-up repos), and stops if any frame shows a path outside it.
# Needs: ffmpeg, ImageMagick (magick), vhs, ttt, and JetBrains Mono installed for vhs.
set -euo pipefail
cd "${0:A:h}/../.."
ROOT=$HOME/ferret-demo
OUT=build/demo
FRAMES=$OUT/frames
CARDS=$OUT/cards
FONT=$PWD/Resources/JetBrainsMono.ttf
KEYFONT=/System/Library/Fonts/Menlo.ttc   # JetBrains Mono has no ↩ for ImageMagick
BG='#1d2021' FG='#ebdbb2' MUTED='#a89984' ACCENT='#fabd2f' KEYBG='#3c3836'

rm -rf $OUT && mkdir -p $FRAMES $CARDS

echo "→ demo repos"
scripts/demo/make-repos.sh "$ROOT" >/dev/null
sleep 3   # fsearch picks up the new files

echo "→ recording the panel"
swift build -q
# One panel at a time: quit the running Ferret and bring it back after.
running=$(pgrep -x Ferret >/dev/null && echo 1 || true)
pkill -x Ferret 2>/dev/null || true
FERRET_DEMO=$PWD/$FRAMES FERRET_SCOPE=$ROOT .build/debug/Ferret -editor ttt >/dev/null 2>&1
[[ -n $running && -d build/Ferret.app ]] && open build/Ferret.app

python3 - "$FRAMES/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
root = m["scope"]
bad = sorted({p for f in m["frames"] for p in f["paths"] if p != root and not p.startswith(root + "/")})
if bad:
    sys.exit("frames show paths outside %s:\n  %s" % (root, "\n  ".join(bad[:20])))
print("  %d frames, all inside %s" % (len(m["frames"]), root))
PY

echo "→ recording ttt"
vhs scripts/demo/ttt.tape >/dev/null 2>&1

# 1920×1080 stage: caption top left, key pressed top right, panel below at 1440×900.
stage() {  # stage <panel png> <caption> <key> <out>
  local args=(-size 1920x1080 "xc:$BG"
              -font $FONT -fill $FG -pointsize 38 -gravity northwest -annotate +240+58 "$2")
  if [[ -n $3 ]]; then
    keycap "$3" $CARDS/key.png
    args+=($CARDS/key.png -gravity northeast -geometry +240+50 -composite)
  fi
  args+=(\( "$1" -resize 1440x900 \( +clone -background black -shadow 60x24+0+16 \) +swap
            -background none -layers merge +repage \)
         -gravity north -geometry +0+132 -composite "$4")
  magick "${args[@]}"
}

keycap() {  # keycap <text> <out>: the key in accent colour on a rounded dark cap
  local w h
  read w h <<< "$(magick -font $KEYFONT -pointsize 32 label:"$1" -format '%w %h' info:)"
  local W=$((w + 44)) H=$((h + 20))
  magick -size ${W}x${H} xc:none -fill $KEYBG -draw "roundrectangle 0,0 $((W - 1)),$((H - 1)) 12,12" \
    -font $KEYFONT -pointsize 32 -fill $ACCENT -gravity center -annotate +0+0 "$1" "$2"
}

card() {  # card <title> <line> <out>
  rsvg-convert -w 300 -h 300 Resources/Icon/ferret.svg -o $CARDS/icon.png
  magick -size 1920x1080 "xc:$BG" $CARDS/icon.png -gravity center -geometry +0-150 -composite \
    -font $FONT -fill $FG -pointsize 96 -gravity center -annotate +0+70 "$1" \
    -fill $MUTED -pointsize 38 -annotate +0+170 "$2" "$3"
}

echo "→ staging frames"
python3 - "$FRAMES/manifest.json" > $OUT/frames.tsv <<'PY'
import json, sys
for f in json.load(open(sys.argv[1]))["frames"]:
    print("\t".join([f["file"], str(f["ms"]), f["caption"], f.get("key", "")]))
PY
: > $OUT/panel.txt
while IFS=$'\t' read -r file ms caption key; do
  stage $FRAMES/$file "$caption" "$key" $OUT/staged_$file
  printf "file 'staged_%s'\nduration %.3f\n" $file $(( ms / 1000.0 )) >> $OUT/panel.txt
  last=$file
done < $OUT/frames.tsv
print "file 'staged_$last'" >> $OUT/panel.txt   # concat needs the last file again for its duration to count

card "Ferret" "Files, code and git changes across every repo. One hotkey." $CARDS/title.png
card "Ferret" "github.com/wingedpanther/ferret" $CARDS/end.png
keycap "⌥↩" $CARDS/key.png
magick -size 1920x1080 "xc:$BG" -font $FONT -fill $FG -pointsize 38 -gravity northwest \
  -annotate +240+58 "Open it in ttt, on the same line." $CARDS/key.png -gravity northeast -geometry +240+50 -composite \
  $CARDS/ttt-stage.png

echo "→ encoding"
enc=(-c:v libx264 -pix_fmt yuv420p -r 30 -preset slow -crf 18)
ffmpeg -loglevel error -y -loop 1 -t 3 -i $CARDS/title.png -vf "fade=in:0:12,fade=out:st=2.6:d=0.4" "${enc[@]}" $OUT/1-title.mp4
ffmpeg -loglevel error -y -f concat -safe 0 -i $OUT/panel.txt -vf "fps=30,fade=in:0:8" "${enc[@]}" $OUT/2-panel.mp4
ffmpeg -loglevel error -y -loop 1 -i $CARDS/ttt-stage.png -i $OUT/ttt.mp4 \
  -filter_complex "[1:v]scale=1440:900[t];[0:v][t]overlay=(W-w)/2:132:shortest=1" "${enc[@]}" $OUT/3-ttt.mp4
ffmpeg -loglevel error -y -loop 1 -t 3.5 -i $CARDS/end.png -vf "fade=in:0:10,fade=out:st=3:d=0.5" "${enc[@]}" $OUT/4-end.mp4
print "file '1-title.mp4'\nfile '2-panel.mp4'\nfile '3-ttt.mp4'\nfile '4-end.mp4'" > $OUT/all.txt
ffmpeg -loglevel error -y -f concat -safe 0 -i $OUT/all.txt -c copy -movflags +faststart $OUT/ferret-demo.mp4

ffmpeg -loglevel error -y -i $OUT/ferret-demo.mp4 \
  -vf "fps=12,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
  $OUT/ferret-demo.gif

echo "→ done"
ls -lh $OUT/ferret-demo.mp4 $OUT/ferret-demo.gif | awk '{print "  " $5 "  " $9}'
