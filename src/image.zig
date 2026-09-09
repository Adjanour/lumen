/// Image loading (via libjpeg-turbo and stb_image) and background preloading.
const std = @import("std");
const c = @import("c.zig").c;

//Global I/O handle
// Set once at startup by main before any image function is called.

pub var global_io: std.Io = undefined;

//Types
pub const Image = struct {
    texture: *c.SDL_Texture,
    w: i32,
    h: i32,
};

/// One-slot preload cache: a background thread decodes the next image while
/// the current one is displayed.  Access is guarded by mutex.
///
/// Data layout note — hot fields first so a cache-hit read touches fewer lines:
///   hot  — data, w, h   (read on every loadImage call that checks the cache)
///   cold — path, mutex, thread  (metadata and synchronisation)
const Preload = struct {
    data: ?[]u8 = null,
    w: i32 = 0,
    h: i32 = 0,
    path: ?[]const u8 = null,
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
};

var preload: Preload = .{};
var preload_inflight: bool = false;

//Format detection

pub fn isJpegExt(path: [:0]const u8) bool {
    const s = std.mem.sliceTo(path.ptr, 0);
    if (s.len >= 4 and std.ascii.eqlIgnoreCase(s[s.len - 4 ..], ".jpg")) return true;
    if (s.len >= 5 and std.ascii.eqlIgnoreCase(s[s.len - 5 ..], ".jpeg")) return true;
    return false;
}

//Pixel loading

/// Decode a JPEG using libjpeg-turbo (faster than stb_image for JPEGs).
/// Returns a heap-allocated RGBA buffer; caller frees with c_allocator.
fn loadPixelsTurbo(path: [:0]const u8, w: *c_int, h: *c_int) ?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(
        global_io,
        std.mem.sliceTo(path.ptr, 0),
        .{},
    ) catch return null;
    defer file.close(global_io);

    const stat = file.stat(global_io) catch return null;
    const sz = stat.size;
    if (sz == 0 or sz > 100 * 1024 * 1024) return null;

    const allocator = std.heap.c_allocator;
    const buf = allocator.alloc(u8, @intCast(sz)) catch return null;
    defer allocator.free(buf);
    const n = file.readPositionalAll(global_io, buf, 0) catch return null;
    if (n != sz) return null;

    const tjh = c.tjInitDecompress();
    if (tjh == null) return null;
    defer _ = c.tjDestroy(tjh);

    var jw: c_int = 0;
    var jh: c_int = 0;
    var subsamp: c_int = 0;
    var colorspace: c_int = 0;
    if (c.tjDecompressHeader3(
        tjh,
        buf.ptr,
        @intCast(buf.len),
        &jw,
        &jh,
        &subsamp,
        &colorspace,
    ) != 0) return null;

    w.* = jw;
    h.* = jh;
    const out = std.heap.c_allocator.alloc(u8, @as(usize, @intCast(jw * jh * 4))) catch return null;
    if (c.tjDecompress2(
        tjh,
        buf.ptr,
        @intCast(buf.len),
        out.ptr,
        jw,
        0,
        jh,
        c.TJPF_RGBA,
        c.TJFLAG_FASTDCT,
    ) != 0) {
        std.heap.c_allocator.free(out);
        return null;
    }
    return out;
}

/// Decode any supported format using stb_image.
/// Returns a heap-allocated RGBA buffer; caller frees with c_allocator.
fn loadPixelsStb(path: [:0]const u8, w: *c_int, h: *c_int) ?[]u8 {
    var ch: c_int = 0;
    const data = c.stbi_load(path.ptr, w, h, &ch, 4);
    if (data == null) return null;
    const len: usize = @as(usize, @intCast(w.* * h.* * 4));
    const out = std.heap.c_allocator.alloc(u8, len) catch {
        c.stbi_image_free(data);
        return null;
    };
    @memcpy(out, data[0..len]);
    c.stbi_image_free(data);
    return out;
}

//Public API

/// Load an image as an SDL texture. Checks the preload cache first.
pub fn loadImage(renderer: *c.SDL_Renderer, path: [:0]const u8) !Image {
    try preload.mutex.lock(global_io);
    if (preload.data) |d| {
        if (preload.path) |pp| {
            if (preload.w != 0 and std.mem.eql(u8, pp, std.mem.sliceTo(path.ptr, 0))) {
                const w = preload.w;
                const h = preload.h;
                const data = d;
                preload.data = null;
                preload.path = null;
                preload.thread = null;
                preload.mutex.unlock(global_io);

                const texture = c.SDL_CreateTexture(
                    renderer,
                    c.SDL_PIXELFORMAT_ABGR8888,
                    c.SDL_TEXTUREACCESS_STATIC,
                    w,
                    h,
                ) orelse {
                    std.heap.c_allocator.free(data);
                    return error.TextureCreateFailed;
                };
                if (c.SDL_UpdateTexture(texture, null, data.ptr, w * 4) != 0) {
                    c.SDL_DestroyTexture(texture);
                    std.heap.c_allocator.free(data);
                    return error.TextureUpdateFailed;
                }
                _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);
                std.heap.c_allocator.free(data);
                return .{ .texture = texture, .w = w, .h = h };
            }
        }
    }
    preload.mutex.unlock(global_io);

    var w: c_int = 0;
    var h: c_int = 0;
    var pixels: ?[]u8 = null;
    if (isJpegExt(path)) pixels = loadPixelsTurbo(path, &w, &h);
    if (pixels == null) pixels = loadPixelsStb(path, &w, &h);

    const data = pixels orelse {
        std.debug.print("failed to load {s}: {s}\n", .{ path, c.stbi_failure_reason() });
        return error.LoadFailed;
    };
    defer std.heap.c_allocator.free(data);

    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_ABGR8888,
        c.SDL_TEXTUREACCESS_STATIC,
        w,
        h,
    ) orelse return error.TextureCreateFailed;
    if (c.SDL_UpdateTexture(texture, null, data.ptr, w * 4) != 0) {
        c.SDL_DestroyTexture(texture);
        return error.TextureUpdateFailed;
    }
    _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);
    return .{ .texture = texture, .w = w, .h = h };
}

/// Kick off background decoding of path into the preload cache.
/// No-op if path is already cached or a decode is already in flight.
///
/// Lock protocol: the mutex is unlocked before Thread.spawn so the worker
/// thread can lock it when it finishes.  After spawn we relock to write
/// preload.thread safely.
pub fn preloadNext(path: [:0]const u8) void {
    preload.mutex.lock(global_io) catch return;
    if (preload_inflight) {
        preload.mutex.unlock(global_io);
        return;
    }
    if (preload.path) |pp| {
        if (std.mem.eql(u8, pp, std.mem.sliceTo(path.ptr, 0))) {
            preload.mutex.unlock(global_io);
            return;
        }
    }
    if (preload.data) |d| std.heap.c_allocator.free(d);
    preload.data = null;
    if (preload.path) |pp| std.heap.c_allocator.free(pp);
    preload.path = null;
    preload_inflight = true;

    const dup_path = std.heap.c_allocator.dupeZ(u8, std.mem.sliceTo(path.ptr, 0)) catch {
        preload_inflight = false;
        preload.mutex.unlock(global_io);
        return;
    };
    preload.mutex.unlock(global_io); // release before spawn; worker will relock

    const thread = std.Thread.spawn(.{}, struct {
        fn run(p: [:0]const u8) void {
            var w: c_int = 0;
            var h: c_int = 0;
            var pix: ?[]u8 = null;
            if (isJpegExt(p)) pix = loadPixelsTurbo(p, &w, &h);
            if (pix == null) pix = loadPixelsStb(p, &w, &h);

            preload.mutex.lock(global_io) catch {
                if (pix) |d| std.heap.c_allocator.free(d);
                std.heap.c_allocator.free(p);
                return;
            };
            defer preload.mutex.unlock(global_io);
            if (pix) |d| {
                if (preload.data) |old| std.heap.c_allocator.free(old);
                if (preload.path) |oldp| std.heap.c_allocator.free(oldp);
                preload.data = d;
                preload.w = w;
                preload.h = h;
                preload.path = std.heap.c_allocator.dupe(
                    u8,
                    std.mem.sliceTo(p.ptr, 0),
                ) catch null;
            }
            preload_inflight = false;
            std.heap.c_allocator.free(p);
        }
    }.run, .{dup_path}) catch {
        std.heap.c_allocator.free(dup_path);
        preload.mutex.lock(global_io) catch return;
        preload_inflight = false;
        preload.mutex.unlock(global_io);
        return;
    };

    preload.mutex.lock(global_io) catch return;
    if (preload.thread) |old| old.detach();
    preload.thread = thread;
    preload.mutex.unlock(global_io);
}

/// Free all preload state. Call at shutdown.
pub fn cleanup() void {
    if (preload.data) |d| std.heap.c_allocator.free(d);
    if (preload.path) |p| std.heap.c_allocator.free(p);
    if (preload.thread) |t| t.join();
}
