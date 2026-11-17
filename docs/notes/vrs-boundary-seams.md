# Seams and shimmer at the foveation boundary

Investigated 2026-11-12. Status: accepted as a VRS trade-off, not fixed.

## What is seen

With DFR on, the area outside `full_area` can look slightly different in
colour from the full-rate area, and the border between them can show as a
stepped edge (8x8-tile staircase), for example across fog over a distant
mountain, or around lit building windows. Fine detail shimmers inside the
2x2 area while the head moves.

## What it is

It comes from 2x2 coarse shading itself, not from a bug:

- At 2x2 one pixel-shader invocation colours four pixels, and texture
  derivatives span two pixels, so sampling uses a mip level one higher.
  Fine detail (rain streaks, fog noise, window lights) averages out, which
  shifts colour and contrast. Next to full-rate pixels this reads as a seam
  that follows the rate map's 8x8 tiles.
- The 2x2 blocks are fixed to the screen. Detail smaller than a block jumps
  between blocks every frame as the head moves, which shows as shimmer.
  Engines that ship VRS usually hide this with TAA; VRChat has none, and
  DXVK cannot add one without rewriting game shaders.

Checked on RX 9070 XT / RADV (Mesa 26.2.6) with offscreen probes in the
dev container: depth written and read under VRS is bit-identical to full
rate, and derivatives / mip selection at 2x2 are exactly as specified
(ddx = 2, one mip higher). The driver and the patch behave correctly.

## What was tried (branch `dfr-vrs-seam-experiments`)

- `need_depth`: foveate only passes that have a depth buffer, so
  post-processing passes stay at full rate.
- `full_rate_discard` / `full_rate_blend`: keep draws that can discard,
  or blended draws, at full rate inside a foveated pass.

Neither removed the seam in the headset. Of these, `need_depth` is the only
one worth keeping on its merits (2x2 in post-processing never helps).

## Ways to reduce it

- Push the boundary out, e.g. `dfrctl set full_area 60 mid_area 80`, so
  less of the image runs at 2x2 and the seam sits where you rarely look.
- Use an intermediate rate for the `mid_area` ring, `dfrctl set mid 2x1` or
  `mid 1x2`. By default the map goes from 1x1 straight to 2x2 on this GPU.
  The half step makes the ring one step coarser than the centre instead of
  two. In the benchmark (`dev-container.sh e2e --bench`, 4128x2208,
  `full_area 45 mid_area 65`) a frame took 57% of the full-rate time with
  `mid 2x2` and 60% with `mid 2x1`. Nobody has judged it in the headset yet.
- Judge in the headset rather than the desktop mirror: in the mirror you
  look straight at the periphery, which exaggerates the seam.
