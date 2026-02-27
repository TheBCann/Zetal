const std = @import("std");
const objc = @import("../objc.zig");
const types = @import("types.zig");

pub const MetalRenderPipelineDescriptor = struct {
    handle: objc.Object,

    pub fn create() ?MetalRenderPipelineDescriptor {
        const class = objc.objc_getClass("MTLRenderPipelineDescriptor");
        const sel = objc.getSelector("new");
        const NewFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const msg: NewFn = @ptrCast(&objc.objc_msgSend);
        if (msg(class, sel)) |p| return MetalRenderPipelineDescriptor{ .handle = p };
        return null;
    }

    pub fn setVertexFunction(self: MetalRenderPipelineDescriptor, func: objc.Object) void {
        const sel = objc.getSelector("setVertexFunction:");
        const SetFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
        const msg: SetFn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, func);
    }

    pub fn setFragmentFunction(self: MetalRenderPipelineDescriptor, func: objc.Object) void {
        const sel = objc.getSelector("setFragmentFunction:");
        const SetFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
        const msg: SetFn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, func);
    }

    // --- THIS WAS MISSING ---
    pub fn setColorAttachmentPixelFormat(self: MetalRenderPipelineDescriptor, index: u64, format: u64) void {
        // 1. Get the ColorAttachments array
        const attach_sel = objc.getSelector("colorAttachments");
        const AttachFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const attach_msg: AttachFn = @ptrCast(&objc.objc_msgSend);
        const attachments = attach_msg(self.handle, attach_sel);

        // 2. Get the specific attachment descriptor
        const get_sel = objc.getSelector("objectAtIndexedSubscript:"); // Note the "ed"
        const GetFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) ?objc.Object;
        const get_msg: GetFn = @ptrCast(&objc.objc_msgSend);

        if (get_msg(attachments, get_sel, index)) |att| {
            // 3. Set the Pixel Format on it
            const setFmt_sel = objc.getSelector("setPixelFormat:");
            const SetFmtFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
            const set_fmt: SetFmtFn = @ptrCast(&objc.objc_msgSend);
            set_fmt(att, setFmt_sel, format);
        }
    }

    pub fn setDepthAttachmentPixelFormat(self: MetalRenderPipelineDescriptor, format: u64) void {
        const sel = objc.getSelector("setDepthAttachmentPixelFormat:");
        const SetFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
        const msg: SetFn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, format);
    }
};

pub const MetalDepthStencilDescriptor = struct {
    handle: objc.Object,

    pub fn create() ?MetalDepthStencilDescriptor {
        const class = objc.objc_getClass("MTLDepthStencilDescriptor");
        const sel = objc.getSelector("new");
        const NewFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const msg: NewFn = @ptrCast(&objc.objc_msgSend);
        if (msg(class, sel)) |p| return MetalDepthStencilDescriptor{ .handle = p };
        return null;
    }

    pub fn setDepthCompareFunction(self: MetalDepthStencilDescriptor, func: types.MTLCompareFunction) void {
        const sel = objc.getSelector("setDepthCompareFunction:");
        const SetFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
        const msg: SetFn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, @intFromEnum(func));
    }

    pub fn setDepthWriteEnabled(self: MetalDepthStencilDescriptor, enabled: bool) void {
        const sel = objc.getSelector("setDepthWriteEnabled:");
        const SetFn = *const fn (?objc.Object, ?objc.Selector, bool) callconv(.c) void;
        const msg: SetFn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, enabled);
    }
};

pub const MetalDepthStencilState = struct {
    handle: objc.Object,
};

pub const MetalRenderPipelineState = struct {
    handle: objc.Object,
};
