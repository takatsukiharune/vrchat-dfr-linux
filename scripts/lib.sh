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

# DXVK commit a Proton build ships. Proton records it in dxvk/version, and the
# stock DLL carries it too.
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

# Release name of a Proton variant that patches DXVK itself (GE-Proton11-12,
# cachyos-11.0-20261015-slr). Empty for every other Proton build.
proton_variant() {
  local name
  name="$(awk 'NR == 1 { print $2 }' "$1/version" 2>/dev/null)"
  case "$name" in
    GE-Proton*|cachyos-*) printf '%s\n' "$name" ;;
  esac
}

# Writes the DXVK patches of that release into DIR as 01.patch, 02.patch, ...
# in the order its own build applies them, and the DXVK commit it pins as DIR/commit.
fetch_variant_patches() {  # VARIANT DIR
  local variant="$1" out="$2" url list src n=0 path
  case "$variant" in
    GE-Proton*) url="https://github.com/GloriousEggroll/proton-ge-custom.git" ;;
    cachyos-*) url="https://github.com/CachyOS/proton-cachyos.git" ;;
    *) return 1 ;;
  esac
  src="$(mktemp -d)"
  git clone -q --depth 1 --filter=blob:none --sparse --branch "$variant" "$url" "$src" 2>/dev/null \
    && git -C "$src" sparse-checkout set patches/dxvk || { rm -rf "$src"; return 1; }
  if [[ "$variant" == GE-Proton* ]]; then
    # GE lists its patches by hand, between `pushd dxvk` and the next `popd`.
    list="$(sed -n '/^ *pushd dxvk$/,/^ *popd$/p' "$src/patches/protonprep-valve-staging.sh" \
      | grep -v '^ *#' | grep -o 'patches/dxvk/[^" ]*\.patch')"
  else
    list="$(cd "$src" && find patches/dxvk -name '*.patch' | sort)"
  fi
  rm -rf "$out" && mkdir -p "$out"
  git -C "$src" ls-tree HEAD dxvk | awk '{ print $3 }' > "$out/commit"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    n=$((n + 1))
    cp "$src/$path" "$out/$(printf '%02d' "$n").patch"
  done <<<"$list"
  rm -rf "$src"
}

# Newest release tag of a variant: latest_variant 'GE-Proton*' or 'cachyos-*-slr'.
latest_variant() {
  local url="https://github.com/GloriousEggroll/proton-ge-custom.git"
  [[ "$1" == cachyos-* ]] && url="https://github.com/CachyOS/proton-cachyos.git"
  git ls-remote --tags --refs --sort=-v:refname "$url" "$1" | head -n1 | sed 's|.*refs/tags/||'
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

# compatibilitytools.d of the Steam installation that holds a Proton build.
tools_dir_of() {
  case "$1" in
    */compatibilitytools.d/*) printf '%s\n' "${1%/compatibilitytools.d/*}/compatibilitytools.d" ;;
    */steamapps/common/*) printf '%s\n' "${1%/steamapps/common/*}/compatibilitytools.d" ;;
    *) return 1 ;;
  esac
}

# The name Steam stores per game for a compatibility tool: the first key under
# "compat_tools" in its manifest, escaped as written there. Valve's Proton has
# no manifest; its directory name stands in, escaped for a manifest.
tool_internal_name() {
  if [[ -f "$1/compatibilitytool.vdf" ]]; then
    sed 's|^[[:space:]]*//.*||' "$1/compatibilitytool.vdf" | grep -o '"\([^"\\]\|\\.\)*"' \
      | awk 'previous == "\"compat_tools\"" { print substr($0, 2, length($0) - 2); exit } { previous = $0 }'
  else
    basename "$1" | sed 's/[\\"]/\\&/g'
  fi
}

# Tools in a compatibilitytools.d that declare an internal name.
tools_named() {  # NAME DIR
  local tool
  for tool in "$2"/*/; do
    [[ "$(tool_internal_name "${tool%/}")" == "$1" ]] && printf '%s\n' "${tool%/}"
  done
  return 0
}

# Copies of a Proton build that install-dxvk.sh made.
copies_of() {
  local dir
  while IFS= read -r dir; do
    [[ -f "$dir/.dfr-clone" && "$(cat "$dir/.dfr-clone")" == "$1" ]] && printf '%s\n' "$dir"
  done < <(proton_installs)
  return 0
}

# Same version file, or neither has one.
same_version() { [[ ! -e "$1/version" && ! -e "$2/version" ]] || cmp -s "$1/version" "$2/version"; }

list_proton_installs() {
  local dir dll state
  while IFS= read -r dir; do
    dll="$(proton_dxvk_dir "$dir")/d3d11.dll"
    state="stock"
    is_patched_dll "$dll" && state="patched"
    printf '  %-8s %-34s %s\n' "$state" "$(dll_dxvk_version "$dll")" "$dir"
  done < <(proton_installs)
}

# Replace a file, read-only or not, by renaming a new one over it. A running
# game keeps its old copy, and the new file gets the mode of the original.
replace_file() {
  local src="$1" dst="$2" tmp
  tmp="$(mktemp "$dst.XXXXXX")"
  if ! { cp "$src" "$tmp" && chmod --reference="$dst" "$tmp" && mv -f "$tmp" "$dst"; }; then
    rm -f "$tmp"
    return 1
  fi
}
