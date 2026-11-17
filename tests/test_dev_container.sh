#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# dev-container.sh with a stand-in container engine: what each command hands it.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
cat > "$dir/engine" <<'ENGINE'
#!/usr/bin/env bash
[[ "$1" == image ]] && exit 0
printf '%s\n' "$@" >> "$ENGINE_LOG"
# The words the container's shell runs, after "mkdir -p /work/home &&".
command="${!#}"
eval "words=(${command#*&& })"
printf 'WORD %s\n' "${words[@]}" >> "$ENGINE_LOG"
ENGINE
chmod +x "$dir/engine"
export DFR_CONTAINER_ENGINE="$dir/engine" ENGINE_LOG="$dir/log"
proton="$dir/My Proton"
mkdir -p "$proton/files/lib/wine/dxvk/x86_64-windows" && touch "$proton/files/lib/wine/dxvk/x86_64-windows/d3d11.dll"
run() { : > "$ENGINE_LOG"; bash "$repo_dir/scripts/dev-container.sh" "$@" >/dev/null; }
# The last command's words, joined by |.
words() { grep '^WORD ' "$ENGINE_LOG" | cut -c6- | paste -sd'|' | sed 's/.*bash|scripts\/build-openxr-bridge.sh|//'; }

# --proton is mounted wherever it stands, and the other options pass through.
run build --proton "$proton" --plain
grep -qx -- "--volume=$proton:/proton:ro" "$ENGINE_LOG"
[[ "$(words)" == 'bash|scripts/build-dxvk.sh|--proton|/proton|--plain' ]]
run build --plain --proton "$proton"
grep -qx -- "--volume=$proton:/proton:ro" "$ENGINE_LOG"
[[ "$(words)" == 'bash|scripts/build-dxvk.sh|--plain|--proton|/proton' ]]
run build
[[ "$(words)" == 'bash|scripts/build-dxvk.sh' ]]

# Arguments keep their words.
run check master 'two words'
[[ "$(words)" == 'bash|scripts/dxvk-patches.sh|check|master|two words' ]]
run e2e --bench 45,65 'a b'
[[ "$(words)" == 'bash|scripts/test-dxvk-e2e.sh|--bench|45,65|a b' ]]
echo "dev-container tests passed"
