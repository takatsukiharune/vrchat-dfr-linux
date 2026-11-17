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
# doctor: which Proton build the game uses, whether it is patched, launch options.
export HOME="$dir/home" STEAM_DIR="$dir/steam"
tool="$STEAM_DIR/compatibilitytools.d/GE-Test-dfr"
mkdir -p "$tool/files/lib/wine/dxvk/x86_64-windows" "$STEAM_DIR/config" "$STEAM_DIR/userdata/1/config" "$dir/origin"
printf '"compat_tools" { "GE-Test-x86_64-dfr" { "install_path" "." } }\n' > "$tool/compatibilitytool.vdf"
printf ' f863776806824486d709fee16ea619c03e22def4 dxvk (v3.1.1-174-gf86377680)\n' > "$tool/files/lib/wine/dxvk/version"
printf 'x\0DXVK_GAZE_VRS\0v3.1.1-1H\0v3.1.1-174-gf8637768-dfr.abc1234\0' > "$tool/files/lib/wine/dxvk/x86_64-windows/d3d11.dll"
printf '"CompatToolMapping" { "438100" { "name" "GE-Test-x86_64-dfr" "config" "" } }\n' > "$STEAM_DIR/config/config.vdf"
options() { printf '"apps" { "438100" { "LastPlayed" "1" "LaunchOptions" "%s" } }\n' "$1" > "$STEAM_DIR/userdata/1/config/localconfig.vdf"; }
options "DXVK_GAZE_VRS=1 DXVK_GAZE_CONFIG=$DFR_CONFIG %command%"
echo "build 1" > "$tool/version"; echo "build 1" > "$dir/origin/version"; echo "$dir/origin" > "$tool/.dfr-clone"
doctor() { "$dfrctl" doctor 2>/dev/null || true; }
report="$(doctor)"
grep -q "ok app 438100 uses 'GE-Test-x86_64-dfr' with gaze DXVK v3.1.1-174-gf8637768-dfr.abc1234" <<<"$report"
grep -q 'ok launch options enable gaze VRS' <<<"$report"
grep -q 'Problems found: 1' <<<"$report"   # only the bridge, which is not running here
options "DXVK_GAZE_VRS=1 %command%"
doctor | grep -q '!! launch options do not point DXVK_GAZE_CONFIG'
options "%command%"
[[ "$(doctor | grep -c '!!')" == 1 ]] && doctor | grep -q 'lack DXVK_GAZE_VRS=1'
# Launch options are read as the shell runs them, from the game's own entry.
options 'DXVK_GAZE_VRS=1 DXVK_GAZE_CONFIG=\"'"$DFR_CONFIG"'\" %command%'
doctor | grep -q 'ok launch options enable gaze VRS'
options "%command% DXVK_GAZE_VRS=1 DXVK_GAZE_CONFIG=$DFR_CONFIG"
doctor | grep -q '!! launch options lack DXVK_GAZE_VRS=1'
options "DXVK_GAZE_VRS=1 DXVK_GAZE_CONFIG=$DFR_CONFIG DXVK_GAZE_VRS=0 %command%"
doctor | grep -q '!! launch options lack DXVK_GAZE_VRS=1'
options "gamemoderun DXVK_GAZE_VRS=1 DXVK_GAZE_CONFIG=$DFR_CONFIG %command%"
doctor | grep -q '!! launch options lack DXVK_GAZE_VRS=1'
options "env DXVK_GAZE_VRS=1 DXVK_GAZE_CONFIG=$DFR_CONFIG gamemoderun %command%"
doctor | grep -q 'ok launch options enable gaze VRS'
printf '"apps" { "438100" { "LastPlayed" "1" } "620" { "LaunchOptions" "DXVK_GAZE_VRS=1 DXVK_GAZE_CONFIG=%s %%command%%" } }\n' \
  "$DFR_CONFIG" > "$STEAM_DIR/userdata/1/config/localconfig.vdf"
doctor | grep -q '!! no launch options set for app 438100'
options "DXVK_GAZE_VRS=1 DXVK_GAZE_CONFIG=$DFR_CONFIG %command%"

# A Steam directory without a configuration is not one Steam uses.
mkdir -p "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
[[ "$(doctor | grep -c '!!')" == 0 ]]

# The copy's source: changed is a problem, the same or gone is not.
rm "$tool/version" "$dir/origin/version"
[[ "$(doctor | grep -c '!!')" == 0 ]]
echo "build 2" > "$dir/origin/version"
doctor | grep -q "changed after this copy was made; run scripts/proton.py install --refresh 'GE-Test-dfr'"
rm -rf "$dir/origin"
[[ "$(doctor | grep -c '!!')" == 0 ]]
printf ' a78a467cadb22bee928904290cf8e7921b121851 dxvk (v3.1.1-97-ga78a467)\n' > "$tool/files/lib/wine/dxvk/version"
doctor | grep -q 'but this Proton build ships'
printf 'v3.1.1-174-gf86377680682448-GE-Proton(dirty)\0' > "$tool/files/lib/wine/dxvk/x86_64-windows/d3d11.dll"
doctor | grep -q 'with stock DXVK v3.1.1-174-gf86377680682448-GE-Proton(dirty); run scripts/proton.py install'
printf '"CompatToolMapping" { "620" { "name" "x" } }\n' > "$STEAM_DIR/config/config.vdf"
doctor | grep -q 'has no compatibility tool selected'

# Steam's default tool (app 0) applies when the game has none of its own.
printf '"CompatToolMapping" { "0" { "name" "GE-Test-x86_64-dfr" } }\n' > "$STEAM_DIR/config/config.vdf"
doctor | grep -q "uses 'GE-Test-x86_64-dfr'"

# Valve's Proton, patched with --in-place, is found in steamapps/common.
valve="$STEAM_DIR/steamapps/common/Proton - Experimental/files/lib/wine/dxvk"
mkdir -p "$valve/x86_64-windows"
printf ' f863776806824486d709fee16ea619c03e22def4 dxvk (v3.1.1-174-gf86377680)\n' > "$valve/version"
printf 'DXVK_GAZE_VRS\0v3.1.1-174-gf8637768-dfr.abc1234\0' > "$valve/x86_64-windows/d3d11.dll"
printf '"CompatToolMapping" { "438100" { "name" "proton_experimental" } }\n' > "$STEAM_DIR/config/config.vdf"
doctor | grep -q "ok app 438100 uses 'proton_experimental' with gaze DXVK"
fails "$dfrctl" doctor
echo "dfrctl tests passed"
