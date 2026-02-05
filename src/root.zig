const std = @import("std");
pub const objc = @import("objc.zig");
pub const window = @import("window.zig");
pub const scene = @import("scene.zig");
pub const render = @import("render/root.zig");

extern "Metal" fn MTLCreateSystemDefaultDevice() ?*anyopaque;

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

// --- WRAPPERS ---

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
        const Fn = *const fn (?*anyopaque, ?objc.Selector, ?objc.Object, ?*anyopaque, ?*anyopaque) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        if (msg(self.handle, sel, ns_src, null, null)) |l| return MetalLibrary{ .handle = l };
        return null;
    }

    pub fn createRenderPipelineState(self: MetalDevice, desc: render.MetalRenderPipelineDescriptor) ?render.MetalRenderPipeLineState {
        const sel = objc.getSelector("newRenderPipelineStateWithDescriptor:error:");
        const Fn = *const fn (?*anyopaque, ?objc.Selector, ?objc.Object, ?*anyopaque) callconv(.c) ?objc.Object;
        const msg: Fn = @ptrCast(&objc.objc_msgSend);
        if (msg(self.handle, sel, desc.handle, null)) |p| return render.MetalRenderPipeLineState{ .handle = p };
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

    // Generic Texture Creator
    pub fn createTexture(self: MetalDevice, width: u64, height: u64, format: u64) ?MetalTexture {
        const desc_class = objc.objc_getClass("MTLTextureDescriptor");
        const desc_sel = objc.getSelector("texture2DDescriptorWithPixelFormat:width:height:mipmapped:");
        const DescFn = *const fn (?objc.Object, ?objc.Selector, u64, u64, u64, bool) callconv(.c) ?objc.Object;
        const desc_msg: DescFn = @ptrCast(&objc.objc_msgSend);

        const tex_desc = desc_msg(desc_class, desc_sel, format, width, height, false);

        // Usage = ShaderRead (1) | RenderTarget (4) = 5
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

    // RESTORED: Helper specifically for Depth Textures
    pub fn createDepthTexture(self: MetalDevice, width: u64, height: u64) ?objc.Object {
        const desc_class = objc.objc_getClass("MTLTextureDescriptor");
        const desc_sel = objc.getSelector("texture2DDescriptorWithPixelFormat:width:height:mipmapped:");
        const DescFn = *const fn (?objc.Object, ?objc.Selector, u64, u64, u64, bool) callconv(.c) ?objc.Object;
        const desc_msg: DescFn = @ptrCast(&objc.objc_msgSend);

        // 252 = Depth32Float
        const tex_desc = desc_msg(desc_class, desc_sel, 252, width, height, false);

        const usage_sel = objc.getSelector("setUsage:");
        const UsageFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
        const usage_msg: UsageFn = @ptrCast(&objc.objc_msgSend);
        usage_msg(tex_desc, usage_sel, 4); // RenderTarget

        const storage_sel = objc.getSelector("setStorageMode:");
        const StorageFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
        const storage_msg: StorageFn = @ptrCast(&objc.objc_msgSend);
        storage_msg(tex_desc, storage_sel, 2); // Private

        const newTex_sel = objc.getSelector("newTextureWithDescriptor:");
        const NewTexFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) ?objc.Object;
        const new_tex_msg: NewTexFn = @ptrCast(&objc.objc_msgSend);

        return new_tex_msg(self.handle, newTex_sel, tex_desc);
    }
};

test {
    std.testing.refAllDecls(@import("render/math.zig"));
    std.testing.refAllDecls(@import("window.zig"));
}
pub const engine = @import("engine.zig");
pub const loader = @import("loader.zig");
