/// Lumen — single-window image viewer.
/// Entry point, event loop, and tab-bar UI.
const std = @import("std");
const c = @import("c.zig").c;
const sock = @import("socket.zig");
const image = @import("image.zig");

const TAB_H: i32 = 32;
const TAB_PAD: i32 = 12;

// ── Tabs: data-oriented tab list ──────────────────────────────────────────
//
// Two parallel arrays kept permanently in sync:
//   paths[i]  — null-terminated path string
//   widths[i] — pre-computed pixel width of tab i
//
// Tab widths are measured once at insertion (TTF_SizeUTF8) and cached here.
// The render loop and mouse hit-tests read directly from widths[] — zero
// TTF calls per frame regardless of how many tabs are open.

const Tabs = struct {
    paths: std.ArrayList([:0]const u8),
    widths: std.ArrayList(i32),

    const empty: Tabs = .{ .paths = .empty, .widths = .empty };

    /// Measure the rendered pixel width of a single tab label.
    fn measureWidth(font: ?*c.TTF_Font, path: [:0]const u8) i32 {
        const name = basename(std.mem.sliceTo(path.ptr, 0));
        var tw: c_int = 0;
        var th: c_int = 0;
        if (font != null) _ = c.TTF_SizeUTF8(font, @ptrCast(name.ptr), &tw, &th);
        return tw + TAB_PAD * 2 + 20; // text + padding + close-button gutter
    }

    /// Append a path, measuring its tab width immediately.
    /// Reserves capacity for both arrays before touching either, so the
    /// operation is atomic with respect to partial failure.
    fn append(
        self: *Tabs,
        allocator: std.mem.Allocator,
        font: ?*c.TTF_Font,
        path: []const u8,
    ) !void {
        const owned = try allocator.dupeZ(u8, path);
        errdefer allocator.free(owned);
        // Reserve first so that if either allocation fails we haven't changed
        // the visible length of either array.
        try self.paths.ensureTotalCapacity(allocator, self.paths.items.len + 1);
        try self.widths.ensureTotalCapacity(allocator, self.widths.items.len + 1);
        self.paths.appendAssumeCapacity(owned);
        self.widths.appendAssumeCapacity(measureWidth(font, owned));
    }

    /// Remove the tab at index i, keeping both arrays in sync.
    fn removeAt(self: *Tabs, i: usize) void {
        _ = self.paths.orderedRemove(i);
        _ = self.widths.orderedRemove(i);
    }

    fn len(self: *const Tabs) usize {
        return self.paths.items.len;
    }
};

// ── Utilities ─────────────────────────────────────────────────────────────

fn basename(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/' or path[i - 1] == '\\') return path[i..];
    }
    return path;
}

fn setTitle(
    window: *c.SDL_Window,
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    index: usize,
    total: usize,
) void {
    const title = std.fmt.allocPrintSentinel(
        allocator,
        "Lumen - {s} ({d}/{d})",
        .{ std.mem.sliceTo(path.ptr, 0), index + 1, total },
        0,
    ) catch return;
    defer allocator.free(title);
    c.SDL_SetWindowTitle(window, title.ptr);
}

/// Close the tab at `target`, adjust `index`, and reload if needed.
/// Fixes the original bug where clicking any close button always closed the
/// currently-selected tab rather than the one that was clicked.
fn closeTabAt(
    tabs: *Tabs,
    current: *?image.Image,
    index: *usize,
    target: usize,
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    window: *c.SDL_Window,
    font: ?*c.TTF_Font,
) bool {
    if (tabs.len() == 0) return false;
    tabs.removeAt(target);
    if (tabs.len() == 0) {
        if (current.*) |img| {
            c.SDL_DestroyTexture(img.texture);
            current.* = null;
        }
        return false;
    }

    if (target == index.*) {
        // The current tab was closed; load whatever is now at the same slot.
        if (current.*) |img| c.SDL_DestroyTexture(img.texture);
        if (index.* >= tabs.len()) index.* = tabs.len() - 1;
        if (image.loadImage(renderer, tabs.paths.items[index.*])) |img| {
            current.* = img;
        } else |_| {
            current.* = null;
            return false;
        }
    } else if (target < index.*) {
        index.* -= 1; // a tab before current was removed, shift index left
    }

    setTitle(window, allocator, tabs.paths.items[index.*], index.*, tabs.len());
    if (index.* + 1 < tabs.len()) image.preloadNext(tabs.paths.items[index.* + 1]);
    _ = font;
    return true;
}

// ── Window icon ──────────────────────────────────────────────────────────────

/// Decode the embedded PNG and hand it to SDL as the window icon.
/// The 64×64 PNG is embedded at compile time via @embedFile; no file I/O at
/// runtime and no extra dependency beyond stb_image (already linked).
fn setWindowIcon(window: *c.SDL_Window) void {
    const png = @embedFile("lumen-icon.png");
    var w: c_int = 0;
    var h: c_int = 0;
    var ch: c_int = 0;
    const pixels = c.stbi_load_from_memory(
        png.ptr,
        @intCast(png.len),
        &w,
        &h,
        &ch,
        4,
    ) orelse return;
    defer c.stbi_image_free(pixels);

    // stbi_load_from_memory with desired_channels=4 gives RGBA bytes.
    // SDL_PIXELFORMAT_RGBA32 matches that layout on little-endian x86.
    const surface = c.SDL_CreateRGBSurfaceWithFormatFrom(
        pixels,
        w,
        h,
        32,
        w * 4,
        c.SDL_PIXELFORMAT_RGBA32,
    ) orelse return;
    defer c.SDL_FreeSurface(surface);

    c.SDL_SetWindowIcon(window, surface);
}

// ── Empty-state rendering ────────────────────────────────────────────────

/// Render a single line of text centred at (cx, cy).
fn renderCenteredText(
    renderer: *c.SDL_Renderer,
    font: *c.TTF_Font,
    text: [*:0]const u8,
    color: c.SDL_Color,
    cx: i32,
    cy: i32,
) void {
    const surf = c.TTF_RenderUTF8_Blended(font, text, color) orelse return;
    defer c.SDL_FreeSurface(surf);
    if (c.SDL_CreateTextureFromSurface(renderer, surf)) |tex| {
        defer c.SDL_DestroyTexture(tex);
        var dst = c.SDL_Rect{
            .x = cx - @divTrunc(surf.*.w, 2),
            .y = cy - @divTrunc(surf.*.h, 2),
            .w = surf.*.w,
            .h = surf.*.h,
        };
        _ = c.SDL_RenderCopy(renderer, tex, null, &dst);
    }
}

/// Draw the placeholder shown when no images are open.
fn renderEmptyState(
    renderer: *c.SDL_Renderer,
    window: *c.SDL_Window,
    font: *c.TTF_Font,
) void {
    var win_w: c_int = 0;
    var win_h: c_int = 0;
    c.SDL_GetWindowSize(window, &win_w, &win_h);
    const cx = @divTrunc(win_w, 2);
    const cy = TAB_H + @divTrunc(win_h - TAB_H, 2);

    renderCenteredText(
        renderer,
        font,
        "No images open",
        c.SDL_Color{ .r = 160, .g = 160, .b = 160, .a = 255 },
        cx,
        cy - 14,
    );
    renderCenteredText(
        renderer,
        font,
        "lumen <file.jpg> [file.jpg ...]",
        c.SDL_Color{ .r = 75, .g = 75, .b = 75, .a = 255 },
        cx,
        cy + 14,
    );
}

// ── Entry point ───────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    image.global_io = io;
    const args = try init.minimal.args.toSlice(allocator);

    // ── Single-instance handoff ──────────────────────────────────────────
    const spath = try sock.socketPath(allocator);
    const spath_z = try allocator.dupeZ(u8, spath);

    // Only attempt handoff when there are images to send; launching with no
    // arguments always opens a fresh empty window.
    if (args.len >= 2 and try sock.tryHandoff(allocator, spath, args)) {
        std.debug.print("handed off {d} file(s) to existing Lumen window\n", .{args.len - 1});
        return;
    }

    // No existing instance — become the server.
    _ = std.os.linux.unlink(spath_z.ptr); // clear any stale socket file
    const server = try sock.Server.init(spath);
    defer server.deinit(spath_z);

    // ── SDL setup ────────────────────────────────────────────────────────
    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    defer c.SDL_Quit();

    if (c.TTF_Init() != 0) {
        std.debug.print("TTF_Init failed: {s}\n", .{c.TTF_GetError()});
        return error.TTFInitFailed;
    }
    defer c.TTF_Quit();

    var font = c.TTF_OpenFont("/usr/share/fonts/liberation/LiberationSans-Regular.ttf".ptr, 14);
    if (font == null) font = c.TTF_OpenFont("/usr/share/fonts/TTF/DejaVuSans.ttf".ptr, 14);
    if (font == null) font = c.TTF_OpenFont("/home/bernard/.local/share/fonts/dejavu/DejaVuSans.ttf".ptr, 14);
    if (font == null) std.debug.print("TTF_OpenFont failed: {s}\n", .{c.TTF_GetError()});
    defer if (font != null) c.TTF_CloseFont(font);

    const window = c.SDL_CreateWindow(
        "Lumen",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        1024,
        768,
        c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_SHOWN,
    ) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.WindowCreateFailed;
    };
    defer c.SDL_DestroyWindow(window);
    setWindowIcon(window);

    const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED) orelse
        c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_SOFTWARE) orelse {
        std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
        return error.RendererCreateFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    // ── Initial tab list ─────────────────────────────────────────────────
    var tabs: Tabs = .empty;
    for (args[1..]) |p| try tabs.append(allocator, font, p);

    var index: usize = 0;
    var current: ?image.Image = null;
    if (tabs.len() > 0) {
        current = try image.loadImage(renderer, tabs.paths.items[0]);
        setTitle(window, allocator, tabs.paths.items[0], 0, tabs.len());
        if (tabs.len() > 1) image.preloadNext(tabs.paths.items[1]);
    }
    defer image.cleanup();

    // ── Event / render loop ──────────────────────────────────────────────
    var running = true;
    var read_buf: [4096]u8 = undefined;
    var pending: std.ArrayList(u8) = .empty;

    while (running) {
        // epoll_wait blocks up to 16 ms, waking early when a client connects.
        // This replaces both the blind accept() poll and SDL_Delay(16).
        if (try server.poll(allocator, &pending, &read_buf, 16)) {
            const old_len = tabs.len();
            var added: usize = 0;
            var it = std.mem.splitScalar(u8, pending.items, '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                try tabs.append(allocator, font, line);
                added += 1;
            }
            pending.clearRetainingCapacity();
            if (added > 0) {
                if (image.loadImage(renderer, tabs.paths.items[old_len])) |img| {
                    if (current) |old| c.SDL_DestroyTexture(old.texture);
                    current = img;
                    index = old_len;
                } else |_| {}
                setTitle(window, allocator, tabs.paths.items[index], index, tabs.len());
                c.SDL_RaiseWindow(window);
                if (index + 1 < tabs.len()) image.preloadNext(tabs.paths.items[index + 1]);
            }
        }

        // ── Input ────────────────────────────────────────────────────────
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => running = false,

                c.SDL_MOUSEBUTTONDOWN => {
                    if (event.button.y < TAB_H) {
                        var x: i32 = 0;
                        for (tabs.widths.items, 0..) |tab_w, i| {
                            const close_x = x + tab_w - 18;
                            if (event.button.x >= close_x and
                                event.button.x < close_x + 12 and
                                event.button.y >= 0 and
                                event.button.y < TAB_H)
                            {
                                // Pass `i` so we close the clicked tab, not
                                // necessarily the currently-selected one.
                                _ = closeTabAt(&tabs, &current, &index, i, allocator, renderer, window, font);
                                // Don't exit when the last tab closes — show
                                // the empty state and wait for new handoffs.
                                break;
                            }
                            if (event.button.x >= x and event.button.x < x + tab_w) {
                                if (i != index) {
                                    if (image.loadImage(renderer, tabs.paths.items[i])) |img| {
                                        if (current) |old| c.SDL_DestroyTexture(old.texture);
                                        current = img;
                                        index = i;
                                        setTitle(window, allocator, tabs.paths.items[i], i, tabs.len());
                                        if (i + 1 < tabs.len())
                                            image.preloadNext(tabs.paths.items[i + 1]);
                                    } else |_| {}
                                }
                                break;
                            }
                            x += tab_w;
                        }
                    }
                },

                c.SDL_KEYDOWN => {
                    const key = event.key.keysym.sym;
                    if (key == c.SDLK_ESCAPE or key == c.SDLK_q) {
                        running = false;
                    } else {
                        const new_index: ?usize = if ((key == c.SDLK_RIGHT or key == c.SDLK_SPACE or key == c.SDLK_d) and
                            index + 1 < tabs.len())
                            index + 1
                        else if ((key == c.SDLK_LEFT or key == c.SDLK_a) and index > 0)
                            index - 1
                        else
                            null;

                        if (new_index) |ni| {
                            if (image.loadImage(renderer, tabs.paths.items[ni])) |img| {
                                if (current) |old| c.SDL_DestroyTexture(old.texture);
                                current = img;
                                index = ni;
                                setTitle(window, allocator, tabs.paths.items[ni], ni, tabs.len());
                                if (ni + 1 < tabs.len())
                                    image.preloadNext(tabs.paths.items[ni + 1]);
                            } else |_| {}
                        }
                    }
                },

                else => {},
            }
        }

        // ── Render ───────────────────────────────────────────────────────
        _ = c.SDL_SetRenderDrawColor(renderer, 20, 20, 20, 255);
        _ = c.SDL_RenderClear(renderer);

        if (font != null) {
            var win_w: c_int = 0;
            c.SDL_GetWindowSize(window, &win_w, null);

            // Tab bar — widths[] is pre-computed, no TTF_SizeUTF8 calls here.
            var x: i32 = 0;
            for (tabs.paths.items, tabs.widths.items, 0..) |p, tab_w, i| {
                if (x + tab_w > win_w) break;
                const is_sel = i == index;
                const bg: u8 = if (is_sel) 60 else 40;
                var rect = c.SDL_Rect{ .x = x, .y = 0, .w = tab_w, .h = TAB_H };
                _ = c.SDL_SetRenderDrawColor(renderer, bg, bg, bg, 255);
                _ = c.SDL_RenderFillRect(renderer, &rect);
                _ = c.SDL_SetRenderDrawColor(renderer, 80, 80, 80, 255);
                _ = c.SDL_RenderDrawRect(renderer, &rect);

                const name = basename(std.mem.sliceTo(p.ptr, 0));
                const text_surf = c.TTF_RenderUTF8_Blended(
                    font,
                    @ptrCast(name.ptr),
                    c.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = 255 },
                );
                if (text_surf) |surf| {
                    defer c.SDL_FreeSurface(surf);
                    if (c.SDL_CreateTextureFromSurface(renderer, surf)) |tex| {
                        defer c.SDL_DestroyTexture(tex);
                        var dst = c.SDL_Rect{
                            .x = x + TAB_PAD,
                            .y = @divTrunc(TAB_H - surf.*.h, 2),
                            .w = surf.*.w,
                            .h = surf.*.h,
                        };
                        _ = c.SDL_RenderCopy(renderer, tex, null, &dst);
                    }
                    if (is_sel) {
                        if (c.TTF_RenderUTF8_Blended(
                            font,
                            "x",
                            c.SDL_Color{ .r = 200, .g = 200, .b = 200, .a = 255 },
                        )) |xs| {
                            defer c.SDL_FreeSurface(xs);
                            if (c.SDL_CreateTextureFromSurface(renderer, xs)) |xt| {
                                defer c.SDL_DestroyTexture(xt);
                                var xr = c.SDL_Rect{
                                    .x = x + tab_w - 18,
                                    .y = @divTrunc(TAB_H - xs.*.h, 2),
                                    .w = @max(xs.*.w, 12),
                                    .h = xs.*.h,
                                };
                                _ = c.SDL_RenderCopy(renderer, xt, null, &xr);
                            }
                        }
                    }
                }
                x += tab_w;
            }
        }

        if (current == null) {
            if (font) |f| renderEmptyState(renderer, window, f);
        } else if (current) |img| {
            var win_w: c_int = 0;
            var win_h: c_int = 0;
            c.SDL_GetWindowSize(window, &win_w, &win_h);
            const avail_h = win_h - TAB_H;
            const img_ratio = @as(f32, @floatFromInt(img.w)) / @as(f32, @floatFromInt(img.h));
            const win_ratio = @as(f32, @floatFromInt(win_w)) / @as(f32, @floatFromInt(avail_h));
            var dst: c.SDL_Rect = undefined;
            if (img_ratio > win_ratio) {
                dst.w = win_w;
                dst.h = @intFromFloat(@as(f32, @floatFromInt(win_w)) / img_ratio);
            } else {
                dst.h = avail_h;
                dst.w = @intFromFloat(@as(f32, @floatFromInt(avail_h)) * img_ratio);
            }
            dst.x = @divTrunc(win_w - dst.w, 2);
            dst.y = TAB_H + @divTrunc(avail_h - dst.h, 2);
            _ = c.SDL_RenderCopy(renderer, img.texture, null, &dst);
        }

        c.SDL_RenderPresent(renderer);
    }

    if (current) |img| c.SDL_DestroyTexture(img.texture);
}
