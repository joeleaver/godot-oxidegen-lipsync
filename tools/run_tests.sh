#!/bin/sh
# Runs the tests headless with GUT (fetched into addons/gut on first run). Exit code != 0 on failure.
# Usage: tools/run_tests.sh   (GODOT=/path/to/godot to pick a binary)
cd "$(dirname "$0")/.." || exit 1
GODOT="${GODOT:-godot}"
GUT_URL="https://github.com/bitwes/Gut/archive/refs/tags/v9.7.1.zip"
GUT_SHA="14969aa46adc84aa08cdd21b9f6d1a64addd92ae60b36f02d0521ed305aa4086"
if [ ! -f addons/gut/gut_cmdln.gd ]; then
	tmp=$(mktemp -d)
	curl -sSL "$GUT_URL" -o "$tmp/gut.zip" || exit 1
	echo "$GUT_SHA  $tmp/gut.zip" | sha256sum -c - >/dev/null || { echo "GUT zip checksum mismatch"; exit 1; }
	unzip -q "$tmp/gut.zip" -d "$tmp" && mkdir -p addons && mv "$tmp/Gut-9.7.1/addons/gut" addons/gut
	rm -rf "$tmp"
fi
"$GODOT" --headless --path . --import >/dev/null 2>&1
exec "$GODOT" --headless --path . -s addons/gut/gut_cmdln.gd -gconfig=res://.gutconfig.json -gexit "$@"
