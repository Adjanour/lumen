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
sudo pacman -S zig sdl2 sdl2_ttf libjpeg-turbo libwebp
```

On current Arch with GCC 16, plain `zig build` hits the Zig 0.16
`.sframe` linker incompatibility — build through the workaround instead:

```
./build-gcc16.sh
./zig-out/bin/imgv ~/Pictures/*.jpg
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

| Key                  | Action                                  |
|----------------------|-----------------------------------------|
| Right / d / Space    | Next image                              |
| Left / a             | Previous image                          |
| g                    | Toggle thumbnail grid                   |
| Up / Down (in grid)  | Move selection by one row               |
| Enter / Space (grid) | Open selected, exit grid                |
| Esc (in grid)        | Exit grid                               |
| Escape / q           | Quit                                    |

Window is resizable; the image is scaled to fit while preserving aspect
ratio. Rendering uses linear filtering, a checkerboard behind transparent
pixels, and honors the EXIF orientation tag, so phone photos display the
way other viewers show them.

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
xdg-mime default imgv.desktop image/png image/jpeg image/webp
```

## Formats

Format dispatch is by magic bytes, not file extension: PNG (8-byte
signature), JPEG (`FF D8`), and WebP (`RIFF....WEBP`) are sniffed from
the file header, so a PNG renamed to `.jpg` still decodes. JPEGs prefer
libjpeg-turbo with an stb_image fallback; WebP decodes via libwebp;
everything else (PNG, GIF, BMP, TGA...) goes through stb_image.

System dependency for WebP:

```
sudo pacman -S --needed libwebp
```

## Where to go next

- Slideshow mode
- Delete/rename keybindings for quick culling
