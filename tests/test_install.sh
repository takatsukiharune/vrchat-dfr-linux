#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# scripts/proton.py against made-up Proton builds.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run_install() { "$repo_dir/scripts/proton.py" install "$@"; }
run_uninstall() { "$repo_dir/scripts/proton.py" uninstall "$@"; }
dir="$(mktemp -d)"
trap 'chmod -R u+w "$dir"; rm -rf "$dir"' EXIT
export HOME="$dir/home" STEAM_DIR="$dir/steam"
tools="$STEAM_DIR/compatibilitytools.d"
fails() { if "$@" >/dev/null 2>&1; then echo "expected failure: $*" >&2; exit 1; fi; }

ge=f863776806824486d709fee16ea619c03e22def4 other=a78a467cadb22bee928904290cf8e7921b121851
proton() {  # NAME COMMIT [RELEASE] [TOOLS_DIR]
  local root="${4:-$tools}" target
  target="$root/$1/files/lib/wine/dxvk/x86_64-windows"
  chmod -R u+w "$root/$1" 2>/dev/null || true
  mkdir -p "$target"
  printf ' %s dxvk (v3.1.1-174-g%s)\n' "$2" "${2:0:9}" > "$target/../version"
  printf 'stock d3d11 v3.1.1-174-g%s-GE-Proton(dirty)\n' "${2:0:15}" > "$target/d3d11.dll"
  printf 'stock dxgi\n' > "$target/dxgi.dll"
  chmod 555 "$target"/*.dll
  echo "1700000000 ${3:-plain-1}" > "$root/$1/version"
  # Like GE-Proton: a comment, then the internal name Steam stores per game.
  printf '"compatibilitytools"\n{\n  "compat_tools"\n  {\n    // the internal name\n    "%s-x86_64"\n    {\n      "install_path" "."\n      "display_name" "%s"\n    }\n  }\n}\n' \
    "${1// /-}" "$1" > "$root/$1/compatibilitytool.vdf"
}
build() {  # DIR COMMIT [RELEASE]
  mkdir -p "$1"
  printf 'patched d3d11 DXVK_GAZE_VRS v3.1.1-174-g%s%s-dfr.abc1234\n' "${2:0:8}" "${3:+-$3}" > "$1/d3d11.dll"
  printf 'patched dxgi\n' > "$1/dxgi.dll"
}
dll() { echo "$tools/$1/files/lib/wine/dxvk/x86_64-windows/$2"; }
internal_name() { grep -v '^ *//' "$tools/$1/compatibilitytool.vdf" | grep -o '"[^"]*"' | sed -n 3p; }
proton "GE Test" "$ge"
build "$dir/match" "$ge"
build "$dir/mismatch" "$other"

# Copy mode leaves the source alone and registers the copy under the source's
# own internal name plus -dfr, the name Steam keeps for the game.
run_install --dxvk-from "$dir/match" "GE Test" >/dev/null
grep -q '^stock' "$(dll "GE Test" d3d11.dll)"
grep -q DXVK_GAZE_VRS "$(dll "GE Test-dfr" d3d11.dll)" && grep -q '^patched' "$(dll "GE Test-dfr" dxgi.dll)"
[[ "$(internal_name "GE Test-dfr")" == '"GE-Test-x86_64-dfr"' ]]
grep -q '"display_name" "GE-Test-x86_64-dfr"' "$tools/GE Test-dfr/compatibilitytool.vdf"
[[ "$(stat -c %a "$(dll "GE Test-dfr" d3d11.dll)")" == 555 ]]
run_install --dxvk-from "$dir/match" "GE Test" >/dev/null
run_install --dxvk-from "$dir/match" "GE Test-dfr" >/dev/null
fails run_install --dxvk-from "$dir/mismatch" "GE Test"
run_install --force --dxvk-from "$dir/mismatch" "GE Test" >/dev/null
fails run_install --dxvk-from "$dir/missing" "GE Test"
mkdir "$dir/stock" && cp "$(dll "GE Test" d3d11.dll)" "$(dll "GE Test" dxgi.dll)" "$dir/stock/"
fails run_install --dxvk-from "$dir/stock" "GE Test"

# A copy made under an older naming scheme gets the internal name on reinstall.
sed -i 's/GE-Test-x86_64-dfr/GE-Test-dfr/g' "$tools/GE Test-dfr/compatibilitytool.vdf"
run_install --dxvk-from "$dir/match" "GE Test" >/dev/null
[[ "$(internal_name "GE Test-dfr")" == '"GE-Test-x86_64-dfr"' ]]

# Another tool already uses that internal name: Steam could pick either one.
proton Taken "$ge"
mkdir -p "$tools/Somebody else" && printf '"compatibilitytools" { "compat_tools" { "Taken-x86_64-dfr" { } } }\n' \
  > "$tools/Somebody else/compatibilitytool.vdf"
fails run_install --dxvk-from "$dir/match" Taken
[[ ! -e "$tools/Taken-dfr" ]]

# The copy is checked against the DXVK it ships, not the DXVK its source moved on to.
proton "GE Test" "$other"
echo "1700000000 plain-1" > "$tools/GE Test/version"
run_install --dxvk-from "$dir/match" "GE Test-dfr" >/dev/null
fails run_install --dxvk-from "$dir/mismatch" "GE Test-dfr"

# A changed source needs --refresh, given the source or the copy; the copy is made again.
echo "1700000001 plain-2" > "$tools/GE Test/version"
fails run_install --dxvk-from "$dir/mismatch" "GE Test"
run_install --refresh --dxvk-from "$dir/mismatch" "GE Test-dfr" >/dev/null
grep -q 'plain-2' "$tools/GE Test-dfr/version" && grep -q -- '-ga78a467c-' "$(dll "GE Test-dfr" d3d11.dll)"

# Without a version file, an unchanged source is not "changed".
proton NoVersion "$ge"
rm "$tools/NoVersion/version"
run_install --dxvk-from "$dir/match" NoVersion >/dev/null
run_install --dxvk-from "$dir/match" NoVersion >/dev/null

# A directory this script did not make, or made from another source, is never touched.
mkdir -p "$tools/Mine-dfr" && proton Mine "$ge"
fails run_install --dxvk-from "$dir/match" Mine
proton Twin "$ge"
run_install --dxvk-from "$dir/match" Twin >/dev/null
echo "$tools/Mine" > "$tools/Twin-dfr/.dfr-clone"
fails run_install --dxvk-from "$dir/match" Twin
rm -rf "$tools/Mine-dfr" "$tools/Twin-dfr" "$tools/Twin"

# Uninstall takes the copy or its source.
run_uninstall "GE Test-dfr" >/dev/null
[[ ! -e "$tools/GE Test-dfr" && -d "$tools/GE Test" ]]
run_install --dxvk-from "$dir/mismatch" "GE Test" >/dev/null
run_uninstall "GE Test" >/dev/null
[[ ! -e "$tools/GE Test-dfr" && -d "$tools/GE Test" ]]

# In place: Proton's DLLs are kept once, and a second install does not replace them.
run_install --in-place --dxvk-from "$dir/match" Mine >/dev/null
run_install --in-place --dxvk-from "$dir/match" Mine >/dev/null
grep -q '^stock' "$(dll Mine d3d11.dll.stock)" && grep -q '^stock' "$(dll Mine dxgi.dll.stock)"
grep -q DXVK_GAZE_VRS "$(dll Mine d3d11.dll)"
run_uninstall Mine >/dev/null
grep -q '^stock' "$(dll Mine d3d11.dll)" && [[ ! -e "$(dll Mine d3d11.dll.stock)" ]]
run_uninstall Mine >/dev/null

# A Proton update replaced the patched DLLs: the kept copies are older and go.
run_install --in-place --dxvk-from "$dir/match" Mine >/dev/null
proton Mine "$ge"
run_uninstall Mine >/dev/null
grep -q '^stock' "$(dll Mine d3d11.dll)" && [[ ! -e "$(dll Mine d3d11.dll.stock)" ]]

# Patched by hand before, no stock copy: install updates it, uninstall refuses.
cp "$dir/match/d3d11.dll" "$(dll Mine d3d11.dll).new" && mv -f "$(dll Mine d3d11.dll).new" "$(dll Mine d3d11.dll)"
run_install --in-place --force --dxvk-from "$dir/mismatch" Mine >/dev/null
[[ ! -e "$(dll Mine d3d11.dll.stock)" ]]
fails run_uninstall Mine

# Without --dxvk-from, only a build made for that Proton release is picked from dist/,
# also once the source is gone and only the copy is left.
proton GE-Rel "$ge" GE-Proton11-12
# build-dxvk.sh reads the DXVK commit and the release that a Proton build ships.
[[ "$("$repo_dir/scripts/proton.py" commit "$tools/GE-Rel")" == "$ge" ]]
[[ "$("$repo_dir/scripts/proton.py" variant "$tools/GE-Rel")" == GE-Proton11-12 ]]
fake_repo="$dir/repo"
mkdir -p "$fake_repo/scripts" && cp "$repo_dir/scripts/proton.py" "$fake_repo/scripts/"
build "$fake_repo/dist/dxvk-plain" "$ge"
fails "$fake_repo/scripts/proton.py" install GE-Rel
build "$fake_repo/dist/dxvk-ge" "$ge" GE-Proton11-12
"$fake_repo/scripts/proton.py" install GE-Rel >/dev/null
grep -q 'GE-Proton11-12-dfr' "$(dll GE-Rel-dfr d3d11.dll)"
chmod -R u+w "$tools/GE-Rel" && rm -rf "$tools/GE-Rel"
"$fake_repo/scripts/proton.py" install GE-Rel-dfr >/dev/null
grep -q 'GE-Proton11-12-dfr' "$(dll GE-Rel-dfr d3d11.dll)"
fails "$fake_repo/scripts/proton.py" install --refresh GE-Rel-dfr
proton GE-Rel2 "$ge" GE-Proton11-12
note="$(run_install --dxvk-from "$dir/match" --in-place GE-Rel2)"
grep -q 'not built with the DXVK patches of GE-Proton11-12' <<<"$note"

# The copy goes beside its source, in the Steam installation that has it.
flatpak="$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
mkdir -p "$HOME/.local/share/Steam" && proton Flat "$ge" "" "$flatpak/compatibilitytools.d"
STEAM_DIR="" run_install --dxvk-from "$dir/match" Flat >/dev/null
[[ -d "$flatpak/compatibilitytools.d/Flat-dfr" && ! -e "$HOME/.local/share/Steam/compatibilitytools.d/Flat-dfr" ]]

# Valve's Proton has no manifest of its own; a name with a quote stays a valid manifest.
valve="$STEAM_DIR/steamapps/common"
proton 'Proton "Q"' "$ge" "" "$valve" && rm "$valve/Proton \"Q\"/compatibilitytool.vdf"
run_install --dxvk-from "$dir/match" 'Proton "Q"' >/dev/null
grep -q '^    "Proton \\"Q\\"-dfr"$' "$tools/Proton \"Q\"-dfr/compatibilitytool.vdf"

fails run_install --dxvk-from "$dir/match" "No Such Proton"
echo "install tests passed"
