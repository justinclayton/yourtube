#!/bin/sh
# Pool allocator for the "YourTube N" simulators shared by parallel agents.
# All devices matching the name prefix are in the pool; a fifth device joins
# just by being named "YourTube 5". One of them, STORE_UDID below, holds the
# only signed-in store: ordinary acquires skip it, and a caller that genuinely
# needs real data asks for it with `acquire --store <agent-name>`.
#
# usage: simpool.sh acquire [--store] <agent-name>   -> prints the UDID on stdout (waits up to 45 min)
#        simpool.sh release <agent-name>
#        simpool.sh status
POOL_DIR="${YOURTUBE_SIMPOOL_DIR:-/tmp/yourtube-simpool}"
STALE_SECS=2700
# The device holding the only signed-in YouTube store. Update this if that
# device is ever renamed or recreated; nothing else in this script or its
# callers should hard-code it.
STORE_UDID="90AFA528-C804-43DE-A76B-3DAE4C767718"

cmd="$1"; shift
want_store=0
if [ "$cmd" = "acquire" ] && [ "$1" = "--store" ]; then want_store=1; shift; fi
name="$1"
mkdir -p "$POOL_DIR"
now() { date +%s; }
udids() { xcrun simctl list devices -j | jq -r '.devices[][] | select(.name | test("^YourTube [0-9]+$")) | select(.state=="Booted") | "\(.name)\t\(.udid)"' | sort; }
candidates() {
  if [ "$want_store" -eq 1 ]; then
    udids | awk -F'\t' -v u="$STORE_UDID" '$2==u'
  else
    udids | awk -F'\t' -v u="$STORE_UDID" '$2!=u'
  fi
}
case "$cmd" in
  acquire)
    [ -n "$name" ] || { echo "need a name" >&2; exit 2; }
    waited=0
    while :; do
      for udid in $(candidates | cut -f2); do
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
      tag=""
      [ "$udid" = "$STORE_UDID" ] && tag=" [store]"
      if [ -d "$L" ]; then echo "$sname $udid$tag: held by $(cat "$L/owner") for $(( $(now) - $(cat "$L/since") ))s"; else echo "$sname $udid$tag: free"; fi
    done ;;
  *) echo "usage: simpool.sh acquire [--store] <name> | release <name> | status" >&2; exit 2 ;;
esac
