# OpenXR + DXVK Gaze-Driven VRS

Gaze-driven variable rate shading (dynamic foveated rendering) for VRChat on
Linux. It also works for other DXVK applications.

A separate native Linux process reads gaze through standard OpenXR
(`XR_EXT_eye_gaze_interaction` with `XR_MND_headless`) and publishes per-eye
centers to `/dev/shm/vrchat_dfr_gaze`. Patched DXVK reads this shared memory
and builds a Vulkan fragment-shading-rate attachment around the gaze point.
This project does not modify the OpenXR runtime or xrizer.

The bridge needs an OpenXR runtime with `XR_MND_headless`,
`XR_EXT_eye_gaze_interaction` and `XR_KHR_convert_timespec_time`. The runtime
must let the bridge run as a second application next to the game, and the
headset must send eye tracking to it. `./build/openxr-gaze-probe` lists whether
a runtime has the extensions. We have tested only WiVRn.

## Status

Meant for everyday use: when anything is missing or goes wrong (no bridge, no
headset, tracking lost, bad setting, unsupported GPU) the game renders at full
rate instead of misbehaving, and every setting can be changed while the game
runs ([Live tuning](#live-tuning)).

What has been checked:

- Live in VRChat, with the revision before live tuning and tracking-loss
  handling were added: an RTX 3060 Ti with a Pico 4 Pro on Arch, and RADV on
  an RX 9070 XT (VRCMark GPU score 7538 -> 9021).
- By the automated tests: `scripts/test-gaze-bridge.sh` (projection
  math, shared-memory protocol, settings parser, map worker, bridge lifecycle
  against a simulated OpenXR runtime) and `scripts/test-dxvk-e2e.sh`, which
  runs the built DLLs under Wine on a real Vulkan driver, renders offscreen
  and checks from the rendered pixels that the full-rate region is where the
  gaze is, has the configured size, follows live setting changes, survives a
  killed and restarted bridge, and produces no Vulkan validation errors.

Not covered by automation: gaze-to-image alignment and latency in a real
headset. Use `dfrctl set dot 1` to check alignment on your hardware.

VRChat issues several passes of similar size, so VRS has to be restricted
to the RGBA16F scene pass (`fmt=97`) with a Y flip - otherwise you get
multiple foveation spots. These are the tested values, not universal
requirements.

> [!WARNING]
> Use at your own risk. This is an unofficial modification, not endorsed by or affiliated with VRChat, DXVK or any OpenXR runtime. It runs the game with modified `d3d11.dll` and `dxgi.dll`, and VRChat's rules or anti-cheat may treat modified clients differently. I haven't verified how.  
> I also recommend against using MSAA/Anti-Aliasing in VRChat with this, as increasing the MSAA sample count can limit the maximum VRS coarse rate available on some GPUs. For better image quality, use a higher render resolution instead.

## Install

**DXVK.** The installer copies a Proton build to `<name>-dfr` and puts the
patched `d3d11.dll` and `dxgi.dll` into the copy. It does not change the
Proton build itself.

```bash
./scripts/install-dxvk.sh                       # list the Proton builds found
./scripts/dev-container.sh build --proton GE-Proton11-12
./scripts/install-dxvk.sh GE-Proton11-12        # makes GE-Proton11-12-dfr
```

Restart Steam and select `GE-Proton11-12-dfr` as the compatibility tool for
the game. `uninstall-dxvk.sh GE-Proton11-12-dfr` deletes the copy.

The DLLs must come from the DXVK commit the Proton build ships. `build
--proton` reads that commit from the Proton build and builds for it. The
installer picks the matching build from `dist/` and refuses any other, unless
you pass `--force`. A release zip, installed with `--dxvk-from
./dxvk-gaze-vrs.zip`, has DLLs for one DXVK commit and fits few Proton builds.

GE-Proton and proton-cachyos add their own patches to DXVK. For those two,
`build --proton` fetches the DXVK patches of that release from its repository
and applies them under the gaze patches, in the order the release's own build
does. The DLL's version string then names the release, and the installer picks
only such a build for it. `scripts/build-dxvk.sh --proton DIR --plain` leaves
those patches out. Other Proton builds get the upstream commit plus the gaze
patches.

When Steam updates the Proton build, the copy stays as it was. `dfrctl doctor`
reports that, and `install-dxvk.sh --refresh NAME` makes the copy again.

`--in-place` patches the Proton build itself and keeps its own DLLs beside
them as `d3d11.dll.stock` and `dxgi.dll.stock`. `uninstall-dxvk.sh NAME` puts
them back. A Proton update replaces the patched DLLs, and you must install
again.

Removing `DXVK_GAZE_VRS=1` from the launch options also turns everything off:
without it the patched DLLs run none of the gaze code.

**Gaze bridge** — build and run on the Linux host:

```bash
# Arch dependencies: base-devel git meson ninja mingw-w64-gcc glslang openxr
bash scripts/setup-dev.sh
bash scripts/build-dxvk.sh

# Start your OpenXR runtime and connect the HMD, with eye tracking enabled.
./dist/gaze/openxr-gaze-bridge --verbose
```

Keep the bridge running while playing. It reconnects to OpenXR every 2 seconds
when the runtime or HMD is unavailable. Ctrl-C stops it. If the bridge does
not find the runtime by itself, set `XR_RUNTIME_JSON` to the runtime's OpenXR
manifest for the bridge process.

The bridge polls at 250 Hz. OpenXR provides one combined gaze ray; each eye's
pose and FOV are used to project it independently. The default assumes infinite
fixation distance. `--distance 1` instead assumes a fixation point 1 metre along
the ray; this is an approximation, not measured convergence. Use `--help` for
the polling rate, sample-age limit, output path and timed diagnostic options.

## Run VRChat

Recommended: keep the settings in a file, so they can be changed while the
game runs and the launch options never need editing again.

```bash
dfrctl set fmt 97 flip_y 1 full_area 45 mid_area 65 coarse auto   # writes ~/.config/vrchat-dfr/dfr.conf
dfrctl launch-options                                             # prints the line for Steam
```

Steam launch options then look like this (a plain Linux path is fine):

    DXVK_GAZE_VRS=1 DXVK_GAZE_CONFIG=/home/you/.config/vrchat-dfr/dfr.conf %command%

The old way still works and gives the same result, without live tuning:

    DXVK_GAZE_VRS=1 DXVK_GAZE_FMT=97 DXVK_GAZE_FLIP_Y=1 DXVK_GAZE_FULL_AREA=45 DXVK_GAZE_MID_AREA=65 DXVK_GAZE_COARSE=auto %command%

Both can be combined: the `DXVK_GAZE_*` variables are the defaults, and the
config file overrides them key by key. See
[`config/dfr.conf.example`](config/dfr.conf.example).

## Live tuning

`dfrctl` (built into `dist/gaze/`, no dependencies) edits the config file;
DXVK notices within about a third of a second. Editing the file by hand works
just as well.

```bash
dfrctl set full_area 35 mid_area 55   # shrink the sharp region
dfrctl set dot 1                      # show where DXVK thinks you are looking
dfrctl off                            # full-rate rendering, e.g. for a screenshot
dfrctl on
dfrctl status                         # is it actually foveating right now?
dfrctl doctor                         # is the whole setup right? Proton build, launch options, bridge
dfrctl keys                           # every setting and its range
```

`dfrctl status` reads a small status file that DXVK writes next to the config
once a second, and checks the bridge's heartbeat:

```
DXVK:   running
        enabled=1
        gaze=live
        source=open
        candidate_passes_per_s=180
        foveated_passes_per_s=180
        map_uploads_per_s=42
        pass=4128x2208 layers=1 fmt=97 samples=1
        coarse=2x2
        mid=2x2
        texel=8x8
Bridge: running, gaze L=(0.512, 0.487) R=(0.488, 0.487)
```

`foveated_passes_per_s=0` with `candidate_passes_per_s>0` means a pass was
found but there is no usable gaze; `candidate_passes_per_s=0` means no render
pass matches `fmt` / `samples` / `minsize`.

A setting that is not valid is never applied: `dfrctl` refuses it, and a
hand-edited file with a mistake is ignored as a whole (the previous settings
stay in effect, the reason is in the DXVK log). `coarse` is clamped to the
rates the GPU reports for the pass's sample count, so `4x4` on a GPU that only
does `2x2` gives `2x2`.

### Tracking loss

When the gaze becomes invalid (a blink, the headset taken off, the bridge
restarting) DXVK keeps the last gaze position for `hold_ms` (default 500), so
blinks do not make the frame rate jump. After that it renders at full rate
(`fallback off`, the default) or foveates around the centre of each eye
(`fallback center`) until tracking returns. Use `hold_ms 0` for the old
behaviour of dropping to full rate at once.

Verify the shared-memory file exists while a session is up:

    ls -l /dev/shm/vrchat_dfr_gaze

The shared format is versioned and incompatible with the `wivrn_gaze`
export of earlier versions. DXVK treats invalid data, or a heartbeat stopped
for 100 ms, as tracking loss (see above). It waits for a sequence change before accepting a
newly mapped file. After a stale mapping is closed, reopening may take up to
2 seconds.

If Steam's container has a different `/dev/shm`, choose a directory visible
both to the host and Proton, for example a directory under your home:

```bash
mkdir -p "$HOME/.cache/vrchat-dfr"
./dist/gaze/openxr-gaze-bridge --file "$HOME/.cache/vrchat-dfr/gaze" --verbose
```

Set `DXVK_GAZE_FILE` to the same path in VRChat's launch options, either as a
Linux path (`/home/you/.cache/vrchat-dfr/gaze`) or as a Wine path
(`'Z:\home\you\.cache\vrchat-dfr\gaze'`). Both processes must see the same
file. The bridge preserves its inode across restarts; do not
remove or truncate it while a reader is running.

## Settings

Every row except the first two and `DXVK_GAZE_FILE` can also be set in the
config file, under the name without `DXVK_GAZE_` in lower case (`full_area`,
`flip_y`, ...), and changed while the game runs.

| Variable | Purpose |
|---|---|
| `DXVK_GAZE_VRS=1` | Master switch, read once at start-up. Without it no gaze code runs |
| `DXVK_GAZE_CONFIG` | Config file to watch (Linux or Wine path). Also enables the status file |
| `enabled` (config file only) | `0` renders at full rate until set back to `1` |
| `DXVK_GAZE_HOLD_MS` | Keep the last gaze this long on tracking loss (default 500) |
| `DXVK_GAZE_FALLBACK` | After the hold: `off` = full rate (default), `center` = foveate around the eye centre |
| `DXVK_GAZE_FMT=97` | Restrict to the RGBA16F scene pass |
| `DXVK_GAZE_FLIP_Y=1` | Flip scene-pass Y |
| `DXVK_GAZE_FULL_AREA` | Percent of the eye image that renders at full rate |
| `DXVK_GAZE_MID_AREA` | Percent rendered at full rate or at `MID`; beyond it uses `COARSE` |
| `DXVK_GAZE_MID` | Rate of the ring between `FULL_AREA` and `MID_AREA`: `1x1`, `2x1`, `1x2` or `2x2` (default). Never coarser than `COARSE` |
| `DXVK_GAZE_R1` / `R2` | Inner / outer radius of the sharp region |
| `DXVK_GAZE_COARSE` | Outer shading rate: `auto` (coarsest the GPU supports), `2x2`, `4x4`, ... or a raw rate code. Clamped to what the GPU supports |
| `DXVK_GAZE_DEBUG=1` | Pass/gaze diagnostics |
| `DXVK_GAZE_DOT=1` | Draw dots at the gaze position used by the displayed VRS image, including upload latency (SBS only) |
| `DXVK_GAZE_SWAP_EYES=1` | Swap per-eye gaze data |
| `DXVK_GAZE_GAIN_Y` | Scale vertical gaze offset around center |
| `DXVK_GAZE_FLIPX_L/R`, `FLIPY_L/R` | Force per-eye X/Y flip |
| `DXVK_GAZE_FAKE=x/y/circle/fixed/grid` | Synthetic gaze modes |
| `DXVK_GAZE_SIZE=WxH`, `SAMPLES` | Force size / sample count |
| `DXVK_GAZE_FILE` | Override the gaze file path (Linux or Wine path), read once at start-up |

For a debug run with `PROTON_LOG=1`:

    grep -a "passes in last" -A8 ~/steam-438100.log | tail -24

### Choosing the sharp area

`DXVK_GAZE_FULL_AREA` and `DXVK_GAZE_MID_AREA` are percentages of one eye's
image. Keep `MID_AREA` above `FULL_AREA`. `100` means the whole eye. The circle's area also counts any part that hangs outside the image, so above
~78% the full-resolution part inside the image is smaller than the percentage
(the corners stay coarse). `100` means the whole eye.

`DXVK_GAZE_R1` / `R2` still work (radius in units of the shorter eye
dimension) and are used only when the area variables are not set.

## Build

DXVK is the `dxvk` submodule, pinned at an upstream commit, plus the patch
series in `patches/dxvk`. The build applies the series with `git am -3` in its
own clone and does not change the submodule.

The container needs only podman. It mounts the repository read-only apart from
`dist/`, and it does not touch the host's Proton, Wine prefix or VR runtime.
Each command runs in a new container that is deleted afterwards.

```bash
bash scripts/dev-container.sh all                   # build + every test; results land in dist/
bash scripts/dev-container.sh build --proton NAME   # DXVK for the commit that Proton build ships
bash scripts/dev-container.sh build --ref v3.1.1    # DXVK for any upstream commit, tag or branch
bash scripts/dev-container.sh e2e --bench           # time per frame with VRS off and on
bash scripts/dev-container.sh rm                    # delete the images and the work volume
```

The end-to-end test and the benchmark need a Vulkan driver with
`VK_KHR_fragment_shading_rate`, which Mesa's software driver lacks. The
script passes the GPU render node into the container for them, and they use
their own Wine prefix.

The same scripts run on the host:

```bash
bash scripts/setup-dev.sh           # checks the tools, fetches the submodule, builds bridge and probe
bash scripts/build-dxvk.sh          # dist/dxvk/{d3d11,dxgi}.dll
bash scripts/build-openxr-bridge.sh # dist/gaze/{openxr-gaze-bridge,dfrctl}
bash scripts/test-gaze-bridge.sh    # projection, IPC, settings, map worker, simulated OpenXR, dfrctl, installer
bash scripts/test-dxvk-e2e.sh       # the built DLLs under Wine on a real GPU, with validation layers
```

`DXVK_WORK_DIR`, `DXVK_OUTPUT_DIR` and `DXVK_BUILD_JOBS` override the DXVK
build clone, output path and parallel job count (default 4). `CXX` and
`GAZE_OUTPUT_DIR` override the bridge compiler and output directory.

To change the DXVK code:

```bash
bash scripts/dxvk-patches.sh apply    # dxvk/ on branch dfr: pinned commit + patches
# edit and commit in dxvk/
bash scripts/dxvk-patches.sh export   # rewrite patches/dxvk from those commits
bash scripts/dxvk-patches.sh check master   # do the patches still apply to upstream?
```

A DLL's version string names its base commit and this repository's revision,
for example `v3.1.1-174-gf8637768-dfr.90f053c`, or
`v3.1.1-174-gf8637768-GE-Proton11-12-dfr.90f053c` for a build with GE-Proton's
patches. DXVK prints it at the start of its log.

For extension enumeration without opening a session, use
`./build/openxr-gaze-probe`. Add `--seconds 15` to that probe to inspect raw
tracking state. For the new publisher, `./dist/gaze/openxr-gaze-bridge
--seconds 15 --verbose` exercises gaze-to-UV conversion and shared-memory output.
Both timed commands return 1 if no valid sample was observed.

See [architecture](docs/architecture.md) for the protocol and failure behavior,
and [the investigation](docs/eye-tracking-investigation.md) for the alternative
OpenVR / existing-session route and its unresolved integration questions.

## Architecture

    Eye tracking
          |
          v
    Unmodified OpenXR runtime
          |
          v
    openxr-gaze-bridge (Linux headless process)
          |
          v
    /dev/shm/vrchat_dfr_gaze (versioned shared memory)
          |
          v
    DXVK (via Wine path)
          |
          v
    VK_KHR_fragment_shading_rate
          |
          v
     VRChat scene pass

## Notes

- `fmt=97` and `FLIP_Y=1` are the values that work for VRChat; other
  applications need their own (`dfrctl set debug 1` lists the passes in the
  DXVK log).
- A sample systemd user unit for the bridge is in
  [`contrib/openxr-gaze-bridge.service`](contrib/openxr-gaze-bridge.service).
- The `dxvk` submodule pins the DXVK commit the patches are written against,
  `0cfe0898`.

## Demo with overexadurated values and gaze dot enabled
[Google drive link](https://drive.google.com/file/d/1OabrqSbzjEp96AFs6StbJrUAcHWSyMiQ/view?usp=sharing)
