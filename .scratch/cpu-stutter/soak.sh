#!/bin/bash
# Longitudinal soak monitor for the CPU/stutter bug. Appends one line per minute.
# Columns: time | uptime | cpu% | main-thread samples | layout samples | layout% | ContentView evals in last 60s
LOG=/Users/alexstark/Projects/forks/Overlook/.scratch/cpu-stutter/soak.log
PCLOG=/tmp/overlook-diag3-pc.log
PREV=0
while true; do
  PID=$(pgrep -x Overlook | head -1)
  if [ -z "$PID" ]; then echo "$(date '+%H:%M:%S') no-process" >> "$LOG"; sleep 60; continue; fi
  OUT=$(mktemp)
  sample "$PID" 3 -file "$OUT" >/dev/null 2>&1
  TOTAL=$(grep -m1 'com.apple.main-thread' "$OUT" | grep -oE '[0-9]+' | head -1); TOTAL=${TOTAL:-0}
  LAYOUT=$(grep '__CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER_CALLBACK_FUNCTION__' "$OUT" | grep -oE ' [0-9]+ ' | head -1 | tr -d ' '); LAYOUT=${LAYOUT:-0}
  CPU=$(ps -o pcpu= -p "$PID" | tr -d ' ')
  UP=$(ps -o etime= -p "$PID" | tr -d ' ')
  RSS=$(ps -o rss= -p "$PID" | awk '{printf "%.0f", $1/1024}')
  EVALS=$(grep -c "^ContentView:" "$PCLOG" 2>/dev/null || echo 0)
  DELTA=$((EVALS - PREV)); PREV=$EVALS
  PCT=0; [ "$TOTAL" -gt 0 ] && PCT=$((LAYOUT * 100 / TOTAL))
  echo "$(date '+%H:%M:%S') up=$UP cpu=$CPU mt=$TOTAL layout=$LAYOUT layout%=$PCT rss=${RSS}MB evals60s=$DELTA" >> "$LOG"
  rm -f "$OUT"
  sleep 57
done
