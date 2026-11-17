#!/usr/bin/env bash
# Build and test inside a podman container that is deleted after each command.
# The repository is mounted read-only apart from dist/, at its own path, so the
# relative paths git keeps in a worktree still lead somewhere. Clones, build trees and
# the Wine prefix live in the volume vrchat-dfr-work. The GPU render node is
# passed through for the end-to-end test only.
#
#   scripts/dev-container.sh build [--proton DIR | --variant NAME | --ref REF]
#                                     DXVK DLLs for the pinned commit, a Proton build or
#                                     any DXVK commit, and dist/gaze/*
#   scripts/dev-container.sh bridge   dist/gaze/* only (built on Ubuntu 24.04 for older hosts)
#   scripts/dev-container.sh check [REF..]
#                                     do the patches apply? See scripts/dxvk-patches.sh
#   scripts/dev-container.sh test     unit and bridge tests (no GPU needed)
#   scripts/dev-container.sh e2e      DXVK end-to-end test under Wine (needs /dev/dri)
#   scripts/dev-container.sh all      build, test and e2e
#   scripts/dev-container.sh shell    interactive shell in the container
#   scripts/dev-container.sh rm       delete the images and the volume
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_dir/scripts/lib.sh"
engine="${DFR_CONTAINER_ENGINE:-podman}"
volume="vrchat-dfr-work"
command -v "$engine" >/dev/null || { echo "Missing: $engine" >&2; exit 1; }

# One image per stage and Containerfile content, so an edit rebuilds it.
image() {
  local tag
  tag="localhost/vrchat-dfr-$1:$(sha256sum "$repo_dir/container/Containerfile" | cut -c1-12)"
  "$engine" image exists "$tag" \
    || "$engine" build -q --target "$1" -t "$tag" -f "$repo_dir/container/Containerfile" "$repo_dir/container" >/dev/null
  printf '%s\n' "$tag"
}

# run STAGE [podman options --] COMMAND
run() {
  local stage="$1" options=()
  shift
  while [[ "${1:-}" == -* ]]; do
    [[ "$1" == "--" ]] && { shift; break; }
    options+=("$1"); shift
  done
  [[ "$stage" == bridge || -e "$repo_dir/dxvk/.git" ]] || git -C "$repo_dir" submodule update --init dxvk
  # In a git worktree, .git points into the main repository: mount that too.
  local common
  common="$(git -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir)"
  [[ "$common" == "$repo_dir/.git" ]] || options+=("--volume=$common:$common:ro")
  mkdir -p "$repo_dir/dist"
  "$engine" run --rm --init --security-opt label=disable --userns=keep-id \
    -v "$repo_dir:$repo_dir:ro" -v "$repo_dir/dist:$repo_dir/dist" -v "$volume":/work:U -w "$repo_dir" \
    -e HOME=/work/home -e DFR_BUILD_DIR=/work/build -e DXVK_WORK_DIR=/work/dxvk-build \
    -e DFR_E2E_DIR=/work/e2e -e DXVK_BUILD_JOBS="${DXVK_BUILD_JOBS:-$(nproc)}" \
    "${options[@]}" "$(image "$stage")" bash -c "mkdir -p /work/home && $1"
}

gpu=()
[[ -d /dev/dri ]] && gpu=(--device=/dev/dri --group-add=keep-groups)
bridge="bash scripts/build-openxr-bridge.sh"
build="bash scripts/build-dxvk.sh"
# The arguments, each quoted for the container's shell.
quoted() { [[ $# -eq 0 ]] || printf ' %q' "$@"; }

case "${1:-}" in
  bridge) run bridge "$bridge" ;;
  build)
    shift
    args=() mount=()
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --proton ]]; then
        proton="$(resolve_proton "${2:?--proton needs a Proton directory or name}")" \
          || { echo "No Proton build '$2'. Found:" >&2; list_proton_installs >&2; exit 1; }
        mount=("--volume=$proton:/proton:ro")
        args+=(--proton /proton)
        shift 2
      else
        args+=("$1")
        shift
      fi
    done
    run bridge "$bridge"
    run build "${mount[@]}" -- "$build$(quoted "${args[@]}")"
    ;;
  check) shift; run build "bash scripts/dxvk-patches.sh check$(quoted "$@")" ;;
  test)  run build "bash scripts/test-gaze-bridge.sh" ;;
  e2e)   shift; run e2e "${gpu[@]}" -- "bash scripts/test-dxvk-e2e.sh$(quoted "$@")" ;;
  all)   run bridge "$bridge"
         run build "$build && bash scripts/test-gaze-bridge.sh"
         run e2e "${gpu[@]}" -- "bash scripts/test-dxvk-e2e.sh" ;;
  shell) run e2e -it "${gpu[@]}" -- bash ;;
  rm)
    "$engine" images --format '{{.Repository}}:{{.Tag}}' | grep -E '^localhost/vrchat-dfr-(bridge|build|e2e):' \
      | xargs -r "$engine" rmi >/dev/null
    "$engine" volume rm -f "$volume" >/dev/null
    echo "Removed the vrchat-dfr images and volume"
    ;;
  *) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
