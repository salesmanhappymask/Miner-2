#!/bin/bash
set -e
jar="$1"
if [ -z "$jar" ]; then
  echo "usage: bash fetch_rom.sh /path/to/ComputerCraft1.63.jar" >&2
  exit 1
fi
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
unzip -q -o "$jar" 'assets/computercraft/lua/*' -d "$tmp"
rm -rf "$here/ccrom"
mv "$tmp/assets/computercraft/lua" "$here/ccrom"
rm -rf "$tmp"
echo "ROM extracted to $here/ccrom"
