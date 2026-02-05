const std = @import("std");
const Zetal = @import("Zetal");
const Math = @import("render/math.zig");
const objc = Zetal.objc;

// --- Helper: Direct Kernel Sleep ---
fn simpleSleep(ns: u64) void {
    const seconds = ns / std.time.ns_per_s;
    const nanoseconds = ns % std.time.ns_per_s;

    var ts = std.c.timespec{
        .sec = @intCast(seconds),
        .nsec = @intCast(nanoseconds),
    };

    _ = std.c.nanosleep(&ts, null);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io; // Keep for future use
    _ = io;

    std.debug.print("Starting Zetal Engine...\n", .{});

    // 1. Init System
    const device = Zetal.MetalDevice.createSystemDefault().?;
    const queue = device.createCommandQueue().?;
    const app = Zetal.window.App.init();
    // _ = app;
    const win = Zetal.window.Window.create(800, 600, "Zetal Engine").?;
    const view = Zetal.window.MetalView.create(.{ .origin_x = 0, .origin_y = 0, .width = 800, .height = 600 }, device.handle).?;
    win.setContentView(view);

    // 2. Build Pipeline (Shader)
    const library = device.createLibrary(Zetal.render.shader.triangle_source).?;
    const vert_fn = library.getFunction("vertex_main").?;
    const frag_fn = library.getFunction("fragment_main").?;

    const pipe_desc = Zetal.render.MetalRenderPipelineDescriptor.create().?;
    pipe_desc.setVertexFunction(vert_fn.handle);
    pipe_desc.setFragmentFunction(frag_fn.handle);
    // 80 = BGRA8Unorm (Must match the view's pixel format!)
    pipe_desc.setColorAttachmentPixelFormat(0, 80);

    const pipeline_state = device.createRenderPipelineState(pipe_desc).?;
    std.debug.print("Shader Pipeline Compiled Successfully.\n", .{});

    // 3. Upload Vertices (CPU -> GPU)
    const vertices = Zetal.render.vertex.triangle_vertices;
    const vertex_buffer = device.createBuffer(@sizeOf(@TypeOf(vertices)), .StorageModeShared).?;
    const dest_ptr = @as([*]Zetal.render.vertex.Vertex, @ptrCast(@alignCast(vertex_buffer.contents())));
    @memcpy(dest_ptr[0..vertices.len], &vertices);
    std.debug.print("Vertex Data Uploaded.\n", .{});

    // 4. Create Uniform Buffer
    // Create a buffer large enough to hold one 4x4 matrix
    const uniform_buffer = device.createBuffer(@sizeOf(Math.Mat4x4), .StorageModeShared).?;

    std.debug.print("Engine Initialized. Starting Render Loop...\n", .{});

    var angle: f32 = 0.0;

    while (true) {
        // Poll Events
        app.pollEvents();

        // Autorelease Pool
        const pool_class = objc.objc_getClass("NSAutoreleasePool");
        const alloc_sel = objc.getSelector("alloc");
        const init_sel = objc.getSelector("init");
        const AllocFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const alloc_msg: AllocFn = @ptrCast(&objc.objc_msgSend);
        var pool = alloc_msg(pool_class, alloc_sel);
        const InitFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
        const init_msg: InitFn = @ptrCast(&objc.objc_msgSend);
        pool = init_msg(pool, init_sel);

        angle += 0.02; // Spin speed
        const model_matrix = Math.Mat4x4.rotateZ(angle);

        // Upload Matrix to GPU
        const uniform_ptr = @as([*]Math.Mat4x4, @ptrCast(@alignCast(uniform_buffer.contents())));
        uniform_ptr[0] = model_matrix;

        // Render Frame
        const drawable = view.nextDrawable();

        if (drawable) |d| {
            const tex_sel = objc.getSelector("texture");
            const GetTexFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
            const get_tex: GetTexFn = @ptrCast(&objc.objc_msgSend);
            const texture = get_tex(d, tex_sel);

            const pass = Zetal.render.MetalRenderPassDescriptor.create().?;
            // Dark Grey Background to make the triangle pop
            const bg_color = Zetal.render.MTLClearColor{ .red = 0.1, .green = 0.1, .blue = 0.1, .alpha = 1.0 };
            pass.setColorAttachment(0, texture.?, .Clear, .Store, bg_color);

            const cmd_buffer = queue.createCommandBuffer().?;
            const encoder = cmd_buffer.createRenderCommandEncoder(pass).?;

            // --- DRAW COMMANDS ---
            encoder.setRenderPipelineState(pipeline_state.handle);

            // Bind Vertex Buffer (Slot 0)
            encoder.setVertexBuffer(vertex_buffer.handle, 0, 0); // Index 0 matches [[attribute(0)]] in shader

            // Bind Vertex Buffer (Slot 1)
            encoder.setVertexBuffer(uniform_buffer.handle, 0, 1);

            encoder.drawPrimitives(.Triangle, 0, 3);
            encoder.endEncoding();

            cmd_buffer.presentDrawable(d);
            cmd_buffer.commit();
        }

        // Drain Pool
        const drain_sel = objc.getSelector("drain");
        const DrainFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) void;
        const drain_msg: DrainFn = @ptrCast(&objc.objc_msgSend);
        drain_msg(pool, drain_sel);

        simpleSleep(16 * 1000 * 1000);
    }
}
