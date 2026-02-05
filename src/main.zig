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
    const allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer_impl = Io.File.Writer.init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_writer_impl.interface;

    try stdout.print("Starting Zetal Engine (Texture Loading)...\n", .{});
    try stdout.flush();

    var core = try Zetal.engine.Core.init();

    // 1. Load Model
    const model = try Zetal.loader.loadObj(allocator, "cube.obj", io);
    try stdout.print("Model loaded.\n", .{});
    try stdout.flush();

    // 2. Load Texture (NEW)
    try stdout.print("Loading test.ppm...\n", .{});
    try stdout.flush();
    const ppm = try Zetal.texture.loadPPM(allocator, "test.ppm", io);
    defer ppm.deinit(); // Clean up CPU memory after upload
    try stdout.print("Texture loaded: {d}x{d}\n", .{ ppm.width, ppm.height });
    try stdout.flush();

    // 3. Initialize Scene
    var scene = try Zetal.scene.Scene.init(allocator);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const fi = @as(f32, @floatFromInt(i));
        const angle = fi * 0.5;
        const radius = 2.0 + (fi * 0.1);
        const x = @cos(angle) * radius;
        const z = @sin(angle) * radius - 10.0;
        const y = (fi * 0.2) - 10.0;
        try scene.add(x, y, z);
    }

    // 4. Upload Texture to GPU
    // RGBA8Unorm = 70
    const texture = core.device.createTexture(ppm.width, ppm.height, 70).?;

    const region = Zetal.MTLRegion{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = ppm.width, .height = ppm.height, .depth = 1 } };

    // Bytes per row = Width * 4 (RGBA)
    texture.replaceRegion(region, @ptrCast(ppm.pixels.ptr), ppm.width * 4);

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

    const vertex_buffer = core.device.createBuffer(@sizeOf(Zetal.render.vertex.Vertex) * model.vertices.len, .StorageModeShared).?;
    const dest_ptr = @as([*]Zetal.render.vertex.Vertex, @ptrCast(@alignCast(vertex_buffer.contents())));
    @memcpy(dest_ptr[0..model.vertices.len], model.vertices);

    const index_buffer = core.device.createBuffer(@sizeOf(u32) * model.indices.len, .StorageModeShared).?;
    const index_ptr = @as([*]u32, @ptrCast(@alignCast(index_buffer.contents())));
    @memcpy(index_ptr[0..model.indices.len], model.indices);

    try stdout.print("Engine Ready.\n", .{});
    try stdout.flush();

    var cam_x: f32 = 0.0;
    var cam_y: f32 = 0.0;
    var cam_z: f32 = 0.0;
    const speed: f32 = 0.1;
    const start_time = try Io.Clock.Timestamp.now(io, .awake);

    while (true) {
        core.pollEvents();
        if (core.app.isPressed(.W)) cam_z += speed;
        if (core.app.isPressed(.S)) cam_z -= speed;
        if (core.app.isPressed(.A)) cam_x -= speed;
        if (core.app.isPressed(.D)) cam_x += speed;
        if (core.app.isPressed(.Q)) cam_y += speed;
        if (core.app.isPressed(.E)) cam_y -= speed;

        const now = try Io.Clock.Timestamp.now(io, .awake);
        const elapsed = start_time.durationTo(now);
        const time_sec = @as(f32, @floatFromInt(elapsed.raw.toMilliseconds())) / 1000.0;

        const view_mat = Math.Mat4x4.translate(cam_x, cam_y, cam_z);
        const proj_mat = Math.Mat4x4.perspective(std.math.degreesToRadians(45.0), 800.0 / 600.0, 0.1, 100.0);
        const model_view = Math.Mat4x4.mul(proj_mat, view_mat);

        const bg_color = Zetal.render.MTLClearColor{ .red = 0.1, .green = 0.1, .blue = 0.1, .alpha = 1.0 };

        if (core.beginFrame(bg_color)) |frame| {
            frame.enc.setRenderPipelineState(pipeline_state.handle);
            frame.enc.setDepthStencilState(depth_state.handle);
            frame.enc.setVertexBuffer(vertex_buffer.handle, 0, 0);
            frame.enc.setFragmentTexture(texture.handle, 0);

            for (scene.objects.items, 0..) |obj, idx| {
                const spin = obj.rot_y + (@as(f32, @floatFromInt(idx)) * 0.05);
                const rot_mat = Math.Mat4x4.rotateY(spin + time_sec);
                var final_model = rot_mat;
                final_model.columns[3][0] = obj.x;
                final_model.columns[3][1] = obj.y;
                final_model.columns[3][2] = obj.z;

                const mvp = Math.Mat4x4.mul(model_view, final_model);
                frame.enc.setVertexBytes(&mvp, @sizeOf(Math.Mat4x4), 1);
                frame.enc.drawIndexedPrimitives(.Triangle, model.indices.len, .UInt32, index_buffer.handle, 0);
            }

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
