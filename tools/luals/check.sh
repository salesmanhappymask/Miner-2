#!/bin/bash
set -e
here="$(cd "$(dirname "$0")" && pwd)"
LUALS=${LUALS:-lua-language-server}
if [ $# -eq 0 ]; then
  echo "usage: bash tools/luals/check.sh DIR [DIR...]" >&2
  exit 1
fi
work="$(mktemp -d)"; [ -n "$KEEP" ] && echo "work dir $work" >&2
[ -n "$KEEP" ] || trap 'rm -rf "$work"' EXIT
for dir in "$@"; do
  name="$(basename "$dir")"
  mkdir -p "$work/src/$name"
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in *.txt|*.md|*.py|*.json|version|cairn_version) continue ;; esac
    cp "$f" "$work/src/$name/${base%.lua}.lua"
  done
done
cat > "$work/src/.luarc.json" <<JSON
{
  "runtime.version": "Lua 5.1",
  "runtime.builtin": { "io": "disable", "os": "disable", "debug": "disable", "package": "disable" },
  "workspace.library": ["$here/library"],
  "workspace.checkThirdParty": false,
  "diagnostics.disable": ["lowercase-global", "trailing-space", "unused-local", "unused-vararg", "redefined-local", "empty-block", "code-after-break"]
}
JSON
"$LUALS" --check "$work/src" --checklevel=Warning --logpath="$work/log" --check_out_path="$work/report.json" >/dev/null 2>&1 || true
if [ ! -s "$work/report.json" ] || [ "$(cat "$work/report.json")" = "[]" ]; then
  echo "LuaLS: no problems found"
  exit 0
fi
python3 - "$work/report.json" "$work/src" <<'PY'
import json, sys, collections
data = json.load(open(sys.argv[1]))
root = sys.argv[2]
counts = collections.Counter()
rows = []
for uri, diags in data.items():
    path = uri.split(root, 1)[-1].lstrip("/")
    if path.endswith(".lua"):
        path = path[:-4]
    for d in diags:
        counts[d.get("code")] += 1
        rows.append((path, d["range"]["start"]["line"] + 1, d.get("code"), d.get("message", "").split("\n")[0]))
rows.sort()
for r in rows:
    print("%s:%d [%s] %s" % r)
print()
for code, n in counts.most_common():
    print("%5d %s" % (n, code))
PY
