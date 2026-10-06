const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.linkSystemLibrary("SDL2", .{});
    mod.linkSystemLibrary("SDL2_ttf", .{});
    mod.linkSystemLibrary("turbojpeg", .{});
    mod.linkSystemLibrary("webp", .{});
    mod.addIncludePath(b.path("src"));
    // Full stb_image format set (PNG, JPEG, BMP, GIF, TGA, PSD, HDR...).
    // Dispatch in image.zig is by magic bytes, not extension, so every
    // compiled-in decoder is reachable.
    mod.addCSourceFile(.{ .file = b.path("src/stb_image_impl.c"), .flags = &.{} });

    const exe = b.addExecutable(.{
        .name = "imgv",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run imgv");
    run_step.dependOn(&run_cmd.step);

    // Wayland shm spike (branch-only): raw wl_shm window, no SDL.
    // `zig build spike` compiles it; the main imgv build above is
    // untouched by the wayland dependency.
    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 7);
    scanner.generate("xdg_wm_base", 3);
    const wayland_mod = b.createModule(.{ .root_source_file = scanner.result });

    const spike_mod = b.createModule(.{
        .root_source_file = b.path("src/spike/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    spike_mod.addImport("wayland", wayland_mod);
    spike_mod.linkSystemLibrary("wayland-client", .{});
    spike_mod.addIncludePath(b.path("src"));
    spike_mod.addCSourceFile(.{ .file = b.path("src/stb_image_impl.c"), .flags = &.{} });

    const spike = b.addExecutable(.{
        .name = "shm-spike",
        .root_module = spike_mod,
    });
    const spike_step = b.step("spike", "Build the Wayland shm spike");
    spike_step.dependOn(&b.addInstallArtifact(spike, .{}).step);
}
