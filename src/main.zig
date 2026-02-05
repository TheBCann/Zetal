const std = @import("std");
const Zetal = @import("Zetal");
const Math = Zetal.render.math;
const Io = std.Io;

fn simpleSleep(ns: u64) void {
    const seconds = ns / std.time.ns_per_s;
    const nanoseconds = ns % std.time.ns_per_s;
    var ts = std.c.timespec{ .sec = @intCast(seconds), .nsec = @intCast(nanoseconds) };
    _ = std.c.nanosleep(&ts, null);
}

pub fn main(init: std.process.Init) !void {
    // 1. Resources
    const allocator = init.arena.allocator();
    const io = init.io;

    // Setup stdout with buffering
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer_impl = Io.File.Writer.init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_writer_impl.interface;

    try stdout.print("Starting Zetal Engine (Model Loading)...\n", .{});
    try stdout.flush();

    var core = try Zetal.engine.Core.init();

    // 2. Load Model
    try stdout.print("Loading cube.obj...\n", .{});
    try stdout.flush();

    // Pass 'io' capability to loader
    const model = try Zetal.loader.loadObj(allocator, "cube.obj", io);

    try stdout.print("Loaded {d} vertices.\n", .{model.vertices.len});
    try stdout.flush();

    // 3. Texture
    const tex_width = 64;
    const tex_height = 64;
    const texture = core.device.createTexture(tex_width, tex_height, 70).?;

    // Checkerboard
    var raw_pixels: [tex_width * tex_height]u32 = undefined;
    for (0..tex_height) |y| {
        for (0..tex_width) |x| {
            const index = y * tex_width + x;
            const is_white = ((x / 8) + (y / 8)) % 2 == 0;
            raw_pixels[index] = if (is_white) 0xFFFFFFFF else 0xFF808080;
        }
    }
    const region = Zetal.MTLRegion{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = tex_width, .height = tex_height, .depth = 1 } };
    texture.replaceRegion(region, @ptrCast(&raw_pixels), tex_width * 4);

    const library = core.device.createLibrary(Zetal.render.shader.triangle_source).?;
    const vert_fn = library.getFunction("vertex_main").?;
    const frag_fn = library.getFunction("fragment_main").?;

    const pipe_desc = Zetal.render.MetalRenderPipelineDescriptor.create().?;
    pipe_desc.setVertexFunction(vert_fn.handle);
    pipe_desc.setFragmentFunction(frag_fn.handle);
    pipe_desc.setColorAttachmentPixelFormat(0, 80);
    pipe_desc.setDepthAttachmentPixelFormat(252);
    const pipeline_state = core.device.createRenderPipelineState(pipe_desc).?;

    const depth_desc = Zetal.render.pipeline.MetalDepthStencilDescriptor.create().?;
    depth_desc.setDepthCompareFunction(.Less);
    depth_desc.setDepthWriteEnabled(true);
    const depth_state = core.device.createDepthStencilState(depth_desc).?;

    // Upload Loaded Model
    const vertex_buffer = core.device.createBuffer(@sizeOf(Zetal.render.vertex.Vertex) * model.vertices.len, .StorageModeShared).?;
    const dest_ptr = @as([*]Zetal.render.vertex.Vertex, @ptrCast(@alignCast(vertex_buffer.contents())));
    @memcpy(dest_ptr[0..model.vertices.len], model.vertices);

    const uniform_buffer = core.device.createBuffer(@sizeOf(Math.Mat4x4), .StorageModeShared).?;

    try stdout.print("Engine Ready.\n", .{});
    try stdout.flush();

    var angle: f32 = 0.0;
    var cam_x: f32 = 0.0;
    var cam_y: f32 = -0.2;
    var cam_z: f32 = -3.0;
    const speed: f32 = 0.05;

    while (true) {
        core.pollEvents();
        if (core.app.isPressed(.W)) cam_z += speed;
        if (core.app.isPressed(.S)) cam_z -= speed;
        if (core.app.isPressed(.A)) cam_x -= speed;
        if (core.app.isPressed(.D)) cam_x += speed;
        if (core.app.isPressed(.Q)) cam_y += speed;
        if (core.app.isPressed(.E)) cam_y -= speed;

        angle += 0.02;
        const model_mat = Math.Mat4x4.rotateY(angle);
        const view_mat = Math.Mat4x4.translate(cam_x, cam_y, cam_z);
        const proj_mat = Math.Mat4x4.perspective(std.math.degreesToRadians(45.0), 800.0 / 600.0, 0.1, 100.0);
        const model_view = Math.Mat4x4.mul(proj_mat, view_mat);
        const final_matrix = Math.Mat4x4.mul(model_view, model_mat);

        const uniform_ptr = @as([*]Math.Mat4x4, @ptrCast(@alignCast(uniform_buffer.contents())));
        uniform_ptr[0] = final_matrix;

        const bg_color = Zetal.render.MTLClearColor{ .red = 0.1, .green = 0.1, .blue = 0.1, .alpha = 1.0 };

        if (core.beginFrame(bg_color)) |frame| {
            frame.enc.setRenderPipelineState(pipeline_state.handle);
            frame.enc.setDepthStencilState(depth_state.handle);

            frame.enc.setVertexBuffer(vertex_buffer.handle, 0, 0);
            frame.enc.setVertexBuffer(uniform_buffer.handle, 0, 1);
            frame.enc.setFragmentTexture(texture.handle, 0);

            // Draw Dynamic Count
            frame.enc.drawPrimitives(.Triangle, 0, model.vertices.len);

            frame.submit();
        }

        const pool_class = Zetal.objc.objc_getClass("NSAutoreleasePool");
        const alloc_sel = Zetal.objc.getSelector("alloc");
        const init_sel = Zetal.objc.getSelector("init");
        const AllocFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
        const alloc_msg: AllocFn = @ptrCast(&Zetal.objc.objc_msgSend);
        var pool = alloc_msg(pool_class, alloc_sel);
        const InitPoolFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
        const init_pool_msg: InitPoolFn = @ptrCast(&Zetal.objc.objc_msgSend);
        pool = init_pool_msg(pool, init_sel);
        const drain_sel = Zetal.objc.getSelector("drain");
        const DrainFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;
        const drain_msg: DrainFn = @ptrCast(&Zetal.objc.objc_msgSend);
        drain_msg(pool, drain_sel);

        simpleSleep(16 * 1000 * 1000);
    }
}
