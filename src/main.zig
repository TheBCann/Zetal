const std = @import("std");
const Io = std.Io;

const metal = @import("metal_graphics_lib");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.print("Initializing Metal...\n", .{});

    const device = metal.MetalDevice.MTLCreateSystemDefaultDevice();

    if (device) |dev| {
        if (dev.getName()) |name| {
            try stdout.print("Success! Running on: {s}\n", .{name});
        } else {
            try stdout.print("Got device, but failed to retrieve name.\n", .{});
        }
    } else {
        try stdout.print("Failed to access Metal Device.\n", .{});
    }

    try stdout.flush();
}

test "app can import library" {
    // 1. Verify library types are accessible
    const device = metal.MetalDevice.createSystemDefault();

    // 2. If on mac, this must succeed
    try std.testing.expect(device != null);

    if (device) |dev| {
        // 3. Verufy we can call library methods
        const name = dev.getName();
        try std.testing.expect(name != null);

        std.debug.print("[Integration Test] App successfully connected to: {s}\n", .{name.?});
    }
}
