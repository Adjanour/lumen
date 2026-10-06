/// Lumen — single-window image viewer.
/// Entry point, event loop, and tab-bar UI.
const std = @import("std");
const c = @import("c.zig").c;
const sock = @import("socket.zig");
const image = @import("image.zig");

const TAB_H: i32 = 32;
const TAB_PAD: i32 = 12;

//Tabs
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

//Thumbnail grid cache (#7)
//
// The grid keeps many textures alive at once, so it runs under a fixed
// budget: at most THUMB_BUDGET thumbnails (160px long edge, ~100KB each,
// ~6.4MB total). Misses decode on demand; when full, the entry farthest
// from the selection is evicted (visible range plus margin). Indices stay
// valid because every tab add/remove clears the cache.
const THUMB_BUDGET: usize = 64;
const THUMB_TARGET: i32 = 160;
const GRID_CELL: i32 = 184;
const GRID_LABEL_MAX: usize = 20;

const ThumbEntry = struct {
    tab: usize,
    thumb: image.Thumb,
};

const ThumbCache = struct {
    entries: std.ArrayList(ThumbEntry) = .empty,

    fn clear(self: *ThumbCache) void {
        for (self.entries.items) |e| c.SDL_DestroyTexture(e.thumb.texture);
        self.entries.clearRetainingCapacity();
    }

    fn evictFarthest(self: *ThumbCache, sel: usize) void {
        var best: usize = 0;
        var best_d: usize = 0;
        for (self.entries.items, 0..) |e, i| {
            const d = if (e.tab > sel) e.tab - sel else sel - e.tab;
            if (d >= best_d) {
                best_d = d;
                best = i;
            }
        }
        const e = self.entries.orderedRemove(best);
        c.SDL_DestroyTexture(e.thumb.texture);
    }

    fn getOrLoad(
        self: *ThumbCache,
        allocator: std.mem.Allocator,
        renderer: *c.SDL_Renderer,
        tab: usize,
        path: [:0]const u8,
        sel: usize,
    ) ?*image.Thumb {
        for (self.entries.items) |*e| {
            if (e.tab == tab) return &e.thumb;
        }
        if (self.entries.items.len >= THUMB_BUDGET) self.evictFarthest(sel);
        const t = image.loadThumb(renderer, path, THUMB_TARGET) catch return null;
        self.entries.append(allocator, .{ .tab = tab, .thumb = t }) catch {
            c.SDL_DestroyTexture(t.texture);
            return null;
        };
        return &self.entries.items[self.entries.items.len - 1].thumb;
    }
};

//Utilities
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
    zoom: f32,
) void {
    const pct: i32 = @intFromFloat(@round(zoom * 100));
    const title = if (pct == 100)
        std.fmt.allocPrintSentinel(
            allocator,
            "Lumen - {s} ({d}/{d})",
            .{ std.mem.sliceTo(path.ptr, 0), index + 1, total },
            0,
        ) catch return
    else
        std.fmt.allocPrintSentinel(
            allocator,
            "Lumen - {s} ({d}/{d}) {d}%",
            .{ std.mem.sliceTo(path.ptr, 0), index + 1, total, pct },
            0,
        ) catch return;
    defer allocator.free(title);
    c.SDL_SetWindowTitle(window, title.ptr);
}

/// Fit-to-window dimensions for an ew×eh image in win_w×avail_h.
/// Pure ratio math shared by the render loop and the zoom handlers.
fn fitDims(ew: i32, eh: i32, win_w: i32, avail_h: i32) struct { w: i32, h: i32 } {
    const img_ratio = @as(f32, @floatFromInt(ew)) / @as(f32, @floatFromInt(eh));
    const win_ratio = @as(f32, @floatFromInt(win_w)) / @as(f32, @floatFromInt(avail_h));
    if (img_ratio > win_ratio) {
        const w = win_w;
        const h: i32 = @intFromFloat(@as(f32, @floatFromInt(win_w)) / img_ratio);
        return .{ .w = w, .h = h };
    } else {
        const h = avail_h;
        const w: i32 = @intFromFloat(@as(f32, @floatFromInt(avail_h)) * img_ratio);
        return .{ .w = w, .h = h };
    }
}

/// Clamp a pan offset so the image center never leaves the window by more
/// than half the rendered size — the picture can't be lost off-screen.
fn clampPan(off: f32, rendered: i32) f32 {
    const lim = @as(f32, @floatFromInt(rendered)) / 2;
    if (off < -lim) return -lim;
    if (off > lim) return lim;
    return off;
}

/// Rendered image dimensions at the given zoom for a win_w×avail_h window.
/// EXIF-transposed images (orientations 5-8) fit against swapped dims.
fn renderedSize(img: image.Image, win_w: i32, avail_h: i32, zoom: f32) struct { w: i32, h: i32 } {
    const swapped = img.orientation >= 5;
    const ew: i32 = if (swapped) img.h else img.w;
    const eh: i32 = if (swapped) img.w else img.h;
    const fit = fitDims(ew, eh, win_w, avail_h);
    return .{
        .w = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(fit.w)) * zoom))),
        .h = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(fit.h)) * zoom))),
    };
}

/// Warm both neighbors of the selected tab: N+1 into the forward slot,
/// N-1 into the backward slot (#4). Forward and backward prefetches live
/// in separate cache slots so they never evict each other.
fn warmNeighbors(tabs: *const Tabs, index: usize) void {
    if (index + 1 < tabs.len()) image.preloadNext(tabs.paths.items[index + 1]);
    if (index > 0) image.preloadPrev(tabs.paths.items[index - 1]);
}

/// Zoom/pan view state. zoom is relative to fit (1.0 = fit to window);
/// ox/oy are screen-pixel offsets from center. Reset on navigation.
const View = struct {
    zoom: f32 = 1.0,
    ox: f32 = 0,
    oy: f32 = 0,

    fn reset(self: *View) void {
        self.zoom = 1.0;
        self.ox = 0;
        self.oy = 0;
    }
};

/// Close the tab at `target`, adjust `index`, and reload if needed.
/// Fixes the original bug where clicking any close button always closed the
/// currently-selected tab rather than the one that was clicked.
fn closeTabAt(
    tabs: *Tabs,
    cache: *ThumbCache,
    current: *?image.Image,
    index: *usize,
    view: *View,
    target: usize,
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    window: *c.SDL_Window,
    font: ?*c.TTF_Font,
) bool {
    if (tabs.len() == 0) return false;
    cache.clear();
    tabs.removeAt(target);
    if (tabs.len() == 0) {
        if (current.*) |img| {
            image.destroy(img.texture);
            current.* = null;
        }
        return false;
    }

    if (target == index.*) {
        // The current tab was closed; load whatever is now at the same slot.
        if (current.*) |img| image.destroy(img.texture);
        if (index.* >= tabs.len()) index.* = tabs.len() - 1;
        view.reset();
        if (image.loadImage(renderer, tabs.paths.items[index.*])) |img| {
            current.* = img;
        } else |_| {
            current.* = null;
            return false;
        }
    } else if (target < index.*) {
        index.* -= 1; // a tab before current was removed, shift index left
    }

    setTitle(window, allocator, tabs.paths.items[index.*], index.*, tabs.len(), view.zoom);
    warmNeighbors(tabs, index.*);
    _ = font;
    return true;
}

// Window icon

/// Decode the embedded PNG and hand it to SDL as the window icon.
/// The 64×64 PNG is embedded at compile time via @embedFile
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

//Empty-state rendering

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

/// Draw the placeholder shown when tabs exist but the selected image failed
/// to load (bad file, unsupported format, decode error).
fn renderFailedState(
    renderer: *c.SDL_Renderer,
    window: *c.SDL_Window,
    font: *c.TTF_Font,
    name: []const u8,
) void {
    var win_w: c_int = 0;
    var win_h: c_int = 0;
    c.SDL_GetWindowSize(window, &win_w, &win_h);
    const cx = @divTrunc(win_w, 2);
    const cy = TAB_H + @divTrunc(win_h - TAB_H, 2);

    renderCenteredText(
        renderer,
        font,
        "Could not load this image",
        c.SDL_Color{ .r = 200, .g = 120, .b = 120, .a = 255 },
        cx,
        cy - 14,
    );
    // basename into a null-terminated scratch buffer for TTF.
    var scratch: [512]u8 = undefined;
    const base = basename(name);
    const n = @min(base.len, scratch.len - 1);
    @memcpy(scratch[0..n], base[0..n]);
    scratch[n] = 0;
    renderCenteredText(
        renderer,
        font,
        @ptrCast(&scratch),
        c.SDL_Color{ .r = 120, .g = 120, .b = 120, .a = 255 },
        cx,
        cy + 14,
    );
}

/// Fill `dst` with a subtle checkerboard so transparent pixels read as
/// transparent instead of as dark smudges. Clipped to the image rect so
/// oversized tabs never paint outside the frame.
fn renderCheckerboard(renderer: *c.SDL_Renderer, dst: *const c.SDL_Rect) void {
    var clip = dst.*;
    _ = c.SDL_RenderSetClipRect(renderer, &clip);
    defer _ = c.SDL_RenderSetClipRect(renderer, null);
    const step: c_int = 16;
    var yy: c_int = dst.y;
    var row: c_int = 0;
    while (yy < dst.y + dst.h) : ({
        yy += step;
        row += 1;
    }) {
        var xx: c_int = dst.x;
        var col: c_int = 0;
        while (xx < dst.x + dst.w) : ({
            xx += step;
            col += 1;
        }) {
            const v: u8 = if ((row + col) & 1 == 0) 38 else 48;
            _ = c.SDL_SetRenderDrawColor(renderer, v, v, v, 255);
            var cell = c.SDL_Rect{
                .x = xx,
                .y = yy,
                .w = @min(step, dst.x + dst.w - xx),
                .h = @min(step, dst.y + dst.h - yy),
            };
            _ = c.SDL_RenderFillRect(renderer, &cell);
        }
    }
}

/// Columns in the grid for the current window width. Always >= 1 so a
/// sliver window degrades to a single column instead of dividing by zero.
fn gridColumns(window: *c.SDL_Window) i32 {
    var win_w: c_int = 0;
    c.SDL_GetWindowSize(window, &win_w, null);
    if (win_w < GRID_CELL) return 1;
    return @divTrunc(win_w, GRID_CELL);
}

/// Render the thumbnail grid (#7). Returns the adjusted top row so the
/// selection stays visible after scrolling. Failed thumbnails draw as a
/// dim placeholder box instead of breaking the layout.
fn renderGrid(
    renderer: *c.SDL_Renderer,
    window: *c.SDL_Window,
    font: ?*c.TTF_Font,
    tabs: *Tabs,
    cache: *ThumbCache,
    allocator: std.mem.Allocator,
    index: usize,
    top: usize,
) usize {
    var win_w: c_int = 0;
    var win_h: c_int = 0;
    c.SDL_GetWindowSize(window, &win_w, &win_h);
    const cols: usize = @intCast(gridColumns(window));
    const avail_h = win_h - TAB_H;
    const max_rows: usize = if (avail_h > 0) @intCast(@max(1, @divTrunc(avail_h + GRID_CELL - 1, GRID_CELL))) else 1;

    var new_top = top;
    const sel_row = index / cols;
    if (sel_row < new_top) new_top = sel_row;
    if (sel_row >= new_top + max_rows) new_top = sel_row - max_rows + 1;

    var r: usize = new_top;
    while (true) : (r += 1) {
        const y = TAB_H + @as(i32, @intCast((r - new_top) * @as(usize, @intCast(GRID_CELL))));
        if (y >= win_h) break;
        var cc: usize = 0;
        while (cc < cols) : (cc += 1) {
            const tab = r * cols + cc;
            if (tab >= tabs.len()) break;
            const x: i32 = @intCast(cc * @as(usize, @intCast(GRID_CELL)));
            var cell = c.SDL_Rect{ .x = x, .y = y, .w = GRID_CELL - 8, .h = GRID_CELL - 8 };
            const is_sel = tab == index;
            const bg: u8 = if (is_sel) 70 else 34;
            _ = c.SDL_SetRenderDrawColor(renderer, bg, bg, bg + 8, 255);
            _ = c.SDL_RenderFillRect(renderer, &cell);
            const edge: u8 = if (is_sel) 140 else 70;
            _ = c.SDL_SetRenderDrawColor(renderer, edge, edge, edge, 255);
            _ = c.SDL_RenderDrawRect(renderer, &cell);

            const box: i32 = 144;
            const bx = x + @divTrunc(GRID_CELL - 8 - box, 2);
            const by = y + 8;
            if (cache.getOrLoad(allocator, renderer, tab, tabs.paths.items[tab], index)) |t| {
                var dst = c.SDL_Rect{ .w = t.w, .h = t.h, .x = 0, .y = 0 };
                // Fit thumb inside the box, centered.
                if (t.w > box or t.h > box) {
                    const tr = @as(f32, @floatFromInt(t.w)) / @as(f32, @floatFromInt(t.h));
                    if (tr > 1) {
                        dst.w = box;
                        dst.h = @intFromFloat(@as(f32, @floatFromInt(box)) / tr);
                    } else {
                        dst.h = box;
                        dst.w = @intFromFloat(@as(f32, @floatFromInt(box)) * tr);
                    }
                }
                dst.x = bx + @divTrunc(box - dst.w, 2);
                dst.y = by + @divTrunc(box - dst.h, 2);
                _ = c.SDL_RenderCopy(renderer, t.texture, null, &dst);
            } else {
                var ph = c.SDL_Rect{ .x = bx, .y = by, .w = box, .h = box };
                _ = c.SDL_SetRenderDrawColor(renderer, 60, 50, 50, 255);
                _ = c.SDL_RenderFillRect(renderer, &ph);
                if (font) |f| renderCenteredText(renderer, f, "?", .{ .r = 150, .g = 120, .b = 120, .a = 255 }, bx + @divTrunc(box, 2), by + @divTrunc(box, 2));
            }

            // Label: truncated basename under the thumbnail.
            if (font) |f| {
                const base = basename(std.mem.sliceTo(tabs.paths.items[tab].ptr, 0));
                var scratch: [GRID_LABEL_MAX + 1]u8 = undefined;
                const n = @min(base.len, GRID_LABEL_MAX);
                @memcpy(scratch[0..n], base[0..n]);
                scratch[n] = 0;
                const surf = c.TTF_RenderUTF8_Blended(f, @ptrCast(&scratch), .{ .r = 220, .g = 220, .b = 220, .a = 255 });
                if (surf) |s| {
                    defer c.SDL_FreeSurface(surf);
                    if (c.SDL_CreateTextureFromSurface(renderer, s)) |tex| {
                        defer c.SDL_DestroyTexture(tex);
                        var dst = c.SDL_Rect{
                            .x = x + @divTrunc(GRID_CELL - 8 - s.*.w, 2),
                            .y = y + GRID_CELL - 8 - s.*.h - 4,
                            .w = s.*.w,
                            .h = s.*.h,
                        };
                        if (dst.x < x) dst.x = x;
                        _ = c.SDL_RenderCopy(renderer, tex, null, &dst);
                    }
                }
            }
        }
        if ((r - new_top + 1) >= max_rows) break;
        if ((r + 1) * cols >= tabs.len()) break;
    }
    return new_top;
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

//Entry point

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    image.global_io = io;
    const args = try init.minimal.args.toSlice(allocator);

    //Single-instance handoff
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

    //SDL setup
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
        c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_ALLOW_HIGHDPI,
    ) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.WindowCreateFailed;
    };
    defer c.SDL_DestroyWindow(window);
    setWindowIcon(window);

    // Nicer scaling: linear filtering for the fit-to-window blit. Must be
    // set before textures are created.
    _ = c.SDL_SetHint(c.SDL_HINT_RENDER_SCALE_QUALITY, "2");

    const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED) orelse
        c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_SOFTWARE) orelse {
        std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
        return error.RendererCreateFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    //Zoom/pan view state (reset on every navigation).
    var view: View = .{};
    // Mouse drag-to-pan tracking.
    var panning: bool = false;
    var pan_sx: i32 = 0;
    var pan_sy: i32 = 0;
    var pan_ox: f32 = 0;
    var pan_oy: f32 = 0;

    //Initial tab list
    var tabs: Tabs = .empty;
    for (args[1..]) |p| try tabs.append(allocator, font, p);

    var index: usize = 0;
    var current: ?image.Image = null;
    if (tabs.len() > 0) {
        // Try each tab in order: a bad first file (missing, zero-byte,
        // not-an-image) must not kill startup. First success wins.
        var loaded: ?usize = null;
        for (tabs.paths.items, 0..) |p, i| {
            if (image.loadImage(renderer, p)) |img| {
                current = img;
                loaded = i;
                break;
            } else |_| {}
        }
        if (loaded) |li| {
            index = li;
            setTitle(window, allocator, tabs.paths.items[li], li, tabs.len(), view.zoom);
            warmNeighbors(&tabs, li);
        } else {
            // Nothing decodable: keep the tabs so the user can see what
            // failed, with the first tab selected.
            index = 0;
            setTitle(window, allocator, tabs.paths.items[0], 0, tabs.len(), view.zoom);
        }
    }
    defer image.cleanup();

    //Grid state (#7)
    var grid: bool = false;
    var grid_top: usize = 0;
    var thumbs: ThumbCache = .{};
    defer thumbs.clear();

    //Event / render loop
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
                thumbs.clear(); // indices shifted; drop stale thumbnails
                if (image.loadImage(renderer, tabs.paths.items[old_len])) |img| {
                    if (current) |old| image.destroy(old.texture);
                    current = img;
                    index = old_len;
                    view.reset();
                } else |_| {}
                setTitle(window, allocator, tabs.paths.items[index], index, tabs.len(), view.zoom);
                c.SDL_RaiseWindow(window);
                warmNeighbors(&tabs, index);
            }
        }

        //Input
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => running = false,

                c.SDL_MOUSEBUTTONDOWN => {
                    if (grid and tabs.len() > 0) {
                        // Grid click: select the clicked cell and exit.
                        const cols: usize = @intCast(gridColumns(window));
                        if (event.button.y >= TAB_H) {
                            const cc: usize = @intCast(@divTrunc(event.button.x, GRID_CELL));
                            const rr: usize = grid_top + @as(usize, @intCast(@divTrunc(event.button.y - TAB_H, GRID_CELL)));
                            const tab = rr * cols + cc;
                            if (tab < tabs.len() and tab != index) {
                                if (image.loadImage(renderer, tabs.paths.items[tab])) |img| {
                                    if (current) |old| image.destroy(old.texture);
                                    current = img;
                                    index = tab;
                                    view.reset();
                                    setTitle(window, allocator, tabs.paths.items[tab], tab, tabs.len(), view.zoom);
                                    warmNeighbors(&tabs, tab);
                                } else |_| {}
                            }
                            grid = false;
                        }
                    } else if (event.button.y < TAB_H) {
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
                                _ = closeTabAt(&tabs, &thumbs, &current, &index, &view, i, allocator, renderer, window, font);
                                // Don't exit when the last tab closes — show
                                // the empty state and wait for new handoffs.
                                break;
                            }
                            if (event.button.x >= x and event.button.x < x + tab_w) {
                                if (i != index) {
                                    if (image.loadImage(renderer, tabs.paths.items[i])) |img| {
                                        if (current) |old| image.destroy(old.texture);
                                        current = img;
                                        index = i;
                                        view.reset();
                                        setTitle(window, allocator, tabs.paths.items[i], i, tabs.len(), view.zoom);
                                        warmNeighbors(&tabs, i);
                                    } else |_| {}
                                }
                                break;
                            }
                            x += tab_w;
                        }
                    } else if (event.button.button == c.SDL_BUTTON_LEFT and tabs.len() > 0) {
                        // Begin drag-to-pan in the image area.
                        panning = true;
                        pan_sx = event.button.x;
                        pan_sy = event.button.y;
                        pan_ox = view.ox;
                        pan_oy = view.oy;
                    }
                },

                c.SDL_MOUSEBUTTONUP => {
                    panning = false;
                },

                c.SDL_MOUSEMOTION => {
                    if (panning and !grid and current != null) {
                        if (current) |img| {
                            var win_w: c_int = 0;
                            var win_h: c_int = 0;
                            c.SDL_GetWindowSize(window, &win_w, &win_h);
                            const rs = renderedSize(img, win_w, win_h - TAB_H, view.zoom);
                            view.ox = clampPan(pan_ox + @as(f32, @floatFromInt(event.motion.x - pan_sx)), rs.w);
                            view.oy = clampPan(pan_oy + @as(f32, @floatFromInt(event.motion.y - pan_sy)), rs.h);
                        }
                    }
                },

                c.SDL_MOUSEWHEEL => {
                    // Cursor-anchored zoom: the point under the cursor stays
                    // put while the scale changes around it.
                    if (!grid and tabs.len() > 0) {
                        const steps = event.wheel.y;
                        if (steps != 0) {
                            if (current) |img| {
                                var win_w: c_int = 0;
                                var win_h: c_int = 0;
                                c.SDL_GetWindowSize(window, &win_w, &win_h);
                                const avail_h = win_h - TAB_H;
                                if (win_w > 0 and avail_h > 0) {
                                    var factor: f32 = 1.0;
                                    var s: i32 = 0;
                                    while (s < steps) : (s += 1) factor *= 1.2;
                                    while (s > steps) : (s -= 1) factor /= 1.2;
                                    const new_zoom = @min(32.0, @max(0.1, view.zoom * factor));
                                    const applied = new_zoom / view.zoom;
                                    var mx: c_int = 0;
                                    var my: c_int = 0;
                                    _ = c.SDL_GetMouseState(&mx, &my);
                                    const fmx: f32 = @floatFromInt(mx);
                                    const fmy: f32 = @floatFromInt(my);
                                    const fww: f32 = @floatFromInt(win_w);
                                    const fah: f32 = @floatFromInt(avail_h);
                                    const cx = fww / 2 + view.ox;
                                    const cy = @as(f32, @floatFromInt(TAB_H)) + fah / 2 + view.oy;
                                    view.zoom = new_zoom;
                                    const rs = renderedSize(img, win_w, avail_h, new_zoom);
                                    view.ox = clampPan(fmx - (fmx - cx) * applied - fww / 2, rs.w);
                                    view.oy = clampPan(fmy - (fmy - cy) * applied - (@as(f32, @floatFromInt(TAB_H)) + fah / 2), rs.h);
                                    setTitle(window, allocator, tabs.paths.items[index], index, tabs.len(), view.zoom);
                                }
                            }
                        }
                    }
                },

                c.SDL_KEYDOWN => {
                    const key = event.key.keysym.sym;
                    if (key == c.SDLK_q) {
                        running = false;
                    } else if (key == c.SDLK_g and tabs.len() > 0) {
                        // Toggle the thumbnail grid (#7).
                        grid = !grid;
                        if (grid) {
                            const cols: usize = @intCast(gridColumns(window));
                            grid_top = index / cols;
                        }
                    } else if (grid and key == c.SDLK_ESCAPE) {
                        grid = false;
                    } else if (grid) {
                        // Grid navigation: arrows move the live selection,
                        // Enter/Space confirm (selection is already live).
                        const cols: usize = @intCast(gridColumns(window));
                        const new_index: ?usize =
                            if ((key == c.SDLK_RIGHT or key == c.SDLK_d) and index + 1 < tabs.len())
                                index + 1
                            else if ((key == c.SDLK_LEFT or key == c.SDLK_a) and index > 0)
                                index - 1
                            else if ((key == c.SDLK_DOWN or key == c.SDLK_SPACE) and index + cols < tabs.len())
                                index + cols
                            else if (key == c.SDLK_UP and index >= cols)
                                index - cols
                            else if (key == c.SDLK_RETURN or key == c.SDLK_KP_ENTER)
                                index
                            else
                                null;

                        if (new_index) |ni| {
                            if (ni != index) {
                                if (image.loadImage(renderer, tabs.paths.items[ni])) |img| {
                                    if (current) |old| image.destroy(old.texture);
                                    current = img;
                                    index = ni;
                                    view.reset();
                                    setTitle(window, allocator, tabs.paths.items[ni], ni, tabs.len(), view.zoom);
                                    warmNeighbors(&tabs, ni);
                                } else |_| {}
                            }
                            if (key == c.SDLK_RETURN or key == c.SDLK_KP_ENTER or key == c.SDLK_SPACE) grid = false;
                        }
                    } else if ((key == c.SDLK_PLUS or key == c.SDLK_EQUALS or key == c.SDLK_KP_PLUS or
                        key == c.SDLK_MINUS or key == c.SDLK_UNDERSCORE or key == c.SDLK_KP_MINUS or
                        key == c.SDLK_0 or key == c.SDLK_KP_0 or
                        key == c.SDLK_1 or key == c.SDLK_KP_1) and tabs.len() > 0)
                    {
                        // Keyboard zoom: + in, - out, 0 fit, 1 actual size.
                        if (current) |img| {
                            var win_w: c_int = 0;
                            var win_h: c_int = 0;
                            c.SDL_GetWindowSize(window, &win_w, &win_h);
                            const avail_h = win_h - TAB_H;
                            if (win_w > 0 and avail_h > 0 and img.w > 0 and img.h > 0) {
                                if (key == c.SDLK_PLUS or key == c.SDLK_EQUALS or key == c.SDLK_KP_PLUS) {
                                    view.zoom = @min(32.0, view.zoom * 1.25);
                                } else if (key == c.SDLK_MINUS or key == c.SDLK_UNDERSCORE or key == c.SDLK_KP_MINUS) {
                                    view.zoom = @max(0.1, view.zoom / 1.25);
                                } else if (key == c.SDLK_0 or key == c.SDLK_KP_0) {
                                    view.reset();
                                } else {
                                    // Actual size: rendered pixels == image pixels.
                                    const swapped = img.orientation >= 5;
                                    const ew: i32 = if (swapped) img.h else img.w;
                                    const eh: i32 = if (swapped) img.w else img.h;
                                    const fit = fitDims(ew, eh, win_w, avail_h);
                                    view.zoom = @min(32.0, @max(0.1, @as(f32, @floatFromInt(ew)) / @as(f32, @floatFromInt(fit.w))));
                                    view.ox = 0;
                                    view.oy = 0;
                                }
                                const rs = renderedSize(img, win_w, avail_h, view.zoom);
                                view.ox = clampPan(view.ox, rs.w);
                                view.oy = clampPan(view.oy, rs.h);
                                setTitle(window, allocator, tabs.paths.items[index], index, tabs.len(), view.zoom);
                            }
                        }
                    } else if (key == c.SDLK_ESCAPE) {
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
                                if (current) |old| image.destroy(old.texture);
                                current = img;
                                index = ni;
                                view.reset();
                                setTitle(window, allocator, tabs.paths.items[ni], ni, tabs.len(), view.zoom);
                                warmNeighbors(&tabs, ni);
                            } else |_| {}
                        }
                    }
                },

                else => {},
            }
        }

        //Render
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

        if (grid and tabs.len() > 0) {
            grid_top = renderGrid(renderer, window, font, &tabs, &thumbs, allocator, index, grid_top);
        } else if (current == null) {
            if (font) |f| {
                if (tabs.len() > 0) {
                    renderFailedState(renderer, window, f, std.mem.sliceTo(tabs.paths.items[index].ptr, 0));
                } else {
                    renderEmptyState(renderer, window, f);
                }
            }
        } else if (current) |img| {
            var win_w: c_int = 0;
            var win_h: c_int = 0;
            c.SDL_GetWindowSize(window, &win_w, &win_h);
            const avail_h = win_h - TAB_H;
            // Minimized or sliver windows report zero/negative space.
            // Skip the blit instead of dividing by zero (#2).
            if (win_w > 0 and avail_h > 0 and img.w > 0 and img.h > 0) {
                const rs = renderedSize(img, win_w, avail_h, view.zoom);
                var dst: c.SDL_Rect = undefined;
                dst.w = rs.w;
                dst.h = rs.h;
                // Center, plus the pan offset. Oversized (zoomed-in) rects
                // are clipped by SDL and the checkerboard clip.
                dst.x = @divTrunc(win_w - dst.w, 2) + @as(i32, @intFromFloat(view.ox));
                dst.y = TAB_H + @divTrunc(avail_h - dst.h, 2) + @as(i32, @intFromFloat(view.oy));
                if (dst.w > 0 and dst.h > 0) {
                    renderCheckerboard(renderer, &dst);
                    // EXIF orientation at render time (#6): a viewer rotates
                    // the blit instead of rewriting pixels. Angle/flip per
                    // the 8 EXIF values; transpose cases were pre-swapped
                    // into dst above.
                    const center = c.SDL_Point{ .x = @divTrunc(dst.w, 2), .y = @divTrunc(dst.h, 2) };
                    switch (img.orientation) {
                        2 => _ = c.SDL_RenderCopyEx(renderer, img.texture, null, &dst, 0, &center, c.SDL_FLIP_HORIZONTAL),
                        3 => _ = c.SDL_RenderCopyEx(renderer, img.texture, null, &dst, 180, &center, c.SDL_FLIP_NONE),
                        4 => _ = c.SDL_RenderCopyEx(renderer, img.texture, null, &dst, 0, &center, c.SDL_FLIP_VERTICAL),
                        5 => _ = c.SDL_RenderCopyEx(renderer, img.texture, null, &dst, 90, &center, c.SDL_FLIP_HORIZONTAL),
                        6 => _ = c.SDL_RenderCopyEx(renderer, img.texture, null, &dst, 90, &center, c.SDL_FLIP_NONE),
                        7 => _ = c.SDL_RenderCopyEx(renderer, img.texture, null, &dst, 90, &center, c.SDL_FLIP_VERTICAL),
                        8 => _ = c.SDL_RenderCopyEx(renderer, img.texture, null, &dst, 270, &center, c.SDL_FLIP_NONE),
                        else => _ = c.SDL_RenderCopy(renderer, img.texture, null, &dst),
                    }
                    _ = c.SDL_SetRenderDrawColor(renderer, 80, 80, 80, 255);
                    _ = c.SDL_RenderDrawRect(renderer, &dst);
                }
            }
        }

        c.SDL_RenderPresent(renderer);
    }

    if (current) |img| image.destroy(img.texture);
    std.debug.print("texture counter at shutdown: {d} (expect 0)\n", .{image.textureCount()});
}
