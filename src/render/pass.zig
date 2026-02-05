const std = @import("std");
const objc = @import("../objc.zig");
const types = @import("types.zig");

pub const MetalRenderPassDescriptor = struct {
    handle: objc.Object,

    pub fn create() ?MetalRenderPassDescriptor {
        const class = objc.objc_getClass("MTLRenderPassDescriptor");
        const sel = objc.getSelector("renderPassDescriptor");

        // Strict Cast
        const CreateFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const msg: CreateFn = @ptrCast(&objc.objc_msgSend);

        const ptr = msg(class, sel);
        if (ptr) |p| return MetalRenderPassDescriptor{ .handle = p };
        return null;
    }

    pub fn setColorAttachment(self: MetalRenderPassDescriptor, index: u64, texture: objc.Object, loadAction: types.MTLLoadAction, storeAction: types.MTLStoreAction, clearColor: types.MTLClearColor) void {
        // 1. Get colorAttachments array container
        const attach_sel = objc.getSelector("colorAttachments");
        const AttachFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const attach_msg: AttachFn = @ptrCast(&objc.objc_msgSend);
        const attachments = attach_msg(self.handle, attach_sel);

        // 2. Get the specific attachment at 'index'
        const get_sel = objc.getSelector("objectAtIndexedSubscript:");
        const GetFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) ?objc.Object;
        const get_msg: GetFn = @ptrCast(&objc.objc_msgSend);
        const attachment = get_msg(attachments, get_sel, index);

        if (attachment) |att| {
            // 3. Set Texture
            const setTex_sel = objc.getSelector("setTexture:");
            const SetTexFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
            const set_tex: SetTexFn = @ptrCast(&objc.objc_msgSend);
            set_tex(att, setTex_sel, texture);

            // 4. Set Load Action
            const setLoad_sel = objc.getSelector("setLoadAction:");
            const SetLoadFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
            const set_load: SetLoadFn = @ptrCast(&objc.objc_msgSend);
            set_load(att, setLoad_sel, @intFromEnum(loadAction));

            // 5. Set Store Action
            const setStore_sel = objc.getSelector("setStoreAction:");
            const SetStoreFn = *const fn (?objc.Object, ?objc.Selector, u64) callconv(.c) void;
            const set_store: SetStoreFn = @ptrCast(&objc.objc_msgSend);
            set_store(att, setStore_sel, @intFromEnum(storeAction));

            // 6. Set Clear Color
            const setClear_sel = objc.getSelector("setClearColor:");
            const SetClearFn = *const fn (?objc.Object, ?objc.Selector, types.MTLClearColor) callconv(.c) void;
            const set_clear: SetClearFn = @ptrCast(&objc.objc_msgSend);
            set_clear(att, setClear_sel, clearColor);
        }
    }
};

pub const MetalRenderCommandEncoder = struct {
    handle: objc.Object,

    pub fn setRenderPipelineState(self: MetalRenderCommandEncoder, pipelineState: objc.Object) void {
        const sel = objc.getSelector("setRenderPipelineState:");
        const SetFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object) callconv(.c) void;
        const msg: SetFn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, pipelineState);
    }

    pub fn setVertexBuffer(self: MetalRenderCommandEncoder, buffer: objc.Object, offset: u64, index: u64) void {
        const sel = objc.getSelector("setVertexBuffer:offset:atIndex:");
        const SetBufFn = *const fn (?objc.Object, ?objc.Selector, ?objc.Object, u64, u64) callconv(.c) void;
        const msg: SetBufFn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, buffer, offset, index);
    }

    pub fn drawPrimitives(self: MetalRenderCommandEncoder, primType: types.MTLPrimitiveType, start: u64, count: u64) void {
        const sel = objc.getSelector("drawPrimitives:vertexStart:vertexCount:");
        const DrawFn = *const fn (?objc.Object, ?objc.Selector, u64, u64, u64) callconv(.c) void;
        const msg: DrawFn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel, @intFromEnum(primType), start, count);
    }

    pub fn endEncoding(self: MetalRenderCommandEncoder) void {
        const sel = objc.getSelector("endEncoding");
        const EndFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) void;
        const msg: EndFn = @ptrCast(&objc.objc_msgSend);
        msg(self.handle, sel);
    }
};
