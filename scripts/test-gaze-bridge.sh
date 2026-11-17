#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${DFR_BUILD_DIR:-$repo_dir/build}"
mkdir -p "$build_dir"
python3 - "$repo_dir" "$build_dir" <<'PY'
from pathlib import Path
import sys
root, build = Path(sys.argv[1]), Path(sys.argv[2])
patch = next((root / 'patches/dxvk').glob('0001-*.patch')).read_text()
section = patch.split('+++ b/src/dxvk/dxvk_gaze_shm.h\n', 1)[1].split('diff --git ', 1)[0]
embedded = ''.join(line[1:] + '\n' for line in section.splitlines() if line.startswith('+'))
assert embedded == (root / 'shared/gaze_shm.h').read_text(), 'DXVK protocol header differs from canonical ABI'
for name in ('dxvk_gaze_buffer.h', 'dxvk_gaze_map.h', 'dxvk_gaze_config.h'):
    section = patch.split(f'+++ b/src/dxvk/{name}\n', 1)[1].split('diff --git ', 1)[0]
    header = ''.join(line[1:] + '\n' for line in section.splitlines() if line.startswith('+'))
    (build / name).write_text(header)
    if name == 'dxvk_gaze_config.h':
        assert header == (root / 'shared/gaze_config.h').read_text(), 'DXVK config header differs from shared/gaze_config.h'
PY
common=(-std=c++17 -O2 -Wall -Wextra -Wno-missing-field-initializers)
"${CXX:-c++}" "${common[@]}" "$repo_dir/tests/gaze_unit.cpp" -o "$build_dir/gaze-unit"
"$build_dir/gaze-unit"
"${CXX:-c++}" "${common[@]}" -I"$build_dir" "$repo_dir/tests/gaze_buffer_unit.cpp" -o "$build_dir/gaze-buffer-unit"
"$build_dir/gaze-buffer-unit"
"${CXX:-c++}" "${common[@]}" -pthread -I"$build_dir" "$repo_dir/tests/gaze_map_unit.cpp" -o "$build_dir/gaze-map-unit"
"$build_dir/gaze-map-unit"
"${CXX:-c++}" "${common[@]}" -I"$build_dir" "$repo_dir/tests/gaze_config_unit.cpp" -o "$build_dir/gaze-config-unit"
"$build_dir/gaze-config-unit"
"${CXX:-c++}" "${common[@]}" "$repo_dir/tools/openxr-gaze-bridge.cpp" \
  "$repo_dir/tests/fake_openxr.cpp" -pthread -o "$build_dir/gaze-bridge-fake"
python3 "$repo_dir/tests/test_gaze_bridge.py" "$build_dir/gaze-bridge-fake"
"${CXX:-c++}" "${common[@]}" "$repo_dir/tools/dfrctl.cpp" -pthread -o "$build_dir/dfrctl"
bash "$repo_dir/tests/test_dfrctl.sh" "$build_dir/dfrctl"
bash "$repo_dir/tests/test_install.sh"
