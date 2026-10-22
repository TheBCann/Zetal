//! Thin typed Metal wrappers: SDK enums and value structs, plus the device, queue, encoder and resource objects the engine drives.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("../objc.zig");

const Object = objc.Object;
const msgSend = objc.msgSend;
const log = std.log.scoped(.zetal);

// Ownership: the types documented +1 (made by MTLCreateSystemDefaultDevice, the device's new* methods,
// +new or newFunctionWithName:) have a `release`. The autoreleased ones (command buffers, encoders,
// render pass descriptors) and the texture descriptors and NSErrors used inside this file live until
// the current autorelease pool drains.

// ============================================================
// Enums and value types (MacOSX SDK 26.5 headers)
// ============================================================

/// MTLPixelFormat; only the formats the engine uses are named.
pub const PixelFormat = enum(u64) {
    invalid = 0,
    rgba8_unorm = 70,
    bgra8_unorm = 80,
    depth32_float = 252,
    _,
};

/// MTLLoadAction: what an attachment holds when a pass begins.
pub const LoadAction = enum(u64) {
    dont_care = 0,
    load = 1,
    clear = 2,
};

/// MTLStoreAction: what happens to an attachment's contents when a pass ends.
pub const StoreAction = enum(u64) {
    dont_care = 0,
    store = 1,
    multisample_resolve = 2,
    store_and_multisample_resolve = 3,
};

/// MTLCompareFunction, used for depth tests.
pub const CompareFunction = enum(u64) {
    never = 0,
    less = 1,
    equal = 2,
    less_equal = 3,
    greater = 4,
    not_equal = 5,
    greater_equal = 6,
    always = 7,
};

/// MTLPrimitiveType.
pub const PrimitiveType = enum(u64) {
    point = 0,
    line = 1,
    line_strip = 2,
    triangle = 3,
    triangle_strip = 4,
};

/// MTLIndexType.
pub const IndexType = enum(u64) {
    uint16 = 0,
    uint32 = 1,
};

/// MTLCullMode.
pub const CullMode = enum(u64) {
    none = 0,
    front = 1,
    back = 2,
};

/// MTLWinding: the vertex order that counts as front-facing.
pub const Winding = enum(u64) {
    clockwise = 0,
    counter_clockwise = 1,
};

/// MTLStorageMode: where a resource's memory lives and whether the CPU can reach it.
pub const StorageMode = enum(u64) {
    shared = 0,
    managed = 1,
    private = 2,
    memoryless = 3,
};

/// MTLTextureUsage bit set (ShaderRead 0x1, ShaderWrite 0x2, RenderTarget 0x4, PixelFormatView 0x10).
pub const TextureUsage = packed struct(u64) {
    shader_read: bool = false,
    shader_write: bool = false,
    render_target: bool = false,
    _unused: bool = false,
    pixel_format_view: bool = false,
    _reserved: u59 = 0,
};

// MTLResourceStorageModeShift. Bits 0-3 hold the CPU cache mode (left at DefaultCache = 0); the
// original engine's "StorageModePrivate = 2" landed in that field instead of here.
const RESOURCE_STORAGE_MODE_SHIFT = 4;

/// Returns the MTLResourceOptions for a buffer in `storage` (storage mode << 4, default cache and hazard tracking).
pub fn resourceOptions(storage: StorageMode) u64 {
    return @backingInt(storage) << RESOURCE_STORAGE_MODE_SHIFT;
}

/// MTLSize: an extent in texels or threads.
pub const Size = extern struct { width: u64, height: u64, depth: u64 };

/// MTLOrigin: a texel coordinate.
pub const Origin = extern struct { x: u64, y: u64, z: u64 };

/// MTLRegion: a box of texels.
pub const Region = extern struct {
    origin: Origin,
    size: Size,

    /// Returns the region covering a whole `width` x `height` 2D image.
    pub fn rect2D(width: u64, height: u64) Region {
        return .{
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .size = .{ .width = width, .height = height, .depth = 1 },
        };
    }
};

/// MTLClearColor: linear RGBA in [0, 1].
pub const ClearColor = extern struct { red: f64, green: f64, blue: f64, alpha: f64 };

/// MTLViewport: a rectangle in pixels plus the window depth range that clip-space z in [0, 1] maps onto.
pub const Viewport = extern struct { origin_x: f64, origin_y: f64, width: f64, height: f64, znear: f64, zfar: f64 };

// ============================================================
// Device and the objects it creates
// ============================================================

extern fn MTLCreateSystemDefaultDevice() ?Object;

// The original engine's queue depth: at most this many command buffers in flight before
// -commandBuffer blocks.
const MAX_COMMAND_BUFFERS: u64 = 64;

/// An MTLDevice (+1: release it after everything it created).
pub const Device = struct {
    handle: Object,

    /// Returns the system default GPU (+1), or null on a machine without Metal.
    pub fn createSystemDefault() ?Device {
        const handle = MTLCreateSystemDefaultDevice() orelse return null;
        return .{ .handle = handle };
    }

    /// Releases the device.
    pub fn release(self: Device) void {
        objc.release(self.handle);
    }

    /// Returns a new command queue (+1).
    pub fn newCommandQueue(self: Device) error{MetalCreateFailed}!CommandQueue {
        const handle = msgSend(?Object, self.handle, "newCommandQueueWithMaxCommandBufferCount:", .{
            MAX_COMMAND_BUFFERS,
        }) orelse return error.MetalCreateFailed;
        return .{ .handle = handle };
    }

    /// Compiles MSL `source` with the default options into a library (+1); on failure logs the
    /// compiler's diagnostics and returns error.ShaderCompileFailed.
    pub fn newLibrary(self: Device, source: [:0]const u8) error{ShaderCompileFailed}!Library {
        var err: ?Object = null;
        const handle = msgSend(?Object, self.handle, "newLibraryWithSource:options:error:", .{
            objc.nsString(source), @as(?Object, null), &err,
        }) orelse {
            logFailure("Metal shader compilation failed:\n{s}", .{errorText(err)});
            return error.ShaderCompileFailed;
        };
        // A library that compiled with warnings comes back together with an NSError holding them.
        if (err) |warnings| log.warn("Metal shader compiled with warnings:\n{s}", .{errorText(warnings)});
        return .{ .handle = handle };
    }

    /// Returns a zero-filled buffer of `length` bytes (+1); `.shared` is CPU- and GPU-visible.
    /// Metal has no empty buffers: `length == 0` returns error.MetalCreateFailed.
    pub fn newBuffer(self: Device, length: usize, storage: StorageMode) error{MetalCreateFailed}!Buffer {
        // Plain Metal returns nil for an empty buffer, but its validation layer aborts the process (probed).
        if (length == 0) return error.MetalCreateFailed;
        const handle = msgSend(?Object, self.handle, "newBufferWithLength:options:", .{
            @as(u64, length), resourceOptions(storage),
        }) orelse return error.MetalCreateFailed;
        return .{ .handle = handle };
    }

    /// Returns a buffer (+1) holding a copy of `bytes`; an empty slice returns error.MetalCreateFailed.
    pub fn newBufferWithBytes(self: Device, bytes: []const u8, storage: StorageMode) error{MetalCreateFailed}!Buffer {
        if (bytes.len == 0) return error.MetalCreateFailed; // as in newBuffer
        const handle = msgSend(?Object, self.handle, "newBufferWithBytes:length:options:", .{
            @as(*const anyopaque, bytes.ptr), @as(u64, bytes.len), resourceOptions(storage),
        }) orelse return error.MetalCreateFailed;
        return .{ .handle = handle };
    }

    /// Returns a 2D texture without mipmaps (+1); a zero dimension returns error.MetalCreateFailed.
    /// Usage and storage are always set: the descriptor's defaults (ShaderRead, Managed) fit none of
    /// the engine's textures.
    pub fn newTexture2D(
        self: Device,
        format: PixelFormat,
        width: u64,
        height: u64,
        usage: TextureUsage,
        storage: StorageMode,
    ) error{MetalCreateFailed}!Texture {
        // A zero-sized descriptor aborts the process inside Metal, with or without validation (probed).
        if (width == 0 or height == 0) return error.MetalCreateFailed;
        const descriptor = msgSend(
            ?Object,
            objc.class("MTLTextureDescriptor"),
            "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
            .{ @backingInt(format), width, height, false },
        ) orelse return error.MetalCreateFailed;
        msgSend(void, descriptor, "setUsage:", .{@backingInt(usage)});
        msgSend(void, descriptor, "setStorageMode:", .{@backingInt(storage)});
        const handle = msgSend(?Object, self.handle, "newTextureWithDescriptor:", .{descriptor}) orelse
            return error.MetalCreateFailed;
        return .{ .handle = handle };
    }

    /// Returns the pipeline state for `desc` (+1); on failure logs Metal's reason under the
    /// descriptor's label and returns error.PipelineCreateFailed.
    pub fn newRenderPipelineState(
        self: Device,
        desc: RenderPipelineDescriptor,
    ) error{PipelineCreateFailed}!RenderPipelineState {
        var err: ?Object = null;
        const handle = msgSend(?Object, self.handle, "newRenderPipelineStateWithDescriptor:error:", .{
            desc.handle, &err,
        }) orelse {
            logFailure("render pipeline '{s}' failed: {s}", .{ stringProperty(desc.handle, "label"), errorText(err) });
            return error.PipelineCreateFailed;
        };
        return .{ .handle = handle };
    }

    /// Returns a compute pipeline state for the kernel `function` (+1); on failure logs Metal's reason
    /// and returns error.PipelineCreateFailed.
    pub fn newComputePipelineState(self: Device, function: Function) error{PipelineCreateFailed}!ComputePipelineState {
        var err: ?Object = null;
        const handle = msgSend(?Object, self.handle, "newComputePipelineStateWithFunction:error:", .{
            function.handle, &err,
        }) orelse {
            logFailure("compute pipeline '{s}' failed: {s}", .{ stringProperty(function.handle, "name"), errorText(err) });
            return error.PipelineCreateFailed;
        };
        return .{ .handle = handle };
    }

    /// Returns a depth-stencil state (+1) with no stencil test that compares depth with `compare` and
    /// writes it iff `write_enabled`. Both are always set: the descriptor defaults to Always, writes off.
    pub fn newDepthStencilState(
        self: Device,
        compare: CompareFunction,
        write_enabled: bool,
    ) error{MetalCreateFailed}!DepthStencilState {
        const descriptor = objc.new("MTLDepthStencilDescriptor") orelse return error.MetalCreateFailed;
        defer objc.release(descriptor);
        msgSend(void, descriptor, "setDepthCompareFunction:", .{@backingInt(compare)});
        msgSend(void, descriptor, "setDepthWriteEnabled:", .{write_enabled});
        const handle = msgSend(?Object, self.handle, "newDepthStencilStateWithDescriptor:", .{descriptor}) orelse
            return error.MetalCreateFailed;
        return .{ .handle = handle };
    }
};

/// An MTLCommandQueue (+1).
pub const CommandQueue = struct {
    handle: Object,

    /// Returns a new command buffer (autoreleased); its work runs in commit order on this queue.
    pub fn commandBuffer(self: CommandQueue) error{MetalCreateFailed}!CommandBuffer {
        const handle = msgSend(?Object, self.handle, "commandBuffer", .{}) orelse return error.MetalCreateFailed;
        return .{ .handle = handle };
    }

    /// Releases the queue.
    pub fn release(self: CommandQueue) void {
        objc.release(self.handle);
    }
};

/// An MTLCommandBuffer (autoreleased).
pub const CommandBuffer = struct {
    handle: Object,

    /// Returns an encoder (autoreleased) for one render pass described by `pass`.
    pub fn renderCommandEncoder(self: CommandBuffer, pass: RenderPassDescriptor) error{MetalCreateFailed}!RenderCommandEncoder {
        const handle = msgSend(?Object, self.handle, "renderCommandEncoderWithDescriptor:", .{pass.handle}) orelse
            return error.MetalCreateFailed;
        return .{ .handle = handle };
    }

    /// Returns a compute encoder (autoreleased).
    pub fn computeCommandEncoder(self: CommandBuffer) error{MetalCreateFailed}!ComputeCommandEncoder {
        const handle = msgSend(?Object, self.handle, "computeCommandEncoder", .{}) orelse
            return error.MetalCreateFailed;
        return .{ .handle = handle };
    }

    /// Schedules `drawable` (a CAMetalDrawable) to be shown once this buffer's work completes.
    pub fn presentDrawable(self: CommandBuffer, drawable: Object) void {
        msgSend(void, self.handle, "presentDrawable:", .{drawable});
    }

    /// Submits the buffer to its queue.
    pub fn commit(self: CommandBuffer) void {
        msgSend(void, self.handle, "commit", .{});
    }

    /// Blocks until the GPU has finished the (committed) buffer.
    pub fn waitUntilCompleted(self: CommandBuffer) void {
        msgSend(void, self.handle, "waitUntilCompleted", .{});
    }
};

// ============================================================
// Descriptors
// ============================================================

// Metal's colour attachment slots per pass or pipeline (MTLRenderPass.h, MTLRenderPipeline.h).
const MAX_COLOR_ATTACHMENTS: u64 = 8;

/// Returns colour attachment `index` of a render pass or render pipeline descriptor. Metal vends a
/// descriptor for every slot below the limit, so nil means a broken descriptor, not a soft failure.
fn colorAttachment(descriptor: Object, index: u64) Object {
    std.debug.assert(index < MAX_COLOR_ATTACHMENTS);
    const attachments = msgSend(?Object, descriptor, "colorAttachments", .{}) orelse
        @panic("Metal descriptor returned no colorAttachments array");
    return msgSend(?Object, attachments, "objectAtIndexedSubscript:", .{index}) orelse
        @panic("Metal descriptor returned no colour attachment");
}

/// An MTLRenderPassDescriptor (autoreleased).
pub const RenderPassDescriptor = struct {
    handle: Object,

    /// Returns an empty pass descriptor (autoreleased).
    pub fn create() error{MetalCreateFailed}!RenderPassDescriptor {
        const handle = msgSend(?Object, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{}) orelse
            return error.MetalCreateFailed;
        return .{ .handle = handle };
    }

    /// Binds `texture` (an MTLTexture) as colour attachment `index` with its load/store actions and clear colour.
    pub fn setColorAttachment(
        self: RenderPassDescriptor,
        index: u64,
        texture: Object,
        load: LoadAction,
        store: StoreAction,
        clear: ClearColor,
    ) void {
        const attachment = colorAttachment(self.handle, index);
        msgSend(void, attachment, "setTexture:", .{texture});
        msgSend(void, attachment, "setLoadAction:", .{@backingInt(load)});
        msgSend(void, attachment, "setStoreAction:", .{@backingInt(store)});
        msgSend(void, attachment, "setClearColor:", .{clear});
    }

    /// Binds `texture` (an MTLTexture) as the depth attachment with its load/store actions and clear depth.
    pub fn setDepthAttachment(
        self: RenderPassDescriptor,
        texture: Object,
        load: LoadAction,
        store: StoreAction,
        clear_depth: f64,
    ) void {
        const attachment = msgSend(?Object, self.handle, "depthAttachment", .{}) orelse
            @panic("MTLRenderPassDescriptor returned no depth attachment");
        msgSend(void, attachment, "setTexture:", .{texture});
        msgSend(void, attachment, "setLoadAction:", .{@backingInt(load)});
        msgSend(void, attachment, "setStoreAction:", .{@backingInt(store)});
        msgSend(void, attachment, "setClearDepth:", .{clear_depth});
    }
};

/// An MTLRenderPipelineDescriptor (+1: release it once its pipeline states exist).
pub const RenderPipelineDescriptor = struct {
    handle: Object,

    /// Returns a blank descriptor (+1): no functions, every pixel format Invalid.
    pub fn create() error{MetalCreateFailed}!RenderPipelineDescriptor {
        const handle = objc.new("MTLRenderPipelineDescriptor") orelse return error.MetalCreateFailed;
        return .{ .handle = handle };
    }

    /// Releases the descriptor; pipeline states made from it stay valid.
    pub fn release(self: RenderPipelineDescriptor) void {
        objc.release(self.handle);
    }

    /// Sets the vertex function.
    pub fn setVertexFunction(self: RenderPipelineDescriptor, function: Function) void {
        msgSend(void, self.handle, "setVertexFunction:", .{function.handle});
    }

    /// Sets the fragment function; null makes a depth-only pipeline (shadow pass).
    pub fn setFragmentFunction(self: RenderPipelineDescriptor, function: ?Function) void {
        const handle: ?Object = if (function) |f| f.handle else null;
        msgSend(void, self.handle, "setFragmentFunction:", .{handle});
    }

    /// Sets the pixel format of colour attachment `index`; it must match the pass's texture.
    pub fn setColorPixelFormat(self: RenderPipelineDescriptor, index: u64, format: PixelFormat) void {
        msgSend(void, colorAttachment(self.handle, index), "setPixelFormat:", .{@backingInt(format)});
    }

    /// Sets the depth attachment pixel format; it must match the pass's depth texture.
    pub fn setDepthPixelFormat(self: RenderPipelineDescriptor, format: PixelFormat) void {
        msgSend(void, self.handle, "setDepthAttachmentPixelFormat:", .{@backingInt(format)});
    }

    /// Sets the label shown in GPU captures and in pipeline error logs.
    pub fn setLabel(self: RenderPipelineDescriptor, label: [:0]const u8) void {
        msgSend(void, self.handle, "setLabel:", .{objc.nsString(label)});
    }
};

// ============================================================
// Encoders
// ============================================================

// Metal's documented ceiling for set*Bytes data; anything larger belongs in a Buffer.
const MAX_INLINE_BYTES = 4096;

/// Rejects at compile time a `T` whose bytes have no fixed layout for the GPU to read: auto-layout
/// structs and unions (Zig may reorder their fields) and non-data types such as pointers or optionals.
fn checkGpuLayout(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int, .float, .bool, .vector, .@"enum" => {},
        .array => |info| checkGpuLayout(info.child),
        .@"struct" => |info| if (info.layout == .auto) {
            @compileError(@typeName(T) ++ " has auto layout; data shared with the GPU needs an extern struct");
        },
        .@"union" => |info| if (info.layout == .auto) {
            @compileError(@typeName(T) ++ " has auto layout; data shared with the GPU needs an extern union");
        },
        else => @compileError(@typeName(T) ++ " cannot be shared with the GPU"),
    }
}

/// Checks a `T` passed by value through set*Bytes: a GPU layout and at most MAX_INLINE_BYTES.
fn checkInlineBytes(comptime T: type) void {
    checkGpuLayout(T);
    if (@sizeOf(T) > MAX_INLINE_BYTES) {
        @compileError(std.fmt.comptimePrint("{s} is {d} bytes; Metal's set*Bytes take at most {d}, use a Buffer", .{
            @typeName(T), @sizeOf(T), MAX_INLINE_BYTES,
        }));
    }
}

/// An MTLRenderCommandEncoder (autoreleased). Bind indices follow the shader's [[buffer(n)]]/[[texture(n)]].
pub const RenderCommandEncoder = struct {
    handle: Object,

    /// Sets the pipeline for the following draws.
    pub fn setRenderPipelineState(self: RenderCommandEncoder, state: RenderPipelineState) void {
        msgSend(void, self.handle, "setRenderPipelineState:", .{state.handle});
    }

    /// Sets the depth test/write state for the following draws.
    pub fn setDepthStencilState(self: RenderCommandEncoder, state: DepthStencilState) void {
        msgSend(void, self.handle, "setDepthStencilState:", .{state.handle});
    }

    /// Sets which faces are culled (default none).
    pub fn setCullMode(self: RenderCommandEncoder, mode: CullMode) void {
        msgSend(void, self.handle, "setCullMode:", .{@backingInt(mode)});
    }

    /// Sets which winding is front-facing (default clockwise).
    pub fn setFrontFacingWinding(self: RenderCommandEncoder, winding: Winding) void {
        msgSend(void, self.handle, "setFrontFacingWinding:", .{@backingInt(winding)});
    }

    /// Sets the viewport (default: the whole attachment, depth range [0, 1]).
    pub fn setViewport(self: RenderCommandEncoder, viewport: Viewport) void {
        msgSend(void, self.handle, "setViewport:", .{viewport});
    }

    /// Binds `buffer` from byte `offset` to vertex buffer slot `index`.
    pub fn setVertexBuffer(self: RenderCommandEncoder, buffer: Buffer, offset: u64, index: u64) void {
        msgSend(void, self.handle, "setVertexBuffer:offset:atIndex:", .{ buffer.handle, offset, index });
    }

    /// Copies `value.*` into vertex buffer slot `index` (Metal copies at encode time).
    pub fn setVertexBytes(self: RenderCommandEncoder, comptime T: type, value: *const T, index: u64) void {
        comptime checkInlineBytes(T);
        msgSend(void, self.handle, "setVertexBytes:length:atIndex:", .{
            @as(*const anyopaque, value), @as(u64, @sizeOf(T)), index,
        });
    }

    /// Binds `buffer` from byte `offset` to fragment buffer slot `index`.
    pub fn setFragmentBuffer(self: RenderCommandEncoder, buffer: Buffer, offset: u64, index: u64) void {
        msgSend(void, self.handle, "setFragmentBuffer:offset:atIndex:", .{ buffer.handle, offset, index });
    }

    /// Copies `value.*` into fragment buffer slot `index` (Metal copies at encode time).
    pub fn setFragmentBytes(self: RenderCommandEncoder, comptime T: type, value: *const T, index: u64) void {
        comptime checkInlineBytes(T);
        msgSend(void, self.handle, "setFragmentBytes:length:atIndex:", .{
            @as(*const anyopaque, value), @as(u64, @sizeOf(T)), index,
        });
    }

    /// Binds `texture` to fragment texture slot `index`.
    pub fn setFragmentTexture(self: RenderCommandEncoder, texture: Texture, index: u64) void {
        msgSend(void, self.handle, "setFragmentTexture:atIndex:", .{ texture.handle, index });
    }

    /// Draws `count` vertices starting at vertex `start` (no index buffer).
    pub fn drawPrimitives(self: RenderCommandEncoder, primitive: PrimitiveType, start: u64, count: u64) void {
        msgSend(void, self.handle, "drawPrimitives:vertexStart:vertexCount:", .{ @backingInt(primitive), start, count });
    }

    /// Draws `instance_count` instances of `index_count` indices read from `index_buffer` at byte
    /// `index_offset`. Asserts instance_count > 0: Metal validation aborts on an empty instanced draw.
    pub fn drawIndexed(
        self: RenderCommandEncoder,
        primitive: PrimitiveType,
        index_count: u64,
        index_type: IndexType,
        index_buffer: Buffer,
        index_offset: u64,
        instance_count: u64,
    ) void {
        std.debug.assert(instance_count > 0);
        msgSend(
            void,
            self.handle,
            "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:",
            .{ @backingInt(primitive), index_count, @backingInt(index_type), index_buffer.handle, index_offset, instance_count },
        );
    }

    /// Ends the pass; the encoder must not be used afterwards.
    pub fn endEncoding(self: RenderCommandEncoder) void {
        msgSend(void, self.handle, "endEncoding", .{});
    }
};

/// An MTLComputeCommandEncoder (autoreleased).
pub const ComputeCommandEncoder = struct {
    handle: Object,

    /// Sets the kernel for the following dispatches.
    pub fn setComputePipelineState(self: ComputeCommandEncoder, state: ComputePipelineState) void {
        msgSend(void, self.handle, "setComputePipelineState:", .{state.handle});
    }

    /// Binds `buffer` from byte `offset` to kernel buffer slot `index`.
    pub fn setBuffer(self: ComputeCommandEncoder, buffer: Buffer, offset: u64, index: u64) void {
        msgSend(void, self.handle, "setBuffer:offset:atIndex:", .{ buffer.handle, offset, index });
    }

    /// Copies `value.*` into kernel buffer slot `index` (Metal copies at encode time).
    pub fn setBytes(self: ComputeCommandEncoder, comptime T: type, value: *const T, index: u64) void {
        comptime checkInlineBytes(T);
        msgSend(void, self.handle, "setBytes:length:atIndex:", .{
            @as(*const anyopaque, value), @as(u64, @sizeOf(T)), index,
        });
    }

    /// Dispatches `groups` threadgroups of `threads_per_group` threads. Asserts no dimension is 0:
    /// Metal validation aborts on an empty dispatch.
    pub fn dispatchThreadgroups(self: ComputeCommandEncoder, groups: Size, threads_per_group: Size) void {
        std.debug.assert(groups.width > 0 and groups.height > 0 and groups.depth > 0);
        std.debug.assert(threads_per_group.width > 0 and threads_per_group.height > 0 and threads_per_group.depth > 0);
        msgSend(void, self.handle, "dispatchThreadgroups:threadsPerThreadgroup:", .{ groups, threads_per_group });
    }

    /// Ends the compute pass; the encoder must not be used afterwards.
    pub fn endEncoding(self: ComputeCommandEncoder) void {
        msgSend(void, self.handle, "endEncoding", .{});
    }
};

// ============================================================
// Resources and compiled objects
// ============================================================

/// An MTLBuffer (+1).
pub const Buffer = struct {
    handle: Object,

    /// Returns the CPU address of the buffer's bytes; panics for private storage, which has none.
    pub fn contents(self: Buffer) [*]u8 {
        return msgSend(?[*]u8, self.handle, "contents", .{}) orelse
            @panic("-[MTLBuffer contents] is NULL: private buffers are not CPU-visible");
    }

    /// Returns the buffer's length in bytes.
    pub fn length(self: Buffer) usize {
        return msgSend(usize, self.handle, "length", .{});
    }

    /// Returns the first `len` elements of the buffer viewed as `T` (asserts they fit). With shared
    /// storage, writes are visible to the GPU without a blit.
    pub fn slice(self: Buffer, comptime T: type, len: usize) []T {
        comptime checkGpuLayout(T);
        std.debug.assert(len * @sizeOf(T) <= self.length());
        const items: [*]T = @ptrCast(@alignCast(self.contents()));
        return items[0..len];
    }

    /// Releases the buffer.
    pub fn release(self: Buffer) void {
        objc.release(self.handle);
    }
};

/// An MTLTexture (+1).
pub const Texture = struct {
    handle: Object,

    /// Copies `bytes` (rows `bytes_per_row` apart) into `region` of mip level 0; needs CPU-visible storage.
    pub fn replaceRegion(self: Texture, region: Region, bytes: [*]const u8, bytes_per_row: u64) void {
        msgSend(void, self.handle, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            region, @as(u64, 0), @as(*const anyopaque, bytes), bytes_per_row,
        });
    }

    /// Copies `region` of mip level 0 into `out` (rows `bytes_per_row` apart); needs CPU-visible
    /// storage and, after GPU writes, a completed command buffer.
    pub fn getBytes(self: Texture, out: [*]u8, bytes_per_row: u64, region: Region) void {
        msgSend(void, self.handle, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{
            @as(*anyopaque, out), bytes_per_row, region, @as(u64, 0),
        });
    }

    /// Returns the width in pixels.
    pub fn width(self: Texture) u64 {
        return msgSend(u64, self.handle, "width", .{});
    }

    /// Returns the height in pixels.
    pub fn height(self: Texture) u64 {
        return msgSend(u64, self.handle, "height", .{});
    }

    /// Releases the texture.
    pub fn release(self: Texture) void {
        objc.release(self.handle);
    }
};

/// An MTLLibrary of compiled MSL functions (+1).
pub const Library = struct {
    handle: Object,

    /// Returns the function called `name` (+1); a missing name is logged and returns error.MetalCreateFailed.
    pub fn newFunction(self: Library, name: [:0]const u8) error{MetalCreateFailed}!Function {
        const handle = msgSend(?Object, self.handle, "newFunctionWithName:", .{objc.nsString(name)}) orelse {
            logFailure("Metal library has no function named '{s}'", .{name});
            return error.MetalCreateFailed;
        };
        return .{ .handle = handle };
    }

    /// Releases the library; functions taken from it stay valid.
    pub fn release(self: Library) void {
        objc.release(self.handle);
    }
};

/// An MTLFunction (+1).
pub const Function = struct {
    handle: Object,

    /// Releases the function.
    pub fn release(self: Function) void {
        objc.release(self.handle);
    }
};

/// An MTLRenderPipelineState (+1).
pub const RenderPipelineState = struct {
    handle: Object,

    /// Releases the pipeline state.
    pub fn release(self: RenderPipelineState) void {
        objc.release(self.handle);
    }
};

/// An MTLComputePipelineState (+1).
pub const ComputePipelineState = struct {
    handle: Object,

    /// Releases the pipeline state.
    pub fn release(self: ComputePipelineState) void {
        objc.release(self.handle);
    }
};

/// An MTLDepthStencilState (+1).
pub const DepthStencilState = struct {
    handle: Object,

    /// Releases the depth-stencil state.
    pub fn release(self: DepthStencilState) void {
        objc.release(self.handle);
    }
};

// ============================================================
// Diagnostics
// ============================================================

/// Logs a failed create with its Metal diagnostics. The test runner fails every run that logs at .err,
/// even when a test provokes the failure on purpose (broken MSL, a missing function), so test builds
/// log at .warn; the error itself still propagates, so an unexpected failure still fails its test.
/// The tests that provoke one also lower `std.testing.log_level` around it, so a passing run prints
/// nothing.
fn logFailure(comptime format: []const u8, args: anytype) void {
    if (builtin.is_test) log.warn(format, args) else log.err(format, args);
}

/// Returns `err`'s localizedDescription; the text lives until the current autorelease pool drains.
fn errorText(err: ?Object) [:0]const u8 {
    const e = err orelse return "(Metal returned no NSError)";
    const description = msgSend(?Object, e, "localizedDescription", .{}) orelse return "(NSError without a description)";
    return objc.fromNSString(description);
}

/// Returns the NSString property `name` of `obj` (e.g. a descriptor's label), or "" when it is nil.
fn stringProperty(obj: Object, comptime name: [:0]const u8) [:0]const u8 {
    const value = msgSend(?Object, obj, name, .{}) orelse return "";
    return objc.fromNSString(value);
}

// ============================================================
// Tests (need a Metal device; skipped without one, no window server)
// ============================================================

const testing = std.testing;

/// The system device inside a fresh autorelease pool (platform/autorelease.zig is outside this unit).
const TestGpu = struct {
    pool: Object,
    device: Device,

    /// Pushes an NSAutoreleasePool and opens the default device, or skips the test without Metal.
    fn begin() !TestGpu {
        const raw = msgSend(?Object, objc.class("NSAutoreleasePool"), "alloc", .{}) orelse return error.PoolAllocFailed;
        const pool = msgSend(?Object, raw, "init", .{}) orelse return error.PoolInitFailed;
        errdefer msgSend(void, pool, "drain", .{});
        const device = Device.createSystemDefault() orelse return error.SkipZigTest;
        return .{ .pool = pool, .device = device };
    }

    /// Releases the device, then drains the pool and every autoreleased object the test made.
    fn end(self: TestGpu) void {
        self.device.release();
        msgSend(void, self.pool, "drain", .{});
    }
};

const COMMAND_BUFFER_STATUS_COMPLETED: u64 = 4; // MTLCommandBufferStatusCompleted

/// Commits `cmd`, waits for it and fails unless the GPU completed it without an error.
fn commitAndWait(cmd: CommandBuffer) !void {
    cmd.commit();
    cmd.waitUntilCompleted();
    if (msgSend(?Object, cmd.handle, "error", .{})) |err| {
        std.debug.print("command buffer failed: {s}\n", .{errorText(err)});
        return error.CommandBufferFailed;
    }
    try testing.expectEqual(COMMAND_BUFFER_STATUS_COMPLETED, msgSend(u64, cmd.handle, "status", .{}));
}

/// Fails unless the BGRA8 pixel (x, y) (row 0 = top) of a `row_pixels`-wide image is within `tolerance` of `expected`.
fn expectPixel(pixels: []const u8, row_pixels: usize, x: usize, y: usize, expected: [4]u8, tolerance: u8) !void {
    const i = (y * row_pixels + x) * 4;
    const actual: [4]u8 = pixels[i..][0..4].*;
    for (actual, expected) |a, e| {
        if (@max(a, e) - @min(a, e) > tolerance) {
            std.debug.print("pixel ({d},{d}) is BGRA {any}, expected {any} +-{d}\n", .{ x, y, actual, expected, tolerance });
            return error.TestUnexpectedResult;
        }
    }
}

const test_msl: [:0]const u8 =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct VOut {
    \\    float4 position [[position]];
    \\    float2 uv;
    \\};
    \\
    \\vertex VOut test_vertex(uint vid [[vertex_id]],
    \\                        const device float4* quads [[buffer(0)]],
    \\                        constant float& depth [[buffer(1)]]) {
    \\    VOut out;
    \\    out.position = float4(quads[vid].xy, depth, 1.0f);
    \\    out.uv = float2(quads[vid].x * 0.5f + 0.5f, 0.5f - quads[vid].y * 0.5f);
    \\    return out;
    \\}
    \\
    \\// red = the depth map under this pixel, green = tint (set*Bytes), blue = extra (a buffer at an offset)
    \\fragment float4 test_fragment(VOut in [[stage_in]],
    \\                              constant float4& tint [[buffer(0)]],
    \\                              const device float4& extra [[buffer(1)]],
    \\                              depth2d<float> depth_map [[texture(0)]]) {
    \\    constexpr sampler nearest(coord::normalized, filter::nearest, address::clamp_to_edge);
    \\    return float4(depth_map.sample(nearest, in.uv), tint.y, extra.z, 1.0f);
    \\}
    \\
    \\struct ScaleAdd {
    \\    uint count;
    \\    float scale;
    \\    float bias;
    \\    uint pad;
    \\};
    \\
    \\kernel void test_scale_add(device float* data [[buffer(0)]],
    \\                           constant ScaleAdd& p [[buffer(1)]],
    \\                           uint id [[thread_position_in_grid]]) {
    \\    if (id >= p.count) return;
    \\    data[id] = data[id] * p.scale + p.bias;
    \\}
;

/// Mirrors `ScaleAdd` in test_msl.
const ScaleAdd = extern struct { count: u32, scale: f32, bias: f32, _pad: u32 = 0 };

// Two counter-clockwise quads (NDC x, y): [0, 6) covers the whole target, [6, 12) its left half.
const test_quads = [12][4]f32{
    .{ -1, -1, 0, 1 }, .{ 1, -1, 0, 1 }, .{ 1, 1, 0, 1 },
    .{ -1, -1, 0, 1 }, .{ 1, 1, 0, 1 },  .{ -1, 1, 0, 1 },
    .{ -1, -1, 0, 1 }, .{ 0, -1, 0, 1 }, .{ 0, 1, 0, 1 },
    .{ -1, -1, 0, 1 }, .{ 0, 1, 0, 1 },  .{ -1, 1, 0, 1 },
};

// Six decoy indices (the left half), then the whole quad: a draw must start at byte offset 12.
const test_indices = [12]u16{ 6, 7, 8, 9, 10, 11, 0, 1, 2, 3, 4, 5 };

test "TextureUsage and resourceOptions use the SDK bit encodings" {
    try testing.expectEqual(0x1, @backingInt(TextureUsage{ .shader_read = true }));
    try testing.expectEqual(0x2, @backingInt(TextureUsage{ .shader_write = true }));
    try testing.expectEqual(0x4, @backingInt(TextureUsage{ .render_target = true }));
    try testing.expectEqual(0x10, @backingInt(TextureUsage{ .pixel_format_view = true }));
    try testing.expectEqual(0x5, @backingInt(TextureUsage{ .render_target = true, .shader_read = true }));
    try testing.expectEqual(0x00, resourceOptions(.shared));
    try testing.expectEqual(0x10, resourceOptions(.managed));
    try testing.expectEqual(0x20, resourceOptions(.private));
    try testing.expectEqual(0x30, resourceOptions(.memoryless));
}

test "value structs match the Metal C layouts" {
    try testing.expectEqual(24, @sizeOf(Size));
    try testing.expectEqual(24, @sizeOf(Origin));
    try testing.expectEqual(48, @sizeOf(Region));
    try testing.expectEqual(24, @offsetOf(Region, "size"));
    try testing.expectEqual(32, @sizeOf(ClearColor));
    try testing.expectEqual(48, @sizeOf(Viewport));
    try testing.expectEqual(32, @offsetOf(Viewport, "znear"));
    try testing.expectEqual(8, @sizeOf(TextureUsage));

    const region = Region.rect2D(640, 480);
    try testing.expectEqual(Origin{ .x = 0, .y = 0, .z = 0 }, region.origin);
    try testing.expectEqual(Size{ .width = 640, .height = 480, .depth = 1 }, region.size);
}

test "shared buffers: zero-filled, CPU round trip through slice/contents, newBufferWithBytes copies" {
    const gpu = try TestGpu.begin();
    defer gpu.end();

    const buffer = try gpu.device.newBuffer(256, .shared);
    defer buffer.release();
    try testing.expectEqual(256, buffer.length());
    for (buffer.contents()[0..256]) |byte| try testing.expectEqual(0, byte);

    const words = buffer.slice(u32, 64);
    for (words, 0..) |*w, i| w.* = @intCast(i * 3);
    const raw: [*]const u32 = @ptrCast(@alignCast(buffer.contents()));
    try testing.expectEqualSlices(u32, words, raw[0..64]);
    try testing.expectEqual(189, buffer.slice(u32, 64)[63]);

    const source = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const copy = try gpu.device.newBufferWithBytes(&source, .shared);
    defer copy.release();
    try testing.expectEqual(source.len, copy.length());
    try testing.expectEqualSlices(u8, &source, copy.contents()[0..source.len]);
}

test "zero-sized buffers and textures return error.MetalCreateFailed without reaching Metal" {
    const gpu = try TestGpu.begin();
    defer gpu.end();
    const device = gpu.device;
    try testing.expectError(error.MetalCreateFailed, device.newBuffer(0, .shared));
    try testing.expectError(error.MetalCreateFailed, device.newBufferWithBytes(&.{}, .shared));
    try testing.expectError(error.MetalCreateFailed, device.newTexture2D(.rgba8_unorm, 0, 4, .{ .shader_read = true }, .shared));
    try testing.expectError(error.MetalCreateFailed, device.newTexture2D(.depth32_float, 4, 0, .{ .render_target = true }, .private));
}

test "compute round trip: a kernel transforms a shared buffer bound at an offset" {
    const gpu = try TestGpu.begin();
    defer gpu.end();
    const device = gpu.device;

    const library = try device.newLibrary(test_msl);
    defer library.release();
    const function = try library.newFunction("test_scale_add");
    defer function.release();
    const pipeline = try device.newComputePipelineState(function);
    defer pipeline.release();
    const queue = try device.newCommandQueue();
    defer queue.release();

    const lead = 4; // floats before the bound offset: the kernel must not see them
    const count = 100; // not a multiple of the 64-thread group, so the kernel's bounds check matters
    const buffer = try device.newBuffer((lead + count) * @sizeOf(f32), .shared);
    defer buffer.release();
    const data = buffer.slice(f32, lead + count);
    for (data, 0..) |*v, i| v.* = @floatFromInt(i);

    const cmd = try queue.commandBuffer();
    const encoder = try cmd.computeCommandEncoder();
    encoder.setComputePipelineState(pipeline);
    encoder.setBuffer(buffer, lead * @sizeOf(f32), 0);
    const params: ScaleAdd = .{ .count = count, .scale = 2, .bias = 1 };
    encoder.setBytes(ScaleAdd, &params, 1);
    encoder.dispatchThreadgroups(.{ .width = (count + 63) / 64, .height = 1, .depth = 1 }, .{ .width = 64, .height = 1, .depth = 1 });
    encoder.endEncoding();
    try commitAndWait(cmd);

    for (data, 0..) |v, i| {
        const x: f32 = @floatFromInt(i);
        try testing.expectEqual(if (i < lead) x else x * 2 + 1, v);
    }
}

test "rgba8 shared texture: replaceRegion then getBytes round-trips, including a sub-region" {
    const gpu = try TestGpu.begin();
    defer gpu.end();

    const texture = try gpu.device.newTexture2D(.rgba8_unorm, 4, 4, .{ .shader_read = true }, .shared);
    defer texture.release();
    try testing.expectEqual(4, texture.width());
    try testing.expectEqual(4, texture.height());

    var source: [4 * 4 * 4]u8 = undefined;
    for (&source, 0..) |*byte, i| byte.* = @intCast(i * 3);
    texture.replaceRegion(.rect2D(4, 4), &source, 4 * 4);

    var whole: [source.len]u8 = undefined;
    texture.getBytes(&whole, 4 * 4, .rect2D(4, 4));
    try testing.expectEqualSlices(u8, &source, &whole);

    // Two texels starting at (1, 2).
    var part: [2 * 4]u8 = undefined;
    texture.getBytes(&part, 2 * 4, .{
        .origin = .{ .x = 1, .y = 2, .z = 0 },
        .size = .{ .width = 2, .height = 1, .depth = 1 },
    });
    try testing.expectEqualSlices(u8, source[(2 * 4 + 1) * 4 ..][0..8], &part);
}

test "offscreen BGRA8 target cleared to (1, 0, 0.2, 1) reads back BGRA {51, 0, 255, 255}" {
    const gpu = try TestGpu.begin();
    defer gpu.end();
    const queue = try gpu.device.newCommandQueue();
    defer queue.release();

    const size = 16;
    const target = try gpu.device.newTexture2D(.bgra8_unorm, size, size, .{ .render_target = true, .shader_read = true }, .shared);
    defer target.release();

    const pass = try RenderPassDescriptor.create();
    pass.setColorAttachment(0, target.handle, .clear, .store, .{ .red = 1.0, .green = 0.0, .blue = 0.2, .alpha = 1.0 });
    const cmd = try queue.commandBuffer();
    const encoder = try cmd.renderCommandEncoder(pass);
    encoder.endEncoding(); // the clear load action does all the work
    try commitAndWait(cmd);

    var pixels: [size * size * 4]u8 = undefined;
    target.getBytes(&pixels, size * 4, .rect2D(size, size));
    for (0..size) |y| {
        for (0..size) |x| try expectPixel(&pixels, size, x, y, .{ 51, 0, 255, 255 }, 1);
    }
}

test "offscreen draws: depth-only pass, sampled depth map, viewport, offsets, indexed draw, depth test" {
    const gpu = try TestGpu.begin();
    defer gpu.end();
    const device = gpu.device;
    const queue = try device.newCommandQueue();
    defer queue.release();

    const library = try device.newLibrary(test_msl);
    defer library.release();
    const vertex_fn = try library.newFunction("test_vertex");
    defer vertex_fn.release();
    const fragment_fn = try library.newFunction("test_fragment");
    defer fragment_fn.release();

    const depth_desc = try RenderPipelineDescriptor.create();
    defer depth_desc.release();
    depth_desc.setLabel("test depth-only");
    depth_desc.setVertexFunction(vertex_fn);
    depth_desc.setFragmentFunction(null);
    depth_desc.setDepthPixelFormat(.depth32_float);
    const depth_only = try device.newRenderPipelineState(depth_desc);
    defer depth_only.release();

    const colour_desc = try RenderPipelineDescriptor.create();
    defer colour_desc.release();
    colour_desc.setLabel("test colour+depth");
    colour_desc.setVertexFunction(vertex_fn);
    colour_desc.setFragmentFunction(fragment_fn);
    colour_desc.setColorPixelFormat(0, .bgra8_unorm);
    colour_desc.setDepthPixelFormat(.depth32_float);
    const colour = try device.newRenderPipelineState(colour_desc);
    defer colour.release();

    const depth_less_write = try device.newDepthStencilState(.less, true);
    defer depth_less_write.release();

    const size = 64;
    const size_f: f64 = size;
    const depth_map = try device.newTexture2D(.depth32_float, size, size, .{ .render_target = true, .shader_read = true }, .private);
    defer depth_map.release();
    const depth_target = try device.newTexture2D(.depth32_float, size, size, .{ .render_target = true }, .private);
    defer depth_target.release();
    const target = try device.newTexture2D(.bgra8_unorm, size, size, .{ .render_target = true, .shader_read = true }, .shared);
    defer target.release();

    const quads = try device.newBufferWithBytes(std.mem.asBytes(&test_quads), .shared);
    defer quads.release();
    const indices = try device.newBufferWithBytes(std.mem.asBytes(&test_indices), .shared);
    defer indices.release();
    // Bound at byte offset 16, so the shader's `extra` is the second float4 (blue 0.4); the 9s are decoys.
    const extra_values = [8]f32{ 9, 9, 9, 9, 0, 0, 0.4, 0 };
    const extra = try device.newBufferWithBytes(std.mem.asBytes(&extra_values), .shared);
    defer extra.release();

    const cmd = try queue.commandBuffer();

    // Pass 1, shadow-pass style: the left-half quad (vertexStart 6) at NDC z 0.5 under a viewport
    // depth range of [0, 0.5], so the stored depth is 0.25 only if the viewport arrived intact.
    {
        const pass = try RenderPassDescriptor.create();
        pass.setDepthAttachment(depth_map.handle, .clear, .store, 1.0);
        const encoder = try cmd.renderCommandEncoder(pass);
        encoder.setRenderPipelineState(depth_only);
        encoder.setDepthStencilState(depth_less_write);
        encoder.setFrontFacingWinding(.counter_clockwise);
        encoder.setCullMode(.back);
        encoder.setViewport(.{ .origin_x = 0, .origin_y = 0, .width = size_f, .height = size_f, .znear = 0, .zfar = 0.5 });
        encoder.setVertexBuffer(quads, 0, 0);
        const z: f32 = 0.5;
        encoder.setVertexBytes(f32, &z, 1);
        encoder.drawPrimitives(.triangle, 6, 6);
        encoder.endEncoding();
    }

    // Pass 2: red samples pass 1's depth map; green comes from setFragmentBytes per draw.
    {
        const pass = try RenderPassDescriptor.create();
        pass.setColorAttachment(0, target.handle, .clear, .store, .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 });
        pass.setDepthAttachment(depth_target.handle, .clear, .dont_care, 1.0);
        const encoder = try cmd.renderCommandEncoder(pass);
        encoder.setRenderPipelineState(colour);
        encoder.setDepthStencilState(depth_less_write);
        encoder.setFrontFacingWinding(.counter_clockwise);
        encoder.setCullMode(.back);
        encoder.setViewport(.{ .origin_x = 0, .origin_y = 0, .width = size_f, .height = size_f, .znear = 0, .zfar = 1 });
        encoder.setFragmentTexture(depth_map, 0);
        encoder.setFragmentBuffer(extra, 16, 1);

        // A: the whole quad from index byte offset 12, depth 0.5, green 1.
        encoder.setVertexBuffer(quads, 0, 0);
        const z_a: f32 = 0.5;
        encoder.setVertexBytes(f32, &z_a, 1);
        encoder.setFragmentBytes([4]f32, &.{ 0, 1, 0, 0 }, 0);
        encoder.drawIndexed(.triangle, 6, .uint16, indices, 12, 1);

        // B: the left half through a 96-byte vertex buffer offset, nearer (0.25), green 0.5.
        encoder.setVertexBuffer(quads, 6 * @sizeOf([4]f32), 0);
        const z_b: f32 = 0.25;
        encoder.setVertexBytes(f32, &z_b, 1);
        encoder.setFragmentBytes([4]f32, &.{ 0, 0.5, 0, 0 }, 0);
        encoder.drawPrimitives(.triangle, 0, 6);

        // C: the whole quad behind both (0.75), green 0: depth test + depth writes must reject all of it.
        encoder.setVertexBuffer(quads, 0, 0);
        const z_c: f32 = 0.75;
        encoder.setVertexBytes(f32, &z_c, 1);
        encoder.setFragmentBytes([4]f32, &.{ 0, 0, 0, 0 }, 0);
        encoder.drawPrimitives(.triangle, 0, 6);
        encoder.endEncoding();
    }

    try commitAndWait(cmd);

    var pixels: [size * size * 4]u8 = undefined;
    target.getBytes(&pixels, size * 4, .rect2D(size, size));
    for (0..size) |y| {
        for (0..size) |x| {
            // BGRA. Left: depth map 0.25 (red 64) under B (green 0.5); right: cleared depth 1.0 under A.
            const expected: [4]u8 = if (x < size / 2) .{ 102, 128, 64, 255 } else .{ 102, 255, 255, 255 };
            try expectPixel(&pixels, size, x, y, expected, 1);
        }
    }
}

test "MSL that does not compile returns error.ShaderCompileFailed" {
    const gpu = try TestGpu.begin();
    defer gpu.end();
    const broken: [:0]const u8 =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\kernel void broken(device float* out [[buffer(0)]]) { out[0] = undefined_symbol_xyz; }
    ;
    // Provoked on purpose: keep logFailure's warning out of `zig build test` output. Restored by hand,
    // because the server-mode test runner (`zig build test`) never resets it between tests.
    const saved_log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_log_level;
    try testing.expectError(error.ShaderCompileFailed, gpu.device.newLibrary(broken));
}

test "a function name the library does not define returns error.MetalCreateFailed" {
    const gpu = try TestGpu.begin();
    defer gpu.end();
    const library = try gpu.device.newLibrary(test_msl);
    defer library.release();
    // Provoked on purpose, like the broken MSL above: no warning in the test output.
    const saved_log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_log_level;
    try testing.expectError(error.MetalCreateFailed, library.newFunction("no_such_function"));
}

test "newBuffer and newTexture2D create resources in the storage mode they are given" {
    const gpu = try TestGpu.begin();
    defer gpu.end();
    // Read back from Metal, so a slip in resourceOptions' bit encoding (the original put the mode in
    // the CPU-cache bits) cannot hide behind buffers that happen to be shared either way.
    inline for (.{ StorageMode.shared, StorageMode.managed, StorageMode.private }) |mode| {
        const buffer = try gpu.device.newBuffer(64, mode);
        defer buffer.release();
        try testing.expectEqual(@backingInt(mode), msgSend(u64, buffer.handle, "storageMode", .{}));
    }
    inline for (.{ StorageMode.shared, StorageMode.private }) |mode| {
        const texture = try gpu.device.newTexture2D(.rgba8_unorm, 4, 4, .{ .shader_read = true }, mode);
        defer texture.release();
        try testing.expectEqual(@backingInt(mode), msgSend(u64, texture.handle, "storageMode", .{}));
    }
}
