#!/bin/zsh
# Copies a Debug build's notes, trace log and reading replays off a connected iPad into the private evidence folder
# beside this repository (../jibiji-device-evidence-private/ipad). Nothing is written into the repository.
#
#   scripts/pull-ipad-evidence.sh            # the first connected iPad
#   JIBIJI_DEVICE=<udid> scripts/pull-ipad-evidence.sh
#
# Then run the local replay tests (they skip when the folder is absent):
#   xcodebuild test-without-building ... -only-testing:JIBIJITests/IPadReplayTests
set -euo pipefail
repo=${0:A:h:h}
out=${JIBIJI_EVIDENCE:-$repo/../jibiji-device-evidence-private/ipad}

prefix=$(sed -n 's/^JIBIJI_BUNDLE_ID_PREFIX *= *//p' "$repo/Config/Local.xcconfig" 2>/dev/null | head -1)
[[ -n "$prefix" ]] || prefix=$(sed -n 's/^JIBIJI_BUNDLE_ID_PREFIX *= *//p' "$repo/Config/JIBIJI.xcconfig" | head -1)
bundle="$prefix.jibiji"

device=${JIBIJI_DEVICE:-}
if [[ -z "$device" ]]; then
  list=$(mktemp)
  xcrun devicectl list devices --json-output "$list" >/dev/null
  device=$(python3 -I -c 'import json,sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    p = d.get("hardwareProperties", {})
    if p.get("platform") == "iOS" and p.get("deviceType") == "iPad" and p.get("reality") == "physical":
        print(d["hardwareProperties"]["udid"]); break' "$list")
  rm -f "$list"
fi
[[ -n "$device" ]] || { echo "No connected iPad found. Set JIBIJI_DEVICE=<udid>." >&2; exit 1; }

copy() { xcrun devicectl device copy from --device "$device" --domain-type appDataContainer --domain-identifier "$bundle" \
           --source "$1" --destination "$2" >/dev/null 2>&1 }

stamp=$(date +%Y%m%d-%H%M%S)
mkdir -p "$out/replays" "$out/traces"
rm -rf "$out/Notes.tmp"
copy "Library/Application Support/Notes" "$out/Notes.tmp" && { rm -rf "$out/Notes"; mv "$out/Notes.tmp" "$out/Notes"; }
copy "Documents/trace.log" "$out/traces/trace-$stamp.log" || true
# Replays accumulate: files already pulled are kept even after the iPad drops its oldest.
rm -rf "$out/replays.tmp"
if copy "Documents/replays" "$out/replays.tmp"; then
  find "$out/replays.tmp" -name '*.json' -exec cp -n {} "$out/replays/" \; 2>/dev/null || true
  rm -rf "$out/replays.tmp"
fi
echo "Pages:   $(find "$out/Notes" -name '*.drawing' 2>/dev/null | wc -l | tr -d ' ')"
echo "Replays: $(find "$out/replays" -name '*.json' | wc -l | tr -d ' ')"
echo "Into:    $out"
