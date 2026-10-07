#!/bin/bash
cd "$(dirname "$0")"
JOBS=${JOBS:-$(nproc)}
mode=${1:-full}
rm -rf out/suite
mkdir -p out/suite

scenarios() {
  echo ""
  echo "return=0"
  echo "dest=60,64,230"
  echo "dest=101,64,240"
  echo "start=-40,70,-25 dest=-75,70,-60"
  echo "cruise=68"
  [ "$mode" = quick ] && return
  for t in $(seq 9.0 0.05 16.0); do echo "events=reboot:Drive1@$t"; done
  for t in $(seq 9.0 0.05 16.0); do echo "events=reboot:Drive2@$t"; done
  for t in $(seq 92.0 0.05 99.0); do echo "events=reboot:Drive2@$t"; done
  for t in $(seq 144.0 0.1 163.0); do echo "events=reboot:RM@$t"; done
  for t in $(seq 5 1.3 320); do echo "events=restart@$t"; done
  for t in $(seq 5 2.9 320); do echo "events=crash@$t"; done
}

list=$(scenarios)
total=$(echo "$list" | wc -l)
start=$(date +%s)
results=$(echo "$list" | xargs -P "$JOBS" -d '\n' -I{} bash one.sh "{}")
echo "$results" | grep -v '^PASS' | sort
echo
echo "$results" | cut -d'|' -f1 | sort | uniq -c
echo "$total scenarios in $(( $(date +%s) - start )) s on $JOBS jobs"
