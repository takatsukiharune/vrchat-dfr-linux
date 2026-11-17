#!/usr/bin/env bash
# Installs the patched d3d11.dll and dxgi.dll for one Proton build.
#
#   install-dxvk.sh [options] PROTON     PROTON is a directory or the name of a Proton build
#   install-dxvk.sh                      list the Proton builds found
#
# Default: copy PROTON to <name>-dfr beside it and patch the copy. PROTON itself
# is not changed. PROTON may also name such a copy, to update it.
#
#   --in-place         patch PROTON itself and keep its DLLs as d3d11.dll.stock and dxgi.dll.stock
#   --refresh          copy PROTON again when it changed after <name>-dfr was made
#   --dxvk-from PATH   directory or .zip with d3d11.dll and dxgi.dll
#                      (default: the build in dist/ made for PROTON with `build --proton`)
#   --force            install DLLs built from a different DXVK commit than PROTON ships
#   --tools-dir DIR    where <name>-dfr goes (default: the compatibilitytools.d of PROTON's Steam)
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_dir/scripts/lib.sh"

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
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
target_dir="$(resolve_proton "$proton")" || die "No Proton build '$proton'. Run without arguments to list them."
[[ -f "$(proton_dxvk_dir "$target_dir")/d3d11.dll" ]] || die "No DXVK in $target_dir."

# source: the Proton build a copy is made from. dest: where the DLLs go.
if [[ -f "$target_dir/.dfr-clone" ]]; then
  dest="$target_dir"
  source_dir="$(cat "$dest/.dfr-clone")"
  tools_dir="$(dirname "$dest")"
elif (( in_place )); then
  dest="$target_dir" source_dir=""
else
  source_dir="$target_dir"
  if [[ -z "$tools_dir" ]]; then
    tools_dir="$(tools_dir_of "$source_dir")" || die "Cannot tell which Steam has $source_dir. Pass --tools-dir DIR."
  fi
  dest="$tools_dir/$(basename "$source_dir")-dfr"
  if [[ -e "$dest" && ! -f "$dest/.dfr-clone" ]]; then
    die "$dest exists and was not made by this script. Remove it, or patch it with: $0 --in-place '$dest'"
  fi
  if [[ -e "$dest" && "$(cat "$dest/.dfr-clone")" != "$source_dir" ]]; then
    die "$dest is a copy of $(cat "$dest/.dfr-clone"), not of $source_dir."
  fi
fi

# A new copy is made when there is none yet, or when --refresh asks for one
# because its source changed.
copy=0
if [[ -n "$source_dir" ]]; then
  if [[ ! -e "$dest" ]]; then
    copy=1
  elif [[ ! -d "$source_dir" ]]; then
    (( ! refresh )) || die "$source_dir no longer exists, so $dest cannot be copied again."
  elif ! same_version "$source_dir" "$dest"; then
    (( refresh )) || die "$source_dir changed after $dest was made.
Close the game and run again with --refresh to copy it again."
    copy=1
  fi
fi

# The DLLs must fit the DXVK the game will run with: the copy's own, unless a
# new copy is about to replace it.
shipped="$dest"
(( copy )) && shipped="$source_dir"
commit="$(proton_dxvk_commit "$shipped" 2>/dev/null || true)"
variant="$(proton_variant "$shipped")"
# A build for this Proton release carries its DXVK patches and names it.
for_this_proton() {
  if [[ -n "$variant" ]]; then [[ "$1" == *"-$variant-dfr."* ]]; else [[ "$1" =~ -g[0-9a-f]+-dfr\. ]]; fi
}

if [[ -z "$dxvk_from" ]]; then
  for dir in "$repo_dir"/dist/dxvk*/; do
    [[ -f "$dir/d3d11.dll" && -f "$dir/dxgi.dll" ]] || continue
    version="$(dll_dxvk_version "$dir/d3d11.dll")"
    if same_commit "$commit" "$(version_commit "$version")" && for_this_proton "$version"; then dxvk_from="${dir%/}"; break; fi
  done
  [[ -n "$dxvk_from" ]] || die "No build in $repo_dir/dist was made for ${variant:-DXVK ${commit:-of this Proton build}}.
Build it with: scripts/dev-container.sh build --proton '$shipped'"
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
Build matching DLLs with: scripts/dev-container.sh build --proton '$shipped'
or pass --force to install these."
  echo "$message Installing them because of --force."
fi
for_this_proton "$new_version" || echo "Note: these DLLs were not built with the DXVK patches of ${variant:-plain upstream DXVK}."

install_dlls() {
  local target name
  target="$(proton_dxvk_dir "$1")"
  for name in d3d11.dll dxgi.dll; do replace_file "$dxvk_from/$name" "$target/$name"; done
}

# Steam keeps the internal name per game. The copy uses its source's name plus
# -dfr, so a game set to a hand-made copy of the same name keeps working.
write_manifest() {  # DIR
  local name
  name="$(tool_internal_name "$source_dir")-dfr"
  while IFS= read -r other; do
    [[ "$other" == "$dest" ]] || die "$other already uses the name $name; Steam could pick either. Remove one of them."
  done < <(tools_named "$name" "$tools_dir")
  cat > "$1/compatibilitytool.vdf" <<VDF
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
  echo "Select '$name' as the compatibility tool for the game in Steam (restart Steam if it is not listed)."
}

if (( copy )); then
  mkdir -p "$tools_dir"
  staging="$(mktemp -d "$dest.XXXXXX")"
  cp -a --reflink=auto "$source_dir/." "$staging/"
  printf '%s\n' "$source_dir" > "$staging/.dfr-clone"
  write_manifest "$staging" >/dev/null
  install_dlls "$staging"
  rm -rf "$dest"
  mv -T "$staging" "$dest"
  echo "Made $dest from $source_dir with DXVK $new_version."
  write_manifest "$dest"
  exit 0
fi
if [[ -n "$source_dir" && -d "$source_dir" ]]; then
  write_manifest "$dest" >/dev/null
elif [[ -z "$source_dir" ]]; then
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
