const std = @import("std");

// --- Objective-C Runtime Bindings ---
const objc = struct {
    extern "c" fn objc_msgSend(self: ?*anyopaque, op: ?*anyopaque, ...) ?*anyopaque;
    extern "c" fn sel_registerName(str: [*:0]const u8) ?*anyopaque;

    fn getSelector(name: [:0]const u8) ?*anyopaque {
        return sel_registerName(name);
    }
};

extern "Metal" fn MTLCreateSystemDefaultDevice() ?*anyopaque;

pub fn main() !void {
    std.debug.print("Initializing Zetal Engine...\n", .{});

    // 1. Ask macOS for the default GPU (Apple Silicon)
    const device = MTLCreateSystemDefaultDevice();

    if (device == null) {
        std.debug.print("ERROR: Failed to create Metal Device (Are you on macOS?)\n", .{});
    }
    std.debug.print("SUCCESS: Metal Device Found: {any}\n", .{device});

    // Create the Command Queue
    // Objective-C equivalent: [device newCommandQueue];
    const sel = objc.getSelector("newCommandQueue");
    const queue = objc.objc_msgSend(device, sel);

    if (queue) |q| {
        std.debug.print("SUCCESS: Command Queue Created: {any}\n", .{q});
    } else {
        std.debug.print("ERROR: Failed to create Command Queue\n", .{});
    }
}
