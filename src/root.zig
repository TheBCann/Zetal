const std = @import("std");

// --- Internal Objective-C Runtime Bindings ---
extern "c" fn objc_getClass(name: [*]const u8) ?*anyopaque;
extern "c" fn sel_registerName(name: [*]const u8) ?*anyopaque;
extern "c" fn objc_msgSend(self: ?*anyopaque, op: ?*anyopaque, ...) ?*anyopaque;
extern "c" fn MTLCreateSystemDefaultDevice() ?*anyopaque;

/// Internal helper to create an NSString from a Zig slice
fn createNSString(content: []const u8) ?*anyopaque {
    const ns_string_class = objc_getClass("NSString");
    if (ns_string_class == null) return null;

    const alloc_sel = sel_registerName("alloc");
    const init_sel = sel_registerName("initWithBytes:length:encoding:");

    // 1. Allocate
    const raw_obj = objc_msgSend(ns_string_class, alloc_sel);

    // 2. Define the exact function signature for the init method
    //    args: (self, op, bytes, len, encoding)
    const InitFn = *const fn (?*anyopaque, ?*anyopaque, [*]const u8, usize, u64) callconv(.c) ?*anyopaque;

    // 3. Cast objc_msgSend to this signature
    //    We use @ptrCast to tell Zig: "Treat this address as a function with THESE arguments"
    const init_msg_send: InitFn = @ptrCast(&objc_msgSend);

    // 4. Call the typed function
    //    4 is NSUTF8StringEncoding
    return init_msg_send(raw_obj, init_sel, content.ptr, content.len, 4);
}

/// A wrapper around a compiled Metal Library (a collection of shaders).
pub const MetalLibrary = struct {
    handle: *anyopaque,

    // In the future, we will add getFunction() here
};

pub const MetalCommandBuffer = struct {
    handle: *anyopaque,

    pub fn commit(self: MetalCommandBuffer) void {
        const sel = sel_registerName("commit");
        _ = objc_msgSend(self.handle, sel);
    }

    pub fn waitUntilCompleted(self: MetalCommandBuffer) void {
        const sel = sel_registerName("waitUntilCompleted");
        _ = objc_msgSend(self.handle, sel);
    }
};

pub const MetalCommandQueue = struct {
    handle: *anyopaque,

    pub fn createCommandBuffer(self: MetalCommandQueue) ?MetalCommandBuffer {
        const sel = sel_registerName("commandBuffer");
        const raw_buffer = objc_msgSend(self.handle, sel);

        if (raw_buffer) |buf| {
            return MetalCommandBuffer{ .handle = buf };
        }
        return null;
    }
};

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

    /// Compiles a source string (MSL) into a Library.
    pub fn createLibrary(self: MetalDevice, source: []const u8) ?MetalLibrary {
        // 1. Convert Zig string -> NSString
        const ns_source = createNSString(source);
        if (ns_source == null) return null;

        // 2. Prepare selector
        const lib_sel = sel_registerName("newLibraryWithSource:options:error:");

        // 3. Define the exact function signature
        //    args: (self, op, source, options, error)
        const NewLibFn = *const fn (
            ?*anyopaque,
            ?*anyopaque,
            ?*anyopaque,
            ?*anyopaque,
            ?*anyopaque,
        ) callconv(.c) ?*anyopaque;

        // 4. Cast objc_msgSend
        const new_lib_msg_send: NewLibFn = @ptrCast(&objc_msgSend);

        // 5. Call
        const raw_lib = new_lib_msg_send(self.handle, lib_sel, ns_source, null, null);

        if (raw_lib) |lib| {
            return MetalLibrary{ .handle = lib };
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

test "Compile Basic Shader" {
    const device = MetalDevice.createSystemDefault().?;
    std.debug.print("\n    > GPU: {s}\n", .{device.getName().?});

    // Simple MSL Shader Source
    // This doesn't do anything useful yet, but it's valid code.
    const shader_src =
        \\ #include <metal_stdlib>
        \\ using namespace metal;
        \\ 
        \\ kernel void compute_main() {
        \\     // Do nothing
        \\ }
    ;

    const library = device.createLibrary(shader_src);
    try std.testing.expect(library != null);

    std.debug.print("    > Successfully compiled MSL shader!\n", .{});
}
