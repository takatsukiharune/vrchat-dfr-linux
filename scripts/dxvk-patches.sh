#!/usr/bin/env bash
# Moves the gaze changes between patches/dxvk and the dxvk submodule.
#
#   dxvk-patches.sh apply          check out branch dfr in the submodule: pinned commit + patches
#   dxvk-patches.sh export         rewrite patches/dxvk from the commits on top of the pinned commit
#   dxvk-patches.sh check [REF..]  test that the patches apply to each REF (default: the pinned commit).
#                                  REF is a DXVK commit, tag or branch, or a GE-Proton or
#                                  proton-cachyos release name: then on top of its DXVK patches.
#
# To change the DXVK code: apply, edit and commit in dxvk/, export, commit patches/dxvk.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_dir/scripts/lib.sh"
sub="$repo_dir/dxvk"
[[ -e "$sub/.git" ]] || { echo "Run: git submodule update --init dxvk" >&2; exit 1; }
pinned="$(pinned_dxvk_commit "$repo_dir")"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-vrchat-dfr-linux}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-vrchat-dfr-linux@users.noreply.github.com}"

case "${1:-}" in
  apply)
    [[ -z "$(git -C "$sub" status --porcelain)" ]] || { echo "dxvk/ has uncommitted changes." >&2; exit 1; }
    if git -C "$sub" rev-parse -q --verify refs/heads/dfr >/dev/null; then
      echo "Branch dfr exists in dxvk/. Export it, or delete it with: git -C dxvk branch -D dfr" >&2
      exit 1
    fi
    git -C "$sub" switch -q -c dfr "$pinned"
    git -C "$sub" am -q -k -3 "$repo_dir"/patches/dxvk/*.patch
    echo "dxvk/ is on branch dfr: $(git -C "$sub" describe "$pinned") + patches/dxvk"
    ;;
  export)
    [[ -z "$(git -C "$sub" status --porcelain)" ]] || { echo "dxvk/ has uncommitted changes." >&2; exit 1; }
    [[ "$(git -C "$sub" rev-list --count "$pinned..HEAD")" -gt 0 ]] || { echo "dxvk/ has no commits on top of $pinned." >&2; exit 1; }
    rm -f "$repo_dir"/patches/dxvk/*.patch
    git -C "$sub" format-patch -q -k --no-signature --zero-commit --full-index -o "$repo_dir/patches/dxvk" "$pinned..HEAD"
    ls "$repo_dir"/patches/dxvk
    ;;
  check)
    shift
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    git clone -q --no-checkout "$sub" "$scratch/dxvk"
    cd "$scratch/dxvk"
    failed=0
    for target in "${@:-$pinned}"; do
      ref="$target" variant=""
      case "$target" in
        GE-Proton*|cachyos-*)
          fetch_variant_patches "$target" "$scratch/variant" || { echo "FETCH     $target"; failed=1; continue; }
          ref="$(cat "$scratch/variant/commit")" variant="$target" ;;
      esac
      base="$(resolve_dxvk_ref "$ref")" || { echo "FETCH     $target"; failed=1; continue; }
      git checkout -q -f --detach "$base"
      git clean -q -fd
      label="$(git rev-parse --short HEAD)"
      if [[ -n "$variant" ]]; then
        label+=" + $target"
        apply_variant_patches "$scratch/variant" "$target" || { echo "VARIANT   $label"; failed=1; continue; }
      fi
      if git am -q -k -3 "$repo_dir"/patches/dxvk/*.patch >/dev/null 2>&1; then
        echo "ok        $label"
      else
        echo "CONFLICT  $label: $(git diff --name-only --diff-filter=U | tr '\n' ' ')"
        git am -q --abort
        failed=1
      fi
    done
    exit "$failed"
    ;;
  *) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
