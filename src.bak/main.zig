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

const LightUniforms = extern struct {
    light_pos: [3]f32,
    _pad0: f32 = 0,
    view_pos: [3]f32,
    _pad1: f32 = 0,
    light_color: [3]f32,
    _pad2: f32 = 0,
    ambient_strength: f32,
    specular_strength: f32,
    shininess: f32,
    _pad3: f32 = 0,
};

fn ortho(left: f32, right_: f32, bottom: f32, top: f32, near: f32, far: f32) Math.Mat4x4 {
    const rl = right_ - left;
    const tb = top - bottom;
    const fn_ = far - near;
    var m = Math.Mat4x4.identity();
    m.columns[0][0] = 2.0 / rl;
    m.columns[1][1] = 2.0 / tb;
    m.columns[2][2] = -1.0 / fn_;
    m.columns[3][0] = -(right_ + left) / rl;
    m.columns[3][1] = -(top + bottom) / tb;
    m.columns[3][2] = -near / fn_;
    return m;
}

/// Create a depth stencil state with raw ObjC: depthWrite OFF, compare Always.
fn createSkyboxDepthState(device: Zetal.MetalDevice) ?Zetal.render.pipeline.MetalDepthStencilState {
    const desc_class = Zetal.objc.objc_getClass("MTLDepthStencilDescriptor");
    const alloc_sel = Zetal.objc.getSelector("alloc");
    const init_sel = Zetal.objc.getSelector("init");

    const AllocFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
    const alloc_msg: AllocFn = @ptrCast(&Zetal.objc.objc_msgSend);
    var desc = alloc_msg(desc_class, alloc_sel);

    const InitFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
    const init_msg: InitFn = @ptrCast(&Zetal.objc.objc_msgSend);
    desc = init_msg(desc, init_sel);

    // setDepthCompareFunction: 3 = LessEqual
    const cmp_sel = Zetal.objc.getSelector("setDepthCompareFunction:");
    const CmpFn = *const fn (?*anyopaque, ?*anyopaque, u64) callconv(.c) void;
    const cmp_msg: CmpFn = @ptrCast(&Zetal.objc.objc_msgSend);
    cmp_msg(desc, cmp_sel, 3);

    // setDepthWriteEnabled: false
    const write_sel = Zetal.objc.getSelector("setDepthWriteEnabled:");
    const WriteFn = *const fn (?*anyopaque, ?*anyopaque, bool) callconv(.c) void;
    const write_msg: WriteFn = @ptrCast(&Zetal.objc.objc_msgSend);
    write_msg(desc, write_sel, false);

    const new_sel = Zetal.objc.getSelector("newDepthStencilStateWithDescriptor:");
    const NewFn = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?Zetal.objc.Object;
    const new_msg: NewFn = @ptrCast(&Zetal.objc.objc_msgSend);
    if (new_msg(device.handle, new_sel, desc)) |s| return Zetal.render.pipeline.MetalDepthStencilState{ .handle = s };
    return null;
}

// Skybox cube vertices (inside-facing, 36 verts, just float4 positions)
const skybox_verts = [36][4]f32{
    // +Z face (looking inward)
    .{ -1, 1, 1, 1 },  .{ -1, -1, 1, 1 },  .{ 1, -1, 1, 1 },
    .{ -1, 1, 1, 1 },  .{ 1, -1, 1, 1 },   .{ 1, 1, 1, 1 },
    // -Z face
    .{ 1, 1, -1, 1 },  .{ 1, -1, -1, 1 },  .{ -1, -1, -1, 1 },
    .{ 1, 1, -1, 1 },  .{ -1, -1, -1, 1 }, .{ -1, 1, -1, 1 },
    // +X face
    .{ 1, 1, 1, 1 },   .{ 1, -1, 1, 1 },   .{ 1, -1, -1, 1 },
    .{ 1, 1, 1, 1 },   .{ 1, -1, -1, 1 },  .{ 1, 1, -1, 1 },
    // -X face
    .{ -1, 1, -1, 1 }, .{ -1, -1, -1, 1 }, .{ -1, -1, 1, 1 },
    .{ -1, 1, -1, 1 }, .{ -1, -1, 1, 1 },  .{ -1, 1, 1, 1 },
    // +Y face (ceiling)
    .{ -1, 1, -1, 1 }, .{ -1, 1, 1, 1 },   .{ 1, 1, 1, 1 },
    .{ -1, 1, -1, 1 }, .{ 1, 1, 1, 1 },    .{ 1, 1, -1, 1 },
    // -Y face (floor)
    .{ -1, -1, 1, 1 }, .{ -1, -1, -1, 1 }, .{ 1, -1, -1, 1 },
    .{ -1, -1, 1, 1 }, .{ 1, -1, -1, 1 },  .{ 1, -1, 1, 1 },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer_impl = Io.File.Writer.init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_writer_impl.interface;

    try stdout.print("Starting Zetal Engine (Skybox + Shadows)...\n", .{});
    try stdout.flush();

    var core = try Zetal.engine.Core.init();

    // Load Assets
    const model = try Zetal.loader.loadObj(allocator, "cube.obj", io);
    const ppm = try Zetal.texture.loadPPM(allocator, "test.ppm", io);
    defer ppm.deinit();

    // --- ECS WORLD ---
    var world = Zetal.ecs.World.init();
    try Zetal.scene.spawnCubeField(&world, 100);
    const instance_count = world.countMatching(Zetal.ecs.mask(&.{ .transform, .mesh_renderer }));

    // Upload Texture
    const texture = core.device.createTexture(ppm.width, ppm.height, 70).?;
    const region = Zetal.MTLRegion{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = ppm.width, .height = ppm.height, .depth = 1 } };
    texture.replaceRegion(region, @ptrCast(ppm.pixels.ptr), ppm.width * 4);

    // --- SHADER LIBRARY ---
    const library = core.device.createLibrary(Zetal.render.shader.triangle_source).?;

    // --- PIPELINES ---

    // Cube pipeline (instanced)
    const cube_pipe_desc = Zetal.render.MetalRenderPipelineDescriptor.create().?;
    cube_pipe_desc.setVertexFunction(library.getFunction("vertex_main").?.handle);
    cube_pipe_desc.setFragmentFunction(library.getFunction("fragment_main").?.handle);
    cube_pipe_desc.setColorAttachmentPixelFormat(0, 80);
    cube_pipe_desc.setDepthAttachmentPixelFormat(252);
    const cube_pipeline = core.device.createRenderPipelineState(cube_pipe_desc).?;

    // Ground pipeline (single)
    const ground_pipe_desc = Zetal.render.MetalRenderPipelineDescriptor.create().?;
    ground_pipe_desc.setVertexFunction(library.getFunction("vertex_single").?.handle);
    ground_pipe_desc.setFragmentFunction(library.getFunction("fragment_main").?.handle);
    ground_pipe_desc.setColorAttachmentPixelFormat(0, 80);
    ground_pipe_desc.setDepthAttachmentPixelFormat(252);
    const ground_pipeline = core.device.createRenderPipelineState(ground_pipe_desc).?;

    // Shadow pipeline (instanced, depth-only)
    const shadow_pipe_desc = Zetal.render.MetalRenderPipelineDescriptor.create().?;
    shadow_pipe_desc.setVertexFunction(library.getFunction("shadow_vertex").?.handle);
    shadow_pipe_desc.setDepthAttachmentPixelFormat(252);
    const shadow_pipeline = core.device.createRenderPipelineState(shadow_pipe_desc).?;

    // Shadow ground pipeline (single, depth-only)
    const shadow_ground_desc = Zetal.render.MetalRenderPipelineDescriptor.create().?;
    shadow_ground_desc.setVertexFunction(library.getFunction("shadow_vertex_single").?.handle);
    shadow_ground_desc.setDepthAttachmentPixelFormat(252);
    const shadow_ground_pipeline = core.device.createRenderPipelineState(shadow_ground_desc).?;

    // Skybox pipeline
    const sky_pipe_desc = Zetal.render.MetalRenderPipelineDescriptor.create().?;
    sky_pipe_desc.setVertexFunction(library.getFunction("skybox_vertex").?.handle);
    sky_pipe_desc.setFragmentFunction(library.getFunction("skybox_fragment").?.handle);
    sky_pipe_desc.setColorAttachmentPixelFormat(0, 80);
    sky_pipe_desc.setDepthAttachmentPixelFormat(252);
    const sky_pipeline = core.device.createRenderPipelineState(sky_pipe_desc).?;

    // --- DEPTH STATES ---

    // Normal: depth write ON, compare Less
    const depth_desc = Zetal.render.pipeline.MetalDepthStencilDescriptor.create().?;
    depth_desc.setDepthCompareFunction(.Less);
    depth_desc.setDepthWriteEnabled(true);
    const depth_state = core.device.createDepthStencilState(depth_desc).?;

    // Skybox: depth write OFF, compare LessEqual (skybox z = 1.0 = clear depth)
    const sky_depth_state = createSkyboxDepthState(core.device).?;

    // --- CUBE BUFFERS ---
    const Vertex = Zetal.render.vertex.Vertex;
    const vertex_buffer = core.device.createBuffer(@sizeOf(Vertex) * model.vertices.len, .StorageModeShared).?;
    @memcpy(@as([*]Vertex, @ptrCast(@alignCast(vertex_buffer.contents())))[0..model.vertices.len], model.vertices);
    const index_buffer = core.device.createBuffer(@sizeOf(u32) * model.indices.len, .StorageModeShared).?;
    @memcpy(@as([*]u32, @ptrCast(@alignCast(index_buffer.contents())))[0..model.indices.len], model.indices);

    // Instance buffers
    const mvp_buffer = core.device.createBuffer(@sizeOf(Math.Mat4x4) * instance_count, .StorageModeShared).?;
    const model_buffer = core.device.createBuffer(@sizeOf(Math.Mat4x4) * instance_count, .StorageModeShared).?;
    const shadow_mvp_buffer = core.device.createBuffer(@sizeOf(Math.Mat4x4) * instance_count, .StorageModeShared).?;

    // --- GROUND PLANE ---
    const ground_size: f32 = 50.0;
    const ground_y: f32 = -12.0;
    const ground_verts = [_]Vertex{
        .{ .position = .{ -ground_size, ground_y, -ground_size, 1 }, .color = .{ 0.3, 0.35, 0.3, 1 }, .uv = .{ 0, 0, 0, 0 }, .normal = .{ 0, 1, 0, 0 } },
        .{ .position = .{ ground_size, ground_y, -ground_size, 1 }, .color = .{ 0.3, 0.35, 0.3, 1 }, .uv = .{ 10, 0, 0, 0 }, .normal = .{ 0, 1, 0, 0 } },
        .{ .position = .{ ground_size, ground_y, ground_size, 1 }, .color = .{ 0.3, 0.35, 0.3, 1 }, .uv = .{ 10, 10, 0, 0 }, .normal = .{ 0, 1, 0, 0 } },
        .{ .position = .{ -ground_size, ground_y, ground_size, 1 }, .color = .{ 0.3, 0.35, 0.3, 1 }, .uv = .{ 0, 10, 0, 0 }, .normal = .{ 0, 1, 0, 0 } },
    };
    const ground_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };

    const ground_vbuf = core.device.createBuffer(@sizeOf(Vertex) * ground_verts.len, .StorageModeShared).?;
    @memcpy(@as([*]Vertex, @ptrCast(@alignCast(ground_vbuf.contents())))[0..ground_verts.len], &ground_verts);
    const ground_ibuf = core.device.createBuffer(@sizeOf(u32) * ground_indices.len, .StorageModeShared).?;
    @memcpy(@as([*]u32, @ptrCast(@alignCast(ground_ibuf.contents())))[0..ground_indices.len], &ground_indices);

    // --- SKYBOX BUFFER ---
    const sky_vbuf = core.device.createBuffer(@sizeOf([4]f32) * 36, .StorageModeShared).?;
    @memcpy(@as([*][4]f32, @ptrCast(@alignCast(sky_vbuf.contents())))[0..36], &skybox_verts);

    try stdout.print("Engine Ready. {d} cubes + ground + skybox.\n", .{instance_count});
    try stdout.flush();

    // --- CAMERA STATE ---
    var cam_pos = Vec3.init(0, 0, 5);
    var cam_yaw: f32 = -90.0;
    var cam_pitch: f32 = 0.0;
    const move_speed: f32 = 5.0;
    const mouse_sensitivity: f32 = 0.1;
    const cam_radius: f32 = 0.3;

    const start_time = try Io.Clock.Timestamp.now(io, .awake);
    var last_time = start_time;

    while (true) {
        const now = try Io.Clock.Timestamp.now(io, .awake);
        const frame_dt = last_time.durationTo(now);
        last_time = now;
        const dt_sec = @as(f32, @floatFromInt(frame_dt.raw.toMilliseconds())) / 1000.0;

        core.pollEvents();
        const aspect = core.updateSize();

        // Mouse Look
        cam_yaw += core.app.mouse_dx * mouse_sensitivity;
        cam_pitch += core.app.mouse_dy * mouse_sensitivity;
        if (cam_pitch > 89.0) cam_pitch = 89.0;
        if (cam_pitch < -89.0) cam_pitch = -89.0;

        // Camera Vectors
        const yaw_rad = std.math.degreesToRadians(cam_yaw);
        const pitch_rad = std.math.degreesToRadians(cam_pitch);

        const front = Vec3.norm(Vec3.init(
            @cos(yaw_rad) * @cos(pitch_rad),
            @sin(pitch_rad),
            @sin(yaw_rad) * @cos(pitch_rad),
        ));

        const world_up = Vec3.init(0, 1, 0);
        const right = Vec3.norm(Vec3.cross(front, world_up));
        const cam_up = Vec3.norm(Vec3.cross(right, front));

        // Movement
        const velocity = move_speed * dt_sec;
        if (core.app.isPressed(.W)) cam_pos = Vec3.add(cam_pos, Vec3.scale(front, velocity));
        if (core.app.isPressed(.S)) cam_pos = Vec3.sub(cam_pos, Vec3.scale(front, velocity));
        if (core.app.isPressed(.A)) cam_pos = Vec3.sub(cam_pos, Vec3.scale(right, velocity));
        if (core.app.isPressed(.D)) cam_pos = Vec3.add(cam_pos, Vec3.scale(right, velocity));
        if (core.app.isPressed(.Q)) cam_pos = Vec3.add(cam_pos, Vec3.scale(world_up, velocity));
        if (core.app.isPressed(.E)) cam_pos = Vec3.sub(cam_pos, Vec3.scale(world_up, velocity));

        // Camera Collision
        const resolved = Zetal.systems.resolveCamera(&world, cam_pos.x, cam_pos.y, cam_pos.z, cam_radius);
        cam_pos = Vec3.init(resolved.x, resolved.y, resolved.z);

        // View-Projection
        const center = Vec3.add(cam_pos, front);
        const view_mat = Math.Mat4x4.lookAt(cam_pos, center, cam_up);
        const proj_mat = Math.Mat4x4.perspective(std.math.degreesToRadians(45.0), aspect, 0.1, 200.0);
        const view_proj = Math.Mat4x4.mul(proj_mat, view_mat);

        // Light View-Projection
        const light_pos = Vec3.init(10.0, 20.0, 10.0);
        const light_target = Vec3.init(0.0, -5.0, -10.0);
        const light_view = Math.Mat4x4.lookAt(light_pos, light_target, Vec3.init(0, 1, 0));
        const light_proj = ortho(-30.0, 30.0, -30.0, 30.0, 0.1, 60.0);
        const light_vp = Math.Mat4x4.mul(light_proj, light_view);

        // ECS Systems
        const total_elapsed = start_time.durationTo(now).raw.toMilliseconds();
        const time_sec = @as(f32, @floatFromInt(total_elapsed)) / 1000.0;

        Zetal.systems.spinSystem(&world, time_sec);
        Zetal.systems.velocitySystem(&world, dt_sec);
        Zetal.systems.collisionSystem(&world);

        // Build instance buffers
        const gpu_mvps = @as([*]Math.Mat4x4, @ptrCast(@alignCast(mvp_buffer.contents())));
        const gpu_models = @as([*]Math.Mat4x4, @ptrCast(@alignCast(model_buffer.contents())));
        const drawn = Zetal.systems.buildInstanceBuffer(&world, view_proj, gpu_mvps, gpu_models);

        // Shadow MVPs
        const gpu_shadow_mvps = @as([*]Math.Mat4x4, @ptrCast(@alignCast(shadow_mvp_buffer.contents())));
        for (0..drawn) |idx| {
            gpu_shadow_mvps[idx] = Math.Mat4x4.mul(light_vp, gpu_models[idx]);
        }

        // Light uniforms
        var light = LightUniforms{
            .light_pos = .{ 10.0, 20.0, 10.0 },
            .view_pos = .{ cam_pos.x, cam_pos.y, cam_pos.z },
            .light_color = .{ 1.0, 0.95, 0.9 },
            .ambient_strength = 0.15,
            .specular_strength = 0.5,
            .shininess = 32.0,
        };
        _ = &light;

        // Sun direction (matches light position, normalized)
        var sun_dir = [3]f32{ 10.0, 20.0, 10.0 };
        _ = &sun_dir;
        const sun_len = @sqrt(sun_dir[0] * sun_dir[0] + sun_dir[1] * sun_dir[1] + sun_dir[2] * sun_dir[2]);
        sun_dir[0] /= sun_len;
        sun_dir[1] /= sun_len;
        sun_dir[2] /= sun_len;

        // Ground matrices
        const ground_model = Math.Mat4x4.identity();
        const ground_mvp = Math.Mat4x4.mul(view_proj, ground_model);
        const ground_shadow_mvp = Math.Mat4x4.mul(light_vp, ground_model);

        // =============================================
        // PASS 1: SHADOW MAP
        // =============================================
        if (core.beginShadowPass()) |shadow| {
            shadow.enc.setDepthStencilState(depth_state.handle);

            // Cubes
            shadow.enc.setRenderPipelineState(shadow_pipeline.handle);
            shadow.enc.setVertexBuffer(vertex_buffer.handle, 0, 0);
            shadow.enc.setVertexBuffer(shadow_mvp_buffer.handle, 0, 1);
            shadow.enc.drawIndexedPrimitivesInstanced(.Triangle, model.indices.len, .UInt32, index_buffer.handle, 0, drawn);

            // Ground
            shadow.enc.setRenderPipelineState(shadow_ground_pipeline.handle);
            shadow.enc.setVertexBuffer(ground_vbuf.handle, 0, 0);
            shadow.enc.setVertexBytes(@ptrCast(&ground_shadow_mvp), @sizeOf(Math.Mat4x4), 1);
            shadow.enc.drawIndexedPrimitives(.Triangle, ground_indices.len, .UInt32, ground_ibuf.handle, 0);

            shadow.enc.endEncoding();
            shadow.cmd.commit();
        }

        // =============================================
        // PASS 2: MAIN RENDER
        // =============================================
        const bg_color = Zetal.render.MTLClearColor{ .red = 0.0, .green = 0.0, .blue = 0.0, .alpha = 1.0 };
        if (core.beginFrame(bg_color)) |frame| {

            // --- SKYBOX (draw first, no depth write, LessEqual) ---
            frame.enc.setDepthStencilState(sky_depth_state.handle);
            frame.enc.setRenderPipelineState(sky_pipeline.handle);
            frame.enc.setVertexBuffer(sky_vbuf.handle, 0, 0);
            frame.enc.setVertexBytes(@ptrCast(&view_proj), @sizeOf(Math.Mat4x4), 1);
            frame.enc.setFragmentBytes(@ptrCast(&sun_dir), @sizeOf([3]f32), 0);
            frame.enc.drawPrimitives(.Triangle, 0, 36);

            // --- Switch to normal depth state ---
            frame.enc.setDepthStencilState(depth_state.handle);

            // Bind textures
            frame.enc.setFragmentTexture(texture.handle, 0);
            frame.enc.setFragmentTexture(core.shadow_map.handle, 1);
            frame.enc.setFragmentBytes(@ptrCast(&light), @sizeOf(LightUniforms), 2);

            // --- CUBES (instanced) ---
            frame.enc.setRenderPipelineState(cube_pipeline.handle);
            frame.enc.setVertexBuffer(vertex_buffer.handle, 0, 0);
            frame.enc.setVertexBuffer(mvp_buffer.handle, 0, 1);
            frame.enc.setVertexBuffer(model_buffer.handle, 0, 3);
            frame.enc.setVertexBytes(@ptrCast(&light_vp), @sizeOf(Math.Mat4x4), 4);
            frame.enc.drawIndexedPrimitivesInstanced(.Triangle, model.indices.len, .UInt32, index_buffer.handle, 0, drawn);

            // --- GROUND (single) ---
            frame.enc.setRenderPipelineState(ground_pipeline.handle);
            frame.enc.setVertexBuffer(ground_vbuf.handle, 0, 0);
            frame.enc.setVertexBytes(@ptrCast(&ground_mvp), @sizeOf(Math.Mat4x4), 1);
            frame.enc.setVertexBytes(@ptrCast(&ground_model), @sizeOf(Math.Mat4x4), 3);
            frame.enc.setVertexBytes(@ptrCast(&light_vp), @sizeOf(Math.Mat4x4), 4);
            frame.enc.drawIndexedPrimitives(.Triangle, ground_indices.len, .UInt32, ground_ibuf.handle, 0);

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

        simpleSleep(8 * 1000 * 1000);
    }
}
