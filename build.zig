const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ============================================================
    // 1. THE LIBRARY (Zetal Engine)
    //    Powered by src/root.zig
    // ============================================================
    const zetal_lib = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link System Frameworks to the Library
    zetal_lib.linkFramework("Foundation", .{});
    zetal_lib.linkFramework("Metal", .{});
    zetal_lib.linkFramework("AppKit", .{});
    zetal_lib.linkSystemLibrary("objc", .{});

    // ============================================================
    // 2. THE APP (Game Demo)
    //    Powered by src/main.zig
    // ============================================================

    // Create a module for the app executable
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Import the Zetal library so main.zig can do: @import("Zetal")
    app_mod.addImport("Zetal", zetal_lib);

    const exe = b.addExecutable(.{
        .name = "Zetal",
        .root_module = app_mod,
    });

    b.installArtifact(exe);

    // ============================================================
    // 3. RUN STEP
    // ============================================================
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // ============================================================
    // 4. TEST STEP
    // ============================================================
    const unit_tests = b.addTest(.{
        .root_module = zetal_lib, // Run tests on the library module
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
