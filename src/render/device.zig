const std = @import("std");
const objc = @import("../objc.zig");
const render = @import("root.zig");

const msgSend = objc.msgSend;
const Object = objc.Object;

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
        return msgSend(*anyopaque, self.handle, "contents", .{});
    }
};

pub const MetalTexture = struct {
    handle: objc.Object,

    pub fn replaceRegion(self: MetalTexture, region: MTLRegion, bytes: [*]const u8, bytesPerRow: u64) void {
        msgSend(void, self.handle, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            region, 
            @as(u64, 0), 
            bytes, 
            bytesPerRow
        });
    }
};

pub const MetalComputeCommandEncoder = struct {
    handle: objc.Object,
    
    pub fn setComputePipelineState(self: MetalComputeCommandEncoder, state: MetalComputePipelineState) void {
        msgSend(void, self.handle, "setComputePipelineState:", .{state.handle});
    }
    
    pub fn setBuffer(self: MetalComputeCommandEncoder, buffer: MetalBuffer, offset: u64, index: u64) void {
        msgSend(void, self.handle, "setBuffer:offset:atIndex:", .{buffer.handle, offset, index});
    }
    
    pub fn dispatchThreadgroups(self: MetalComputeCommandEncoder, groups: MTLSize, threads: MTLSize) void {
        msgSend(void, self.handle, "dispatchThreadgroups:threadsPerThreadgroup:", .{groups, threads});
    }
    
    pub fn endEncoding(self: MetalComputeCommandEncoder) void {
        msgSend(void, self.handle, "endEncoding", .{});
    }
};

pub const MetalLibrary = struct {
    handle: objc.Object,
    
    pub fn getFunction(self: MetalLibrary, name: [:0]const u8) ?MetalFunction {
        const ns_name = objc.createNSString(name) orelse return null;
        if (msgSend(?Object, self.handle, "newFunctionWithName:", .{ns_name})) |f| return MetalFunction{ .handle = f };
        return null;
    }
};

pub const MetalCommandBuffer = struct {
    handle: objc.Object,
    
    pub fn createRenderCommandEncoder(self: MetalCommandBuffer, desc: render.MetalRenderPassDescriptor) ?render.MetalRenderCommandEncoder {
        if (msgSend(?Object, self.handle, "renderCommandEncoderWithDescriptor:", .{desc.handle})) |p| {
            return render.MetalRenderCommandEncoder{ .handle = p };
        }
        return null;
    }
    
    pub fn presentDrawable(self: MetalCommandBuffer, drawable: objc.Object) void {
        msgSend(void, self.handle, "presentDrawable:", .{drawable});
    }
    
    pub fn commit(self: MetalCommandBuffer) void {
        msgSend(void, self.handle, "commit", .{});
    }

    pub fn createComputeCommandEncoder(self: MetalCommandBuffer) ?MetalComputeCommandEncoder {
        if (msgSend(?Object, self.handle, "computeCommandEncoder", .{})) |p| {
            return MetalComputeCommandEncoder{ .handle = p };
        }
        return null;
    }

    pub fn waitUntilCompleted(self: MetalCommandBuffer) void {
        msgSend(void, self.handle, "waitUntilCompleted", .{});
    }
};

pub const MetalCommandQueue = struct {
    handle: objc.Object,
    
    pub fn createCommandBuffer(self: MetalCommandQueue) ?MetalCommandBuffer {
        if (msgSend(?Object, self.handle, "commandBuffer", .{})) |b| {
            return MetalCommandBuffer{ .handle = b };
        }
        return null;
    }
};

pub const MetalDevice = struct {
    handle: objc.Object,

    pub fn createSystemDefault() ?MetalDevice {
        const ptr = MTLCreateSystemDefaultDevice();
        if (ptr) |p| return MetalDevice{ .handle = @ptrCast(p) };
        return null;
    }

    pub fn createCommandQueue(self: MetalDevice) ?MetalCommandQueue {
        if (msgSend(?Object, self.handle, "newCommandQueueWithMaxCommandBufferCount:", .{@as(u64, 64)})) |ptr| {
            return MetalCommandQueue{ .handle = ptr };
        }
        return null;
    }

    pub fn createLibrary(self: MetalDevice, source: [:0]const u8) ?MetalLibrary {
        const ns_src = objc.createNSString(source) orelse return null;
        
        // Error pointer to capture Metal compiler feedback
        var err_ptr: ?objc.Object = null;
        
        const lib_handle = msgSend(?Object, self.handle, "newLibraryWithSource:options:error:", .{
            ns_src, 
            @as(?Object, null), 
            &err_ptr 
        });

        if (lib_handle == null) {
            if (err_ptr) |err| {
                const desc = msgSend(?Object, err, "localizedDescription", .{});
                const str = msgSend([*:0]const u8, desc, "UTF8String", .{});
                std.debug.print("\n\x1b[31m--- METAL SHADER ERROR ---\x1b[0m\n{s}\n\x1b[31m--------------------------\x1b[0m\n", .{str});
            }
            return null;
        }

        return MetalLibrary{ .handle = lib_handle.? };
    }

    pub fn createRenderPipelineState(self: MetalDevice, desc: render.MetalRenderPipelineDescriptor) ?render.MetalRenderPipelineState {
        if (msgSend(?Object, self.handle, "newRenderPipelineStateWithDescriptor:error:", .{desc.handle, @as(?Object, null)})) |p| {
            return render.MetalRenderPipelineState{ .handle = p };
        }
        return null;
    }

    pub fn createDepthStencilState(self: MetalDevice, desc: render.pipeline.MetalDepthStencilDescriptor) ?render.pipeline.MetalDepthStencilState {
        if (msgSend(?Object, self.handle, "newDepthStencilStateWithDescriptor:", .{desc.handle})) |p| {
            return render.pipeline.MetalDepthStencilState{ .handle = p };
        }
        return null;
    }

    pub fn createBuffer(self: MetalDevice, length: u64, options: MTLResourceOptions) ?MetalBuffer {
        if (msgSend(?Object, self.handle, "newBufferWithLength:options:", .{length, @intFromEnum(options)})) |p| {
            return MetalBuffer{ .handle = p };
        }
        return null;
    }

    pub fn createTexture(self: MetalDevice, width: u64, height: u64, format: u64) ?MetalTexture {
        const desc_class = objc.class("MTLTextureDescriptor");
        const tex_desc = msgSend(?Object, desc_class, "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            format, 
            width, 
            height, 
            false
        });

        msgSend(void, tex_desc, "setUsage:", .{@as(u64, 5)});

        if (msgSend(?Object, self.handle, "newTextureWithDescriptor:", .{tex_desc})) |t| {
            return MetalTexture{ .handle = t };
        }
        return null;
    }

    pub fn createDepthTexture(self: MetalDevice, width: u64, height: u64) ?objc.Object {
        const desc_class = objc.class("MTLTextureDescriptor");
        const tex_desc = msgSend(?Object, desc_class, "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            @as(u64, 252), // Depth32Float
            width, 
            height, 
            false
        });

        msgSend(void, tex_desc, "setUsage:", .{@as(u64, 4)});
        msgSend(void, tex_desc, "setStorageMode:", .{@as(u64, 2)});

        return msgSend(?Object, self.handle, "newTextureWithDescriptor:", .{tex_desc});
    }

    /// Like createDepthTexture but with ShaderRead usage so the fragment shader can sample it.
    pub fn createShadowMap(self: MetalDevice, width: u64, height: u64) ?MetalTexture {
        const desc_class = objc.class("MTLTextureDescriptor");
        const tex_desc = msgSend(?Object, desc_class, "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            @as(u64, 252), // Depth32Float 
            width, 
            height, 
            false
        });

        msgSend(void, tex_desc, "setUsage:", .{@as(u64, 5)});
        msgSend(void, tex_desc, "setStorageMode:", .{@as(u64, 2)}); // Private

        if (msgSend(?Object, self.handle, "newTextureWithDescriptor:", .{tex_desc})) |t| {
            return MetalTexture{ .handle = t };
        }
        return null;
    }

    pub fn createComputePipelineState(self: MetalDevice, function: MetalFunction) ?MetalComputePipelineState {
        if (msgSend(?Object, self.handle, "newComputePipelineStateWithFunction:error:", .{function.handle, @as(?Object, null)})) |p| {
            return MetalComputePipelineState{ .handle = p };
        }
        return null;
    }
};
