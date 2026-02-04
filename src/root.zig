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

    // 2. Define signature: (self, op, bytes, len, encoding)
    const InitFn = *const fn (?*anyopaque, ?*anyopaque, [*]const u8, usize, u64) callconv(.c) ?*anyopaque;
    const init_msg_send: InitFn = @ptrCast(&objc_msgSend);

    // 3. Call (4 is UTF-8)
    return init_msg_send(raw_obj, init_sel, content.ptr, content.len, 4);
}

/// Represents a 3D size (width, height, depth).
/// Used for defining a threadgroup grids.
pub const MTLSize = extern struct {
    width: u64,
    height: u64,
    depth: u64,
};

/// A handle to a specific function (shader) inside a library.
pub const MetalFunction = struct {
    handle: *anyopaque,
};

/// A compiled pipeline state ready for execution.
pub const MetalComputePipelineState = struct {
    handle: *anyopaque,
};

/// The object used to encode commads for a compute pass
pub const MetalComputeCommandEncoder = struct {
    handle: *anyopaque,

    /// Sets the pipeline stats (the shader to run).
    pub fn setComputePipelineState(self: MetalComputeCommandEncoder, state: MetalComputePipelineState) void {
        const sel = sel_registerName("setComputePipelineState:");

        const SetPipeLineFn = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void;
        const msg_send: SetPipeLineFn = @ptrCast(&objc_msgSend);

        msg_send(self.handle, sel, state.handle);
    }

    /// Dispatches the threads.
    /// Note: On ARM64, structs > 16 bytes (like MTLSize, which is 24) are passed by pointer implicitly
    /// in the C ABI, but we define them by value here and let Zig/LLVM handle the ABI lowerng.
    pub fn dispatchThreadgroups(self: MetalComputeCommandEncoder, threadgroups: MTLSize, threadsPerThreadgroup: MTLSize) void {
        const sel = sel_registerName("dispatchThreadgroups:threadsPerThreadgroup:");

        const DispatchFn = *const fn (?*anyopaque, ?*anyopaque, MTLSize, MTLSize) callconv(.c) void;
        const msg_send: DispatchFn = @ptrCast(&objc_msgSend);

        msg_send(self.handle, sel, threadgroups, threadsPerThreadgroup);
    }

    /// Declares that all commands for this encoder have been recorded
    pub fn endEncoding(self: MetalComputeCommandEncoder) void {
        const sel = sel_registerName("endEncoding");
        _ = objc_msgSend(self.handle, sel);
    }
};

/// A wrapper around a compiled Metal Library.
pub const MetalLibrary = struct {
    handle: *anyopaque,

    /// Retrieves a function by name from the library.
    pub fn getFunction(self: MetalLibrary, name: []const u8) ?MetalFunction {
        const ns_name = createNSString(name);
        if (ns_name == null) return null;

        const sel = sel_registerName("newFunctionWithName:");

        // STRICT CASTING
        const NewFuncFn = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
        const new_func_msg_send: NewFuncFn = @ptrCast(&objc_msgSend);

        const raw_func = new_func_msg_send(self.handle, sel, ns_name);

        if (raw_func) |f| {
            return MetalFunction{ .handle = f };
        }
        return null;
    }
};

pub const MetalCommandBuffer = struct {
    handle: *anyopaque,

    /// Creates a compute encoder to write commands into this buffer
    pub fn createComputeCommandEncoder(self: MetalCommandBuffer) ?MetalComputeCommandEncoder {
        const sel = sel_registerName("computeCommandEncoder");
        const raw_encoder = objc_msgSend(self.handle, sel);

        if (raw_encoder) |enc| {
            return MetalComputeCommandEncoder{ .handle = enc };
        }
        return null;
    }

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

    pub fn createLibrary(self: MetalDevice, source: []const u8) ?MetalLibrary {
        const ns_source = createNSString(source);
        if (ns_source == null) return null;

        const lib_sel = sel_registerName("newLibraryWithSource:options:error:");

        // Define signature: (self, op, source, options, error)
        const NewLibFn = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
        const new_lib_msg_send: NewLibFn = @ptrCast(&objc_msgSend);

        const raw_lib = new_lib_msg_send(self.handle, lib_sel, ns_source, null, null);

        if (raw_lib) |lib| {
            return MetalLibrary{ .handle = lib };
        }
        return null;
    }

    /// Creates a Compute Pipeline State from a Function.
    /// This is an expensive operation (compiles machine code for the GPU).
    pub fn createComputePipelineState(self: MetalDevice, func: MetalFunction) ?MetalComputePipelineState {
        const sel = sel_registerName("newComputePipelineStateWithFunction:error:");

        // Define signature: (self, op, function, error) -> pipelineState
        const NewPipelineFn = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
        const pipeline_msg_send: NewPipelineFn = @ptrCast(&objc_msgSend);

        const raw_pipeline = pipeline_msg_send(self.handle, sel, func.handle, null);

        if (raw_pipeline) |p| {
            return MetalComputePipelineState{ .handle = p };
        }
        return null;
    }
};

// --- Library Tests ---
test "Full GPU Lifecycle: Dispatch a Thread" {
    const device = MetalDevice.createSystemDefault().?;
    std.debug.print("\n    > GPU: {s}\n", .{device.getName().?});

    // 1. Setup Pipeline
    const shader_src =
        \\ #include <metal_stdlib>
        \\ using namespace metal;
        \\ kernel void compute_main() { /* Hello from GPU */ }
    ;
    const library = device.createLibrary(shader_src).?;
    const func = library.getFunction("compute_main").?;
    const pipeline = device.createComputePipelineState(func).?;
    std.debug.print("    > Pipeline Ready.\n", .{});

    // 2. Setup Command Stream
    const queue = device.createCommandQueue().?;
    const buffer = queue.createCommandBuffer().?;

    // 3. Encode Commands
    const encoder = buffer.createComputeCommandEncoder().?;
    encoder.setComputePipelineState(pipeline);

    // Dispatch 1 threadgroup with 1 thread (1x1x1)
    const grid_size = MTLSize{ .width = 1, .height = 1, .depth = 1 };
    const threadgroup_size = MTLSize{ .width = 1, .height = 1, .depth = 1 };

    encoder.dispatchThreadgroups(grid_size, threadgroup_size);
    encoder.endEncoding();
    std.debug.print("    > Commands Encoded.\n", .{});

    // 4. Submit
    buffer.commit();
    buffer.waitUntilCompleted();

    std.debug.print("    > Execution Finished Successfully!\n", .{});
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
        \\ kernel void compute_main() { /* Do nothing */ }
    ;

    // Compile Library
    const library = device.createLibrary(shader_src).?;
    std.debug.print("    > Library compiled.\n", .{});

    // Get Function
    const func = library.getFunction("compute_main");
    try std.testing.expect(func != null);
    std.debug.print("    > Function 'compute_main' found,\n", .{});

    // Create Pipeline State
    const pipeline = device.createComputePipelineState(func.?);
    try std.testing.expect(pipeline != null);
    std.debug.print("    > Compute Pipeline State created! Ready to dispatch.\n", .{});
}
