#!/usr/bin/env bash
set -euo pipefail

# Replace a (possibly read-only) DLL without touching its permissions: write a
# temp file beside it, copy the original's mode, and rename it into place.
replace_dll() {
  local src="$1" dst="$2" tmp
  tmp="$(mktemp "$dst.XXXXXX")"
  if ! { cp "$src" "$tmp" && chmod --reference="$dst" "$tmp" && mv -f "$tmp" "$dst"; }; then
    rm -f "$tmp"
    return 1
  fi
}

backup_dir="${1:-}"
[[ -d "$backup_dir" ]] || { echo "Usage: $0 /path/to/backup" >&2; exit 2; }

proton_dir="${PROTON_DIR:-}"
[[ -n "$proton_dir" && -d "$proton_dir" ]] || { echo "Set PROTON_DIR=/path/to/Proton" >&2; exit 2; }

[[ -f "$backup_dir/d3d11.dll" && -f "$backup_dir/dxgi.dll" ]] || {
  echo "Backup is missing d3d11.dll and/or dxgi.dll." >&2
  exit 1
}

target="$proton_dir/files/lib/wine/dxvk/x86_64-windows"

[[ -d "$target" ]] || {
  echo "Could not find target DXVK directory: $target" >&2
  exit 1
}

replace_dll "$backup_dir/d3d11.dll" "$target/d3d11.dll"
replace_dll "$backup_dir/dxgi.dll" "$target/dxgi.dll"

echo "Restored original DXVK DLLs in $target"