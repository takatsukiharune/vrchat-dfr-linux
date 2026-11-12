#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${GAZE_OUTPUT_DIR:-$repo_dir/dist/gaze}"
mkdir -p "$out_dir"
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Wno-missing-field-initializers \
  "$repo_dir/tools/openxr-gaze-bridge.cpp" \
  $(pkg-config --cflags --libs openxr) -pthread -o "$out_dir/openxr-gaze-bridge"
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra "$repo_dir/tools/dfrctl.cpp" -pthread -o "$out_dir/dfrctl"
echo "Built: $out_dir/openxr-gaze-bridge $out_dir/dfrctl"
