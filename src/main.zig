const std = @import("std");
const Zetal = @import("Zetal");
const Math = Zetal.render.math;
const Vec3 = Math.Vec3;
const LightUniforms = Zetal.render.lighting.LightUniforms;
const Io = std.Io;

const KILL_Y: f32 = -30.0;
const GROUND_Y: f32 = Zetal.render.buffers.GROUND_Y;
const SUN_POS = Vec3.init(10.0, 20.0, 10.0);
const SUN_TARGET = Vec3.init(0.0, -5.0, -10.0);
const SUN_LEN = @sqrt(SUN_POS.x * SUN_POS.x + SUN_POS.y * SUN_POS.y + SUN_POS.z * SUN_POS.z);
const SUN_DIR = [3]f32{ SUN_POS.x / SUN_LEN, SUN_POS.y / SUN_LEN, SUN_POS.z / SUN_LEN };

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer_impl = Io.File.Writer.init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_writer_impl.interface;

    try stdout.print("Starting Zetal Engine (FPS Mode)...\n", .{});
    try stdout.flush();

    var core = try Zetal.engine.Core.init();

    // --- Assets ---
    const cube_mesh = try Zetal.loader.loadObj(allocator, "cube.obj", io);
    const gun_mesh = try Zetal.loader.loadObj(allocator, "hands.obj", io);
    const world_ppm = try Zetal.texture.loadPPM(allocator, "test.ppm", io);
    defer world_ppm.deinit();
    const gun_ppm = try Zetal.texture.loadPPM(allocator, "gun_metal.ppm", io);
    defer gun_ppm.deinit();

    // --- World ---
    var world = Zetal.ecs.World.init();
    try Zetal.scene.spawnFPSScene(&world);
    const initial_count = world.countMatching(Zetal.ecs.mask(&.{ .transform, .mesh_renderer }));

    // --- GPU compute physics ---
    var compute_phys = try Zetal.render.compute.ComputePhysics.init(
        core.device,
        core.queue,
        Zetal.ecs.world.MAX_ENTITIES,
    );

    // --- Render resources ---
    const pipes = try Zetal.render.pipelines.Pipelines.init(core.device);
    const static_bufs = try Zetal.render.buffers.StaticBuffers.init(
        core.device,
        cube_mesh,
        gun_mesh,
        world_ppm,
        gun_ppm,
    );
    const instance_bufs = try Zetal.render.buffers.InstanceBuffers.init(
        core.device,
        Zetal.ecs.world.MAX_ENTITIES,
    );

    // --- Player ---
    var player = Zetal.Player.init();

    try stdout.print("FPS Mode Ready. {d} target cubes. Left-click to fire!\n", .{initial_count});
    try stdout.print("GPU Compute Physics: spatial hash grid + impact conversion\n", .{});
    try stdout.flush();

    const start_time = Io.Clock.Timestamp.now(io, .awake);
    var last_time = start_time;

    while (true) {
        var pool = Zetal.AutoreleasePool.init();
        defer pool.deinit();

        const now = Io.Clock.Timestamp.now(io, .awake);
        const frame_dt_ns = last_time.durationTo(now).raw.toNanoseconds();
        last_time = now;
        // Clamp dt: a window drag or system hitch can produce a huge frame delta,
        // and at 40 u/s a projectile would tunnel straight through colliders.
        const dt_sec = @min(@as(f32, @floatFromInt(frame_dt_ns)) / @as(f32, std.time.ns_per_s), 0.033);

        const total_elapsed_ns = start_time.durationTo(now).raw.toNanoseconds();
        const time_sec = @as(f32, @floatFromInt(total_elapsed_ns)) / @as(f32, std.time.ns_per_s);

        core.pollEvents();
        const aspect = core.updateSize();

        // ── Per-frame simulation ─────────────────────────────
        player.update(&core.app, &world, GROUND_Y, dt_sec);

        Zetal.systems.spinSystem(&world, time_sec);
        Zetal.systems.hitTimerSystem(&world, dt_sec);

        compute_phys.uploadToGPU(&world);
        compute_phys.dispatch(dt_sec, world.count);
        compute_phys.downloadToWorld(&world);

        if (Zetal.systems.resolveCollisionPairs(&world, compute_phys.readPairs(), 0.5)) {
            player.onConfirmedHit();
        }

        Zetal.systems.enforceFloor(&world, GROUND_Y, 0.6);
        _ = Zetal.systems.cleanupFallen(&world, KILL_Y);

        // ── Per-frame matrices ───────────────────────────────
        const cam = player.camera(aspect, time_sec);

        const light_view = Math.Mat4x4.lookAt(SUN_POS, SUN_TARGET, Vec3.init(0, 1, 0));
        const light_proj = Math.Mat4x4.ortho(-30.0, 30.0, -30.0, 30.0, 0.1, 60.0);
        const light_vp = Math.Mat4x4.mul(light_proj, light_view);

        const mvps = instance_bufs.mvps();
        const models = instance_bufs.models();
        const hit_timers = instance_bufs.hitTimers();
        const drawn = Zetal.systems.buildInstanceBuffer(&world, cam.view_proj, mvps, models, hit_timers);

        const shadow_mvps = instance_bufs.shadowMvps();
        for (0..drawn) |idx| {
            shadow_mvps[idx] = Math.Mat4x4.mul(light_vp, models[idx]);
        }

        const light = LightUniforms{
            .light_pos = .{ SUN_POS.x, SUN_POS.y, SUN_POS.z },
            .view_pos = .{ player.pos.x, player.pos.y, player.pos.z },
            .light_color = .{ 1.0, 0.95, 0.9 },
            .ambient_strength = 0.15,
            .specular_strength = 0.5,
            .shininess = 32.0,
        };

        const ground_model = Math.Mat4x4.identity();
        const ground_mvp = Math.Mat4x4.mul(cam.view_proj, ground_model);
        const ground_shadow_mvp = Math.Mat4x4.mul(light_vp, ground_model);

        // ── PASS 1: shadow map ───────────────────────────────
        if (core.beginShadowPass()) |shadow| {
            shadow.enc.setDepthStencilState(pipes.depth.handle);

            shadow.enc.setRenderPipelineState(pipes.shadow.handle);
            shadow.enc.setVertexBuffer(static_bufs.cube_vertex.handle, 0, 0);
            shadow.enc.setVertexBuffer(instance_bufs.shadow_mvp.handle, 0, 1);
            shadow.enc.drawIndexedPrimitivesInstanced(
                .triangle,
                static_bufs.cube_index_count,
                .uint32,
                static_bufs.cube_index.handle,
                0,
                drawn,
            );

            shadow.enc.setRenderPipelineState(pipes.shadow_ground.handle);
            shadow.enc.setVertexBuffer(static_bufs.ground_vertex.handle, 0, 0);
            shadow.enc.setVertexBytes(@ptrCast(&ground_shadow_mvp), @sizeOf(Math.Mat4x4), 1);
            shadow.enc.drawIndexedPrimitives(
                .triangle,
                static_bufs.ground_index_count,
                .uint32,
                static_bufs.ground_index.handle,
                0,
            );

            shadow.enc.endEncoding();
            shadow.cmd.commit();
        }

        // ── PASS 2: main color + depth ───────────────────────
        const bg_color = Zetal.render.MTLClearColor{ .red = 0.0, .green = 0.0, .blue = 0.0, .alpha = 1.0 };
        if (core.beginFrame(bg_color)) |frame| {
            // Skybox first — depth write off, LessEqual
            frame.enc.setDepthStencilState(pipes.sky_depth.handle);
            frame.enc.setRenderPipelineState(pipes.sky.handle);
            frame.enc.setVertexBuffer(static_bufs.skybox_vertex.handle, 0, 0);
            frame.enc.setVertexBytes(@ptrCast(&cam.view_proj), @sizeOf(Math.Mat4x4), 1);
            frame.enc.setFragmentBytes(@ptrCast(&SUN_DIR), @sizeOf([3]f32), 0);
            frame.enc.drawPrimitives(.triangle, 0, static_bufs.skybox_vertex_count);

            // Normal depth state from here on
            frame.enc.setDepthStencilState(pipes.depth.handle);
            frame.enc.setFragmentTexture(static_bufs.world_texture.handle, 0);
            frame.enc.setFragmentTexture(core.shadow_map.handle, 1);
            frame.enc.setFragmentBytes(@ptrCast(&light), @sizeOf(LightUniforms), 2);

            // Cubes (instanced)
            frame.enc.setRenderPipelineState(pipes.cube.handle);
            frame.enc.setVertexBuffer(static_bufs.cube_vertex.handle, 0, 0);
            frame.enc.setVertexBuffer(instance_bufs.mvp.handle, 0, 1);
            frame.enc.setVertexBuffer(instance_bufs.model.handle, 0, 3);
            frame.enc.setVertexBuffer(instance_bufs.hit_timer.handle, 0, 5);
            frame.enc.setVertexBytes(@ptrCast(&light_vp), @sizeOf(Math.Mat4x4), 4);
            frame.enc.drawIndexedPrimitivesInstanced(
                .triangle,
                static_bufs.cube_index_count,
                .uint32,
                static_bufs.cube_index.handle,
                0,
                drawn,
            );

            // Ground
            frame.enc.setRenderPipelineState(pipes.ground.handle);
            frame.enc.setVertexBuffer(static_bufs.ground_vertex.handle, 0, 0);
            frame.enc.setVertexBytes(@ptrCast(&ground_mvp), @sizeOf(Math.Mat4x4), 1);
            frame.enc.setVertexBytes(@ptrCast(&ground_model), @sizeOf(Math.Mat4x4), 3);
            frame.enc.setVertexBytes(@ptrCast(&light_vp), @sizeOf(Math.Mat4x4), 4);
            frame.enc.drawIndexedPrimitives(
                .triangle,
                static_bufs.ground_index_count,
                .uint32,
                static_bufs.ground_index.handle,
                0,
            );

            // Viewmodel (gun) — re-uses the single-mesh pipeline + a viewmodel depth state
            frame.enc.setDepthStencilState(pipes.viewmodel_depth.handle);
            frame.enc.setRenderPipelineState(pipes.ground.handle);
            frame.enc.setVertexBuffer(static_bufs.gun_vertex.handle, 0, 0);

            const gun_model_mat = player.gunModel(time_sec);
            // CRITICAL: gun is multiplied by proj only — glues it to the screen.
            const gun_mvp = Math.Mat4x4.mul(cam.proj, gun_model_mat);

            frame.enc.setFragmentTexture(static_bufs.gun_texture.handle, 0);
            frame.enc.setVertexBytes(@ptrCast(&gun_mvp), @sizeOf(Math.Mat4x4), 1);
            frame.enc.setVertexBytes(@ptrCast(&gun_model_mat), @sizeOf(Math.Mat4x4), 3);
            frame.enc.setVertexBytes(@ptrCast(&light_vp), @sizeOf(Math.Mat4x4), 4);
            frame.enc.drawIndexedPrimitives(
                .triangle,
                static_bufs.gun_index_count,
                .uint32,
                static_bufs.gun_index.handle,
                0,
            );

            // Crosshair last — no depth test, always on top
            frame.enc.setDepthStencilState(pipes.crosshair_depth.handle);
            frame.enc.setRenderPipelineState(pipes.crosshair.handle);
            frame.enc.setVertexBuffer(static_bufs.crosshair_vertex.handle, 0, 0);
            frame.enc.setVertexBytes(@ptrCast(&aspect), @sizeOf(f32), 1);
            frame.enc.setVertexBytes(@ptrCast(&player.hit_marker_timer), @sizeOf(f32), 2);
            frame.enc.setFragmentBytes(@ptrCast(&player.hit_marker_timer), @sizeOf(f32), 2);
            frame.enc.drawPrimitives(.triangle, 0, static_bufs.crosshair_vert_count);

            frame.submit();
        }
    }
}
