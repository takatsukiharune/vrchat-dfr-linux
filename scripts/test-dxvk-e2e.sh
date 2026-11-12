#!/usr/bin/env bash
# End-to-end test of the built DXVK DLLs: an offscreen D3D11 probe under Wine,
# a fake gaze writer and live config edits. Needs wine, a Vulkan driver with
# VK_KHR_fragment_shading_rate and (unless --no-validate) the Khronos
# validation layer. Uses a throwaway Wine prefix; see scripts/dev-container.sh.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dxvk_dir="${DXVK_OUTPUT_DIR:-$repo_dir/dist/dxvk}"
work="${DFR_E2E_DIR:-${TMPDIR:-/tmp}/vrchat-dfr-e2e}"
[[ -f "$dxvk_dir/d3d11.dll" ]] || { echo "Build DXVK first: bash scripts/build-dxvk.sh" >&2; exit 1; }
for tool in wine wineserver x86_64-w64-mingw32-g++ python3; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
mkdir -p "$repo_dir/build/e2e" "$work"
x86_64-w64-mingw32-g++ -std=c++17 -O2 -static -o "$repo_dir/build/e2e/d3d11_vrs_probe.exe" \
  "$repo_dir/tests/e2e/d3d11_vrs_probe.cpp" -ld3d11 -ld3dcompiler -ldxguid
"${CXX:-c++}" -std=c++17 -O2 -pthread -o "$repo_dir/build/e2e/gaze-writer" "$repo_dir/tests/e2e/gaze_writer.cpp"

# Never the user's own prefix. Wine's first-run setup can stall without a
# display, so give it a bounded time and then mark the prefix as up to date.
export HOME="$work/home" WINEPREFIX="$work/home/wine" XDG_RUNTIME_DIR="$work/home"
export WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
unset DISPLAY WAYLAND_DISPLAY
mkdir -p "$HOME"
if [[ ! -f "$WINEPREFIX/.update-timestamp" ]]; then
  timeout -k 2 60 wine wineboot -i >/dev/null 2>&1 || true
  wineserver -k >/dev/null 2>&1 || true
  echo disable > "$WINEPREFIX/.update-timestamp"
fi
python3 "$repo_dir/tests/e2e/test_dxvk_e2e.py" --dxvk "$dxvk_dir" \
  --probe "$repo_dir/build/e2e/d3d11_vrs_probe.exe" --writer "$repo_dir/build/e2e/gaze-writer" \
  --work "$work/run" "$@"
