const std = @import("std");

// --- Internal Objective-C Runtime Bindings ---
extern "c" fn sel_registerName(name: [*]const u8) ?*anyopaque;
extern "c" fn objc_msgSend(self: ?*anyopaque, op: ?*anyopaque, ...) ?*anyopaque;
extern "c" fn MTLCreateSystemDefaultDevice() ?*anyopaque;

/// A container for GPU commands.
/// You create this, encode commands into it, and then "commit" it to the queue.
pub const MetalCommandBuffer = struct {
    handle: *anyopaque,

    /// Submits this buffer to the GPU for execution.
    pub fn commit(self: MetalCommandBuffer) void {
        const sel = sel_registerName("commit");
        _ = objc_msgSend(self.handle, sel);
    }

    /// Blocks the CPU thread until the GPU has finished executing this buffer.
    /// (Useful for scripts/tests, but avoid this in high-performance render loops!)
    pub fn waitUntilCompleted(self: MetalCommandBuffer) void {
        const sel = sel_registerName("waitUntilCompleted");
        _ = objc_msgSend(self.handle, sel);
    }
};

/// A wrapper around the Metal Command Queue.
pub const MetalCommandQueue = struct {
    handle: *anyopaque,

    /// Creates a lightweight command buffer for a single frame of work.
    pub fn createCommandBuffer(self: MetalCommandQueue) ?MetalCommandBuffer {
        // Selector: "commandBuffer"
        const sel = sel_registerName("commandBuffer");
        const raw_buffer = objc_msgSend(self.handle, sel);

        if (raw_buffer) |buf| {
            return MetalCommandBuffer{ .handle = buf };
        }
        return null;
    }
};

/// A wrapper around the Metal Device Object (The GPU).
pub const MetalDevice = struct {
    handle: *anyopaque,

    pub fn createSystemDefault() ?MetalDevice {
        const raw_ptr = MTLCreateSystemDefaultDevice();
        if (raw_ptr) |ptr| {
            return MetalDevice{ .handle = ptr };
        }
        return null;
    }

    pub fn getName(self: MetalDevice) ?[]const u8 {
        const name_sel = sel_registerName("name");
        const ns_string = objc_msgSend(self.handle, name_sel);

        if (ns_string) |str| {
            const utf8_sel = sel_registerName("UTF8String");
            const utf8_ptr = objc_msgSend(str, utf8_sel);
            if (utf8_ptr) |ptr| {
                return std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
            }
        }
        return null;
    }

    pub fn createCommandQueue(self: MetalDevice) ?MetalCommandQueue {
        const queue_sel = sel_registerName("newCommandQueue");
        const raw_queue = objc_msgSend(self.handle, queue_sel);

        if (raw_queue) |q| {
            return MetalCommandQueue{ .handle = q };
        }
        return null;
    }
};

// --- Library Tests ---
test "Full GPU Lifecycle: Device -> Queue -> Buffer -> Commit" {
    // 1. Get Device
    const device = MetalDevice.createSystemDefault().?;
    std.debug.print("\n    > GPU: {s}\n", .{device.getName().?});

    // 2. Get Queue
    const queue = device.createCommandQueue().?;
    std.debug.print("    > Queue created.\n", .{});

    // 3. Create Buffer (The Envelope)
    const buffer = queue.createCommandBuffer().?;
    std.debug.print("    > Buffer created. Committing...\n", .{});

    // 4. Commit and Wait (Send to GPU and wait for receipt)
    buffer.commit();
    buffer.waitUntilCompleted();

    std.debug.print("    > GPU finished execution. Success!\n", .{});
}
