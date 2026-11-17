#!/usr/bin/env bash
# Undoes install-dxvk.sh for one Proton build.
#
#   uninstall-dxvk.sh PROTON     PROTON is a directory or the name of a Proton build
#   uninstall-dxvk.sh            list the Proton builds found
#
# A <name>-dfr copy is deleted. A build patched with --in-place gets its own
# DLLs back from the .stock copies.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_dir/scripts/lib.sh"

if [[ $# -ne 1 || "$1" == -* ]]; then
  echo "Proton builds found:"
  list_proton_installs
  sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi
dir="$(resolve_proton "$1")" || { echo "No Proton build '$1'." >&2; exit 1; }

if [[ -f "$dir/.dfr-clone" ]]; then
  rm -rf "$dir"
  echo "Removed $dir. Select another compatibility tool for the game in Steam."
  exit 0
fi

target="$(proton_dxvk_dir "$dir")"
[[ -f "$target/d3d11.dll" ]] || { echo "No DXVK in $dir." >&2; exit 1; }
if ! is_patched_dll "$target/d3d11.dll"; then
  # A Proton update put its own, newer DLLs back: the kept ones are older.
  rm -f "$target/d3d11.dll.stock" "$target/dxgi.dll.stock"
  echo "$dir already has Proton's own DXVK."
  exit 0
fi
[[ -f "$target/d3d11.dll.stock" && -f "$target/dxgi.dll.stock" ]] || {
  echo "$dir is patched but has no .stock copies. Reinstall this Proton build, or verify its files in Steam." >&2
  exit 1
}
mv -f "$target/d3d11.dll.stock" "$target/d3d11.dll"
mv -f "$target/dxgi.dll.stock" "$target/dxgi.dll"
echo "Proton's own DXVK is back in $dir."
