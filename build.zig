const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Create the module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 2. Link Frameworks to the MODULE (New API)
    // We pass .{} because the third argument 'options' is mandatory now
    root_module.linkFramework("Foundation", .{});
    root_module.linkFramework("Metal", .{});
    root_module.linkFramework("AppKit", .{});
    root_module.linkSystemLibrary("objc", .{});

    // 3. Create the executable using the module
    const exe = b.addExecutable(.{
        .name = "Zetal",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .root_module = root_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
