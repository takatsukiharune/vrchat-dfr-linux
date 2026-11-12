#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
dfrctl="$1"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
export DFR_CONFIG="$dir/nested/dfr.conf" DFR_GAZE_FILE="$dir/gaze"
fails() { if "$@" >/dev/null 2>&1; then echo "expected failure: $*" >&2; exit 1; fi; }

"$dfrctl" set full_area 40 MID_AREA=60 DXVK_GAZE_COARSE auto >/dev/null
grep -qx 'full_area = 40' "$DFR_CONFIG" && grep -qx 'mid_area = 60' "$DFR_CONFIG" && grep -qx 'coarse = auto' "$DFR_CONFIG"
"$dfrctl" set full_area 25 >/dev/null
[[ "$(grep -c full_area "$DFR_CONFIG")" == 1 ]] && grep -qx 'full_area = 25' "$DFR_CONFIG"
before="$(cat "$DFR_CONFIG")"
fails "$dfrctl" set full_area banana
fails "$dfrctl" set coarse 3
fails "$dfrctl" set no_such_key 1
fails "$dfrctl" set full_area
fails "$dfrctl" set file /tmp/x
fails "$dfrctl" unset no_such_key
[[ "$(cat "$DFR_CONFIG")" == "$before" ]]
"$dfrctl" off >/dev/null && grep -qx 'enabled = 0' "$DFR_CONFIG"
"$dfrctl" on >/dev/null && grep -qx 'enabled = 1' "$DFR_CONFIG"
"$dfrctl" unset full_area enabled >/dev/null
! grep -q 'full_area\|enabled' "$DFR_CONFIG" && grep -qx 'mid_area = 60' "$DFR_CONFIG"
# Hand-written comments survive; a hand-made mistake blocks further writes.
printf '# mine\nmid_area = 60 # wide\n' > "$DFR_CONFIG"
"$dfrctl" set hold_ms 300 >/dev/null
grep -qx '# mine' "$DFR_CONFIG" && grep -qx 'mid_area = 60 # wide' "$DFR_CONFIG" && grep -qx 'hold_ms = 300' "$DFR_CONFIG"
echo 'oops' >> "$DFR_CONFIG"
fails "$dfrctl" set hold_ms 400
[[ "$("$dfrctl" launch-options)" == "DXVK_GAZE_VRS=1 DXVK_GAZE_CONFIG=$DFR_CONFIG %command%" ]]
"$dfrctl" status | grep -q 'no status file'
"$dfrctl" status | grep -q 'no gaze file'
printf 'tick=1\nenabled=1\ngaze=live\n' > "$DFR_CONFIG.status"
"$dfrctl" status | grep -q 'gaze=live'
touch -d '1 minute ago' "$DFR_CONFIG.status"
"$dfrctl" status | grep -q 'not running'
"$dfrctl" reset >/dev/null && [[ ! -e "$DFR_CONFIG" ]]
"$dfrctl" show | grep -q 'does not exist'
echo "dfrctl tests passed"
