const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("sqlite", .{
        .root_source_file = b.path("index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.linkSystemLibrary("sqlite3", .{});

    const test_lib = b.addTest(.{
        .root_module = module,
    });
    const run_tests = b.addRunArtifact(test_lib);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
