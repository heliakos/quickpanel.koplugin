#!/bin/bash
# Smoke test for quickpanel.koplugin on the KOReader Linux emulator (no device needed).
#
# Needs: Xvfb, xdotool, ImageMagick (import), and the official Linux build, e.g.
#   curl -LO https://github.com/koreader/koreader/releases/download/v2026.07.1/koreader-linux-x86_64-v2026.07.1.tar.xz
#   mkdir ko && tar -xJf koreader-linux-x86_64-v2026.07.1.tar.xz -C ko
#
# Usage:
#   KO=./ko/lib/koreader BOOK=/path/book.epub dev/emulator-test.sh <x> <y>
# Opens BOOK (or the folder of BOOK with FM=1), swipes down from the top, taps (x, y) on the panel,
# saves screenshots to ./qp-test-*.png and prints any Lua error from the log.
# Panel rows on a 1072x1448 screen (reader): y = 163, 300, 437, 573, 710, exit = 850; columns x = 180, 536, 888.
set -u
KO=${KO:?set KO to the koreader dir}; BOOK=${BOOK:?set BOOK}
X=${1:-536}; Y=${2:-163}
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT=$PWD
rm -rf "$KO/plugins/quickpanel.koplugin" && mkdir -p "$KO/plugins/quickpanel.koplugin"
cp "$HERE"/_meta.lua "$HERE"/main.lua "$KO/plugins/quickpanel.koplugin/"

Xvfb :99 -screen 0 1072x1448x24 >/dev/null 2>&1 & XPID=$!
sleep 2
export DISPLAY=:99 HOME=$OUT/qp-home EMULATE_READER_W=1072 EMULATE_READER_H=1448 EMULATE_READER_DPI=300 XDG_RUNTIME_DIR=/tmp
mkdir -p "$HOME"
TARGET=$BOOK; [ "${FM:-0}" = 1 ] && TARGET=$(dirname "$BOOK")
(cd "$KO" && ./luajit ./reader.lua "$TARGET" > "$OUT/qp-test.log" 2>&1 &)
sleep 10
xdotool mousemove 536 20 mousedown 1; for y in $(seq 40 25 520); do xdotool mousemove 536 "$y"; sleep 0.015; done; xdotool mouseup 1
sleep 2; import -window root "$OUT/qp-test-panel.png"
xdotool mousemove "$X" "$Y" click 1
sleep 3; import -window root "$OUT/qp-test-after.png"
pkill -x luajit; sleep 1; kill $XPID 2>/dev/null
if grep -iE "traceback|attempt to|bad argument" "$OUT/qp-test.log"; then echo "FAIL"; exit 1; fi
echo "OK (screenshots: qp-test-panel.png, qp-test-after.png)"
