# Upstream provenance

The gaze source is a standalone OpenXR headless bridge. DXVK is the only
upstream this project patches.

## DXVK

Repository: https://github.com/doitsujin/dxvk

The patch series in `patches/dxvk` is written against
`0cfe0898289fb11e3d8d0e1c62cd344b825b7d57`, the commit the `dxvk` submodule
pins. It is the upstream base of the canonical `dfr` branch
(ReinaS-64892/dxvk). The series has two patches: the new gaze source files,
then the hooks in existing DXVK files. `git am -3` also applies it to the DXVK
commits of GE-Proton11-12 (`f8637768`), proton-cachyos 20261015 (`a78a467c`)
and upstream master as of 2026-11-17, and those builds compile.

The patch also includes the VRS tile-capacity fix from local DXVK commit
`1e25cb242d23be9f5455dca11d8a0761d1c6daab`. Attachment capacity scales with
the GPU's texel size to cover at least 8192 pixels per axis, subject to the
device's image-size limit. Image allocation, aligned upload-buffer allocation
and pass bounds checks use the same capacity, which is logged at startup.

The patch also ports double-buffered uploads and matching DOT latency from
canonical DXVK commit `985e429f25ca8c4ac70927f119df66f90e567178`.
The pinned commit is the matching upstream base.

The VRS attachment and upload buffer now use two slots. Rendering keeps the
completed front image while an upload is pending in the back slot. GPU command
list completion is polled without waiting; a retired front slot is reused only
after all its recorded reads finish. The upload-to-attachment barrier is emitted
when publishing a completed image, before recording the next upload. Startup or
an incompatible render-target change uses full-rate rendering until a matching
image is ready. Updates may therefore lag by multiple frames when the GPU queue
is backed up; this is not a fixed one-frame delay. CPU tile generation and GPU
transfer work still occur, so live VRChat FPS improvement remains unmeasured.

`DXVK_GAZE_DOT=1` uses the gaze coordinates saved with the displayed attachment,
including upload latency and tile-granularity caching. The existing SBS-only DOT
and `DXVK_GAZE_FAKE=grid` overlay behavior is retained. Slot lifetime is tracked
by command lists, including teardown and partially failed resource allocation.

Canonical DXVK commit `54010d54d3a41e0b23bdf08ba6e6dfd7a3683844`
moves gaze file mapping, freshness checks, transforms,
fake gaze and tile-map generation onto `dxvk-gaze-map`. The worker polls every
4 ms after receiving a candidate render-target description, computes outside
the mailbox lock, and retains only the latest queued request and completed
result. The render thread uses a try-lock and swaps CPU map ownership without
allocating or freeing tile arrays. It never waits for map generation. Fixed
or tile-quantized unchanged gaze skips regeneration. Invalid gaze is published
to the render thread to disable VRS, including after a bridge heartbeat stalls.

CPU logic lives in `dxvk_gaze_source.*` and `dxvk_gaze_map.h`. The worker is
hidden behind a private implementation in `dxvk_gaze_vrs.cpp`; its header has
no source or map-worker dependency. Vulkan allocation, pass compatibility,
upload command recording and double-buffer publication remain on `dxvk-cs`.
DOT coordinates travel with each generated map and GPU slot. The worker joins
before its source mapping is closed during destruction. Unit tests cover map
contents, source transforms, request replacement, try-lock contention,
independent polling, invalidation/recovery, failure and worker shutdown.

### Changes on top of the canonical gaze revision

The series no longer equals the canonical gaze commit `54010d54`; it adds:

- `dxvk_gaze_config.h`: validated settings, read from the environment and from
  an optional config file (`DXVK_GAZE_CONFIG`) that is re-read while running,
  plus a once-a-second status file. All former `getenv` parsing in
  `dxvk_gaze_vrs.cpp` and `dxvk_gaze_source.cpp` goes through it.
- Tracking-loss policy in `dxvk_gaze_source.cpp` (`hold_ms`, `fallback`).
- Coarse-rate resolution against the device's supported rates per sample count
  (previously a raw code was written to the attachment unchecked).
- A single-layer attachment when `layeredShadingRateAttachments` is false
  (previously a two-layer view was always created, which that limit forbids),
  and a format-feature check for `R8_UINT`.
- `VK_PIPELINE_CREATE_2_RENDERING_FRAGMENT_SHADING_RATE_ATTACHMENT_BIT_KHR` on
  graphics pipelines and libraries in `dxvk_graphics.cpp` / `dxvk_shader.cpp`
  (VUID-vkCmdDraw-imageView-06183, found by the validation layer).
- Gaze VRS refuses to enable on tiling GPUs, where the dynamic shading rate
  was never set for the secondary command buffers.
- Each uploaded slot remembers the full map request, so a radius or rate change
  re-uploads; "gaze source opened" is logged once instead of every 2 seconds.
- `DXVK_GAZE_FILE` / `DXVK_GAZE_CONFIG` accept Linux paths.
- `mid`: the rate of the ring between `full_area` and `mid_area`, resolved
  against the device like `coarse`.

`scripts/build-dxvk.sh` holds the DXVK build configuration.
