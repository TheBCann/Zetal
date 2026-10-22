const std = @import("std");
const objc = @import("../objc.zig");
const types = @import("types.zig");

const msgSend = objc.msgSend;
const Object = objc.Object;

pub const MetalRenderPassDescriptor = struct {
    handle: Object,

    pub fn create() ?MetalRenderPassDescriptor {
        // `renderPassDescriptor` is a class method returning an autoreleased instance.
        const ptr = msgSend(?Object, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
        return if (ptr) |p| .{ .handle = p } else null;
    }

    pub fn setColorAttachment(
        self: MetalRenderPassDescriptor,
        index: u64,
        texture: Object,
        load_action: types.MTLLoadAction,
        store_action: types.MTLStoreAction,
        clear_color: types.MTLClearColor,
    ) void {
        const att = self.colorAttachmentAt(index) orelse return;
        msgSend(void, att, "setTexture:", .{texture});
        msgSend(void, att, "setLoadAction:", .{@intFromEnum(load_action)});
        msgSend(void, att, "setStoreAction:", .{@intFromEnum(store_action)});
        msgSend(void, att, "setClearColor:", .{clear_color});
    }

    pub fn setDepthAttachment(
        self: MetalRenderPassDescriptor,
        texture: Object,
        clear_depth: f64,
    ) void {
        self.setDepthAttachmentWithStore(texture, clear_depth, .dont_care);
    }

    pub fn setDepthAttachmentWithStore(
        self: MetalRenderPassDescriptor,
        texture: Object,
        clear_depth: f64,
        store_action: types.MTLStoreAction,
    ) void {
        const att = msgSend(?Object, self.handle, "depthAttachment", .{}) orelse return;
        msgSend(void, att, "setTexture:", .{texture});
        msgSend(void, att, "setLoadAction:", .{@intFromEnum(types.MTLLoadAction.clear)});
        msgSend(void, att, "setStoreAction:", .{@intFromEnum(store_action)});
        msgSend(void, att, "setClearDepth:", .{clear_depth});
    }

    fn colorAttachmentAt(self: MetalRenderPassDescriptor, index: u64) ?Object {
        const attachments = msgSend(?Object, self.handle, "colorAttachments", .{}) orelse return null;
        return msgSend(?Object, attachments, "objectAtIndexedSubscript:", .{index});
    }
};

pub const MetalRenderCommandEncoder = struct {
    handle: Object,

    pub fn setFragmentTexture(self: MetalRenderCommandEncoder, texture: Object, index: u64) void {
        msgSend(void, self.handle, "setFragmentTexture:atIndex:", .{ texture, index });
    }

    pub fn setDepthStencilState(self: MetalRenderCommandEncoder, state: Object) void {
        msgSend(void, self.handle, "setDepthStencilState:", .{state});
    }

    pub fn setRenderPipelineState(self: MetalRenderCommandEncoder, pipeline_state: Object) void {
        msgSend(void, self.handle, "setRenderPipelineState:", .{pipeline_state});
    }

    pub fn setVertexBuffer(self: MetalRenderCommandEncoder, buffer: Object, offset: u64, index: u64) void {
        msgSend(void, self.handle, "setVertexBuffer:offset:atIndex:", .{ buffer, offset, index });
    }

    pub fn setVertexBytes(self: MetalRenderCommandEncoder, bytes: *const anyopaque, length: u64, index: u64) void {
        msgSend(void, self.handle, "setVertexBytes:length:atIndex:", .{ bytes, length, index });
    }

    pub fn setFragmentBytes(self: MetalRenderCommandEncoder, bytes: *const anyopaque, length: u64, index: u64) void {
        msgSend(void, self.handle, "setFragmentBytes:length:atIndex:", .{ bytes, length, index });
    }

    pub fn drawPrimitives(self: MetalRenderCommandEncoder, prim_type: types.MTLPrimitiveType, start: u64, count: u64) void {
        msgSend(void, self.handle, "drawPrimitives:vertexStart:vertexCount:", .{
            @intFromEnum(prim_type), start, count,
        });
    }

    pub fn drawIndexedPrimitives(
        self: MetalRenderCommandEncoder,
        prim_type: types.MTLPrimitiveType,
        index_count: u64,
        index_type: types.MTLIndexType,
        index_buffer: Object,
        index_buffer_offset: u64,
    ) void {
        msgSend(void, self.handle, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:", .{
            @intFromEnum(prim_type),
            index_count,
            @intFromEnum(index_type),
            index_buffer,
            index_buffer_offset,
        });
    }

    pub fn drawIndexedPrimitivesInstanced(
        self: MetalRenderCommandEncoder,
        prim_type: types.MTLPrimitiveType,
        index_count: u64,
        index_type: types.MTLIndexType,
        index_buffer: Object,
        index_buffer_offset: u64,
        instance_count: u64,
    ) void {
        msgSend(void, self.handle, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:", .{
            @intFromEnum(prim_type),
            index_count,
            @intFromEnum(index_type),
            index_buffer,
            index_buffer_offset,
            instance_count,
        });
    }

    pub fn endEncoding(self: MetalRenderCommandEncoder) void {
        msgSend(void, self.handle, "endEncoding", .{});
    }
};
