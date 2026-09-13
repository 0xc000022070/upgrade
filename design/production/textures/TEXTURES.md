# Dazzle production texture reference

These assets add surface variation. They never carry status, hierarchy, or interaction by themselves. Apply opacity at the layer level. Keep text and controls above the texture layer.

| Asset | Tile | Intended opacity | Use |
|---|---:|---:|---|
| `noise-fine.png` | 512×512 | 4%, allowed range 3–5% | Primary background, restrained branding fields, empty states |
| `grid-8.svg` | 8×8 | 2%, allowed range 1–3% | Static background fields and technical diagrams |
| `scanline-3.png` | 8×3 | 0.8%, allowed range 0.5–1% | Transitions and empty states only |

## Rules

- Composite over `#08090B` with normal blending.
- Do not texture text, icons, controls, progress bars, or state markers.
- Use one texture at a time in normal UI. Noise plus grid is reserved for a branding or empty-state field and must stay under 5% combined opacity.
- Do not scale `grid-8.svg` or `scanline-3.png` with filtering. Tile them at their native logical size.
- Tile `noise-fine.png` at 512 logical pixels. Its mirrored edges are seamless on both axes.
- All raster pixels have white RGB. Alpha carries the texture. No colored pixels are present.

## Provenance

The raw grain field came from the built-in image generation tool. ImageMagick removed its color and low-frequency clusters, added fine high-frequency variation, mirrored a 256×256 quadrant on both axes, copied luminance into alpha, and forced RGB to white. The grid and scanline tiles are deterministic geometry.

No signal-distortion strip is included. At this size it read as a generic glitch overlay and added no information.
