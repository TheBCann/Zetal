const std = @import("std");
const Zetal = @import("Zetal");
const objc = Zetal.objc;

// NEW SIGNATURE: Takes std.process.Init to get the IO context
pub fn main(init: std.process.Init) !void {
    // 1. Grab the IO context provided by the runtime
    const io = init.io;

    std.debug.print("Starting Zetal Engine...\n", .{});

    const device = Zetal.MetalDevice.createSystemDefault().?;
    const queue = device.createCommandQueue().?;

    const app = Zetal.window.App.init();
    //_ = app; // Keep app alive
    const win = Zetal.window.Window.create(800, 600, "Zetal Engine").?;
    const view = Zetal.window.MetalView.create(.{ .origin_x = 0, .origin_y = 0, .width = 800, .height = 600 }, device.handle).?;
    win.setContentView(view);

    std.debug.print("Engine Initialized. Starting Render Loop...\n", .{});

    while (true) {
        app.pollEvents();
        // A. Autorelease Pool
        const pool_class = objc.objc_getClass("NSAutoreleasePool");
        const alloc_sel = objc.getSelector("alloc");
        const init_sel = objc.getSelector("init");

        const AllocFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const alloc_msg: AllocFn = @ptrCast(&objc.objc_msgSend);
        var pool = alloc_msg(pool_class, alloc_sel);

        const InitFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const init_msg: InitFn = @ptrCast(&objc.objc_msgSend);
        pool = init_msg(pool, init_sel);

        // B. Render
        const drawable = view.nextDrawable();

        if (drawable) |d| {
            const tex_sel = objc.getSelector("texture");
            const GetTexFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
            const get_tex: GetTexFn = @ptrCast(&objc.objc_msgSend);
            const texture = get_tex(d, tex_sel);

            const pass = Zetal.render.MetalRenderPassDescriptor.create().?;
            const red = Zetal.render.MTLClearColor{ .red = 1.0, .green = 0.0, .blue = 0.0, .alpha = 1.0 };

            pass.setColorAttachment(0, texture.?, .Clear, .Store, red);

            const cmd_buffer = queue.createCommandBuffer().?;
            const encoder = cmd_buffer.createRenderCommandEncoder(pass).?;
            encoder.endEncoding();

            cmd_buffer.presentDrawable(d);
            cmd_buffer.commit();
        }

        // C. Drain Pool
        const drain_sel = objc.getSelector("drain");
        const DrainFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) void;
        const drain_msg: DrainFn = @ptrCast(&objc.objc_msgSend);
        drain_msg(pool, drain_sel);

        // D. Sleep using the new API
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(16), .awake);
    }
}
