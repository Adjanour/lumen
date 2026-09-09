/// Shared C import — one @cImport call so every module gets the same type.
/// Usage: `const c = @import("c.zig").c;`
pub const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
    @cInclude("stb_image.h");
    @cInclude("turbojpeg.h");
});
