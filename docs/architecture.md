# OpenXR gaze bridge architecture

## Data path

`openxr-gaze-bridge` is a native Linux process with its own OpenXR instance and
headless session. It enables `XR_MND_headless`, `XR_EXT_eye_gaze_interaction`
and `XR_KHR_convert_timespec_time`, binds
`/user/eyes_ext/input/gaze_ext/pose`, polls session events and synchronizes its
own action set. It never creates a swapchain or calls frame submission APIs.

At each tick (default 250 Hz), it converts `CLOCK_MONOTONIC` to `XrTime`, locates
gaze relative to VIEW, and obtains stereo view poses/FOVs with `xrLocateViews`
at the same time. This is current host time, not VRChat's predicted display
time. Unknown sample timestamps are allowed; known samples older than 100 ms
are rejected by default (`--max-age-ms` changes this limit).

The combined ray is transformed into each eye's coordinates, including eye
rotation. By default it is projected at infinity. With `--distance N`, a point
N metres along the ray is assumed and eye translation is included. Neither
option supplies measured binocular convergence. Projection uses tangents of
each eye's asymmetric FOV and produces UVs with top=0. Finite UVs are clamped
to image bounds. Invalid poses, FOVs and rays behind an eye invalidate gaze.

The default output is `/dev/shm/vrchat_dfr_gaze`. DXVK maps it through Wine as
`Z:\dev\shm\vrchat_dfr_gaze`; `--file` and `DXVK_GAZE_FILE` override the host
and Wine paths. Containers must expose the same file to both processes.
The reader does not load OpenVR/OpenXR or depend on xrizer changes. The
runtime's standard OpenXR interface supplies the data without a runtime patch.

## Shared memory protocol

The canonical ABI is [shared/gaze_shm.h](../shared/gaze_shm.h), embedded unchanged
as `src/dxvk/dxvk_gaze_shm.h` in the DXVK patches. It is 64 bytes, little endian,
with 16 aligned 32-bit words. Linux GCC/Clang and MinGW use lock-free 32-bit
atomic operations for every word, including payload. There is no interprocess
C++ mutex or non-atomic concurrent payload access.

| Word | Contents |
| --- | --- |
| 0 | Magic `0x325a4147` (`GAZ2`) |
| 1 | ABI version 1 |
| 2 | Size 64 |
| 3 | Sequence, odd during write, even when stable |
| 4 | Valid, exactly 1 for valid gaze |
| 5–6 | Left and right U, IEEE 754 float bits |
| 7–8 | Left and right V, IEEE 754 float bits |
| 9–15 | Reserved, zero |

A single writer holds an exclusive `flock` for the mapping's lifetime. It
publishes odd sequence, header/payload, then even sequence, using sequentially
consistent atomic operations. The reader accepts a packet only if the sequence
is even and unchanged across atomic payload loads. It validates magic, version,
size, finite coordinates and range. Readers retry interrupted snapshots on the
next worker tick; they never block waiting for a writer.

The output is a regular file owned by the current user, mode 0600. Existing
files must have size zero or exactly 64. The writer keeps the inode and
sequence across restarts, rather than unlinking/replacing it. It repairs an odd
sequence left by a killed writer. Symlinks and simultaneous writers are
rejected. The `GAZE` format of the earlier WiVRn export patch is not accepted.

## Failure and restart behavior

The bridge publishes invalid packets while waiting for READY, while actions are
inactive/not focused, when tracking is invalid/untracked, or when projection is
invalid. OpenXR failures invalidate output before destroying the session,
then retry initialization after 2 seconds. SIGINT/SIGTERM invalidate output
before closing the connection. No valid center is held across tracking loss.

DXVK's `Freshness` requires a sequence change after opening a mapping, so an
abandoned file is not accepted at reader startup. An unchanged sequence expires
after 100 ms measured with the reader's steady clock. This handles SIGKILL, a
stalled API call and a crash during an odd sequence without comparing Wine and
Linux clocks. A stale mapping is closed; opening is throttled to once every
2 seconds, so replaced files can eventually be discovered as well.

Whenever no live sample is available (invalid packet, stopped heartbeat, no
file) the reader applies the tracking-loss policy: the last live gaze is reused
for `hold_ms` (default 500, long enough for a blink), then `fallback` decides
between publishing an invalid map, which makes the render thread drop the
attachment and shade at full rate (`off`, default), and foveating around the
centre of each eye (`center`). A held or fallback gaze is never mistaken for a
live one: the status file reports `gaze=live|held|fallback|none`.

The sample-age limit and heartbeat timeout are independent. If the runtime
supplies no sample timestamp, sensor sample age cannot be checked, but tracking
flags and heartbeat still apply. `--verbose` reports unknown timestamps and
the reason a packet is invalid.

## Settings and live reconfiguration

`dxvk_gaze_config.h` (canonical copy: [shared/gaze_config.h](../shared/gaze_config.h),
also used by `dfrctl`) holds every tunable in one `GazeConfig`. At start-up it
is filled from the `DXVK_GAZE_*` environment variables. If `DXVK_GAZE_CONFIG`
names a file, `dxvk-gaze-map` re-reads it every 250 ms and compares the
content; values in the file override the environment key by key, and removing
the file returns to the environment values.

Values are validated when parsed (ranges, known rate codes, finite numbers).
A file containing any unusable line is rejected as a whole and the previous
configuration stays in effect, so a typo or a half-written file cannot apply
partially. `dfrctl` validates with the same code before writing and replaces
the file with a rename.

A new configuration is published to the render thread through a generation
counter and a mutex the render thread only try-locks; like map exchange, a
contended lock just defers the change to a later pass. Pass selection (`fmt`,
`samples`, `minsize`, `size`), `enabled`, radii and `coarse` therefore change
without a restart. Radii and rate are part of each map request, so a change
regenerates and re-uploads the attachment through the normal double-buffered
path. `enabled = 0` stops attaching the image; pipelines keep their dynamic
shading-rate state (set to 1x1 for every pass), so nothing is recompiled.

Only two things are fixed at start-up: `DXVK_GAZE_VRS=1` itself, because it
decides whether pipelines are created with dynamic shading-rate state and the
shading-rate-attachment flag, and the gaze and config file paths.

With a config file, the worker also writes `<config>.status` once a second:
gaze state, whether the source is mapped, candidate/foveated passes and map
uploads per second, the last foveated pass and the resolved coarse rate.

## Device limits

The integration only hands the driver what it advertised:

- The coarse rate is resolved per sample count against
  `vkGetPhysicalDeviceFragmentShadingRatesKHR`: `auto` takes the coarsest
  rate, an explicit rate is replaced by the coarsest supported rate that is no
  coarser in either direction.
- Without `layeredShadingRateAttachments` (RADV, for example) the attachment is
  a single layer and only side-by-side eye passes are foveated; two-layer
  array passes are left at full rate.
- `R8_UINT` must support use as a shading-rate attachment, otherwise gaze VRS
  stays off.
- Graphics pipelines and their libraries are created with
  `VK_PIPELINE_CREATE_RENDERING_FRAGMENT_SHADING_RATE_ATTACHMENT_BIT_KHR`.
- Tiling GPUs, where DXVK renders through secondary command buffers, are not
  supported; `DXVK_GAZE_VRS=1` is ignored there with a warning.

## VRS and render coordinates

The existing shading-rate attachment generation and pass selection remain in
DXVK. Depth-only passes are rejected; format and sample-count filters can
restrict scene passes. The original VRChat settings use format 97 (RGBA16F)
and `DXVK_GAZE_FLIP_Y=1`. Global/per-eye flips and eye swapping remain available.
This transport sets source flip flags to zero.

Runtime FOVs can differ from an application's custom projection or submitted
texture bounds. Gaze-dot alignment in VRChat must be checked on hardware;
automated tests establish coordinate math and protocol behavior, not VRChat's
projection conventions or end-to-end latency.

## DXVK worker and GPU buffers

`dxvk-cs` selects eligible render passes and sends their dimensions, layer
count, format, sample count, VRS texel size and rate/radius settings to
`dxvk-gaze-map`. The worker polls the shared gaze source every 4 ms after its
first request. File opening/mapping, heartbeat checks, coordinate transforms,
fake gaze, map allocation and full tile traversal run on this worker.

The mailbox holds one queued request and one completed result. New requests
replace queued work; an in-progress map finishes before the next request is
handled. A try-lock lets the render thread skip the exchange under contention.
CPU map ownership is swapped and storage is recycled by the worker. A stationary
or tile-quantized unchanged gaze does not cause repeated map generation.

The render thread records uploads only for completed maps compatible with the
current pass. Two GPU image/upload-buffer slots retain the previous completed
attachment while an upload is pending. A slot is overwritten only after all
its recorded GPU uses finish; completion is polled without waiting. The upload
and its command recording remain on the graphics path. Startup and target
changes use full-rate rendering until a compatible map is ready. Invalid gaze
or worker failure disables VRS. Debug DOT uses the gaze saved with the displayed
GPU attachment, including worker and upload latency.

`dxvk_gaze_source.*` owns the CPU gaze adapter, `dxvk_gaze_map.h` contains the
map algorithm and mailbox/worker, and `dxvk_gaze_vrs.*` handles Vulkan integration.
The worker implementation is private to the Vulkan integration source file so
CPU changes do not require exposing worker details in the rendering header.

## Validation

`bash scripts/test-gaze-bridge.sh` checks symmetric/asymmetric FOVs, canted eyes,
upward gaze, finite fixation distance, malformed inputs, ABI validation,
sequence wrap, stale-file rejection and process-shared packet consistency.
The real publisher is also linked against a simulated OpenXR implementation to
test sampling, invalid tracking/views, inactive/unfocused actions, sample age,
missing extensions, runtime restart, session loss, output locking, inode
preservation, SIGTERM invalidation and SIGKILL sequence freeze.

The same script also checks two-slot GPU ownership policy and the CPU map
worker: map contents, alignment padding, latest-request replacement, mailbox
contention, independent polling, invalidation/recovery and failure handling.
Canonical DXVK additionally has a native source-adapter test for fake gaze,
coordinate transforms and fixed-gaze caching.

`bash scripts/test-dxvk-e2e.sh` tests the built DLLs themselves. A D3D11 probe
(`tests/e2e/d3d11_vrs_probe.cpp`) runs under Wine on a real Vulkan driver,
draws a per-pixel hash into a side-by-side RGBA16F target without a window, and
reads the image back to classify every 8x8 tile as shaded per pixel, 2x2 or
coarser. A stand-in bridge publishes a fixed gaze. The test then asserts, for
1 and 4 samples: the full-rate disc is centred on the published gaze of each
eye and has the configured area; `full_area`, `flip_y`, `swap_eyes`,
`enabled` and `coarse` take effect while running; an invalid config file is
rejected; a SIGKILLed bridge is held for `hold_ms`, then drops to full rate or
to the centre fallback; a restarted bridge is picked up; removing the config
file restores the environment values; the status file reports live foveation;
without `DXVK_GAZE_VRS` nothing is foveated and no gaze code runs. All of it
runs under the Khronos validation layer and fails on any validation error that
the same probe does not produce without gaze VRS.

Not covered by automation: sampling from a real HMD, gaze-dot alignment with
VRChat's projection, and end-to-end latency.
