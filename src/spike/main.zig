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
// Failsafe: never run longer than this, so a headless run without input
// can never hang forever. (Slice counting alone doesn't bound wall time:
// vsync frame events can burn hundreds of slices per second.)
const FAILSAFE_SEC: i64 = 30;

// Wayland keycodes are evdev + 8. evdev ESC = 1, Q = 16.
const KEY_ESC: u32 = 9;
const KEY_Q: u32 = 24;

const Ctx = struct {
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
    seat: ?*wl.Seat = null,
    keyboard: ?*wl.Keyboard = null,
    pointer: ?*wl.Pointer = null,
    configured: bool = false,
    // Set by input/close handlers; the main loop exits on it.
    done: bool = false,
    // Set by the frame callback; the main loop re-arms vsync on it.
    need_frame: bool = false,
    // Frame completions seen (vsync pacing proof).
    frames: u32 = 0,
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
            } else if (std.mem.eql(u8, iface, "wl_seat")) {
                ctx.seat = registry.bind(g.name, wl.Seat, 7) catch null;
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

fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, ctx: *Ctx) void {
    switch (event) {
        .close => ctx.done = true,
        else => {},
    }
}

fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, ctx: *Ctx) void {
    switch (event) {
        .capabilities => |caps| {
            if (caps.capabilities.keyboard and ctx.keyboard == null) {
                ctx.keyboard = seat.getKeyboard() catch null;
                if (ctx.keyboard) |kbd| kbd.setListener(*Ctx, keyboardListener, ctx);
            }
            if (caps.capabilities.pointer and ctx.pointer == null) {
                ctx.pointer = seat.getPointer() catch null;
                if (ctx.pointer) |ptr| ptr.setListener(*Ctx, pointerListener, ctx);
            }
        },
        else => {},
    }
}

fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, ctx: *Ctx) void {
    switch (event) {
        // Raw keycodes only (no xkbcommon yet): q / Esc quits.
        .key => |k| {
            if (k.state == .pressed and (k.key == KEY_Q or k.key == KEY_ESC)) ctx.done = true;
        },
        // The keymap fd must not leak; we ignore its content for now.
        .keymap => |km| _ = std.os.linux.close(km.fd),
        else => {},
    }
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, ctx: *Ctx) void {
    switch (event) {
        // Any click quits the spike.
        .button => |b| {
            if (b.state == .pressed) ctx.done = true;
        },
        else => {},
    }
}

fn frameListener(callback: *wl.Callback, event: wl.Callback.Event, ctx: *Ctx) void {
    switch (event) {
        .done => {
            callback.destroy();
            ctx.frames += 1;
            ctx.need_frame = true;
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
    if (ctx.seat) |seat| {
        seat.setListener(*Ctx, seatListener, &ctx);
        // Second roundtrip delivers capabilities so keyboard/pointer
        // objects exist before the main loop starts.
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    }

    const surface = try compositor.createSurface();
    const xsurf = try wm_base.getXdgSurface(surface);
    xsurf.setListener(*Ctx, xdgSurfaceListener, &ctx);
    const top = try xsurf.getToplevel();
    top.setListener(*Ctx, toplevelListener, &ctx);
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

    // Frame-driven main loop: vsync callbacks pace repaints, poll() with
    // a short timeout keeps the failsafe honest when nothing happens.
    // Quits on q / Esc / any click / toplevel close / ~30s.
    std.debug.print("spike running: q/Esc/click quits (seat: kbd={} ptr={})\n", .{
        ctx.keyboard != null,
        ctx.pointer != null,
    });
    var frame_cb = try surface.frame();
    frame_cb.setListener(*Ctx, frameListener, &ctx);
    const wfd = display.getFd();
    var start_ts: posix.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &start_ts);
    var slices: u32 = 0;
    while (!ctx.done) : (slices += 1) {
        var now_ts: posix.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &now_ts);
        if (now_ts.sec - start_ts.sec >= FAILSAFE_SEC) break;
        var pfd = [_]posix.pollfd{.{ .fd = wfd, .events = posix.POLL.IN, .revents = 0 }};
        _ = posix.poll(&pfd, 250) catch {};
        if (display.dispatchPending() != .SUCCESS) break;
        if (ctx.need_frame and !ctx.done) {
            ctx.need_frame = false;
            // Static content: nothing to re-commit. Re-arming the
            // callback alone keeps the vsync pacing signal without a
            // commit/done ping-pong storm at socket speed.
            frame_cb = try surface.frame();
            frame_cb.setListener(*Ctx, frameListener, &ctx);
            if (display.flush() != .SUCCESS) break;
        }
    }
    std.debug.print("spike exiting after {d} slices, {d} frames (done={})\n", .{ slices, ctx.frames, ctx.done });

    top.destroy();
    xsurf.destroy();
    surface.destroy();
}
