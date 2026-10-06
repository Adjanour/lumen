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
    /// EXIF orientation (1-8). 1 = normal. Rendered via SDL_RenderCopyEx.
    orientation: u8 = 1,
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
    orientation: u8 = 1,
    path: ?[]const u8 = null,
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
};

var preload_next: Preload = .{};
var preload_next_inflight: bool = false;
var preload_prev: Preload = .{};
var preload_prev_inflight: bool = false;

//Texture lifecycle accounting (#3)

// Every Image texture created in loadImage increments this; every one
// released through `destroy` decrements it. SDL_Textures live outside
// Zig's allocator so DebugAllocator cannot see them — this counter is
// the leak check. It must read zero after the final destroy at
// shutdown. (Per-frame tab-label textures are intentionally excluded:
// they are created and freed inside one frame by construction.)
var texture_live: usize = 0;

/// Release an Image texture and update the lifecycle counter.
pub fn destroy(tex: *c.SDL_Texture) void {
    c.SDL_DestroyTexture(tex);
    if (texture_live > 0) texture_live -= 1;
}

/// Live Image texture count. Expect 0 at clean shutdown.
pub fn textureCount() usize {
    return texture_live;
}

//Format detection

/// Byte-based format dispatch (#5). Extensions lie — browsers, file
/// managers, and lazy renames all produce `photo.jpg` files that are
/// actually PNGs. Sniff the magic numbers instead:
///
///   PNG  — 8-byte signature 89 50 4E 47 0D 0A 1A 0A
///   JPEG — starts with FF D8
///   WebP — RIFF container with "WEBP" at offset 8
///   GIF  — "GIF87a" / "GIF89a"
///   BMP  — "BM"
pub const Format = enum { jpeg, png, webp, other };

pub fn sniffFormat(header: []const u8) Format {
    if (header.len >= 8 and
        header[0] == 0x89 and header[1] == 0x50 and header[2] == 0x4E and
        header[3] == 0x47 and header[4] == 0x0D and header[5] == 0x0A and
        header[6] == 0x1A and header[7] == 0x0A) return .png;
    if (header.len >= 12 and
        header[0] == 'R' and header[1] == 'I' and header[2] == 'F' and header[3] == 'F' and
        header[8] == 'W' and header[9] == 'E' and header[10] == 'B' and header[11] == 'P') return .webp;
    if (header.len >= 2 and header[0] == 0xFF and header[1] == 0xD8) return .jpeg;
    return .other;
}

/// Read up to 16 leading bytes for sniffing. Returns byte count.
fn readHeader(path: [:0]const u8, out: *[16]u8) usize {
    // cwd-relative open: handles both absolute paths and argv-relative
    // ones (openFileAbsolute would assert on the latter).
    const file = std.Io.Dir.cwd().openFile(
        global_io,
        std.mem.sliceTo(path.ptr, 0),
        .{},
    ) catch return 0;
    defer file.close(global_io);
    return file.readPositionalAll(global_io, out, 0) catch 0;
}

pub fn detectFormat(path: [:0]const u8) Format {
    var buf: [16]u8 = undefined;
    const n = readHeader(path, &buf);
    if (n == 0) return .other;
    return sniffFormat(buf[0..n]);
}

pub fn isJpegExt(path: [:0]const u8) bool {
    const s = std.mem.sliceTo(path.ptr, 0);
    if (s.len >= 4 and std.ascii.eqlIgnoreCase(s[s.len - 4 ..], ".jpg")) return true;
    if (s.len >= 5 and std.ascii.eqlIgnoreCase(s[s.len - 5 ..], ".jpeg")) return true;
    return false;
}

//EXIF orientation (#6)

/// Read a u16 with the given endianness from a 2-byte slice.
fn readU16(b: []const u8, little: bool) u16 {
    if (little) return @as(u16, b[0]) | (@as(u16, b[1]) << 8);
    return (@as(u16, b[0]) << 8) | @as(u16, b[1]);
}

/// Read a u32 with the given endianness from a 4-byte slice.
fn readU32(b: []const u8, little: bool) u32 {
    if (little) return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | @as(u32, b[3]);
}

/// Minimal EXIF orientation reader: find the JPEG APP1 segment, confirm the
/// `Exif` marker, walk the TIFF IFD for tag 0x0112, return 1-8 (1 = normal).
/// Anything unrecognized returns 1 — display as-is. Never fails the load.
pub fn readExifOrientation(path: [:0]const u8) u8 {
    const file = std.Io.Dir.cwd().openFile(
        global_io,
        std.mem.sliceTo(path.ptr, 0),
        .{},
    ) catch return 1;
    defer file.close(global_io);

    const allocator = std.heap.c_allocator;
    // EXIF lives near the head; 64 KiB covers it without reading the pixels.
    const cap: usize = 64 * 1024;
    const buf = allocator.alloc(u8, cap) catch return 1;
    defer allocator.free(buf);
    const n = file.readPositionalAll(global_io, buf, 0) catch return 1;
    const data = buf[0..n];
    if (data.len < 4 or data[0] != 0xFF or data[1] != 0xD8) return 1;

    // Walk JPEG segments: FF xx len_hi len_lo, payload follows.
    var pos: usize = 2;
    while (pos + 4 <= data.len) {
        if (data[pos] != 0xFF) return 1;
        const marker = data[pos + 1];
        if (marker == 0xDA or marker == 0xD9) return 1; // SOS / EOI: past metadata
        if (pos + 4 > data.len) return 1;
        const seg_len = (@as(usize, data[pos + 2]) << 8) | @as(usize, data[pos + 3]);
        if (seg_len < 2 or pos + 2 + seg_len > data.len) return 1;
        if (marker == 0xE1) { // APP1: possible EXIF
            const body = data[pos + 4 .. pos + 2 + seg_len];
            if (body.len > 6 and std.mem.eql(u8, body[0..4], "Exif") and body[4] == 0 and body[5] == 0) {
                const tiff = body[6..];
                if (tiff.len < 8) return 1;
                const little = if (std.mem.eql(u8, tiff[0..2], "II")) true else if (std.mem.eql(u8, tiff[0..2], "MM")) false else return 1;
                if (readU16(tiff[2..4], little) != 42) return 1;
                const ifd_off = readU32(tiff[4..8], little);
                if (ifd_off + 2 > tiff.len) return 1;
                const count = readU16(tiff[ifd_off .. ifd_off + 2], little);
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const e = ifd_off + 2 + i * 12;
                    if (e + 12 > tiff.len) return 1;
                    if (readU16(tiff[e .. e + 2], little) == 0x0112) {
                        const val_off = e + 8;
                        // Orientation is SHORT count=1: value sits in the
                        // first 2 bytes of the 4-byte value field.
                        const v = readU16(tiff[val_off .. val_off + 2], little);
                        if (v >= 1 and v <= 8) return @intCast(v);
                        return 1;
                    }
                }
                return 1;
            }
        }
        pos += 2 + seg_len;
    }
    return 1;
}

//Pixel loading

/// Decode a JPEG using libjpeg-turbo (faster than stb_image for JPEGs).
/// Returns a heap-allocated RGBA buffer; caller frees with c_allocator.
fn loadPixelsTurbo(path: [:0]const u8, w: *c_int, h: *c_int) ?[]u8 {
    const file = std.Io.Dir.cwd().openFile(
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

/// Decode WebP via libwebp (#5). Reads the whole file, decodes to RGBA
/// with WebPDecodeRGBA (malloc'd; freed with WebPFree after copying).
fn loadPixelsWebP(path: [:0]const u8, w: *c_int, h: *c_int) ?[]u8 {
    const file = std.Io.Dir.cwd().openFile(
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

    var dw: c_int = 0;
    var dh: c_int = 0;
    const rgba = c.WebPDecodeRGBA(buf.ptr, buf.len, &dw, &dh);
    if (rgba == null) return null;
    defer c.WebPFree(rgba);
    if (dw <= 0 or dh <= 0) return null;

    const len: usize = @as(usize, @intCast(dw * dh * 4));
    const out = allocator.alloc(u8, len) catch return null;
    @memcpy(out, rgba[0..len]);
    w.* = dw;
    h.* = dh;
    return out;
}

/// Dispatch decode by magic bytes (#5): WebP files go to libwebp, JPEGs
/// prefer libjpeg-turbo with an stb fallback, everything else goes to
/// stb_image (PNG, GIF, BMP, TGA...). A `photo.jpg` that is really a PNG
/// decodes correctly because the sniff, not the extension, decides.
fn decodePixels(path: [:0]const u8, fmt: Format, w: *c_int, h: *c_int) ?[]u8 {
    switch (fmt) {
        .webp => {
            const pix = loadPixelsWebP(path, w, h);
            if (pix != null) return pix;
            return loadPixelsStb(path, w, h);
        },
        .jpeg => {
            const pix = loadPixelsTurbo(path, w, h);
            if (pix != null) return pix;
            return loadPixelsStb(path, w, h);
        },
        .png, .other => return loadPixelsStb(path, w, h),
    }
}

//Public API

/// Load an image as an SDL texture. Checks the preload caches first
/// (next, then previous — #4 keeps both neighbors warm).
pub fn loadImage(renderer: *c.SDL_Renderer, path: [:0]const u8) !Image {
    const needle = std.mem.sliceTo(path.ptr, 0);
    for ([2]*Preload{ &preload_next, &preload_prev }) |cache| {
        try cache.mutex.lock(global_io);
        if (cache.data) |d| {
            if (cache.path) |pp| {
                if (cache.w != 0 and std.mem.eql(u8, pp, needle)) {
                    const w = cache.w;
                    const h = cache.h;
                    const orient = cache.orientation;
                    const data = d;
                    cache.data = null;
                    cache.path = null;
                    cache.thread = null;
                    cache.mutex.unlock(global_io);

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
                    texture_live += 1;
                    return .{ .texture = texture, .w = w, .h = h, .orientation = orient };
                }
            }
        }
        cache.mutex.unlock(global_io);
    }

    var w: c_int = 0;
    var h: c_int = 0;
    const fmt = detectFormat(path);
    const pixels: ?[]u8 = decodePixels(path, fmt, &w, &h);

    const data = pixels orelse {
        std.debug.print("failed to load {s}: {s}\n", .{ path, c.stbi_failure_reason() });
        return error.LoadFailed;
    };
    defer std.heap.c_allocator.free(data);
    const orientation: u8 = if (fmt == .jpeg) readExifOrientation(path) else 1;

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
    texture_live += 1;
    return .{ .texture = texture, .w = w, .h = h, .orientation = orientation };
}

//Thumbnails (#7)

pub const Thumb = struct {
    texture: *c.SDL_Texture,
    w: i32,
    h: i32,
};

/// Decode a thumbnail that fits within `target` px on the long edge.
/// Pays the full decode cost, then CPU-downscales (nearest neighbor):
/// stb_image exposes no reduced-scale decode, so "decode full, downscale
/// after" is the honest cost model here. The caller bounds total memory
/// with a fixed thumbnail budget and an eviction policy instead.
pub fn loadThumb(renderer: *c.SDL_Renderer, path: [:0]const u8, target: i32) !Thumb {
    var w: c_int = 0;
    var h: c_int = 0;
    const fmt = detectFormat(path);
    const pixels = decodePixels(path, fmt, &w, &h) orelse return error.LoadFailed;
    defer std.heap.c_allocator.free(pixels);
    if (w <= 0 or h <= 0) return error.LoadFailed;

    var tw: i32 = w;
    var th: i32 = h;
    const long: i32 = @max(w, h);
    if (long > target) {
        tw = @max(1, @divTrunc(w * target, long));
        th = @max(1, @divTrunc(h * target, long));
    }

    const allocator = std.heap.c_allocator;
    const out = allocator.alloc(u8, @as(usize, @intCast(tw * th * 4))) catch return error.OutOfMemory;
    errdefer allocator.free(out);
    var y: i32 = 0;
    while (y < th) : (y += 1) {
        const sy = @divTrunc(y * h, th);
        var x: i32 = 0;
        while (x < tw) : (x += 1) {
            const sx = @divTrunc(x * w, tw);
            const s = @as(usize, @intCast((sy * w + sx) * 4));
            const d = @as(usize, @intCast((y * tw + x) * 4));
            out[d] = pixels[s];
            out[d + 1] = pixels[s + 1];
            out[d + 2] = pixels[s + 2];
            out[d + 3] = pixels[s + 3];
        }
    }

    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_ABGR8888,
        c.SDL_TEXTUREACCESS_STATIC,
        tw,
        th,
    ) orelse {
        allocator.free(out);
        return error.TextureCreateFailed;
    };
    errdefer c.SDL_DestroyTexture(texture);
    if (c.SDL_UpdateTexture(texture, null, out.ptr, tw * 4) != 0) {
        return error.TextureUpdateFailed;
    }
    _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);
    allocator.free(out);
    return .{ .texture = texture, .w = tw, .h = th };
}
/// Kick off background decoding of path into the preload cache.
/// No-op if path is already cached or a decode is already in flight.
///
/// Lock protocol: the mutex is unlocked before Thread.spawn so the worker
/// thread can lock it when it finishes.  After spawn we relock to write
/// preload.thread safely.
fn kickOff(cache: *Preload, inflight: *bool, path: [:0]const u8) void {
    cache.mutex.lock(global_io) catch return;
    if (inflight.*) {
        cache.mutex.unlock(global_io);
        return;
    }
    if (cache.path) |pp| {
        if (std.mem.eql(u8, pp, std.mem.sliceTo(path.ptr, 0))) {
            cache.mutex.unlock(global_io);
            return;
        }
    }
    if (cache.data) |d| std.heap.c_allocator.free(d);
    cache.data = null;
    if (cache.path) |pp| std.heap.c_allocator.free(pp);
    cache.path = null;
    inflight.* = true;

    const dup_path = std.heap.c_allocator.dupeZ(u8, std.mem.sliceTo(path.ptr, 0)) catch {
        inflight.* = false;
        cache.mutex.unlock(global_io);
        return;
    };
    cache.mutex.unlock(global_io); // release before spawn; worker will relock

    const thread = std.Thread.spawn(.{}, struct {
        fn run(p: [:0]const u8, target: *Preload, flying: *bool) void {
            var w: c_int = 0;
            var h: c_int = 0;
            const fmt = detectFormat(p);
            const pix: ?[]u8 = decodePixels(p, fmt, &w, &h);
            const orient: u8 = if (pix != null and fmt == .jpeg) readExifOrientation(p) else 1;

            target.mutex.lock(global_io) catch {
                if (pix) |d| std.heap.c_allocator.free(d);
                std.heap.c_allocator.free(p);
                return;
            };
            defer target.mutex.unlock(global_io);
            if (pix) |d| {
                if (target.data) |old| std.heap.c_allocator.free(old);
                if (target.path) |oldp| std.heap.c_allocator.free(oldp);
                target.data = d;
                target.w = w;
                target.h = h;
                target.orientation = orient;
                target.path = std.heap.c_allocator.dupe(
                    u8,
                    std.mem.sliceTo(p.ptr, 0),
                ) catch null;
            }
            flying.* = false;
            std.heap.c_allocator.free(p);
        }
    }.run, .{ dup_path, cache, inflight }) catch {
        std.heap.c_allocator.free(dup_path);
        cache.mutex.lock(global_io) catch return;
        inflight.* = false;
        cache.mutex.unlock(global_io);
        return;
    };

    cache.mutex.lock(global_io) catch return;
    if (cache.thread) |old| old.detach();
    cache.thread = thread;
    cache.mutex.unlock(global_io);
}

/// Decode the next image (N+1) on a background thread while the user
/// is still looking at N, so forward navigation is instant.
pub fn preloadNext(path: [:0]const u8) void {
    kickOff(&preload_next, &preload_next_inflight, path);
}

/// Decode the previous image (N-1) on a background thread, so backward
/// navigation is instant too. Kept in a separate slot from preloadNext:
///
///   - forward and backward prefetches never evict each other;
///   - texture creation still happens on the renderer thread in
///     loadImage (SDL renderers are not thread-safe), the workers only
///     hand over decoded pixel buffers.
pub fn preloadPrev(path: [:0]const u8) void {
    kickOff(&preload_prev, &preload_prev_inflight, path);
}

/// Free all preload state. Call at shutdown.
pub fn cleanup() void {
    for ([2]*Preload{ &preload_next, &preload_prev }) |cache| {
        if (cache.data) |d| std.heap.c_allocator.free(d);
        if (cache.path) |p| std.heap.c_allocator.free(p);
        if (cache.thread) |t| t.join();
    }
}
