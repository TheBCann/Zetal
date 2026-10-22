<<<<<<< HEAD
//! Zetal game executable: command-line options, startup, and the vsync-paced frame loop with fixed-step GPU physics.

const std = @import("std");
const Zetal = @import("Zetal");

const Io = std.Io;
const objc = Zetal.objc;
const math = Zetal.math;
const platform = Zetal.platform;
const render = Zetal.render;
const metal = render.metal;
const ecs = Zetal.ecs;
const systems = ecs.systems;
const game = Zetal.game;

const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

const log = std.log.scoped(.zetal);

// ============================================================
// TUNING — the original's values unless noted
// ============================================================

const WINDOW_WIDTH: f64 = 800;
const WINDOW_HEIGHT: f64 = 600;
const WINDOW_TITLE = "Zetal Engine";

/// Longest step a frame may advance the simulation by; do not remove the clamp. After a hitch (a
/// window drag, a breakpoint) it bounds how far one frame moves the player, who integrates once per
/// frame (an unclamped second would carry the eye through walls in one resolveCamera pass), and how
/// many 1 ms physics substeps the frame replays (at most 34, under MAX_PHYSICS_STEPS). The substeps
/// themselves keep projectiles from tunnelling at any frame length.
const MAX_FRAME_DT: f32 = 0.033;
/// Fixed physics substep. Close to the original's ~0.6 ms loop period, so the per-step rules (MTV
/// push-out, floor friction 0.92, the bounce cutoff) feel as they did before vsync pacing.
const PHYSICS_DT: f32 = 0.001;
/// Most substeps per frame; a bigger backlog is dropped instead of snowballing.
const MAX_PHYSICS_STEPS: u32 = 40;
/// Restitution of body-body contacts.
const COLLISION_RESTITUTION: f32 = 0.5;
/// Restitution of the floor.
const FLOOR_RESTITUTION: f32 = 0.6;
/// Dynamic bodies that fall below this height are despawned.
const KILL_Y: f32 = -30.0;
const GROUND_Y = render.geometry.GROUND_Y;

/// The sun: shading light position, shadow camera eye and (normalized) the sky's sun disc direction.
const SUN_POS: Vec3 = .init(10.0, 20.0, 10.0);
/// Where the shadow camera looks.
const SUN_TARGET: Vec3 = .init(0.0, -5.0, -10.0);
/// Half the side of the shadow camera's orthographic box, and its depth range.
const SHADOW_HALF_EXTENT: f32 = 30.0;
const SHADOW_NEAR: f32 = 0.1;
const SHADOW_FAR: f32 = 60.0;
const LIGHT_COLOR = [3]f32{ 1.0, 0.95, 0.9 };
const AMBIENT_STRENGTH: f32 = 0.15;
const SPECULAR_STRENGTH: f32 = 0.5;
const SHININESS: f32 = 32.0;
const CLEAR_COLOR: metal.ClearColor = .{ .red = 0.0, .green = 0.0, .blue = 0.0, .alpha = 1.0 };

// Smoke mode (new): the window size it switches to halfway, and how --autofire aims and fires.
const SMOKE_RESIZE_WIDTH: f64 = 640;
const SMOKE_RESIZE_HEIGHT: f64 = 480;
const AUTOFIRE_INTERVAL: u64 = 12;
const AUTOFIRE_YAW: f32 = -90;
const AUTOFIRE_PITCH: f32 = 10;

// ============================================================
// COMMAND LINE
// ============================================================

/// What the command line asked for.
pub const Options = struct {
    /// Smoke mode: quit after this many rendered frames, resize the window halfway, print a summary.
    max_frames: ?u64 = null,
    /// Aim at the gallery once, then click on every AUTOFIRE_INTERVAL-th frame (hands-free smoke runs).
    autofire: bool = false,
};

const usage = "usage: Zetal [--frames N] [--autofire]";

/// Parses the arguments after the program name: `--frames N` or `--frames=N` (N >= 1) and
/// `--autofire`, in any order (a repeated --frames wins last). Anything else is error.UnknownOption;
/// a missing, malformed or zero N is error.InvalidOption.
pub fn parseOptions(args: []const []const u8) error{ UnknownOption, InvalidOption }!Options {
    var options: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--autofire")) {
            options.autofire = true;
        } else if (std.mem.eql(u8, arg, "--frames")) {
            i += 1;
            if (i == args.len) return error.InvalidOption;
            options.max_frames = try parseFrameCount(args[i]);
        } else if (std.mem.cutPrefix(u8, arg, "--frames=")) |value| {
            options.max_frames = try parseFrameCount(value);
        } else {
            return error.UnknownOption;
        }
    }
    return options;
}

/// Parses a smoke-run frame count: a decimal integer of at least 1, digits only.
fn parseFrameCount(text: []const u8) error{InvalidOption}!u64 {
    // parseInt would also take a leading '+' and '_' digit separators ("1_0" is 10).
    if (text.len == 0) return error.InvalidOption;
    for (text) |c| if (!std.ascii.isDigit(c)) return error.InvalidOption;
    // Overflow means the user gave no usable N either.
    const frames = std.fmt.parseInt(u64, text, 10) catch return error.InvalidOption;
    if (frames == 0) return error.InvalidOption;
    return frames;
}

// ============================================================
// MAIN
// ============================================================

/// Runs the game until Escape, a window close or (in smoke mode) the end of the frame budget.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseOptions(argv[@min(argv.len, 1)..]) catch |err| {
        log.err(usage, .{});
        return err;
    };

    // Catches everything autoreleased during startup and shutdown; each frame drains its own pool.
    const startup_pool = platform.AutoreleasePool.init();
    defer startup_pool.deinit();

    // Streaming, not positional: stdout may be a pipe, or a file opened for append.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.print("Starting Zetal Engine (FPS Mode)...\n", .{});
    try out.flush();

    // --- Platform and GPU ---
    var app = platform.App.init();
    const device = metal.Device.createSystemDefault() orelse {
        log.err("no Metal device available", .{});
        return error.NoMetalDevice;
    };
    defer device.release();
    // Shared by the renderer and the physics: the single-buffered instance buffers rely on it.
    const queue = try device.newCommandQueue();
    defer queue.release();
    var window = try platform.Window.create(device.handle, WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_TITLE);
    defer window.deinit();
    app.activate();

    // --- Renderer: owns the static resources once init succeeds; until then they are ours ---
    var renderer = blk: {
        var static_resources = try loadStaticResources(gpa, io, device);
        errdefer static_resources.deinit();
        break :blk try render.Renderer.init(device, queue, static_resources, ecs.MAX_ENTITIES);
    };
    defer renderer.deinit();

    // --- World and physics ---
    var world = ecs.World.init();
    try game.scene.spawnShootingGallery(&world);
    const target_count = world.countMatching(ecs.mask(&.{ .transform, .mesh_renderer }));
    var physics = try render.ComputePhysics.init(device, queue, ecs.MAX_ENTITIES);
    defer physics.deinit();

    // --- Player ---
    const gunshot = platform.Sound.load("assets/gunshot.wav");
    defer if (gunshot) |sound| sound.deinit();
    if (gunshot == null) log.warn("assets/gunshot.wav did not load; shots will be silent", .{});
    var player = game.Player.init(gunshot); // borrows the sound; it outlives the player
    if (options.autofire) player.setLook(AUTOFIRE_YAW, AUTOFIRE_PITCH);

    try out.print("FPS Mode Ready. {d} target cubes. Left-click to fire!\n", .{target_count});
    try out.print("GPU Compute Physics: spatial hash grid + impact conversion\n", .{});
    try out.flush();

    // --- Per-run constants ---
    const light_view = Mat4.lookAt(SUN_POS, SUN_TARGET, .init(0, 1, 0));
    const light_proj = Mat4.orthographic(
        -SHADOW_HALF_EXTENT,
        SHADOW_HALF_EXTENT,
        -SHADOW_HALF_EXTENT,
        SHADOW_HALF_EXTENT,
        SHADOW_NEAR,
        SHADOW_FAR,
    );
    const light_view_proj = light_proj.mul(light_view);
    // normalize(SUN_POS), not SUN_POS - SUN_TARGET: the original sky's sun disc direction (~13 degrees
    // off the shadow direction), kept for its look.
    const sun_dir = SUN_POS.normalize();
    const sky: render.uniforms.SkyUniforms = .{ .sun_dir = .{ sun_dir.x, sun_dir.y, sun_dir.z, 0 } };

    var stats: RunStats = .{};
    var physics_clock: PhysicsClock = .{};
    var warned_dropped_pairs = false;
    const start = Io.Clock.Timestamp.now(io, .awake);
    var last = start;

    // ============================================================
    // FRAME LOOP — paced by the display through nextDrawable
    // ============================================================
    while (true) {
        const frame_pool = platform.AutoreleasePool.init();
        defer frame_pool.deinit();

        app.input.beginFrame();
        app.pollEvents();
        if (app.shouldQuit() or !window.isOpen(&app)) break;
        // The vsync wait: blocks until the layer frees a drawable; null after its ~1 s timeout.
        const drawable = window.nextDrawable() orelse continue;
        // Input that arrived during the wait still counts for this frame.
        app.pollEvents();

        const now = Io.Clock.Timestamp.now(io, .awake);
        const dt = frameSeconds(last.durationTo(now).raw.toNanoseconds());
        last = now;
        const time_sec = elapsedSeconds(start.durationTo(now).raw.toNanoseconds());
        const aspect = aspectRatio(window.drawableSize());

        if (options.autofire and autofireFrame(stats.frames, player.fire_cooldown)) {
            app.input.mouse_left_pressed = true;
        }

        // --- Simulation ---
        player.update(&app.input, &world, GROUND_Y, dt);
        systems.spinSystem(&world, time_sec);
        systems.hitTimerSystem(&world, dt);

        var projectile_impacts: u32 = 0;
        const steps = physics_clock.advance(dt);
        for (0..steps) |_| {
            physics.upload(&world);
            // The high-water mark, not liveCount: dead slots below it still occupy GPU slots.
            try physics.step(PHYSICS_DT, world.count);
            physics.download(&world);
            const report = systems.resolveCollisionPairs(&world, physics.pairs(), COLLISION_RESTITUTION);
            projectile_impacts += report.projectile_impacts;
            systems.enforceFloor(&world, GROUND_Y, FLOOR_RESTITUTION);

            if (!warned_dropped_pairs and physics.droppedPairs() > 0) {
                warned_dropped_pairs = true; // once per run: this would otherwise log up to 1000 times a second
                log.warn("broad phase dropped {d} collision pairs (buffer holds {d})", .{
                    physics.droppedPairs(), render.physics.MAX_PAIRS,
                });
            }
        }
        if (steps == 0) {
            // No physics step waited on the queue this frame, yet buildInstances is about to rewrite the
            // single-buffered instance buffers the previous frame's render may still be reading: an
            // empty command buffer is a fence, since the queue completes buffers in commit order.
            const fence = try queue.commandBuffer();
            fence.commit();
            fence.waitUntilCompleted();
        }
        // The hit marker confirms only shots that knocked a block loose, not cubes hitting cubes.
        if (projectile_impacts > 0) player.onConfirmedHit();
        stats.projectile_impacts += projectile_impacts;
        stats.recycled += systems.projectileLifetimeSystem(&world, dt);
        stats.recycled += systems.cleanupFallen(&world, KILL_Y);

        // --- Rendering ---
        const camera = player.camera(aspect, time_sec);
        const instances = renderer.instances;
        const instance_count = systems.buildInstances(&world, camera.view_proj, light_view_proj, .{
            .mvps = instances.mvps(),
            .models = instances.models(),
            .shadow_mvps = instances.shadowMvps(),
            .hit_timers = instances.hitTimers(),
        });
        if (options.max_frames != null) stats.drawable_size = drawableTextureSize(drawable);

        try renderer.drawFrame(drawable, .{
            .view_proj = camera.view_proj,
            .proj = camera.proj,
            .light_view_proj = light_view_proj,
            .light = .{
                .light_pos = .{ SUN_POS.x, SUN_POS.y, SUN_POS.z },
                // The unshaken eye: screen shake never moves the specular highlights (as the original).
                .view_pos = .{ player.position.x, player.position.y, player.position.z },
                .light_color = LIGHT_COLOR,
                .ambient_strength = AMBIENT_STRENGTH,
                .specular_strength = SPECULAR_STRENGTH,
                .shininess = SHININESS,
            },
            .sky = sky,
            .instance_count = instance_count,
            .gun_model = player.gunModel(time_sec),
            .crosshair = .{ .aspect = aspect, .hit_marker = player.hit_marker_timer },
            .clear_color = CLEAR_COLOR,
        });
        stats.frames += 1;

        // --- Smoke mode ---
        if (options.max_frames) |max_frames| {
            if (stats.frames == max_frames / 2) {
                // Proves the resize path: the drawables must follow the view to the new size.
                stats.drawable_size_before_resize = stats.drawable_size;
                window.setContentSize(SMOKE_RESIZE_WIDTH, SMOKE_RESIZE_HEIGHT);
            }
            if (stats.frames >= max_frames) break;
        }
    }

    if (options.max_frames != null) {
        const before = stats.drawable_size_before_resize orelse stats.drawable_size;
        const after = stats.drawable_size;
        try out.print(
            "Smoke run: {d} frames, {d} shots, {d} projectile impacts, {d} live entities, {d} recycled, " ++
                "drawable {d}x{d} -> {d}x{d}\n",
            .{
                stats.frames,
                player.shots_fired,
                stats.projectile_impacts,
                world.liveCount(),
                stats.recycled,
                before[0],
                before[1],
                after[0],
                after[1],
            },
        );
        try out.flush();
        if (stats.drawable_size_before_resize != null and std.mem.eql(u64, &before, &after)) {
            log.warn("smoke run: the drawable size did not change after the resize", .{});
        }
    }
}

// ============================================================
// STARTUP HELPERS
// ============================================================

/// Loads the meshes and textures from assets/ (relative to the cwd), uploads them to the GPU and
/// frees the CPU copies again.
fn loadStaticResources(gpa: std.mem.Allocator, io: Io, device: metal.Device) !render.StaticResources {
    var cube = try loadMesh(gpa, io, "assets/cube.obj");
    defer cube.deinit(gpa);
    var gun = try loadMesh(gpa, io, "assets/hands.obj");
    defer gun.deinit(gpa);
    var world_image = try loadImage(gpa, io, "assets/test.ppm");
    defer world_image.deinit(gpa);
    var gun_image = try loadImage(gpa, io, "assets/gun_metal.ppm");
    defer gun_image.deinit(gpa);
    return render.StaticResources.init(device, cube, gun, world_image, gun_image);
}

/// Loads one OBJ mesh, naming the file when it fails.
fn loadMesh(gpa: std.mem.Allocator, io: Io, path: []const u8) !Zetal.assets.Mesh {
    return Zetal.assets.obj.load(gpa, io, path) catch |err| {
        log.err("cannot load {s}: {t} (run from the repo root, e.g. through `zig build run`)", .{ path, err });
        return err;
    };
}

/// Loads one PPM image, naming the file when it fails.
fn loadImage(gpa: std.mem.Allocator, io: Io, path: []const u8) !Zetal.assets.Image {
    return Zetal.assets.ppm.load(gpa, io, path) catch |err| {
        log.err("cannot load {s}: {t} (run from the repo root, e.g. through `zig build run`)", .{ path, err });
        return err;
    };
}

// ============================================================
// FRAME HELPERS
// ============================================================

/// Counters the smoke-run summary reports.
const RunStats = struct {
    /// Frames rendered so far.
    frames: u64 = 0,
    /// Blocks knocked loose by projectiles (the hit-marker events).
    projectile_impacts: u64 = 0,
    /// Entity slots the lifetime and cleanup systems handed back to the free list.
    recycled: u64 = 0,
    /// Pixel size of the latest drawable (tracked in smoke mode only).
    drawable_size: [2]u64 = .{ 0, 0 },
    /// `drawable_size` when the smoke run resized the window; null until then.
    drawable_size_before_resize: ?[2]u64 = null,
};

/// Fixed-step physics clock: banks frame time and pays it out in PHYSICS_DT substeps.
const PhysicsClock = struct {
    /// Banked time not stepped yet, in seconds.
    accumulator: f32 = 0,

    /// Banks `dt` and returns how many PHYSICS_DT steps are due; at MAX_PHYSICS_STEPS the rest of the
    /// backlog is dropped, so one slow frame cannot snowball into ever more work.
    fn advance(self: *PhysicsClock, dt: f32) u32 {
        self.accumulator += dt;
        var steps: u32 = 0;
        while (self.accumulator >= PHYSICS_DT and steps < MAX_PHYSICS_STEPS) : (steps += 1) {
            self.accumulator -= PHYSICS_DT;
        }
        if (steps == MAX_PHYSICS_STEPS) self.accumulator = 0;
        return steps;
    }
};

/// Returns how far a frame advances the simulation: its duration `frame_ns` in seconds, clamped to MAX_FRAME_DT.
fn frameSeconds(frame_ns: i96) f32 {
    return @min(@as(f32, @floatFromInt(frame_ns)) / @as(f32, std.time.ns_per_s), MAX_FRAME_DT);
}

/// Returns `elapsed_ns` in seconds: the animation clock behind spin, shake and gun sway.
fn elapsedSeconds(elapsed_ns: i96) f32 {
    return @as(f32, @floatFromInt(elapsed_ns)) / @as(f32, std.time.ns_per_s);
}

/// Returns width / height of a drawable size, or 1 while a side is under a pixel (a collapsed view).
fn aspectRatio(size: objc.CGSize) f32 {
    if (size.width < 1 or size.height < 1) return 1.0;
    return @floatCast(size.width / size.height);
}

/// True on the frames --autofire clicks: every AUTOFIRE_INTERVAL-th frame, once the cooldown is over.
fn autofireFrame(frame: u64, fire_cooldown: f32) bool {
    return frame % AUTOFIRE_INTERVAL == 0 and fire_cooldown <= 0;
}

/// Returns the pixel size of `drawable`'s texture, or 0x0 when it has none.
fn drawableTextureSize(drawable: objc.Object) [2]u64 {
    const handle = objc.msgSend(?objc.Object, drawable, "texture", .{}) orelse return .{ 0, 0 };
    const texture: metal.Texture = .{ .handle = handle }; // borrowed from the drawable, never released here
    return .{ texture.width(), texture.height() };
}

// ============================================================
// TESTS (pure logic only: no window, no GPU)
// ============================================================

const testing = std.testing;

test "parseOptions: no arguments means an endless, manual game" {
    try testing.expectEqual(Options{}, try parseOptions(&.{}));
}

test "parseOptions: --frames N, --frames=N and --autofire, in any order" {
    try testing.expectEqual(Options{ .max_frames = 30 }, try parseOptions(&.{ "--frames", "30" }));
    try testing.expectEqual(Options{ .max_frames = 45 }, try parseOptions(&.{"--frames=45"}));
    try testing.expectEqual(Options{ .autofire = true }, try parseOptions(&.{"--autofire"}));
    try testing.expectEqual(
        Options{ .max_frames = 240, .autofire = true },
        try parseOptions(&.{ "--autofire", "--frames", "240" }),
    );
    try testing.expectEqual(
        Options{ .max_frames = 240, .autofire = true },
        try parseOptions(&.{ "--frames=240", "--autofire" }),
    );
    // A repeated --frames wins last.
    try testing.expectEqual(Options{ .max_frames = 7 }, try parseOptions(&.{ "--frames", "3", "--frames=7" }));
}

test "parseOptions: unknown arguments are rejected" {
    try testing.expectError(error.UnknownOption, parseOptions(&.{"--fullscreen"}));
    try testing.expectError(error.UnknownOption, parseOptions(&.{"240"}));
    try testing.expectError(error.UnknownOption, parseOptions(&.{ "--frames", "10", "extra" }));
    try testing.expectError(error.UnknownOption, parseOptions(&.{"--frames10"}));
    try testing.expectError(error.UnknownOption, parseOptions(&.{"-frames=10"}));
    try testing.expectError(error.UnknownOption, parseOptions(&.{"--autofire=yes"}));
}

test "parseOptions: a missing, malformed or zero frame count is rejected" {
    try testing.expectError(error.InvalidOption, parseOptions(&.{"--frames"}));
    try testing.expectError(error.InvalidOption, parseOptions(&.{ "--autofire", "--frames" }));
    try testing.expectError(error.InvalidOption, parseOptions(&.{"--frames="}));
    try testing.expectError(error.InvalidOption, parseOptions(&.{ "--frames", "ten" }));
    try testing.expectError(error.InvalidOption, parseOptions(&.{ "--frames", "-5" }));
    try testing.expectError(error.InvalidOption, parseOptions(&.{ "--frames", "+5" }));
    try testing.expectError(error.InvalidOption, parseOptions(&.{"--frames=1_0"}));
    try testing.expectError(error.InvalidOption, parseOptions(&.{ "--frames", " 5" }));
    try testing.expectError(error.InvalidOption, parseOptions(&.{"--frames=1.5"}));
    try testing.expectError(error.InvalidOption, parseOptions(&.{ "--frames", "0" }));
    try testing.expectError(error.InvalidOption, parseOptions(&.{"--frames=99999999999999999999999"}));
}

test "parseOptions accepts argv as std.process.Args.toSlice returns it" {
    // toSlice yields []const [:0]const u8; main passes it minus argv[0].
    const argv: []const [:0]const u8 = &.{ "Zetal", "--frames", "12" };
    try testing.expectEqual(Options{ .max_frames = 12 }, try parseOptions(argv[@min(argv.len, 1)..]));
    const bare: []const [:0]const u8 = &.{};
    try testing.expectEqual(Options{}, try parseOptions(bare[@min(bare.len, 1)..]));
}

test "frameSeconds converts nanoseconds and clamps hitches to 33 ms" {
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 60.0), frameSeconds(16_666_667), 1e-6);
    try testing.expectEqual(@as(f32, 0), frameSeconds(0));
    try testing.expectEqual(MAX_FRAME_DT, frameSeconds(40_000_000));
    try testing.expectEqual(MAX_FRAME_DT, frameSeconds(std.time.ns_per_s * 5));
    try testing.expectApproxEqAbs(@as(f32, 2.5), elapsedSeconds(2_500_000_000), 1e-6);
}

test "PhysicsClock pays out 1 ms steps and carries the remainder" {
    var clock: PhysicsClock = .{};
    var total: u32 = 0;
    for (0..60) |_| {
        const steps = clock.advance(1.0 / 60.0);
        try testing.expect(steps == 16 or steps == 17);
        total += steps;
    }
    // One simulated second, give or take the f32 rounding of the banked remainder.
    try testing.expect(total == 999 or total == 1000);
    try testing.expect(clock.accumulator >= 0 and clock.accumulator < PHYSICS_DT);

    // Time is conserved: what was not stepped stays banked.
    var fresh: PhysicsClock = .{};
    const steps = fresh.advance(MAX_FRAME_DT);
    const stepped = @as(f32, @floatFromInt(steps)) * PHYSICS_DT;
    try testing.expectApproxEqAbs(MAX_FRAME_DT, stepped + fresh.accumulator, 1e-6);
    try testing.expect(fresh.accumulator < PHYSICS_DT);

    // Less than a step banks it all; the next frame steps it.
    var slow: PhysicsClock = .{};
    try testing.expectEqual(0, slow.advance(0.0004));
    try testing.expectEqual(1, slow.advance(0.0007));
}

test "PhysicsClock caps a backlog at MAX_PHYSICS_STEPS and drops the rest" {
    var clock: PhysicsClock = .{};
    try testing.expectEqual(MAX_PHYSICS_STEPS, clock.advance(0.25));
    try testing.expectEqual(0, clock.accumulator);
    // A clamped frame never reaches the cap, so in the game the cap only guards against bugs.
    try testing.expect(@as(f32, @floatFromInt(MAX_PHYSICS_STEPS)) * PHYSICS_DT > MAX_FRAME_DT);
}

test "aspectRatio is width over height, and 1 for a collapsed view" {
    try testing.expectApproxEqAbs(@as(f32, 4.0 / 3.0), aspectRatio(.{ .width = 1600, .height = 1200 }), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2), aspectRatio(.{ .width = 1280, .height = 640 }), 1e-6);
    try testing.expectEqual(@as(f32, 1), aspectRatio(.{ .width = 0, .height = 0 }));
    try testing.expectEqual(@as(f32, 1), aspectRatio(.{ .width = 800, .height = 0.5 }));
}

test "autofireFrame clicks every 12th frame once the cooldown is over" {
    try testing.expect(autofireFrame(0, 0));
    try testing.expect(autofireFrame(24, 0));
    try testing.expect(!autofireFrame(13, 0));
    try testing.expect(!autofireFrame(36, 0.05));
    var clicks: u32 = 0;
    for (0..240) |frame| {
        if (autofireFrame(frame, 0)) clicks += 1;
    }
    try testing.expectEqual(20, clicks); // 5 shots a second at 60 Hz
}
||||||| empty tree
=======
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
>>>>>>> Zetal/main
