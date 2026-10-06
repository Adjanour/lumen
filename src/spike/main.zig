/// Wayland shm spike: open a raw xdg_toplevel window and blit one decoded
/// image into a wl_shm buffer. No SDL, no input handling — the window
/// shows for a few seconds, then the program exits.
///
/// Run:  ./build-gcc16.sh spike
///        ./zig-out/bin/shm-spike <image>
const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const c = @cImport({
    @cInclude("stb_image.h");
});

const MAX_W: i32 = 1280;
const MAX_H: i32 = 800;
const SHOW_NS: u64 = 4 * std.time.ns_per_s;

const Ctx = struct {
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
    configured: bool = false,
};

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, ctx: *Ctx) void {
    switch (event) {
        .global => |g| {
            const iface = std.mem.span(g.interface);
            if (std.mem.eql(u8, iface, "wl_compositor")) {
                ctx.compositor = registry.bind(g.name, wl.Compositor, 4) catch null;
            } else if (std.mem.eql(u8, iface, "wl_shm")) {
                ctx.shm = registry.bind(g.name, wl.Shm, 1) catch null;
            } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
                ctx.wm_base = registry.bind(g.name, xdg.WmBase, 3) catch null;
            }
        },
        .global_remove => {},
    }
}

fn wmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: *Ctx) void {
    switch (event) {
        .ping => |p| wm_base.pong(p.serial),
    }
}

fn xdgSurfaceListener(surface: *xdg.Surface, event: xdg.Surface.Event, ctx: *Ctx) void {
    switch (event) {
        .configure => |cfg| {
            surface.ackConfigure(cfg.serial);
            ctx.configured = true;
        },
    }
}

const Decoded = struct {
    pixels: []u32, // XRGB8888, row-major
    w: i32,
    h: i32,
};

/// Decode path to XRGB8888, downscaling (nearest neighbor) to fit
/// MAX_W×MAX_H. Caller frees pixels with c_allocator.
fn decodeFit(path: [*:0]const u8) !Decoded {
    var w: c_int = 0;
    var h: c_int = 0;
    var ch: c_int = 0;
    const raw = c.stbi_load(path, &w, &h, &ch, 4) orelse return error.DecodeFailed;
    defer c.stbi_image_free(raw);
    if (w <= 0 or h <= 0) return error.DecodeFailed;

    var tw: i32 = w;
    var th: i32 = h;
    if (w > MAX_W or h > MAX_H) {
        // Scale by the tighter axis, like fitDims in main.zig.
        const rw: f32 = @as(f32, @floatFromInt(MAX_W)) / @as(f32, @floatFromInt(w));
        const rh: f32 = @as(f32, @floatFromInt(MAX_H)) / @as(f32, @floatFromInt(h));
        const s = @min(rw, rh);
        tw = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(w)) * s)));
        th = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(h)) * s)));
    }

    const bytes = std.mem.sliceAsBytes(raw[0..@as(usize, @intCast(w * h * 4))]);
    const out = std.heap.c_allocator.alloc(u32, @as(usize, @intCast(tw * th))) catch
        return error.OutOfMemory;
    var y: i32 = 0;
    while (y < th) : (y += 1) {
        const sy = @divTrunc(y * h, th);
        var x: i32 = 0;
        while (x < tw) : (x += 1) {
            const sx = @divTrunc(x * w, tw);
            const s = @as(usize, @intCast((sy * w + sx) * 4));
            const r: u32 = bytes[s];
            const g: u32 = bytes[s + 1];
            const b: u32 = bytes[s + 2];
            out[@intCast(y * tw + x)] = 0xFF000000 | (r << 16) | (g << 8) | b;
        }
    }
    return .{ .pixels = out, .w = tw, .h = th };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) {
        std.debug.print("usage: shm-spike <image>\n", .{});
        return error.MissingArg;
    }

    const img = try decodeFit(args[1]);
    defer std.heap.c_allocator.free(img.pixels);
    std.debug.print("decoded {s}: {d}x{d}\n", .{ args[1], img.w, img.h });

    const display = try wl.Display.connect(null);
    defer wl.Display.disconnect(display);

    var ctx = Ctx{};
    const registry = try display.getRegistry();
    defer registry.destroy();
    registry.setListener(*Ctx, registryListener, &ctx);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    const compositor = ctx.compositor orelse return error.NoCompositor;
    const shm = ctx.shm orelse return error.NoShm;
    const wm_base = ctx.wm_base orelse return error.NoXdgWmBase;
    wm_base.setListener(*Ctx, wmBaseListener, &ctx);

    const surface = try compositor.createSurface();
    const xsurf = try wm_base.getXdgSurface(surface);
    xsurf.setListener(*Ctx, xdgSurfaceListener, &ctx);
    const top = try xsurf.getToplevel();
    top.setTitle("shm-spike");
    top.setAppId("shm-spike");
    surface.commit();

    // Wait for the compositor's configure before attaching a buffer.
    var spins: u32 = 0;
    while (!ctx.configured) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
        spins += 1;
        if (spins > 1000) return error.NoConfigure;
    }

    // Backing store: one memfd, mapped writable, sized w*h*4.
    const stride = img.w * 4;
    const size: i32 = stride * img.h;
    const fd = try posix.memfd_create("shm-spike", 0);
    defer _ = std.os.linux.close(fd);
    {
        const rc = std.os.linux.ftruncate(fd, size);
        if (@as(isize, @bitCast(rc)) < 0) return error.FtruncateFailed;
    }
    const map = try posix.mmap(
        null,
        @intCast(size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer posix.munmap(map);
    @memcpy(@as([*]u8, @ptrCast(map))[0..@intCast(size)], std.mem.sliceAsBytes(img.pixels));

    const pool = try shm.createPool(fd, size);
    defer pool.destroy();
    const buffer = try pool.createBuffer(0, img.w, img.h, stride, .xrgb8888);
    defer buffer.destroy();

    surface.attach(buffer, 0, 0);
    surface.damage(0, 0, img.w, img.h);
    surface.commit();
    if (display.flush() != .SUCCESS) return error.FlushFailed;

    std.debug.print("window up for 4s (no input handling in spike)\n", .{});
    {
        const req = posix.timespec{ .sec = 4, .nsec = 0 };
        _ = std.os.linux.nanosleep(&req, null);
    }

    top.destroy();
    xsurf.destroy();
    surface.destroy();
}
