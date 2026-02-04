const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ============================================================
    // 1. THE LIBRARY (src/root.zig)
    // ============================================================
    // This is the actual graphics library you are building.
    const mod = b.addModule("metal_graphics_lib", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // LINKING: The library needs Metal to work.
    // Anyone who imports this module will inherit these links.
    mod.linkFramework("Metal", .{});
    mod.linkFramework("Foundation", .{});
    mod.linkSystemLibrary("objc", .{}); // <--- Changed to linkSystemLibrary

    // ============================================================
    // 2. THE EXECUTABLE (src/main.zig)
    // ============================================================
    // This is the CLI tool/demo that uses your library.
    const exe = b.addExecutable(.{
        .name = "metal_graphics_lib",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                // This allows main.zig to do: @import("metal_graphics_lib")
                .{ .name = "metal_graphics_lib", .module = mod },
            },
        }),
    });

    // We also link Metal to the exe directly, in case you write
    // raw Metal code inside main.zig instead of importing it.
    exe.root_module.linkFramework("Metal", .{});
    exe.root_module.linkFramework("Foundation", .{});
    exe.root_module.linkSystemLibrary("objc", .{});

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
    // 4. TESTS
    // ============================================================

    // Test the Library (src/root.zig)
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    // Note: mod_tests shares 'mod', so it already has Metal linked!

    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Test the Executable (src/main.zig)
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
