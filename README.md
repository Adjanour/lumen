# imgv

A minimal single-window image viewer for Omarchy/Hyprland, written in Zig + SDL2.

## Why this exists

Omarchy's default viewer is `imv`. When your file manager (Nautilus) or
`xdg-open` invokes it per-file, or when double-clicking hands it one path
at a time, you end up with a new `imv` window per image instead of one
window you can page through. `imgv` takes every path on argv and keeps
them in a single window/process — no matter how many files you pass, you
get one window with left/right navigation.

## Dependencies (Arch/Omarchy)

```
sudo pacman -S zig sdl2
```

(`zig` in Arch's `extra` repo is 0.16.0 — the code here targets that
version's API, which changed significantly from older Zig releases
around argv handling: `main` now takes a `std.process.Init` parameter
instead of calling `std.process.argsAlloc`.)

## Build & run

```
zig build
./zig-out/bin/imgv ~/Pictures/*.jpg
```

Or via the build system:

```
zig build run -- ~/Pictures/*.jpg
```

## Keybindings

| Key                  | Action        |
|----------------------|---------------|
| Right / d / Space    | Next image    |
| Left / a             | Previous image|
| Escape / q           | Quit          |

Window is resizable; the image is scaled to fit while preserving aspect
ratio.

## Making it your default / fixing the "one window per image" problem

To have it open multiple selected files in Nautilus as one window, create
`~/.local/share/applications/imgv.desktop`:

```ini
[Desktop Entry]
Name=imgv
Exec=/path/to/imgv %F
Type=Application
MimeType=image/png;image/jpeg;image/bmp;image/gif;
Terminal=false
```

`%F` is the key part — it tells the file manager to pass *all* selected
files to a single invocation instead of launching one process per file.
Then set it as the default handler:

```
xdg-mime default imgv.desktop image/png image/jpeg
```

## Known limitation

Image decoding uses `stb_image`, which does **not** support WebP (this is
actually the same complaint that's been raised about `imv` — see
Omarchy issue #1442). JPEG, PNG, BMP, GIF, TGA, PSD, HDR are all fine.
Adding WebP support would mean linking `libwebp` and branching on file
extension/magic bytes in `loadImage`.

## Where to go next

- Thumbnail strip / grid view
- EXIF orientation handling (currently images aren't auto-rotated)
- WebP via libwebp
- Slideshow mode
- Delete/rename keybindings for quick culling
