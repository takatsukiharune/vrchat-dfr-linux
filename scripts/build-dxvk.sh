#!/usr/bin/env bash
# Builds d3d11.dll and dxgi.dll from an upstream DXVK commit plus patches/dxvk.
#
#   build-dxvk.sh                  the commit pinned by the dxvk submodule -> dist/dxvk
#   build-dxvk.sh --proton DIR     the commit that Proton build ships      -> dist/dxvk-<version>
#                                  GE-Proton and proton-cachyos patch DXVK themselves: their
#                                  patches for that release go under the gaze patches.
#                                  --plain leaves them out.
#   build-dxvk.sh --variant NAME   the same for a release by name, e.g. GE-Proton11-12 or
#                                  cachyos-11.0-20261015-slr, without a local Proton build
#   build-dxvk.sh --ref REF        any upstream commit, tag or branch      -> dist/dxvk-<version>
#
# The submodule is only read. The build happens in a separate clone
# (DXVK_WORK_DIR, default .work/dxvk-build). DXVK_OUTPUT_DIR and
# DXVK_BUILD_JOBS override the output directory and the job count.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_dir/scripts/lib.sh"
work="${DXVK_WORK_DIR:-$repo_dir/.work/dxvk-build}"

ref="" proton="" plain=0 variant=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) ref="${2:?--ref needs a value}"; shift 2 ;;
    --proton) proton="${2:?--proton needs a value}"; shift 2 ;;
    --plain) plain=1; shift ;;
    --variant) variant="${2:?--variant needs a value}"; shift 2 ;;
    *) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
  esac
done

[[ -e "$repo_dir/dxvk/.git" ]] || {
  echo "The dxvk submodule is missing. Run: git submodule update --init dxvk" >&2
  exit 1
}
pinned="$(pinned_dxvk_commit "$repo_dir")"
if [[ -n "$proton" ]]; then
  ref="$(proton_dxvk_commit "$proton")" || {
    echo "Cannot tell which DXVK commit $proton ships. Pass --ref COMMIT." >&2
    exit 1
  }
  (( plain )) || variant="$(proton_variant "$proton")"
fi

[[ -d "$work/.git" ]] || git clone -q --no-checkout "$repo_dir/dxvk" "$work"
cd "$work"
if [[ -n "$variant" ]]; then
  fetch_variant_patches "$variant" "$work/.git/variant-patches" || {
    echo "Cannot fetch the DXVK patches of $variant. Pass --plain to build without them." >&2
    exit 1
  }
  ref="${ref:-$(cat "$work/.git/variant-patches/commit")}"
fi
git fetch -q --tags origin HEAD
base="$(resolve_dxvk_ref "${ref:-$pinned}")" || exit 1
base_version="$(git describe "$base")"

# With a fixed identity and date, the same base and patches give the same commits.
export GIT_COMMITTER_NAME="vrchat-dfr-linux" GIT_COMMITTER_EMAIL="vrchat-dfr-linux@users.noreply.github.com"
export GIT_COMMITTER_DATE="2000-01-01T00:00:00Z"
git am -q --abort 2>/dev/null || true
git checkout -q -f --detach "$base"
git clean -q -fd -e '/build-*'
# Before any commit is made here, or `git add` would record stale submodules.
git submodule update -q --init --recursive
if [[ -n "$variant" ]]; then
  apply_variant_patches "$work/.git/variant-patches" "$variant" || exit 1
  base_version+="-$variant"
fi
if ! git am -q -k -3 "$repo_dir"/patches/dxvk/*.patch; then
  git am -q --abort || true
  git checkout -q -f --detach "$base"
  echo "patches/dxvk does not apply to DXVK $base_version." >&2
  exit 1
fi

# DXVK takes its version string from `git describe`. Tagging the patched commit
# makes the DLL name its base commit and the revision of this repository.
revision="$(git -C "$repo_dir" rev-parse --short HEAD)"
[[ -z "$(git -C "$repo_dir" status --porcelain --ignore-submodules=all)" ]] || revision+="+"
git tag -l '*-dfr.*' | xargs -r git tag -d >/dev/null
git tag -a -m "gaze VRS on $base_version" "$base_version-dfr.$revision"

out_dir="${DXVK_OUTPUT_DIR:-$repo_dir/dist/dxvk}"
[[ ( "$base" == "$pinned" && -z "$variant" ) || -n "${DXVK_OUTPUT_DIR:-}" ]] || out_dir="$repo_dir/dist/dxvk-$base_version"
build="build-${base:0:12}"
setup_args=()
[[ -f "$build/meson-private/coredata.dat" ]] && setup_args+=(--reconfigure)
meson setup "${setup_args[@]}" "$build" \
  --cross-file build-win64.txt \
  -Dbuildtype=release \
  -Denable_d3d8=false \
  -Denable_d3d9=false \
  -Denable_d3d10=false
ninja -C "$build" -j "${DXVK_BUILD_JOBS:-4}"

mkdir -p "$out_dir"
cp "$build/src/d3d11/d3d11.dll" "$build/src/dxgi/dxgi.dll" "$out_dir/"
echo "Built DXVK $(git describe): $out_dir/d3d11.dll $out_dir/dxgi.dll"
