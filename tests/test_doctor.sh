#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# proton.py doctor: which Proton build the game uses, whether it is patched, launch options.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
export HOME="$dir/home" STEAM_DIR="$dir/steam" DFR_CONFIG="$dir/nested/dfr.conf"
fails() { if "$@" >/dev/null 2>&1; then echo "expected failure: $*" >&2; exit 1; fi; }
tool="$STEAM_DIR/compatibilitytools.d/GE-Test-dfr"
mkdir -p "$tool/files/lib/wine/dxvk/x86_64-windows" "$STEAM_DIR/config" "$STEAM_DIR/userdata/1/config" "$dir/origin"
printf '"compat_tools" { "GE-Test-x86_64-dfr" { "install_path" "." } }\n' > "$tool/compatibilitytool.vdf"
printf ' f863776806824486d709fee16ea619c03e22def4 dxvk (v3.1.1-174-gf86377680)\n' > "$tool/files/lib/wine/dxvk/version"
printf 'x\0DXVK_GAZE_VRS\0v3.1.1-1H\0v3.1.1-174-gf8637768-dfr.abc1234\0' > "$tool/files/lib/wine/dxvk/x86_64-windows/d3d11.dll"
printf '"CompatToolMapping" { "438100" { "name" "GE-Test-x86_64-dfr" "config" "" } }\n' > "$STEAM_DIR/config/config.vdf"
options() { printf '"apps" { "438100" { "LastPlayed" "1" "LaunchOptions" "%s" } }\n' "$1" > "$STEAM_DIR/userdata/1/config/localconfig.vdf"; }
options "DXVK_GAZE_VRS=1 DXVK_GAZE_CONFIG=$DFR_CONFIG %command%"
echo "build 1" > "$tool/version"; echo "build 1" > "$dir/origin/version"; echo "$dir/origin" > "$tool/.dfr-clone"
doctor() { "$repo_dir/scripts/proton.py" doctor 2>/dev/null || true; }
report="$(doctor)"
grep -q "ok app 438100 uses 'GE-Test-x86_64-dfr' with gaze DXVK v3.1.1-174-gf8637768-dfr.abc1234" <<<"$report"
grep -q 'ok launch options enable gaze VRS' <<<"$report"
grep -q 'No problems found.' <<<"$report"
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
printf '"CompatToolMapping" { }\n' > "$STEAM_DIR/config/config.vdf"
fails "$repo_dir/scripts/proton.py" doctor
echo "doctor tests passed"
