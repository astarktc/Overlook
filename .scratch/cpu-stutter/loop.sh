#!/bin/bash
# Feedback loop for the "high CPU + stutter while streaming" bug.
# RED  = main thread spends >30% of samples in SwiftUI layout/update work
# GREEN = <10%
# Usage: ./loop.sh   (Overlook must be running and streaming)
set -euo pipefail
PID=$(pgrep -x Overlook | head -1)
[ -n "$PID" ] || { echo "Overlook not running"; exit 2; }
OUT=$(mktemp)
sample "$PID" 3 -file "$OUT" >/dev/null 2>&1
# Main-thread samples total vs. samples inside SwiftUI render/layout
TOTAL=$(grep -m1 'com.apple.main-thread' "$OUT" | grep -oE '[0-9]+' | head -1)
TOTAL=${TOTAL:-0}
LAYOUT=$(grep '__CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER_CALLBACK_FUNCTION__' "$OUT" | grep -oE ' [0-9]+ ' | head -1 | tr -d ' ')
LAYOUT=${LAYOUT:-0}
[ "$TOTAL" -gt 0 ] || { echo "no main-thread samples parsed"; exit 2; }
CPU=$(ps -o pcpu= -p "$PID" | tr -d ' ')
PCT=$(( LAYOUT * 100 / TOTAL ))
echo "process CPU: ${CPU}%  main-thread samples: $TOTAL  swiftui-observer samples: $LAYOUT (${PCT}%)"
if [ "$PCT" -gt 30 ]; then echo "RED: main thread dominated by SwiftUI layout"; exit 1; fi
if [ "$PCT" -lt 10 ]; then echo "GREEN"; exit 0; fi
echo "AMBER"; exit 1
