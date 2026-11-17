#!/usr/bin/env bash
# Installs the patched d3d11.dll and dxgi.dll for one Proton build.
#
#   install-dxvk.sh [options] PROTON     PROTON is a directory or the name of a Proton build
#   install-dxvk.sh                      list the Proton builds found
#
# Default: copy PROTON to <name>-dfr beside Steam's other compatibility tools
# and patch the copy. PROTON itself is not changed. Select <name>-dfr for the
# game in Steam (restart Steam to see it).
#
#   --in-place         patch PROTON itself and keep its DLLs as d3d11.dll.stock and dxgi.dll.stock
#   --refresh          copy PROTON again when it changed after <name>-dfr was made
#   --dxvk-from PATH   directory or .zip with d3d11.dll and dxgi.dll
#                      (default: the build in dist/ that matches PROTON's DXVK commit)
#   --force            install DLLs built from a different DXVK commit than PROTON ships
#   --tools-dir DIR    where <name>-dfr goes (default: Steam's compatibilitytools.d)
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_dir/scripts/lib.sh"

usage() { sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "$*" >&2; exit 1; }

in_place=0 refresh=0 force=0 dxvk_from="${DXVK_FROM:-}" tools_dir="" proton=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --in-place) in_place=1; shift ;;
    --refresh) refresh=1; shift ;;
    --force) force=1; shift ;;
    --dxvk-from) dxvk_from="${2:?--dxvk-from needs a value}"; shift 2 ;;
    --tools-dir) tools_dir="${2:?--tools-dir needs a value}"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) [[ -z "$proton" ]] || usage; proton="$1"; shift ;;
  esac
done
if [[ -z "$proton" ]]; then
  echo "Proton builds found:"
  list_proton_installs
  usage
fi
source_dir="$(resolve_proton "$proton")" || die "No Proton build '$proton'. Run without arguments to list them."
[[ -f "$(proton_dxvk_dir "$source_dir")/d3d11.dll" ]] || die "No DXVK in $source_dir."

# Where the DLLs go: a copy made earlier, the build itself, or a new copy.
origin="$source_dir"
if [[ -f "$source_dir/.dfr-clone" ]]; then
  dest="$source_dir"
  origin="$(cat "$source_dir/.dfr-clone")"
elif (( in_place )); then
  dest="$source_dir"
else
  if [[ -z "$tools_dir" ]]; then
    tools_dir="$(steam_roots | head -n1)/compatibilitytools.d"
    [[ "$tools_dir" != "/compatibilitytools.d" ]] || die "Steam not found. Pass --tools-dir DIR."
  fi
  name="$(basename "$source_dir" | tr ' ' '-')-dfr"
  dest="$tools_dir/$name"
  if [[ -e "$dest" && ! -f "$dest/.dfr-clone" ]]; then
    die "$dest exists and was not made by this script. Remove it, or patch it with: $0 --in-place '$dest'"
  fi
fi

commit="$(proton_dxvk_commit "$origin" 2>/dev/null || proton_dxvk_commit "$dest" 2>/dev/null || true)"

if [[ -z "$dxvk_from" ]]; then
  for dir in "$repo_dir"/dist/dxvk*/; do
    [[ -f "$dir/d3d11.dll" && -f "$dir/dxgi.dll" ]] || continue
    if same_commit "$commit" "$(version_commit "$(dll_dxvk_version "$dir/d3d11.dll")")"; then dxvk_from="${dir%/}"; break; fi
  done
  [[ -n "$dxvk_from" ]] || die "No build in $repo_dir/dist matches DXVK ${commit:-of this Proton build}.
Build it with: scripts/dev-container.sh build --proton '$origin'"
fi

extracted=""
staging=""
cleanup() { rm -rf "$extracted" "$staging"; }
trap cleanup EXIT
if [[ -f "$dxvk_from" && "$dxvk_from" == *.zip ]]; then
  command -v unzip >/dev/null || die "unzip is required to read $dxvk_from"
  extracted="$(mktemp -d)"
  unzip -q "$dxvk_from" -d "$extracted"
  dxvk_from="$(dirname "$(find "$extracted" -name d3d11.dll | sort | head -n1)")"
fi
[[ -f "$dxvk_from/d3d11.dll" && -f "$dxvk_from/dxgi.dll" ]] || die "No d3d11.dll and dxgi.dll in $dxvk_from."
is_patched_dll "$dxvk_from/d3d11.dll" || die "$dxvk_from/d3d11.dll is not a gaze-VRS build."

new_version="$(dll_dxvk_version "$dxvk_from/d3d11.dll")"
if [[ -z "$commit" ]]; then
  echo "Cannot tell which DXVK commit this Proton build ships; version match not checked."
elif ! same_commit "$commit" "$(version_commit "$new_version")"; then
  message="The DLLs are DXVK $new_version, but this Proton build ships DXVK commit ${commit:0:12}."
  (( force )) || die "$message
Build matching DLLs with: scripts/dev-container.sh build --proton '$origin'
or pass --force to install these."
  echo "$message Installing them because of --force."
fi

install_dlls() {
  local target name
  target="$(proton_dxvk_dir "$1")"
  for name in d3d11.dll dxgi.dll; do replace_file "$dxvk_from/$name" "$target/$name"; done
}

if [[ "$dest" != "$source_dir" ]]; then
  if [[ -e "$dest" ]] && ! cmp -s "$source_dir/version" "$dest/version"; then
    (( refresh )) || die "$source_dir changed after $dest was made.
Close the game and run again with --refresh to copy it again."
    rm -rf "$dest"
  fi
  if [[ ! -e "$dest" ]]; then
    mkdir -p "$tools_dir"
    staging="$(mktemp -d "$dest.XXXXXX")"
    cp -a --reflink=auto "$source_dir/." "$staging/"
    printf '%s\n' "$source_dir" > "$staging/.dfr-clone"
    cat > "$staging/compatibilitytool.vdf" <<VDF
"compatibilitytools"
{
  "compat_tools"
  {
    "$name"
    {
      "install_path" "."
      "display_name" "$name"
      "from_oslist"  "windows"
      "to_oslist"    "linux"
    }
  }
}
VDF
    install_dlls "$staging"
    mv -T "$staging" "$dest"
    echo "Made $dest from $source_dir with DXVK $new_version."
    echo "Restart Steam, then select '$name' as the compatibility tool for the game."
    exit 0
  fi
elif [[ ! -f "$dest/.dfr-clone" ]]; then
  # Keep Proton's own DLLs once. A patched DLL is never kept as stock.
  target="$(proton_dxvk_dir "$dest")"
  if ! is_patched_dll "$target/d3d11.dll"; then
    for name in d3d11.dll dxgi.dll; do cp -pf "$target/$name" "$target/$name.stock"; done
    echo "Kept Proton's DLLs as $target/{d3d11,dxgi}.dll.stock"
  elif [[ ! -f "$target/d3d11.dll.stock" ]]; then
    echo "$dest is already patched and has no .stock copy; uninstall cannot bring its own DLLs back."
  fi
fi
install_dlls "$dest"
echo "Installed DXVK $new_version into $dest."
