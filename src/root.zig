const std = @import("std");
pub const objc = @import("objc.zig");
pub const window = @import("window.zig");
pub const render = @import("render/root.zig");

// --- Metal C-Bindings ---
extern "Metal" fn MTLCreateSystemDefaultDevice() ?*anyopaque;

// --- Helper Types ---
pub const MTLSize = extern struct {
    width: u64,
    height: u64,
    depth: u64,
};

pub const MTLResourceOptions = enum(u64) {
    StorageModeShared = 0,
};

// --- Public Engine API ---

pub const MetalFunction = struct {
    handle: objc.Object,
};

pub const MetalComputePipelineState = struct {
    handle: objc.Object,
};

pub const MetalBuffer = struct {
    handle: objc.Object,

    /// Returns a raw pointer to the memory (CPU-side).
    pub fn contents(self: MetalBuffer) *anyopaque {
        const sel = objc.getSelector("contents");
        const ContentsFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) *anyopaque;
        const msg_send: ContentsFn = @ptrCast(&objc.objc_msgSend);
        return msg_send(self.handle, sel);
    }
};

pub const MetalComputeCommandEncoder = struct {
    handle: objc.Object,

    pub fn setComputePipelineState(self: MetalComputeCommandEncoder, state: MetalComputePipelineState) void {
        const sel = objc.getSelector("setComputePipelineState:");
        const SetPipeLineFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
        const msg_send: SetPipeLineFn = @ptrCast(&objc.objc_msgSend);
        msg_send(self.handle, sel, state.handle);
    }

    pub fn setBuffer(self: MetalComputeCommandEncoder, buffer: MetalBuffer, offset: u64, index: u64) void {
        const sel = objc.getSelector("setBuffer:offset:atIndex:");
        const SetBufFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object, u64, u64) callconv(.c) void;
        const msg_send: SetBufFn = @ptrCast(&objc.objc_msgSend);
        msg_send(self.handle, sel, buffer.handle, offset, index);
    }

    pub fn dispatchThreadgroups(self: MetalComputeCommandEncoder, threadgroups: MTLSize, threadsPerThreadgroup: MTLSize) void {
        const sel = objc.getSelector("dispatchThreadgroups:threadsPerThreadgroup:");
        const DispatchFn = *const fn (?objc.Object, ?objc.Selector, MTLSize, MTLSize) callconv(.c) void;
        const msg_send: DispatchFn = @ptrCast(&objc.objc_msgSend);
        msg_send(self.handle, sel, threadgroups, threadsPerThreadgroup);
    }

    pub fn endEncoding(self: MetalComputeCommandEncoder) void {
        const sel = objc.getSelector("endEncoding");
        _ = objc.objc_msgSend(self.handle, sel);
    }
};

pub const MetalLibrary = struct {
    handle: objc.Object,

    pub fn getFunction(self: MetalLibrary, name: [:0]const u8) ?MetalFunction {
        // We now use the helper from objc.zig
        const ns_name = objc.createNSString(name);
        if (ns_name == null) return null;

        const sel = objc.getSelector("newFunctionWithName:");
        const NewFuncFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) ?objc.Object;
        const new_func_msg_send: NewFuncFn = @ptrCast(&objc.objc_msgSend);
        const raw_func = new_func_msg_send(self.handle, sel, ns_name);

        if (raw_func) |f| return MetalFunction{ .handle = f };
        return null;
    }
};

pub const MetalCommandBuffer = struct {
    handle: objc.Object,

    pub fn createComputeCommandEncoder(self: MetalCommandBuffer) ?MetalComputeCommandEncoder {
        const sel = objc.getSelector("computeCommandEncoder");
        const raw_encoder = objc.objc_msgSend(self.handle, sel);
        if (raw_encoder) |enc| return MetalComputeCommandEncoder{ .handle = enc };
        return null;
    }

    pub fn createRenderCommandEncoder(self: MetalCommandBuffer, desc: render.MetalRenderPassDescriptor) ?render.MetalRenderCommandEncoder {
        const sel = objc.getSelector("renderCommandEncoderWithDescriptor:");
        const CreateFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) ?objc.Object;
        const msg: CreateFn = @ptrCast(&objc.objc_msgSend);
        const ptr = msg(self.handle, sel, desc.handle);
        if (ptr) |p| return render.MetalRenderCommandEncoder{ .handle = p };
        return null;
    }

    pub fn presentDrawable(self: MetalCommandBuffer, drawable: objc.Object) void {
        const sel = objc.getSelector("presentDrawable:");
        const PresFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
        const msg: PresFn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, drawable);
    }

    pub fn commit(self: MetalCommandBuffer) void {
        const sel = objc.getSelector("commit");
        _ = objc.objc_msgSend(self.handle, sel);
    }

    pub fn waitUntilCompleted(self: MetalCommandBuffer) void {
        const sel = objc.getSelector("waitUntilCompleted");
        _ = objc.objc_msgSend(self.handle, sel);
    }
};

pub const MetalCommandQueue = struct {
    handle: objc.Object,

    pub fn createCommandBuffer(self: MetalCommandQueue) ?MetalCommandBuffer {
        const sel = objc.getSelector("commandBuffer");
        const raw_buffer = objc.objc_msgSend(self.handle, sel);
        if (raw_buffer) |buf| return MetalCommandBuffer{ .handle = buf };
        return null;
    }
};

pub const MetalDevice = struct {
    handle: *anyopaque,

    pub fn createSystemDefault() ?MetalDevice {
        const ptr = MTLCreateSystemDefaultDevice();
        if (ptr) |p| return MetalDevice{ .handle = p };
        return null;
    }

    pub fn getName(self: MetalDevice) ?[]const u8 {
        const name_sel = objc.getSelector("name");
        const ns_string = objc.objc_msgSend(self.handle, name_sel);

        if (ns_string) |str| {
            const utf8_sel = objc.getSelector("UTF8String");
            const utf8_ptr = objc.objc_msgSend(str, utf8_sel);
            if (utf8_ptr) |ptr| {
                return std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
            }
        }
        return null;
    }

    pub fn createCommandQueue(self: MetalDevice) ?MetalCommandQueue {
        const sel = objc.getSelector("newCommandQueue");
        const raw = objc.objc_msgSend(self.handle, sel);
        if (raw) |q| return MetalCommandQueue{ .handle = q };
        return null;
    }

    pub fn createLibrary(self: MetalDevice, source: [:0]const u8) ?MetalLibrary {
        // Use helper from objc.zig
        const ns_source = objc.createNSString(source);
        if (ns_source == null) return null;

        const lib_sel = objc.getSelector("newLibraryWithSource:options:error:");
        const NewLibFn = *const fn (?*anyopaque, ?objc.Selector, ?objc.Object, ?*anyopaque, ?*anyopaque) callconv(.c) ?objc.Object;
        const new_lib_msg_send: NewLibFn = @ptrCast(&objc.objc_msgSend);

        const raw_lib = new_lib_msg_send(self.handle, lib_sel, ns_source, null, null);
        if (raw_lib) |lib| return MetalLibrary{ .handle = lib };
        return null;
    }

    pub fn createComputePipelineState(self: MetalDevice, func: MetalFunction) ?MetalComputePipelineState {
        const sel = objc.getSelector("newComputePipelineStateWithFunction:error:");
        const NewPipelineFn = *const fn (?*anyopaque, ?objc.Selector, ?objc.Object, ?*anyopaque) callconv(.c) ?objc.Object;
        const pipeline_msg_send: NewPipelineFn = @ptrCast(&objc.objc_msgSend);
        const raw_pipeline = pipeline_msg_send(self.handle, sel, func.handle, null);

        if (raw_pipeline) |p| return MetalComputePipelineState{ .handle = p };
        return null;
    }

    pub fn createBuffer(self: MetalDevice, length: u64, options: MTLResourceOptions) ?MetalBuffer {
        const sel = objc.getSelector("newBufferWithLength:options:");

        const NewBufFn = *const fn (?*anyopaque, ?objc.Selector, u64, u64) callconv(.c) ?objc.Object;
        const msg_send: NewBufFn = @ptrCast(&objc.objc_msgSend);

        const ptr = msg_send(self.handle, sel, length, @intFromEnum(options));
        if (ptr) |p| return MetalBuffer{ .handle = p };
        return null;
    }

    pub fn createRenderPipelineState(self: MetalDevice, desc: render.MetalRenderPipelineDescriptor) ?render.MetalRenderPipeLineState {
        const sel = objc.getSelector("newRenderPipelineStateWithDescriptor:error:");
        const NewPipeFn = *const fn (?*anyopaque, ?objc.Selector, ?objc.Object, ?*anyopaque) callconv(.c) ?objc.Object;
        const msg: NewPipeFn = @ptrCast(&objc.objc_msgSend);

        // Pass null for error for now
        const ptr = msg(self.handle, sel, desc.handle, null);

        if (ptr) |p| return render.MetalRenderPipeLineState{ .handle = p };

        std.debug.print("ERROR: Failed to create Render Pipeline State!\n", .{});
        return null;
    }

    pub fn createDepthStencilState(self: MetalDevice, desc: render.pipeline.MetalDepthStencilDescriptor) ?render.pipeline.MetalDepthStencilState {
        const sel = objc.getSelector("newDepthStencilStateWithDescriptor:");
        const NewFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) ?objc.Object;
        const msg: NewFn = @ptrCast(&objc.objc_msgSend);
        if (msg(self.handle, sel, desc.handle)) |p| return render.pipeline.MetalDepthStencilState{ .handle = p };
        return null;
    }

    // Quick helper to create a Depth Texture
    pub fn createDepthTexture(self: MetalDevice, width: u64, height: u64) ?objc.Object {
        // 1. Create Descriptor
        const desc_class = objc.objc_getClass("MTLTextureDescriptor");
        const desc_sel = objc.getSelector("texture2DDescriptorWithPixelFormat:width:height:mipmapped:");
        const DescFn = *const fn (?objc.Object, ?objc.Selector, u64, u64, u64, bool) callconv(.c) ?objc.Object;
        const desc_msg: DescFn = @ptrCast(&objc.objc_msgSend);

        // 252 = Depth32Float
        const tex_desc = desc_msg(desc_class, desc_sel, 252, width, height, false);

        // 2. Set Usage (RenderTarget)
        const usage_sel = objc.getSelector("setUsage:");
        const UsageFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
        const usage_msg: UsageFn = @ptrCast(&objc.objc_msgSend);
        usage_msg(tex_desc, usage_sel, 4); // 4 = ShaderRead | RenderTarget

        // 3. Set StorageMode (Private - GPU Only)
        const storage_sel = objc.getSelector("setStorageMode:");
        const StorageFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
        const storage_msg: StorageFn = @ptrCast(&objc.objc_msgSend);
        storage_msg(tex_desc, storage_sel, 2); // 2 = Private

        // 4. Create Texture
        const newTex_sel = objc.getSelector("newTextureWithDescriptor:");
        const NewTexFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) ?objc.Object;
        const new_tex_msg: NewTexFn = @ptrCast(&objc.objc_msgSend);

        return new_tex_msg(self.handle, newTex_sel, tex_desc);
    }
};

// --- Tests ---

test "Compute Shader: Calculate 42 on GPU" {
    const device = MetalDevice.createSystemDefault().?;
    std.debug.print("\n    > GPU: {s}\n", .{device.getName().?});

    // 1. Create a Buffer for the result (Shared memory)
    const buffer = device.createBuffer(4, .StorageModeShared).?;

    //    Get pointer and initialize to 0.0
    const ptr = @as(*f32, @ptrCast(@alignCast(buffer.contents())));
    ptr.* = 0.0;
    std.debug.print("    > Buffer initialized to: {d}\n", .{ptr.*});

    // 2. Setup Pipeline with Shader that writes to the buffer
    const shader_src =
        \\ #include <metal_stdlib>
        \\ using namespace metal;
        \\ 
        \\ // Argument table index 0 maps to setBuffer(..., 0)
        \\ kernel void compute_main(device float *result [[buffer(0)]]) {
        \\     result[0] = 42.0;
        \\ }
    ;
    const library = device.createLibrary(shader_src).?;
    const func = library.getFunction("compute_main").?;
    const pipeline = device.createComputePipelineState(func).?;

    // 3. Encode Commands
    const queue = device.createCommandQueue().?;
    const cmd_buffer = queue.createCommandBuffer().?;
    const encoder = cmd_buffer.createComputeCommandEncoder().?;

    encoder.setComputePipelineState(pipeline);

    // BIND THE BUFFER TO INDEX 0
    encoder.setBuffer(buffer, 0, 0);

    const grid_size = MTLSize{ .width = 1, .height = 1, .depth = 1 };
    const threadgroup_size = MTLSize{ .width = 1, .height = 1, .depth = 1 };
    encoder.dispatchThreadgroups(grid_size, threadgroup_size);
    encoder.endEncoding();

    // 4. Submit and Wait
    cmd_buffer.commit();
    cmd_buffer.waitUntilCompleted();

    // 5. Verify Result
    std.debug.print("    > GPU calculation finished. Result in buffer: {d}\n", .{ptr.*});
    try std.testing.expectEqual(@as(f32, 42.0), ptr.*);
}
