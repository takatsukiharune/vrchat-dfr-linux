#!/usr/bin/env bash
# Build and test everything inside a podman container, leaving the host's
# Proton, Wine prefixes and VR runtime alone. The repository is the only host
# directory mounted. The GPU render node is passed through for the end-to-end
# test only so that it can render offscreen with a real Vulkan driver.
#
#   scripts/dev-container.sh all      build DXVK + tools, run every test
#   scripts/dev-container.sh build    dist/dxvk/*.dll, dist/gaze/*
#   scripts/dev-container.sh test     unit and bridge tests (no GPU needed)
#   scripts/dev-container.sh e2e      DXVK end-to-end test under Wine (needs /dev/dri)
#   scripts/dev-container.sh shell    interactive shell in the container
#   scripts/dev-container.sh rm       delete the container and its image
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="${DFR_CONTAINER:-vrchat-dfr-dev}"
image="localhost/$name:latest"
engine="${DFR_CONTAINER_ENGINE:-podman}"
command -v "$engine" >/dev/null || { echo "Missing: $engine" >&2; exit 1; }

ensure() {
  if ! "$engine" image exists "$image"; then
    "$engine" build -t "$image" - <<'CONTAINERFILE'
FROM registry.fedoraproject.org/fedora:45
RUN dnf install -y git meson ninja-build gcc-c++ pkgconf-pkg-config python3 diffutils findutils which procps-ng \
      mingw64-gcc-c++ mingw64-winpthreads-static mingw64-headers glslang openxr-devel \
      wine-core mesa-vulkan-drivers vulkan-validation-layers vulkan-tools \
    && dnf clean all
CONTAINERFILE
  fi
  if ! "$engine" container exists "$name"; then
    local devices=()
    [[ -d /dev/dri ]] && devices=(--device /dev/dri --group-add keep-groups)
    "$engine" run -d --name "$name" --init --security-opt label=disable --userns=keep-id \
      "${devices[@]}" -v "$repo_dir":/src -w /src "$image" sleep infinity >/dev/null
  fi
  "$engine" start "$name" >/dev/null
}

# HOME inside the container, so caches do not land in the repository.
run() {
  "$engine" exec -e HOME=/var/tmp/home -e DXVK_BUILD_JOBS="${DXVK_BUILD_JOBS:-$(nproc)}" "$name" \
    bash -c "mkdir -p /var/tmp/home && cd /src && $1"
}

case "${1:-}" in
  build) ensure; run "bash scripts/setup-dev.sh && bash scripts/build-dxvk.sh" ;;
  test)  ensure; run "bash scripts/test-gaze-bridge.sh" ;;
  e2e)   ensure; shift; run "bash scripts/test-dxvk-e2e.sh $*" ;;
  all)   ensure; run "bash scripts/setup-dev.sh && bash scripts/build-dxvk.sh && bash scripts/test-gaze-bridge.sh && bash scripts/test-dxvk-e2e.sh" ;;
  shell) ensure; exec "$engine" exec -it -e HOME=/var/tmp/home "$name" bash ;;
  rm)    "$engine" rm -f "$name" >/dev/null 2>&1 || true; "$engine" rmi "$image" >/dev/null 2>&1 || true; echo "Removed $name" ;;
  *)     sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
