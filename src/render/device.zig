const std = @import("std");
const objc = @import("../objc.zig");
const render = @import("root.zig");

extern "Metal" fn MTLCreateSystemDefaultDevice() ?*anyopaque;

// ============================================================
// Metal Types
// ============================================================

pub const MTLSize = extern struct {
    width: u64,
    height: u64,
    depth: u64,
};

pub const MTLOrigin = extern struct {
    x: u64,
    y: u64,
    z: u64,
};

pub const MTLRegion = extern struct {
    origin: MTLOrigin,
    size: MTLSize,
};

pub const MTLResourceOptions = enum(u64) {
    StorageModeShared = 0,
    StorageModePrivate = 2,
};

// ============================================================
// Metal Wrappers
// ============================================================

pub const MetalFunction = struct { handle: objc.Object };
pub const MetalComputePipelineState = struct { handle: objc.Object };

pub const MetalBuffer = struct {
    handle: objc.Object,
    pub fn contents(self: MetalBuffer) *anyopaque {
        const sel = objc.getSelector("contents");
        const Fn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) *anyopaque;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        return msg(self.handle, sel);
    }
};

pub const MetalTexture = struct {
    handle: objc.Object,

    pub fn replaceRegion(self: MetalTexture, region: MTLRegion, bytes: [*]const u8, bytesPerRow: u64) void {
        const sel = objc.getSelector("replaceRegion:mipmapLevel:withBytes:bytesPerRow:");
        const Fn = *const fn (?objc.Object, ?objc.Selector, MTLRegion, u64, [*]const u8, u64) callconv(.c) void;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, region, 0, bytes, bytesPerRow);
    }
};

pub const MetalComputeCommandEncoder = struct {
    handle: objc.Object,
    pub fn setComputePipelineState(self: MetalComputeCommandEncoder, state: MetalComputePipelineState) void {
        const sel = objc.getSelector("setComputePipelineState:");
        const Fn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, state.handle);
    }
    pub fn setBuffer(self: MetalComputeCommandEncoder, buffer: MetalBuffer, offset: u64, index: u64) void {
        const sel = objc.getSelector("setBuffer:offset:atIndex:");
        const Fn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object, u64, u64) callconv(.c) void;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, buffer.handle, offset, index);
    }
    pub fn dispatchThreadgroups(self: MetalComputeCommandEncoder, groups: MTLSize, threads: MTLSize) void {
        const sel = objc.getSelector("dispatchThreadgroups:threadsPerThreadgroup:");
        const Fn = *const fn (?objc.Object, ?objc.Selector, MTLSize, MTLSize) callconv(.c) void;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, groups, threads);
    }
    pub fn endEncoding(self: MetalComputeCommandEncoder) void {
        const sel = objc.getSelector("endEncoding");
        _ = objc.objc_msgSend(self.handle, sel);
    }
};

pub const MetalLibrary = struct {
    handle: objc.Object,
    pub fn getFunction(self: MetalLibrary, name: [:0]const u8) ?MetalFunction {
        const ns_name = objc.createNSString(name) orelse return null;
        const sel = objc.getSelector("newFunctionWithName:");
        const Fn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        if (msg(self.handle, sel, ns_name)) |f| return MetalFunction{ .handle = f };
        return null;
    }
};

pub const MetalCommandBuffer = struct {
    handle: objc.Object,
    pub fn createRenderCommandEncoder(self: MetalCommandBuffer, desc: render.MetalRenderPassDescriptor) ?render.MetalRenderCommandEncoder {
        const sel = objc.getSelector("renderCommandEncoderWithDescriptor:");
        const Fn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        if (msg(self.handle, sel, desc.handle)) |p| return render.MetalRenderCommandEncoder{ .handle = p };
        return null;
    }
    pub fn presentDrawable(self: MetalCommandBuffer, drawable: objc.Object) void {
        const sel = objc.getSelector("presentDrawable:");
        const Fn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, drawable);
    }
    pub fn commit(self: MetalCommandBuffer) void {
        const sel = objc.getSelector("commit");
        _ = objc.objc_msgSend(self.handle, sel);
    }

    pub fn createComputeCommandEncoder(self: MetalCommandBuffer) ?MetalComputeCommandEncoder {
        const sel = objc.getSelector("computeCommandEncoder");
        const Fn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        if (msg(self.handle, sel)) |p| return MetalComputeCommandEncoder{ .handle = p };
        return null;
    }

    pub fn waitUntilCompleted(self: MetalCommandBuffer) void {
        const sel = objc.getSelector("waitUntilCompleted");
        const Fn = *const fn (objc.Object, ?objc.Selector) callconv(.c) void;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel);
    }
};

pub const MetalCommandQueue = struct {
    handle: objc.Object,
    pub fn createCommandBuffer(self: MetalCommandQueue) ?MetalCommandBuffer {
        const sel = objc.getSelector("commandBuffer");
        const buf = objc.objc_msgSend(self.handle, sel);
        if (buf) |b| return MetalCommandBuffer{ .handle = b };
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

    pub fn createCommandQueue(self: MetalDevice) ?MetalCommandQueue {
        const sel = objc.getSelector("newCommandQueue");
        const q = objc.objc_msgSend(self.handle, sel);
        if (q) |ptr| return MetalCommandQueue{ .handle = ptr };
        return null;
    }

    pub fn createLibrary(self: MetalDevice, source: [:0]const u8) ?MetalLibrary {
        const ns_src = objc.createNSString(source) orelse return null;
        const sel = objc.getSelector("newLibraryWithSource:options:error:");

        // Error pointer to capture Metal compiler feedback
        var err_ptr: ?objc.Object = null;
        const Fn = *const fn (?*anyopaque, ?objc.Selector, ?objc.Object, ?*anyopaque, *?objc.Object) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);

        const lib_handle = msg(self.handle, sel, ns_src, null, &err_ptr);

        if (lib_handle == null) {
            if (err_ptr) |err| {
                const desc_sel = objc.getSelector("localizedDescription");
                const DescFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
                const desc_msg: DescFn = @ptrCast(&objc.objc_msgSend);
                const desc = desc_msg(err, desc_sel);

                const utf8_sel = objc.getSelector("UTF8String");
                const Utf8Fn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) [*:0]const u8;
                const utf8_msg: Utf8Fn = @ptrCast(&objc.objc_msgSend);
                const str = utf8_msg(desc, utf8_sel);

                std.debug.print("\n\x1b[31m--- METAL SHADER ERROR ---\x1b[0m\n{s}\n\x1b[31m--------------------------\x1b[0m\n", .{str});
            }
            return null;
        }

        return MetalLibrary{ .handle = lib_handle.? };
    }

    pub fn createRenderPipelineState(self: MetalDevice, desc: render.MetalRenderPipelineDescriptor) ?render.MetalRenderPipelineState {
        const sel = objc.getSelector("newRenderPipelineStateWithDescriptor:error:");
        const Fn = *const fn (?*anyopaque, ?objc.Selector, ?objc.Object, ?*anyopaque) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        if (msg(self.handle, sel, desc.handle, null)) |p| return render.MetalRenderPipelineState{ .handle = p };
        return null;
    }

    pub fn createDepthStencilState(self: MetalDevice, desc: render.pipeline.MetalDepthStencilDescriptor) ?render.pipeline.MetalDepthStencilState {
        const sel = objc.getSelector("newDepthStencilStateWithDescriptor:");
        const Fn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        if (msg(self.handle, sel, desc.handle)) |p| return render.pipeline.MetalDepthStencilState{ .handle = p };
        return null;
    }

    pub fn createBuffer(self: MetalDevice, length: u64, options: MTLResourceOptions) ?MetalBuffer {
        const sel = objc.getSelector("newBufferWithLength:options:");
        const Fn = *const fn (?*anyopaque, ?objc.Selector, u64, u64) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        if (msg(self.handle, sel, length, @intFromEnum(options))) |p| return MetalBuffer{ .handle = p };
        return null;
    }

    pub fn createTexture(self: MetalDevice, width: u64, height: u64, format: u64) ?MetalTexture {
        const desc_class = objc.objc_getClass("MTLTextureDescriptor");
        const desc_sel = objc.getSelector("texture2DDescriptorWithPixelFormat:width:height:mipmapped:");
        const DescFn = *const fn (?objc.Object, ?objc.Selector, u64, u64, u64, bool) callconv(.c) ?objc.Object;
        const desc_msg: DescFn = @ptrCast(&objc.objc_msgSend);
        const tex_desc = desc_msg(desc_class, desc_sel, format, width, height, false);

        const usage_sel = objc.getSelector("setUsage:");
        const UsageFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
        const usage_msg: UsageFn = @ptrCast(&objc.objc_msgSend);
        usage_msg(tex_desc, usage_sel, 5);

        const newTex_sel = objc.getSelector("newTextureWithDescriptor:");
        const NewTexFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) ?objc.Object;
        const new_tex_msg: NewTexFn = @ptrCast(&objc.objc_msgSend);
        if (new_tex_msg(self.handle, newTex_sel, tex_desc)) |t| return MetalTexture{ .handle = t };
        return null;
    }

    pub fn createDepthTexture(self: MetalDevice, width: u64, height: u64) ?objc.Object {
        const desc_class = objc.objc_getClass("MTLTextureDescriptor");
        const desc_sel = objc.getSelector("texture2DDescriptorWithPixelFormat:width:height:mipmapped:");
        const DescFn = *const fn (?objc.Object, ?objc.Selector, u64, u64, u64, bool) callconv(.c) ?objc.Object;
        const desc_msg: DescFn = @ptrCast(&objc.objc_msgSend);
        const tex_desc = desc_msg(desc_class, desc_sel, 252, width, height, false);

        const usage_sel = objc.getSelector("setUsage:");
        const UsageFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
        const usage_msg: UsageFn = @ptrCast(&objc.objc_msgSend);
        usage_msg(tex_desc, usage_sel, 4);

        const storage_sel = objc.getSelector("setStorageMode:");
        const StorageFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
        const storage_msg: StorageFn = @ptrCast(&objc.objc_msgSend);
        storage_msg(tex_desc, storage_sel, 2);

        const newTex_sel = objc.getSelector("newTextureWithDescriptor:");
        const NewTexFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) ?objc.Object;
        const new_tex_msg: NewTexFn = @ptrCast(&objc.objc_msgSend);
        return new_tex_msg(self.handle, newTex_sel, tex_desc);
    }

    /// Like createDepthTexture but with ShaderRead usage so the fragment shader can sample it.
    pub fn createShadowMap(self: MetalDevice, width: u64, height: u64) ?MetalTexture {
        const desc_class = objc.objc_getClass("MTLTextureDescriptor");
        const desc_sel = objc.getSelector("texture2DDescriptorWithPixelFormat:width:height:mipmapped:");
        const DescFn = *const fn (?objc.Object, ?objc.Selector, u64, u64, u64, bool) callconv(.c) ?objc.Object;
        const desc_msg: DescFn = @ptrCast(&objc.objc_msgSend);
        const tex_desc = desc_msg(desc_class, desc_sel, 252, width, height, false);

        const usage_sel = objc.getSelector("setUsage:");
        const UsageFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
        const usage_msg: UsageFn = @ptrCast(&objc.objc_msgSend);
        usage_msg(tex_desc, usage_sel, 5);

        const storage_sel = objc.getSelector("setStorageMode:");
        const StorageFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
        const storage_msg: StorageFn = @ptrCast(&objc.objc_msgSend);
        storage_msg(tex_desc, storage_sel, 2); // Private

        const newTex_sel = objc.getSelector("newTextureWithDescriptor:");
        const NewTexFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) ?objc.Object;
        const new_tex_msg: NewTexFn = @ptrCast(&objc.objc_msgSend);
        if (new_tex_msg(self.handle, newTex_sel, tex_desc)) |t| return MetalTexture{ .handle = t };
        return null;
    }

    pub fn createComputePipelineState(self: MetalDevice, function: MetalFunction) ?MetalComputePipelineState {
        const sel = objc.getSelector("newComputePipelineStateWithFunction:error:");
        const Fn = *const fn (?*anyopaque, ?objc.Selector, ?objc.Object, ?*anyopaque) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        if (msg(self.handle, sel, function.handle, null)) |p| return MetalComputePipelineState{ .handle = p };
        return null;
    }
};
