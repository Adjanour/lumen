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
    mod.addIncludePath(b.path("src"));
    mod.addCSourceFile(.{ .file = b.path("src/stb_image_impl.c"), .flags = &.{ "-DSTBI_ONLY_JPEG", "-DSTBI_ONLY_PNG" } });

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
