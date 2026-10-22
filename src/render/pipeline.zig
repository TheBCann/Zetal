const std = @import("std");
const objc = @import("../objc.zig");
const types = @import("types.zig");

const msgSend = objc.msgSend;
const Object = objc.Object;

pub const MetalRenderPipelineDescriptor = struct {
    handle: Object,

    pub fn create() ?MetalRenderPipelineDescriptor {
        const ptr = msgSend(?Object, objc.class("MTLRenderPipelineDescriptor"), "new", .{});
        return if (ptr) |p| .{ .handle = p } else null;
    }

    pub fn deinit(self: MetalRenderPipelineDescriptor) void {
        objc.release(self.handle);
    }

    pub fn setVertexFunction(self: MetalRenderPipelineDescriptor, func: Object) void {
        msgSend(void, self.handle, "setVertexFunction:", .{func});
    }

    pub fn setFragmentFunction(self: MetalRenderPipelineDescriptor, func: Object) void {
        msgSend(void, self.handle, "setFragmentFunction:", .{func});
    }

    pub fn setColorAttachmentPixelFormat(
        self: MetalRenderPipelineDescriptor,
        index: u64,
        format: types.MTLPixelFormat,
    ) void {
        const att = self.colorAttachmentAt(index) orelse return;
        msgSend(void, att, "setPixelFormat:", .{@intFromEnum(format)});
    }

    pub fn setDepthAttachmentPixelFormat(
        self: MetalRenderPipelineDescriptor,
        format: types.MTLPixelFormat,
    ) void {
        msgSend(void, self.handle, "setDepthAttachmentPixelFormat:", .{@intFromEnum(format)});
    }

    fn colorAttachmentAt(self: MetalRenderPipelineDescriptor, index: u64) ?Object {
        const attachments = msgSend(?Object, self.handle, "colorAttachments", .{}) orelse return null;
        return msgSend(?Object, attachments, "objectAtIndexedSubscript:", .{index});
    }
};

pub const MetalDepthStencilDescriptor = struct {
    handle: Object,

    pub fn create() ?MetalDepthStencilDescriptor {
        const ptr = msgSend(?Object, objc.class("MTLDepthStencilDescriptor"), "new", .{});
        return if (ptr) |p| .{ .handle = p } else null;
    }

    pub fn deinit(self: MetalDepthStencilDescriptor) void {
        objc.release(self.handle);
    }

    pub fn setDepthCompareFunction(
        self: MetalDepthStencilDescriptor,
        func: types.MTLCompareFunction,
    ) void {
        msgSend(void, self.handle, "setDepthCompareFunction:", .{@intFromEnum(func)});
    }

    pub fn setDepthWriteEnabled(self: MetalDepthStencilDescriptor, enabled: bool) void {
        msgSend(void, self.handle, "setDepthWriteEnabled:", .{enabled});
    }
};

pub const MetalDepthStencilState = struct {
    handle: Object,

    pub fn deinit(self: MetalDepthStencilState) void {
        objc.release(self.handle);
    }
};

pub const MetalRenderPipelineState = struct {
    handle: Object,

    pub fn deinit(self: MetalRenderPipelineState) void {
        objc.release(self.handle);
    }
};
