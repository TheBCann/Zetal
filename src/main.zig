const std = @import("std");
const Zetal = @import("Zetal");
const Math = Zetal.render.math;
const Vec3 = Math.Vec3;
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

    try stdout.print("Starting Zetal Engine (FPS Camera)...\n", .{});
    try stdout.flush();

    var core = try Zetal.engine.Core.init();

    // Load Assets
    const model = try Zetal.loader.loadObj(allocator, "cube.obj", io);
    const ppm = try Zetal.texture.loadPPM(allocator, "test.ppm", io);
    defer ppm.deinit();

    // Scene
    var scene = try Zetal.scene.Scene.init(allocator);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const fi = @as(f32, @floatFromInt(i));
        const angle = fi * 0.5;
        const radius = 2.0 + (fi * 0.1);
        try scene.add(@cos(angle) * radius, (fi * 0.2) - 10.0, @sin(angle) * radius - 10.0);
    }

    // Upload Texture
    const texture = core.device.createTexture(ppm.width, ppm.height, 70).?;
    const region = Zetal.MTLRegion{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = ppm.width, .height = ppm.height, .depth = 1 } };
    texture.replaceRegion(region, @ptrCast(ppm.pixels.ptr), ppm.width * 4);

    // Pipeline
    const library = core.device.createLibrary(Zetal.render.shader.triangle_source).?;
    const pipe_desc = Zetal.render.MetalRenderPipelineDescriptor.create().?;
    pipe_desc.setVertexFunction(library.getFunction("vertex_main").?.handle);
    pipe_desc.setFragmentFunction(library.getFunction("fragment_main").?.handle);
    pipe_desc.setColorAttachmentPixelFormat(0, 80);
    pipe_desc.setDepthAttachmentPixelFormat(252);
    const pipeline_state = core.device.createRenderPipelineState(pipe_desc).?;

    const depth_desc = Zetal.render.pipeline.MetalDepthStencilDescriptor.create().?;
    depth_desc.setDepthCompareFunction(.Less);
    depth_desc.setDepthWriteEnabled(true);
    const depth_state = core.device.createDepthStencilState(depth_desc).?;

    // Buffers
    const vertex_buffer = core.device.createBuffer(@sizeOf(Zetal.render.vertex.Vertex) * model.vertices.len, .StorageModeShared).?;
    @memcpy(@as([*]Zetal.render.vertex.Vertex, @ptrCast(@alignCast(vertex_buffer.contents())))[0..model.vertices.len], model.vertices);
    const index_buffer = core.device.createBuffer(@sizeOf(u32) * model.indices.len, .StorageModeShared).?;
    @memcpy(@as([*]u32, @ptrCast(@alignCast(index_buffer.contents())))[0..model.indices.len], model.indices);

    // --- CAMERA STATE ---
    var cam_pos = Vec3.init(0, 0, 5); // Start back a bit
    var cam_yaw: f32 = -90.0; // Facing -Z
    var cam_pitch: f32 = 0.0;
    const move_speed: f32 = 5.0; // Units per second
    const mouse_sensitivity: f32 = 0.1;

    const start_time = try Io.Clock.Timestamp.now(io, .awake);
    var last_time = start_time;

    while (true) {
        // Time Delta
        const now = try Io.Clock.Timestamp.now(io, .awake);
        const frame_dt = last_time.durationTo(now);
        last_time = now;
        const dt_sec = @as(f32, @floatFromInt(frame_dt.raw.toMilliseconds())) / 1000.0;

        // Input
        core.pollEvents();

        // 1. Mouse Look
        cam_yaw += core.app.mouse_dx * mouse_sensitivity;
        cam_pitch += core.app.mouse_dy * mouse_sensitivity;
        // cam_pitch -= core.app.mouse_dy * mouse_sensitivity;  // FPS NAVIGATION

        // Clamp Pitch (Prevent backflip)
        if (cam_pitch > 89.0) cam_pitch = 89.0;
        if (cam_pitch < -89.0) cam_pitch = -89.0;

        // 2. Calculate Forward/Right Vectors
        // Convert Spherical to Cartesian
        const yaw_rad = std.math.degreesToRadians(cam_yaw);
        const pitch_rad = std.math.degreesToRadians(cam_pitch);

        const front = Vec3.norm(Vec3.init(@cos(yaw_rad) * @cos(pitch_rad), @sin(pitch_rad), // Note: Metal/Y-up might need inversion here depending on coord system. Let's test.
            @sin(yaw_rad) * @cos(pitch_rad)));

        // Standard Up
        const world_up = Vec3.init(0, 1, 0);
        const right = Vec3.norm(Vec3.cross(front, world_up));
        // Recalculate camera up (for roll/tilt)
        const cam_up = Vec3.norm(Vec3.cross(right, front));

        // 3. Movement (WASD) - Now relative to looking direction
        const velocity = move_speed * dt_sec;
        if (core.app.isPressed(.W)) cam_pos = Vec3.add(cam_pos, Vec3.scale(front, velocity));
        if (core.app.isPressed(.S)) cam_pos = Vec3.sub(cam_pos, Vec3.scale(front, velocity));
        if (core.app.isPressed(.A)) cam_pos = Vec3.sub(cam_pos, Vec3.scale(right, velocity)); // Strafe Left
        if (core.app.isPressed(.D)) cam_pos = Vec3.add(cam_pos, Vec3.scale(right, velocity)); // Strafe Right
        if (core.app.isPressed(.Q)) cam_pos = Vec3.add(cam_pos, Vec3.scale(world_up, velocity)); // Fly Up
        if (core.app.isPressed(.E)) cam_pos = Vec3.sub(cam_pos, Vec3.scale(world_up, velocity)); // Fly Down

        // Construct View Matrix using LookAt
        const center = Vec3.add(cam_pos, front);
        const view_mat = Math.Mat4x4.lookAt(cam_pos, center, cam_up);
        const proj_mat = Math.Mat4x4.perspective(std.math.degreesToRadians(45.0), 800.0 / 600.0, 0.1, 100.0);
        const view_proj = Math.Mat4x4.mul(proj_mat, view_mat);

        // Render
        const bg_color = Zetal.render.MTLClearColor{ .red = 0.1, .green = 0.1, .blue = 0.1, .alpha = 1.0 };
        if (core.beginFrame(bg_color)) |frame| {
            frame.enc.setRenderPipelineState(pipeline_state.handle);
            frame.enc.setDepthStencilState(depth_state.handle);
            frame.enc.setVertexBuffer(vertex_buffer.handle, 0, 0);
            frame.enc.setFragmentTexture(texture.handle, 0);

            // Time for rotation
            const total_elapsed = start_time.durationTo(now).raw.toMilliseconds();
            const time_sec = @as(f32, @floatFromInt(total_elapsed)) / 1000.0;

            for (scene.objects.items, 0..) |obj, idx| {
                const spin = obj.rot_y + (@as(f32, @floatFromInt(idx)) * 0.05);
                const rot_mat = Math.Mat4x4.rotateY(spin + time_sec);

                var final_model = rot_mat;
                final_model.columns[3][0] = obj.x;
                final_model.columns[3][1] = obj.y;
                final_model.columns[3][2] = obj.z;

                const mvp = Math.Mat4x4.mul(view_proj, final_model);
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

        // Slightly shorter sleep for higher FPS feel
        simpleSleep(8 * 1000 * 1000);
    }
}
