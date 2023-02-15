const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const log_level = b.option(
        std.log.Level,
        "log-level",
        "The log level for the application. default .err",
    ) orelse .err;
    const build_options = b.addOptions();
    build_options.addOption(std.log.Level, "log_level", log_level);

    const lib = b.addStaticLibrary(.{
        .name = "diff-zimilar",
        .root_source_file = .{ .path = "src/lib.zig" },
        .target = target,
        .optimize = optimize,
    });
    lib.addOptions("build_options", build_options);
    lib.install();

    const test_filter = b.option([]const u8, "test-filter", "test filter");

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/tests.zig" },
        .target = target,
        .optimize = optimize,
    });
    main_tests.setFilter(test_filter);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
