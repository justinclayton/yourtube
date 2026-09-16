#!/bin/sh
# Pool allocator for the throwaway "YourTube Test N" simulators shared by
# parallel agents. Tests and -seedFixtures drives run here; only a drive
# against the real signed-in store belongs on "YourTube Dev" (see simlock.sh).
#
# usage: simpool.sh acquire <agent-name>   -> prints the UDID on stdout (waits up to 45 min)
#        simpool.sh release <agent-name>
#        simpool.sh status
POOL_DIR="${YOURTUBE_SIMPOOL_DIR:-/tmp/yourtube-simpool}"
STALE_SECS=2700
cmd="$1"; name="$2"
mkdir -p "$POOL_DIR"
now() { date +%s; }
udids() { xcrun simctl list devices -j | jq -r '.devices[][] | select(.name | test("^YourTube Test [0-9]+$")) | select(.state=="Booted") | "\(.name)\t\(.udid)"' | sort; }
case "$cmd" in
  acquire)
    [ -n "$name" ] || { echo "need a name" >&2; exit 2; }
    waited=0
    while :; do
      for udid in $(udids | cut -f2); do
        L="$POOL_DIR/$udid"
        if [ -d "$L" ] && [ "$(cat "$L/owner" 2>/dev/null)" = "$name" ]; then echo "$udid"; exit 0; fi
        if [ -d "$L" ] && [ $(( $(now) - $(cat "$L/since" 2>/dev/null || echo 0) )) -gt "$STALE_SECS" ]; then
          echo "simpool: breaking stale lock on $udid held by $(cat "$L/owner")" >&2; rm -rf "$L"
        fi
        if mkdir "$L" 2>/dev/null; then
          echo "$name" > "$L/owner"; now > "$L/since"
          echo "simpool: $name acquired $udid" >&2; echo "$udid"; exit 0
        fi
      done
      if [ "$waited" -ge 2700 ]; then echo "simpool: gave up after 45 min" >&2; exit 1; fi
      [ $((waited % 120)) -eq 0 ] && echo "simpool: all pool simulators busy, waiting" >&2
      sleep 15; waited=$((waited + 15))
    done ;;
  release)
    for L in "$POOL_DIR"/*; do
      [ -d "$L" ] || continue
      if [ "$(cat "$L/owner" 2>/dev/null)" = "$name" ]; then rm -rf "$L"; echo "simpool: released $(basename "$L") from $name"; fi
    done ;;
  status)
    udids | while IFS="$(printf '\t')" read -r sname udid; do
      L="$POOL_DIR/$udid"
      if [ -d "$L" ]; then echo "$sname $udid: held by $(cat "$L/owner") for $(( $(now) - $(cat "$L/since") ))s"; else echo "$sname $udid: free"; fi
    done ;;
  *) echo "usage: simpool.sh acquire|release <name> | status" >&2; exit 2 ;;
esac
