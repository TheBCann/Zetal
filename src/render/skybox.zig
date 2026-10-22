const objc = @import("../objc.zig");
const pipeline = @import("pipeline.zig");
const device = @import("device.zig");

/// Inside-facing cube vertices for skybox (36 verts, position only as float4).
pub const vertices = [36][4]f32{
    // +Z face (looking inward)
    .{ -1, 1, 1, 1 },  .{ -1, -1, 1, 1 }, .{ 1, -1, 1, 1 },
    .{ -1, 1, 1, 1 },  .{ 1, -1, 1, 1 },  .{ 1, 1, 1, 1 },
    // -Z face
    .{ 1, 1, -1, 1 },  .{ 1, -1, -1, 1 }, .{ -1, -1, -1, 1 },
    .{ 1, 1, -1, 1 },  .{ -1, -1, -1, 1 }, .{ -1, 1, -1, 1 },
    // +X face
    .{ 1, 1, 1, 1 },   .{ 1, -1, 1, 1 },  .{ 1, -1, -1, 1 },
    .{ 1, 1, 1, 1 },   .{ 1, -1, -1, 1 }, .{ 1, 1, -1, 1 },
    // -X face
    .{ -1, 1, -1, 1 }, .{ -1, -1, -1, 1 }, .{ -1, -1, 1, 1 },
    .{ -1, 1, -1, 1 }, .{ -1, -1, 1, 1 }, .{ -1, 1, 1, 1 },
    // +Y face (ceiling)
    .{ -1, 1, -1, 1 }, .{ -1, 1, 1, 1 },  .{ 1, 1, 1, 1 },
    .{ -1, 1, -1, 1 }, .{ 1, 1, 1, 1 },   .{ 1, 1, -1, 1 },
    // -Y face (floor)
    .{ -1, -1, 1, 1 }, .{ -1, -1, -1, 1 }, .{ 1, -1, -1, 1 },
    .{ -1, -1, 1, 1 }, .{ 1, -1, -1, 1 }, .{ 1, -1, 1, 1 },
};

pub const vertex_count: u64 = 36;

/// Create a depth stencil state for skybox rendering:
/// depth write OFF, compare LessEqual (skybox z = 1.0 = clear depth).
pub fn createDepthState(dev: device.MetalDevice) ?pipeline.MetalDepthStencilState {
    const desc_class = objc.objc_getClass("MTLDepthStencilDescriptor");
    const alloc_sel = objc.sel("alloc");
    const init_sel = objc.sel("init");

    const AllocFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
    const alloc_msg: AllocFn = @ptrCast(&objc.objc_msgSend);
    var desc = alloc_msg(desc_class, alloc_sel);

    const InitFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
    const init_msg: InitFn = @ptrCast(&objc.objc_msgSend);
    desc = init_msg(desc, init_sel);

    const cmp_sel = objc.sel("setDepthCompareFunction:");
    const CmpFn = *const fn (?*anyopaque, ?*anyopaque, u64) callconv(.c) void;
    const cmp_msg: CmpFn = @ptrCast(&objc.objc_msgSend);
    cmp_msg(desc, cmp_sel, 3); // LessEqual

    const write_sel = objc.sel("setDepthWriteEnabled:");
    const WriteFn = *const fn (?*anyopaque, ?*anyopaque, bool) callconv(.c) void;
    const write_msg: WriteFn = @ptrCast(&objc.objc_msgSend);
    write_msg(desc, write_sel, false);

    const new_sel = objc.sel("newDepthStencilStateWithDescriptor:");
    const NewFn = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?objc.Object;
    const new_msg: NewFn = @ptrCast(&objc.objc_msgSend);
    if (new_msg(dev.handle, new_sel, desc)) |s| return pipeline.MetalDepthStencilState{ .handle = s };
    return null;
}
