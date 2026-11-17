#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# install-dxvk.sh and uninstall-dxvk.sh against made-up Proton builds.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="$repo_dir/scripts/install-dxvk.sh" uninstall="$repo_dir/scripts/uninstall-dxvk.sh"
dir="$(mktemp -d)"
trap 'chmod -R u+w "$dir"; rm -rf "$dir"' EXIT
export HOME="$dir/home" STEAM_DIR="$dir/steam"
tools="$STEAM_DIR/compatibilitytools.d"
fails() { if "$@" >/dev/null 2>&1; then echo "expected failure: $*" >&2; exit 1; fi; }

ge=f863776806824486d709fee16ea619c03e22def4 other=a78a467cadb22bee928904290cf8e7921b121851
proton() {  # NAME COMMIT
  local target="$tools/$1/files/lib/wine/dxvk/x86_64-windows"
  mkdir -p "$target"
  printf ' %s dxvk (v3.1.1-174-g%s)\n' "$2" "${2:0:9}" > "$target/../version"
  printf 'stock d3d11 v3.1.1-174-g%s-GE-Proton(dirty)\n' "${2:0:15}" > "$target/d3d11.dll"
  printf 'stock dxgi\n' > "$target/dxgi.dll"
  chmod 555 "$target"/*.dll
  echo "$1 build 1" > "$tools/$1/version"
}
build() {  # DIR COMMIT
  mkdir -p "$1"
  printf 'patched d3d11 DXVK_GAZE_VRS v3.1.1-174-g%s-dfr.abc1234\n' "${2:0:8}" > "$1/d3d11.dll"
  printf 'patched dxgi\n' > "$1/dxgi.dll"
}
dll() { echo "$tools/$1/files/lib/wine/dxvk/x86_64-windows/$2"; }
proton "GE Test" "$ge"
build "$dir/match" "$ge"
build "$dir/mismatch" "$other"

# Copy mode leaves the source alone and registers the copy under its own name.
"$install" --dxvk-from "$dir/match" "GE Test" >/dev/null
grep -q '^stock' "$(dll "GE Test" d3d11.dll)"
grep -q DXVK_GAZE_VRS "$(dll GE-Test-dfr d3d11.dll)" && grep -q '^patched' "$(dll GE-Test-dfr dxgi.dll)"
grep -q '"display_name" "GE-Test-dfr"' "$tools/GE-Test-dfr/compatibilitytool.vdf"
[[ "$(stat -c %a "$(dll GE-Test-dfr d3d11.dll)")" == 555 ]]
"$install" --dxvk-from "$dir/match" "GE Test" >/dev/null
"$install" --dxvk-from "$dir/match" GE-Test-dfr >/dev/null
fails "$install" --dxvk-from "$dir/mismatch" "GE Test"
"$install" --force --dxvk-from "$dir/mismatch" "GE Test" >/dev/null
fails "$install" --dxvk-from "$dir/missing" "GE Test"
mkdir "$dir/stock" && cp "$(dll "GE Test" d3d11.dll)" "$(dll "GE Test" dxgi.dll)" "$dir/stock/"
fails "$install" --dxvk-from "$dir/stock" "GE Test"

# A changed source needs --refresh; the copy is then made again.
echo "GE Test build 2" > "$tools/GE Test/version"
fails "$install" --dxvk-from "$dir/match" "GE Test"
"$install" --refresh --dxvk-from "$dir/match" "GE Test" >/dev/null
grep -q 'build 2' "$tools/GE-Test-dfr/version"

# A directory this script did not make is never replaced or deleted.
mkdir -p "$tools/Mine-dfr" && proton Mine "$ge"
fails "$install" --dxvk-from "$dir/match" Mine
"$uninstall" GE-Test-dfr >/dev/null
[[ ! -e "$tools/GE-Test-dfr" && -d "$tools/GE Test" ]]

# In place: Proton's DLLs are kept once, and a second install does not replace them.
"$install" --in-place --dxvk-from "$dir/match" Mine >/dev/null
"$install" --in-place --dxvk-from "$dir/match" Mine >/dev/null
grep -q '^stock' "$(dll Mine d3d11.dll.stock)" && grep -q '^stock' "$(dll Mine dxgi.dll.stock)"
grep -q DXVK_GAZE_VRS "$(dll Mine d3d11.dll)"
"$uninstall" Mine >/dev/null
grep -q '^stock' "$(dll Mine d3d11.dll)" && [[ ! -e "$(dll Mine d3d11.dll.stock)" ]]
"$uninstall" Mine >/dev/null

# A Proton update replaced the patched DLLs: the kept copies are older and go.
"$install" --in-place --dxvk-from "$dir/match" Mine >/dev/null
chmod -R u+w "$tools/Mine" && proton Mine "$ge"
"$uninstall" Mine >/dev/null
grep -q '^stock' "$(dll Mine d3d11.dll)" && [[ ! -e "$(dll Mine d3d11.dll.stock)" ]]

# Patched by hand before, no stock copy: install updates it, uninstall refuses.
cp "$dir/match/d3d11.dll" "$(dll Mine d3d11.dll).new" && mv -f "$(dll Mine d3d11.dll).new" "$(dll Mine d3d11.dll)"
"$install" --in-place --force --dxvk-from "$dir/mismatch" Mine >/dev/null
[[ ! -e "$(dll Mine d3d11.dll.stock)" ]]
fails "$uninstall" Mine

fails "$install" --dxvk-from "$dir/match" "No Such Proton"
echo "install tests passed"
