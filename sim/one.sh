#!/bin/bash
cd "$(dirname "$0")"
LUA=${LUA:-luajit}
spec="$1"
name=$(echo "$spec" | tr -c 'A-Za-z0-9_.@:=-' '_' | cut -c1-80)
dir="out/suite/$name/"
mkdir -p "$dir"
result=$("$LUA" run.lua $spec out="$dir" 2>&1)
outcome=$(echo "$result" | sed -n 's/^RESULT: //p')
[ -z "$outcome" ] && outcome="ERROR"
if [ "$outcome" = "PASS" ]; then
  rm -rf "$dir"
  echo "PASS | $spec"
else
  echo "$result" > "${dir}report.txt"
  echo "$outcome | $spec | $(echo "$result" | grep -E '^\^ (VIOLATION|FATAL|SAFE)|^luajit|error' | head -2 | tr '\n' ' ')"
fi
