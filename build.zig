const std = @import("std");

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
}
