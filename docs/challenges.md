# Challenge resolutions (issues #1–#8)

What changed for each open issue, and the tradeoff picked where the
issue asked for a decision.

## #1 — Prove the loop (edge cases)

Startup used `try loadImage(first)` — one bad first file killed the
program. It now tries each tab in order; first success wins, otherwise
the tabs stay open on a "Could not load" state naming the failed file.
Navigation failures already kept the old image (`else |_| {}`).

Behavior per case:

| Input | Result |
|---|---|
| Missing file | Stays on current image; startup skips to first decodable tab |
| Non-image / zero-byte | Same as missing (decode error path) |
| Duplicate argv (`a.png a.png`) | Two tabs, both valid; selecting either works |
| Larger than monitor | Fit math clamps to window; no overflow |
| 1x1 | Renders as one centered pixel block with border |
| Zero args | Empty state; process becomes the handoff server |

## #2 — Scaling

Float casts were already correct. Added the two missing guards:

- `SDL_WINDOW_ALLOW_HIGHDPI` on window creation.
- Zero/negative guard: `win_w <= 0` or `avail_h <= 0` (minimized or
  sliver window under tiling) skips the blit instead of dividing by
  zero. Rounding overshoot is clamped before centering.

Display is nicer beyond the issue: `SDL_HINT_RENDER_SCALE_QUALITY=2`
(linear filtering), checkerboard behind transparent pixels clipped to
the image rect, 1px frame.

## #3 — Texture lifecycle

State machine, for the record:

```
NONE ── load ok ──► LOADED(current)
LOADED ── nav ok ──► LOADED(new; old destroyed first)
LOADED ── nav fails ──► LOADED(old kept; error to stderr)
LOADED ── close ──► LOADED(neighbor) | NONE (last tab)
ANY ── quit ──► NONE (final destroy + preload cleanup)
```

No path holds two current textures; no error path leaks the old one.
SDL_Textures are invisible to DebugAllocator, so `image.texture_live`
counts Image textures: +1 per `loadImage` success (either path), -1
per `image.destroy`. Shutdown prints the count; expect 0. Per-frame
tab-label textures are excluded by design (born and freed in one
frame). Valgrind run is still worthwhile before release.

## #4 — The stall (preload vs. indicator)

Kept Option B (preload), extended to both neighbors: N+1 in the
forward slot, N-1 in a separate backward slot, so the two directions
never evict each other. Workers decode to pixel buffers only; texture
creation stays on the renderer thread (SDL renderers are not
thread-safe). Tradeoff as the issue frames it: preload pays memory
(two full-res buffers) and background CPU for instant navigation, while
an indicator would pay nothing but leave the stall visible. For a
viewer where next/prev is the hot path, preload is the right side.

## #5 — Format dispatch + WebP

`detectFormat` sniffs 16 header bytes (PNG signature, JPEG `FF D8`,
`RIFF....WEBP`); `decodePixels` dispatches on that, not the extension.
WebP decodes via libwebp (`WebPDecodeRGBA`), JPEGs prefer
libjpeg-turbo with stb fallback, everything else goes to stb_image —
which is now compiled with its full format set (the old
`-DSTBI_ONLY_JPEG -DSTBI_ONLY_PNG` flags are gone, so GIF/BMP/TGA work
too). `build.zig` links `webp`; README lists `libwebp` in deps.

## #6 — EXIF orientation

`readExifOrientation` walks JPEG segments to APP1, checks `Exif\0\0`,
reads byte order (`II`/`MM`), walks IFD0 for tag `0x0112`, returns
1–8 (anything else: 1, display as-is; never fails the load). Rendered
via `SDL_RenderCopyEx` angle/flip; values 5–8 pre-swap the fit math.
Viewer-side rotation only — pixels are never rewritten.

## #7 — Grid view

`g` toggles a thumbnail grid. Thumbnails decode full-res then
CPU-downscale to 160px (stb exposes no reduced-scale decode — that is
the documented cost; turbojpeg DCT downscale is the future
optimization if folders get huge). Budget: 64 thumbnails (~6.4MB),
farthest-from-selection eviction, cache cleared on tab add/remove so
indices never go stale. Arrows move the live selection (up/down by
row), click or Enter opens, Esc exits.

## #8 — Remove SDL (stretch)

Not attempted. Native Wayland/EGL is a rewrite of the render and input
stacks, not an improvement to this one. Everything above keeps the
SDL2 backend.
