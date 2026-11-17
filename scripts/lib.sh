# Shared by the build, install and uninstall scripts. Source it, do not run it.

dxvk_upstream_url="https://github.com/doitsujin/dxvk.git"

# Present in every d3d11.dll built with the gaze patches, absent from stock DXVK.
dxvk_marker="DXVK_GAZE_VRS"

proton_dxvk_dir() { printf '%s\n' "$1/files/lib/wine/dxvk/x86_64-windows"; }

is_patched_dll() { grep -qa "$dxvk_marker" "$1"; }

# The `git describe` string DXVK embeds, e.g. v3.1.1-174-gf86377680682448-GE-Proton(dirty).
dll_dxvk_version() {
  grep -a -o -m1 -E 'v[0-9]+\.[0-9]+(\.[0-9]+)?-[0-9]+-g[0-9a-f]{7,}[-+.A-Za-z0-9()]*' "$1" | head -n1
}

# Commit hash inside a describe string.
version_commit() { sed -n -E 's/^v[0-9.]+-[0-9]+-g([0-9a-f]{7,}).*/\1/p' <<<"$1"; }

# DXVK commit a Proton build ships: Proton records it in dxvk/version, and the
# stock DLL carries it as a fallback.
proton_dxvk_commit() {
  local dir dll
  dir="$(proton_dxvk_dir "$1")"
  if [[ -f "$dir/../version" ]]; then
    grep -o -m1 -E '[0-9a-f]{40}' "$dir/../version" && return 0
  fi
  dll="$dir/d3d11.dll"
  [[ -f "$dll.stock" ]] && dll="$dll.stock"
  [[ -f "$dll" ]] && ! is_patched_dll "$dll" || return 1
  version_commit "$(dll_dxvk_version "$dll")" | grep .
}

same_commit() { [[ -n "$1" && -n "$2" && ( "$1" == "$2"* || "$2" == "$1"* ) ]]; }

steam_roots() {
  local root
  for root in "${STEAM_DIR:-}" "$HOME/.local/share/Steam" "$HOME/.steam/steam" \
      "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
    if [[ -n "$root" && -d "$root" ]]; then readlink -f "$root"; fi
  done | awk '!seen[$0]++'
}

# Every Proton build Steam can use, one path per line.
proton_installs() {
  local root dir
  while IFS= read -r root; do
    for dir in "$root"/compatibilitytools.d/*/ "$root"/steamapps/common/*/; do
      [[ -f "$(proton_dxvk_dir "${dir%/}")/d3d11.dll" ]] && printf '%s\n' "${dir%/}"
    done
  done < <(steam_roots)
  return 0
}

# A path, or the directory name of a discovered Proton build.
resolve_proton() {
  local dir
  if [[ -d "$1" ]]; then (cd "$1" && pwd); return; fi
  while IFS= read -r dir; do
    if [[ "$(basename "$dir")" == "$1" ]]; then printf '%s\n' "$dir"; return; fi
  done < <(proton_installs)
  return 1
}

list_proton_installs() {
  local dir dll state
  while IFS= read -r dir; do
    dll="$(proton_dxvk_dir "$dir")/d3d11.dll"
    state="stock"
    is_patched_dll "$dll" && state="patched"
    printf '  %-8s %-34s %s\n' "$state" "$(dll_dxvk_version "$dll")" "$dir"
  done < <(proton_installs)
}

# Replace a (possibly read-only) file without writing over it: a running game
# keeps its old copy, and the mode of the original is preserved.
replace_file() {
  local src="$1" dst="$2" tmp
  tmp="$(mktemp "$dst.XXXXXX")"
  if ! { cp "$src" "$tmp" && chmod --reference="$dst" "$tmp" && mv -f "$tmp" "$dst"; }; then
    rm -f "$tmp"
    return 1
  fi
}
