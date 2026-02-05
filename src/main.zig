const std = @import("std");
const Zetal = @import("Zetal");
const Math = Zetal.render.math;
const objc = Zetal.objc;

fn simpleSleep(ns: u64) void {
    const seconds = ns / std.time.ns_per_s;
    const nanoseconds = ns % std.time.ns_per_s;
    var ts = std.c.timespec{ .sec = @intCast(seconds), .nsec = @intCast(nanoseconds) };
    _ = std.c.nanosleep(&ts, null);
}

pub fn main(init: std.process.Init) !void {
    _ = init.io;

    std.debug.print("Starting Zetal Engine (Textured!)...\n", .{});

    const device = Zetal.MetalDevice.createSystemDefault().?;
    const queue = device.createCommandQueue().?;
    var app = Zetal.window.App.init();

    const win = Zetal.window.Window.create(800, 600, "Zetal Engine").?;
    const view = Zetal.window.MetalView.create(.{ .origin_x = 0, .origin_y = 0, .width = 800, .height = 600 }, device.handle).?;
    win.setContentView(view);

    // --- TEXTURE CREATION ---
    const tex_width = 64;
    const tex_height = 64;

    // Create Texture Object (RGBA8Unorm = 70)
    // 70 is MTLPixelFormatRGBA8Unorm
    const texture = device.createTexture(tex_width, tex_height, 70).?;

    // Generate Checkerboard Pixels (White & Gray)
    var raw_pixels: [tex_width * tex_height]u32 = undefined;
    for (0..tex_height) |y| {
        for (0..tex_width) |x| {
            const index = y * tex_width + x;
            // XOR pattern for checkerboard
            const is_white = ((x / 8) + (y / 8)) % 2 == 0;

            if (is_white) {
                raw_pixels[index] = 0xFFFFFFFF; // White (ABGR in u32 typically maps to RGBA in Metal depending on endianness)
            } else {
                raw_pixels[index] = 0xFF808080; // Gray
            }
        }
    }

    // Upload to GPU
    const region = Zetal.MTLRegion{
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .size = .{ .width = tex_width, .height = tex_height, .depth = 1 },
    };
    // Bytes per row = width * 4 bytes (RGBA8)
    texture.replaceRegion(region, @ptrCast(&raw_pixels), tex_width * 4);
    std.debug.print("Texture Generated & Uploaded.\n", .{});
    // ------------------------

    const library = device.createLibrary(Zetal.render.shader.triangle_source).?;
    const vert_fn = library.getFunction("vertex_main").?;
    const frag_fn = library.getFunction("fragment_main").?;

    const pipe_desc = Zetal.render.MetalRenderPipelineDescriptor.create().?;
    pipe_desc.setVertexFunction(vert_fn.handle);
    pipe_desc.setFragmentFunction(frag_fn.handle);
    pipe_desc.setColorAttachmentPixelFormat(0, 80);
    pipe_desc.setDepthAttachmentPixelFormat(252);

    const pipeline_state = device.createRenderPipelineState(pipe_desc).?;

    const depth_desc = Zetal.render.pipeline.MetalDepthStencilDescriptor.create().?;
    depth_desc.setDepthCompareFunction(.Less);
    depth_desc.setDepthWriteEnabled(true);
    const depth_state = device.createDepthStencilState(depth_desc).?;

    const depth_texture = device.createDepthTexture(800, 600).?;

    const vertices = Zetal.render.vertex.triangle_vertices;
    const vertex_buffer = device.createBuffer(@sizeOf(@TypeOf(vertices)), .StorageModeShared).?;
    const dest_ptr = @as([*]Zetal.render.vertex.Vertex, @ptrCast(@alignCast(vertex_buffer.contents())));
    @memcpy(dest_ptr[0..vertices.len], &vertices);

    const uniform_buffer = device.createBuffer(@sizeOf(Math.Mat4x4), .StorageModeShared).?;

    std.debug.print("Engine Initialized. Fly mode active.\n", .{});

    var angle: f32 = 0.0;
    var cam_x: f32 = 0.0;
    var cam_y: f32 = -0.2;
    var cam_z: f32 = -3.0;
    const speed: f32 = 0.05;

    while (true) {
        app.pollEvents();

        if (app.isPressed(.W)) cam_z += speed;
        if (app.isPressed(.S)) cam_z -= speed;
        if (app.isPressed(.A)) cam_x -= speed;
        if (app.isPressed(.D)) cam_x += speed;
        if (app.isPressed(.Q)) cam_y += speed;
        if (app.isPressed(.E)) cam_y -= speed;

        angle += 0.02;

        const model_mat = Math.Mat4x4.rotateY(angle);
        const view_mat = Math.Mat4x4.translate(cam_x, cam_y, cam_z);
        const proj_mat = Math.Mat4x4.perspective(std.math.degreesToRadians(45.0), 800.0 / 600.0, 0.1, 100.0);

        const model_view = Math.Mat4x4.mul(proj_mat, view_mat);
        const final_matrix = Math.Mat4x4.mul(model_view, model_mat);

        const uniform_ptr = @as([*]Math.Mat4x4, @ptrCast(@alignCast(uniform_buffer.contents())));
        uniform_ptr[0] = final_matrix;

        const drawable = view.nextDrawable();

        if (drawable) |d| {
            const tex_sel = objc.getSelector("texture");
            const GetTexFn = *const fn (?objc.Object, ?objc.Selector) callconv(.c) ?objc.Object;
            const get_tex: GetTexFn = @ptrCast(&objc.objc_msgSend);
            const drawable_tex = get_tex(d, tex_sel);

            const pass = Zetal.render.MetalRenderPassDescriptor.create().?;
            const bg_color = Zetal.render.MTLClearColor{ .red = 0.1, .green = 0.1, .blue = 0.1, .alpha = 1.0 };
            pass.setColorAttachment(0, drawable_tex.?, .Clear, .Store, bg_color);
            pass.setDepthAttachment(depth_texture, 1.0);

            const cmd_buffer = queue.createCommandBuffer().?;
            const encoder = cmd_buffer.createRenderCommandEncoder(pass).?;

            encoder.setRenderPipelineState(pipeline_state.handle);
            encoder.setDepthStencilState(depth_state.handle);

            encoder.setVertexBuffer(vertex_buffer.handle, 0, 0);
            encoder.setVertexBuffer(uniform_buffer.handle, 0, 1);

            // NEW: Bind Checkerboard Texture to Fragment Shader (Index 0)
            encoder.setFragmentTexture(texture.handle, 0);

            encoder.drawPrimitives(.Triangle, 0, 18);
            encoder.endEncoding();

            cmd_buffer.presentDrawable(d);
            cmd_buffer.commit();
        }

        // Drain Pool
        const pool_class = objc.objc_getClass("NSAutoreleasePool");
        const alloc_sel = objc.getSelector("alloc");
        const init_sel = objc.getSelector("init");
        const AllocFn = *const fn (?*anyopaque, ?objc.Selector) callconv(.c) ?*anyopaque;
        const alloc_msg: AllocFn = @ptrCast(&objc.objc_msgSend);
        var pool = alloc_msg(pool_class, alloc_sel);

        const InitPoolFn = *const fn (?*anyopaque, ?objc.Selector) callconv(.c) ?*anyopaque;
        const init_pool_msg: InitPoolFn = @ptrCast(&objc.objc_msgSend);
        pool = init_pool_msg(pool, init_sel);

        const drain_sel = objc.getSelector("drain");
        const DrainFn = *const fn (?*anyopaque, ?objc.Selector) callconv(.c) void;
        const drain_msg: DrainFn = @ptrCast(&objc.objc_msgSend);
        drain_msg(pool, drain_sel);

        simpleSleep(16 * 1000 * 1000);
    }
}
