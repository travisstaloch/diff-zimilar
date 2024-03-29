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

    _ = b.addModule("diff-zimilar", .{
        .source_file = .{ .path = "src/lib.zig" },
    });

    const lib = b.addStaticLibrary(.{
        .name = "diff-zimilar",
        .root_source_file = .{ .path = "src/lib.zig" },
        .target = target,
        .optimize = optimize,
    });
    lib.addOptions("build_options", build_options);
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "diffit",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addOptions("build_options", build_options);
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_filter = b.option([]const u8, "test-filter", "test filter");

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/tests.zig" },
        .target = target,
        .optimize = optimize,
    });
    main_tests.filter = test_filter;

    const test_step = b.step("test", "Run library tests");
    const main_tests_run = b.addRunArtifact(main_tests);
    main_tests_run.has_side_effects = true;
    test_step.dependOn(&main_tests_run.step);
}
