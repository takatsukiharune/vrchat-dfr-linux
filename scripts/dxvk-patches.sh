#!/usr/bin/env bash
# Moves the gaze changes between patches/dxvk and the dxvk submodule.
#
#   dxvk-patches.sh apply          check out branch dfr in the submodule: pinned commit + patches
#   dxvk-patches.sh export         rewrite patches/dxvk from the commits on top of the pinned commit
#   dxvk-patches.sh check [REF..]  test that the patches apply to each REF (default: the pinned commit)
#
# To change the DXVK code: apply, edit and commit in dxvk/, export, commit patches/dxvk.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_dir/scripts/lib.sh"
sub="$repo_dir/dxvk"
[[ -e "$sub/.git" ]] || { echo "Run: git submodule update --init dxvk" >&2; exit 1; }
pinned="$(git -C "$repo_dir" ls-files -s dxvk | awk '{print $2}')"
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
    git -C "$sub" am -q -3 "$repo_dir"/patches/dxvk/*.patch
    echo "dxvk/ is on branch dfr: $(git -C "$sub" describe "$pinned") + patches/dxvk"
    ;;
  export)
    [[ -z "$(git -C "$sub" status --porcelain)" ]] || { echo "dxvk/ has uncommitted changes." >&2; exit 1; }
    [[ "$(git -C "$sub" rev-list --count "$pinned..HEAD")" -gt 0 ]] || { echo "dxvk/ has no commits on top of $pinned." >&2; exit 1; }
    rm -f "$repo_dir"/patches/dxvk/*.patch
    git -C "$sub" format-patch -q --no-signature --zero-commit --full-index -o "$repo_dir/patches/dxvk" "$pinned..HEAD"
    ls "$repo_dir"/patches/dxvk
    ;;
  check)
    shift
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    git clone -q --no-checkout "$sub" "$scratch/dxvk"
    cd "$scratch/dxvk"
    failed=0
    for ref in "${@:-$pinned}"; do
      if ! git rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1; then
        git fetch -q "$dxvk_upstream_url" "$ref:refs/check/target"
        ref=refs/check/target
      fi
      git checkout -q -f --detach "$ref"
      if git am -q -3 "$repo_dir"/patches/dxvk/*.patch >/dev/null 2>&1; then
        echo "ok        $(git rev-parse --short "$ref")"
      else
        echo "CONFLICT  $(git rev-parse --short "$ref"): $(git diff --name-only --diff-filter=U | tr '\n' ' ')"
        git am -q --abort
        failed=1
      fi
    done
    exit "$failed"
    ;;
  *) sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
