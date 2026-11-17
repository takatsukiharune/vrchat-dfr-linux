#!/usr/bin/env bash
# Host build without the container: checks the tools, fetches the dxvk
# submodule and builds the bridge and the probe.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for tool in git meson ninja x86_64-w64-mingw32-g++ glslangValidator c++ pkg-config; do
  if ! command -v "$tool" >/dev/null; then
    echo "Missing tool: $tool (Arch: base-devel git meson ninja mingw-w64-gcc glslang openxr)" >&2
    exit 1
  fi
done
pkg-config --exists openxr
git -C "$repo_dir" submodule update --init dxvk
bash "$repo_dir/scripts/build-openxr-probe.sh"
bash "$repo_dir/scripts/build-openxr-bridge.sh"
echo "Ready. Build DXVK with: bash '$repo_dir/scripts/build-dxvk.sh'"
