# Shimmering on foliage and bright edges under 4x MSAA

Investigated 2026-11-24. Status: kept on branch `dfr-msaa-shimmer-experiments`, not merged into `main`.

## What is seen

In VRChat with 4x MSAA at `5040x2772` side by side, grass, tree leaves and bright edges shimmer even when looked at directly and before DFR is enabled. Setting `d3d11.forceSampleRateShading=True` in stock DXVK cuts both forms of shimmering sharply. It also halves frame rate, because Vulkan forces a `1x1` shading rate whenever sample shading is active and runs four fragment shader invocations per pixel across the whole `5040x2772` target, roughly 56 million samples per frame.

## What was tried

Branch `dfr-msaa-shimmer-experiments` adds two targeted DXVK options that keep gaze VRS active on opaque geometry.

- `cutout_ssaa`, read once at start-up, scans fragment shader IR in `dxvk_shader_ir.cpp` for `OpCode::eDemote` and enables `HasSampleRateShading` and `ioPass.enableSampleInterpolation()` only for shaders that discard. Opaque draws stay at 1x shading with VRS enabled.
- `hdr_resolve`, toggled live through `dfr.conf`, routes float MSAA color resolves for `R16G16B16A16_SFLOAT`, `B10G11R11_UFLOAT_PACK32` and `R32G32B32A32_SFLOAT` through `DxvkMetaResolve` using Karis weights `1 / (1 + max(r, g, b))`. Uniform HDR pixels keep their exact linear value, while a single bright edge sample carries less weight. The status file reports `hdr_resolves_per_s`.

Both paths passed the Wine and Vulkan validation end-to-end probe on a real GPU with zero added validation errors. In the probe, `cutout_ssaa=1` resolved a half-pixel discard shader to `0.500` on 4x MSAA while an opaque pass in the same frame still foveated. Toggling `hdr_resolve` live changed a 1-of-4 `10.0` sample edge over `0.1` from `2.574` to `0.419` while keeping a uniform `10.0` interior at `10.000`.

## Live result in VRChat

Both paths ran in VRChat at `5040x2772`, `fmt=97`, `samples=4` with `cutout_ssaa=1`, `hdr_resolve=1` and `hdr_resolves_per_s=378`. Neither produced a clear visual improvement compared with global `d3d11.forceSampleRateShading=True`.

This indicates that the shimmering removed by global sample shading came mainly from non-discard shaders.

- Many foliage shaders use alpha-to-coverage, alpha blending or 3D leaf geometry without `discard`, so `cutout_ssaa` leaves them at 1x shading.
- Intra-triangle specular highlights, Fresnel rims and normal-map edges compute one value per pixel under 1x shading. All four MSAA samples store that same bright value, so Karis resolve cannot reweight them.
- Outside `full_area=20`, non-discard draws remain at `2x2` VRS, whereas `d3d11.forceSampleRateShading=True` forces `1x1` across the entire eye.

## Alternatives

- Run VRChat at 2x MSAA with `d3d11.forceSampleRateShading=True`. That applies 2x rotated-grid sample shading to every shader at half the fragment shader cost of 4x, without VRS.
- Turn MSAA off with `samples=1`, raise the render resolution and keep DFR active. That acts as foveated SSAA, concentrating pixel density inside `full_area`. From `5040x2772`, 2x total pixels is `7128x3920`, which fits under the current `8192 px` VRS attachment limit; 4x total pixels is `10080x5544` and exceeds it.
- Adding TAA in DXVK or with optical flow is not practical here. DXVK lacks object identities and previous-frame skinning matrices for moving avatars, external sub-pixel projection jitter shifts UI and mirrors, and coarse optical flow blocks ghost on thin edges.
