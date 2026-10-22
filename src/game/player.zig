//! First-person player: mouse look, walking and jumping, projectile fire, screen shake, hit marker, gun viewmodel.

const std = @import("std");
const math = @import("../math.zig");
const ecs = @import("../ecs/world.zig");
const systems = @import("../ecs/systems.zig");
const app = @import("../platform/app.zig");
const sound = @import("../platform/sound.zig");
const scene = @import("scene.zig");

const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const World = ecs.World;
const Input = app.Input;
const Sound = sound.Sound;

// ============================================================
// TUNING — the original's values; every one shapes the game feel
// ============================================================

/// Muzzle speed of a shot (units/s), far above the 8 u/s it takes to knock a block loose.
const PROJECTILE_SPEED: f32 = 40.0;
/// A shot spawns this far ahead of the eye, along the view.
const PROJECTILE_SPAWN_OFFSET: f32 = 1.0;
/// Seconds between shots.
const FIRE_COOLDOWN: f32 = 0.15;

/// Walking speed (units/s).
const MOVE_SPEED: f32 = 5.0;
/// Degrees of turn per unit of mouse motion.
const MOUSE_SENSITIVITY: f32 = 0.1;
/// Half-size of the box the eye collides with.
const CAM_RADIUS: f32 = 0.3;
/// Pitch limit in degrees: at ±90 the view would be parallel to world up and the basis would collapse.
const PITCH_LIMIT: f32 = 89.0;

/// Eye height above the ground.
const PLAYER_HEIGHT: f32 = 2.0;
/// Take-off speed of a jump (units/s).
const JUMP_FORCE: f32 = 18.0;
/// The player's own gravity (physics bodies fall at -15).
const GRAVITY: f32 = -45.0;

/// Seconds of screen shake and gun kickback a shot starts.
const SHAKE_ON_FIRE: f32 = 0.06;
/// Eye offset per second of remaining shake.
const SHAKE_AMPLITUDE: f32 = 0.3;
/// Time scale of the shake's sine waves.
const SHAKE_RATE: f32 = 120.0;
/// Hit-marker strength a confirmed hit sets.
const HIT_MARKER_ON_HIT: f32 = 1.0;
/// Hit-marker fade per second: a full marker is gone after 0.2 s.
const HIT_MARKER_DECAY_RATE: f32 = 5.0;

/// Vertical field of view in degrees.
const FOV_DEG: f32 = 45.0;
/// Near clip plane distance.
const NEAR_PLANE: f32 = 0.1;
/// Far clip plane distance.
const FAR_PLANE: f32 = 200.0;

/// Gun rest position in view space: low on the right, in front of the eye.
const GUN_OFFSET: Vec3 = .init(0.3, -0.25, -0.7);
/// Amplitude of the gun's idle sway.
const GUN_SWAY: f32 = 0.01;
/// Gun recoil towards the eye per second of remaining shake.
const GUN_KICKBACK: f32 = 1.5;

/// Spawn point, 2 units above standing height, so the player drops onto the ground first.
const START_POSITION: Vec3 = .init(0, -8, 5);
/// Spawn heading: down -z, towards the gallery.
const START_YAW: f32 = -90.0;
/// Spawn pitch: level.
const START_PITCH: f32 = 0.0;

const WORLD_UP: Vec3 = .init(0, 1, 0);

// ============================================================
// PLAYER
// ============================================================

/// One frame's camera matrices.
pub const Camera = struct {
    /// World to view space.
    view: Mat4,
    /// View to Metal clip space.
    proj: Mat4,
    /// proj · view.
    view_proj: Mat4,
};

/// The first-person player: an eye with a yaw/pitch view basis, its own gravity, and the weapon state.
pub const Player = struct {
    /// Eye position, unshaken (also the lighting's view position).
    position: Vec3,
    /// Heading in degrees; -90 looks down -z.
    yaw: f32,
    /// Elevation in degrees, within ±PITCH_LIMIT.
    pitch: f32,
    /// Unit view direction from yaw and pitch.
    front: Vec3,
    /// Unit horizontal right vector (front × world up).
    right: Vec3,
    /// Unit camera up (right × front).
    up: Vec3,
    /// Jump and fall speed (units/s).
    vertical_velocity: f32,
    /// True while standing on the ground; only then can the player jump.
    grounded: bool,
    /// Seconds until the next shot may fire.
    fire_cooldown: f32,
    /// Seconds of screen shake and gun kickback left.
    shake_timer: f32,
    /// Hit-marker strength, fading from 1 to 0.
    hit_marker_timer: f32,
    /// The shot sound, borrowed: its owner deinits it once the player is no longer used.
    gunshot: ?Sound,
    /// Shots that actually spawned a projectile.
    shots_fired: u32 = 0,

    /// A player at the spawn point, looking down -z with the weapon idle; `gunshot` is borrowed.
    pub fn init(gunshot: ?Sound) Player {
        const basis = lookBasis(START_YAW, START_PITCH);
        return .{
            .position = START_POSITION,
            .yaw = START_YAW,
            .pitch = START_PITCH,
            .front = basis.front,
            .right = basis.right,
            .up = basis.up,
            .vertical_velocity = 0,
            .grounded = false,
            .fire_cooldown = 0,
            .shake_timer = 0,
            .hit_marker_timer = 0,
            .gunshot = gunshot,
        };
    }

    /// Turns the view to `yaw_deg` and `pitch_deg` (clamped to ±89°) and rebuilds front, right and up.
    pub fn setLook(self: *Player, yaw_deg: f32, pitch_deg: f32) void {
        self.yaw = yaw_deg;
        self.pitch = std.math.clamp(pitch_deg, -PITCH_LIMIT, PITCH_LIMIT);
        const basis = lookBasis(self.yaw, self.pitch);
        self.front = basis.front;
        self.right = basis.right;
        self.up = basis.up;
    }

    /// Advances one frame, in this order: mouse look, walking and jumping, gravity onto the
    /// infinite floor at `ground_y`, push-out from colliders, firing (left click), timer decay.
    pub fn update(self: *Player, input: *const Input, world: *World, ground_y: f32, dt: f32) void {
        self.updateLook(input);
        self.updateMovement(input, dt);
        self.updateGravity(ground_y, dt);
        self.resolveAgainstWorld(world);
        self.updateFire(input, world, dt);
        self.decayTimers(dt);
    }

    /// Shows the hit marker at full strength (for a shot that knocked a block loose).
    pub fn onConfirmedHit(self: *Player) void {
        self.hit_marker_timer = HIT_MARKER_ON_HIT;
    }

    /// This frame's camera at `aspect` (width / height); while shake_timer runs, the eye shakes
    /// with a pattern driven by `time_sec`.
    pub fn camera(self: *const Player, aspect: f32, time_sec: f32) Camera {
        var eye = self.position;
        if (self.shake_timer > 0) {
            const intensity = self.shake_timer * SHAKE_AMPLITUDE;
            const t = time_sec * SHAKE_RATE;
            eye = eye.add(.init(@sin(t * 7.3) * intensity, @sin(t * 11.1) * intensity, 0));
        }
        // Only the eye shakes: the view keeps aiming at the unshaken position + front.
        const center = self.position.add(self.front);
        const view = Mat4.lookAt(eye, center, self.up);
        const proj = Mat4.perspective(std.math.degreesToRadians(FOV_DEG), aspect, NEAR_PLANE, FAR_PLANE);
        return .{ .view = view, .proj = proj, .view_proj = proj.mul(view) };
    }

    /// The gun's view-space model matrix (drawn with proj · gunModel, so it stays glued to the
    /// screen): turned to face down the view, with idle sway and shot kickback.
    pub fn gunModel(self: *const Player, time_sec: f32) Mat4 {
        // The hands mesh is modelled facing the other way.
        var m = Mat4.rotationY(std.math.pi);
        const sway_x = @cos(time_sec * 1.5) * GUN_SWAY;
        const sway_y = @sin(time_sec * 3.0) * GUN_SWAY;
        const kickback = self.shake_timer * GUN_KICKBACK;
        m.columns[3] = .{ GUN_OFFSET.x + sway_x, GUN_OFFSET.y + sway_y, GUN_OFFSET.z + kickback, 1 };
        return m;
    }

    // --- update steps ---

    fn updateLook(self: *Player, input: *const Input) void {
        // AppKit's deltaY grows downwards, so moving the mouse up raises the pitch.
        self.setLook(self.yaw + input.mouse_dx * MOUSE_SENSITIVITY, self.pitch - input.mouse_dy * MOUSE_SENSITIVITY);
    }

    fn updateMovement(self: *Player, input: *const Input, dt: f32) void {
        const step = MOVE_SPEED * dt;
        // Walk in the ground plane: looking up or down changes neither the direction nor the speed.
        const flat_front = Vec3.init(self.front.x, 0, self.front.z).normalize();
        if (input.isDown(.w)) self.position = self.position.add(flat_front.scale(step));
        if (input.isDown(.s)) self.position = self.position.sub(flat_front.scale(step));
        if (input.isDown(.a)) self.position = self.position.sub(self.right.scale(step));
        if (input.isDown(.d)) self.position = self.position.add(self.right.scale(step));

        if (input.isDown(.space) and self.grounded) {
            self.vertical_velocity = JUMP_FORCE;
            self.grounded = false;
        }
    }

    fn updateGravity(self: *Player, ground_y: f32, dt: f32) void {
        self.vertical_velocity += GRAVITY * dt;
        self.position.y += self.vertical_velocity * dt;

        // Like the physics floor, this one has no x/z bound.
        const standing_y = ground_y + PLAYER_HEIGHT;
        if (self.position.y <= standing_y) {
            self.position.y = standing_y;
            self.vertical_velocity = 0;
            self.grounded = true;
        } else {
            self.grounded = false;
        }
    }

    fn resolveAgainstWorld(self: *Player, world: *const World) void {
        const resolved = systems.resolveCamera(world, self.position, CAM_RADIUS);
        // Pushed up out of a block's top: the block carries the player, so the fall stops there.
        // Otherwise the fall speed keeps growing while he stands on it, and once a frame's sink
        // outgrows the horizontal overlap the push-out turns sideways and shoves him off (about
        // 0.8 s at 60 Hz; the original's ~1.6 kHz loop kept the sink tiny). `grounded` stays false:
        // as in the original, only the floor can be jumped from.
        if (resolved.y > self.position.y and self.vertical_velocity < 0) self.vertical_velocity = 0;
        self.position = resolved;
    }

    fn updateFire(self: *Player, input: *const Input, world: *World, dt: f32) void {
        self.fire_cooldown -= dt;
        if (self.fire_cooldown < 0) self.fire_cooldown = 0;

        // Edge-triggered: one shot per click, however long the button is held.
        if (!(input.mouse_left_pressed and self.fire_cooldown <= 0)) return;

        const muzzle = self.position.add(self.front.scale(PROJECTILE_SPAWN_OFFSET));
        // A full world means no shot, so no kick, sound or cooldown either: the next click retries.
        _ = scene.spawnProjectile(world, muzzle, self.front.scale(PROJECTILE_SPEED)) catch return;

        self.shots_fired += 1;
        self.shake_timer = SHAKE_ON_FIRE;
        if (self.gunshot) |gunshot| gunshot.play();
        self.fire_cooldown = FIRE_COOLDOWN;
    }

    fn decayTimers(self: *Player, dt: f32) void {
        self.shake_timer -= dt;
        if (self.shake_timer < 0) self.shake_timer = 0;

        self.hit_marker_timer -= dt * HIT_MARKER_DECAY_RATE;
        if (self.hit_marker_timer < 0) self.hit_marker_timer = 0;
    }
};

/// The camera axes for a yaw/pitch in degrees.
const Basis = struct { front: Vec3, right: Vec3, up: Vec3 };

fn lookBasis(yaw_deg: f32, pitch_deg: f32) Basis {
    const yaw = std.math.degreesToRadians(yaw_deg);
    const pitch = std.math.degreesToRadians(pitch_deg);
    const front = Vec3.init(@cos(yaw) * @cos(pitch), @sin(pitch), @sin(yaw) * @cos(pitch)).normalize();
    const right = front.cross(WORLD_UP).normalize();
    return .{ .front = front, .right = right, .up = right.cross(front).normalize() };
}

// ============================================================
// TESTS (pure logic: no window, no GPU, no sound)
// ============================================================

const testing = std.testing;
const KeyCode = app.KeyCode;
const Entity = ecs.Entity;

/// The ground plane the tests stand on (the game's GROUND_Y).
const TEST_GROUND_Y: f32 = -12.0;
/// Where the eye rests on that ground.
const STANDING_Y: f32 = TEST_GROUND_Y + PLAYER_HEIGHT;

fn press(input: *Input, key: KeyCode) void {
    input.keyDown(@backingInt(key));
}

fn release(input: *Input, key: KeyCode) void {
    input.keyUp(@backingInt(key));
}

/// A left click (down and up) inside the current frame.
fn click(input: *Input) void {
    input.mouseButton(.left, true);
    input.mouseButton(.left, false);
}

/// A player standing on the test ground, looking along yaw/pitch degrees.
fn standingPlayer(yaw_deg: f32, pitch_deg: f32) Player {
    var player = Player.init(null);
    player.position.y = STANDING_Y;
    player.grounded = true;
    player.setLook(yaw_deg, pitch_deg);
    return player;
}

/// Runs frames until the player stands on the test ground; fails after 10 simulated seconds.
fn runUntilGrounded(player: *Player, input: *const Input, world: *World, dt: f32) !void {
    var frames: u32 = 0;
    while (!player.grounded) : (frames += 1) {
        if (@as(f32, @floatFromInt(frames)) * dt > 10) return error.TestUnexpectedResult;
        player.update(input, world, TEST_GROUND_Y, dt);
    }
}

fn positionOf(world: *const World, e: Entity) Vec3 {
    const t = world.transforms[e];
    return .init(t.x, t.y, t.z);
}

fn velocityOf(world: *const World, e: Entity) Vec3 {
    const v = world.velocities[e];
    return .init(v.x, v.y, v.z);
}

fn expectVec3(expected: Vec3, actual: Vec3, tolerance: f32) !void {
    try testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
    try testing.expectApproxEqAbs(expected.z, actual.z, tolerance);
}

fn expectPoint(expected: [4]f32, actual: [4]f32, tolerance: f32) !void {
    for (expected, actual) |e, a| try testing.expectApproxEqAbs(e, a, tolerance);
}

test "init places the player at (0, -8, 5) facing -z with the weapon idle" {
    const player = Player.init(null);
    try testing.expectEqual(Vec3.init(0, -8, 5), player.position);
    try testing.expectEqual(-90, player.yaw);
    try testing.expectEqual(0, player.pitch);
    try expectVec3(.init(0, 0, -1), player.front, 1e-6);
    try expectVec3(.init(1, 0, 0), player.right, 1e-6);
    try expectVec3(.init(0, 1, 0), player.up, 1e-6);
    try testing.expectEqual(0, player.vertical_velocity);
    try testing.expect(!player.grounded);
    try testing.expectEqual(0, player.fire_cooldown);
    try testing.expectEqual(0, player.shake_timer);
    try testing.expectEqual(0, player.hit_marker_timer);
    try testing.expectEqual(0, player.shots_fired);
    try testing.expect(player.gunshot == null);
}

test "setLook clamps pitch to ±89° and rebuilds an orthonormal view basis" {
    var player = Player.init(null);
    player.setLook(30, 120);
    try testing.expectEqual(30, player.yaw);
    try testing.expectEqual(89, player.pitch);
    player.setLook(-200, -95);
    try testing.expectEqual(-200, player.yaw);
    try testing.expectEqual(-89, player.pitch);

    const looks = [_][2]f32{ .{ -90, 0 }, .{ 30, 45 }, .{ -200, -89 }, .{ 135, 89 } };
    for (looks) |look| {
        player.setLook(look[0], look[1]);
        const yaw = std.math.degreesToRadians(look[0]);
        const pitch = std.math.degreesToRadians(look[1]);
        try expectVec3(.init(@cos(yaw) * @cos(pitch), @sin(pitch), @sin(yaw) * @cos(pitch)), player.front, 1e-6);
        for ([_]Vec3{ player.front, player.right, player.up }) |axis| {
            try testing.expectApproxEqAbs(1, axis.length(), 1e-6);
        }
        try testing.expectApproxEqAbs(0, player.front.dot(player.right), 1e-6);
        try testing.expectApproxEqAbs(0, player.front.dot(player.up), 1e-6);
        try testing.expectApproxEqAbs(0, player.right.dot(player.up), 1e-6);
        try testing.expectEqual(0, player.right.y); // strafing stays level
        try testing.expect(player.up.y > 0); // never upside down
    }
}

test "mouse look turns 0.1° per unit of motion and pitch stops at ±89°" {
    var world = World.init();
    var player = standingPlayer(-90, 0);
    var input: Input = .{};

    input.mouseMoved(50, -30); // right and up
    player.update(&input, &world, TEST_GROUND_Y, 0.01);
    try testing.expectApproxEqAbs(-85, player.yaw, 1e-5);
    try testing.expectApproxEqAbs(3, player.pitch, 1e-5);
    try expectVec3(lookBasis(-85, 3).front, player.front, 1e-6);

    input.beginFrame();
    input.mouseMoved(0, -5000);
    player.update(&input, &world, TEST_GROUND_Y, 0.01);
    try testing.expectEqual(89, player.pitch);

    input.beginFrame();
    input.mouseMoved(0, 5000);
    player.update(&input, &world, TEST_GROUND_Y, 0.01);
    try testing.expectEqual(-89, player.pitch);

    // beginFrame cleared the deltas: no motion, no turn.
    input.beginFrame();
    const yaw = player.yaw;
    player.update(&input, &world, TEST_GROUND_Y, 0.01);
    try testing.expectEqual(yaw, player.yaw);
    try testing.expectEqual(-89, player.pitch);
}

test "WASD walks along the flat view direction at 5 u/s, whatever the pitch" {
    var world = World.init();
    var player = standingPlayer(30, 45);
    const start = player.position;
    const dt: f32 = 0.1;
    const step = MOVE_SPEED * dt;
    const yaw = std.math.degreesToRadians(@as(f32, 30));
    const forward: Vec3 = .init(@cos(yaw), 0, @sin(yaw));
    const right: Vec3 = .init(-@sin(yaw), 0, @cos(yaw));
    var input: Input = .{};

    press(&input, .w);
    player.update(&input, &world, TEST_GROUND_Y, dt);
    try expectVec3(start.add(forward.scale(step)), player.position, 1e-5);
    release(&input, .w);

    press(&input, .s);
    player.update(&input, &world, TEST_GROUND_Y, dt);
    try expectVec3(start, player.position, 1e-5);
    release(&input, .s);

    press(&input, .d);
    player.update(&input, &world, TEST_GROUND_Y, dt);
    try expectVec3(start.add(right.scale(step)), player.position, 1e-5);
    release(&input, .d);

    press(&input, .a);
    player.update(&input, &world, TEST_GROUND_Y, dt);
    try expectVec3(start, player.position, 1e-5);
    release(&input, .a);

    // Nothing held: the player stays put on the ground.
    player.update(&input, &world, TEST_GROUND_Y, dt);
    try expectVec3(start, player.position, 1e-5);
    try testing.expect(player.grounded);
}

test "jumps only from the ground, peak 3.45 above it at 60 Hz, and lands back on ground_y + 2" {
    var world = World.init();
    var player = Player.init(null); // spawns in the air
    var input: Input = .{};
    const dt: f32 = 1.0 / 60.0;

    // Airborne: Space does nothing.
    press(&input, .space);
    player.update(&input, &world, TEST_GROUND_Y, dt);
    try testing.expect(!player.grounded);
    try testing.expect(player.vertical_velocity < 0);
    release(&input, .space);

    // The fall stops exactly at standing height.
    try runUntilGrounded(&player, &input, &world, dt);
    try testing.expectEqual(STANDING_Y, player.position.y);
    try testing.expectEqual(0, player.vertical_velocity);

    // Jump, and keep Space held all the way: there is no second jump in mid-air.
    press(&input, .space);
    player.update(&input, &world, TEST_GROUND_Y, dt);
    try testing.expect(!player.grounded);
    try testing.expectApproxEqAbs(JUMP_FORCE + GRAVITY * dt, player.vertical_velocity, 1e-5);
    var peak = player.position.y;
    var last_velocity = player.vertical_velocity;
    var frames: u32 = 0;
    while (!player.grounded) : (frames += 1) {
        if (frames == 600) return error.TestUnexpectedResult;
        player.update(&input, &world, TEST_GROUND_Y, dt);
        if (!player.grounded) try testing.expect(player.vertical_velocity < last_velocity);
        last_velocity = player.vertical_velocity;
        peak = @max(peak, player.position.y);
    }
    // Per-frame integration: 18² / (2 · 45) - 9 · dt = 3.6 - 0.15 at 60 Hz.
    try testing.expectApproxEqAbs(3.45, peak - STANDING_Y, 1e-3);
    try testing.expectEqual(STANDING_Y, player.position.y);
    try testing.expectEqual(0, player.vertical_velocity);
}

test "a left click fires a projectile from one unit ahead along the view, with kick and cooldown" {
    var world = World.init();
    var player = standingPlayer(-60, 10);
    var input: Input = .{};
    const dt: f32 = 0.01;

    click(&input);
    player.update(&input, &world, TEST_GROUND_Y, dt);

    try testing.expectEqual(1, world.liveCount());
    try testing.expectEqual(1, player.shots_fired);
    const shot: Entity = 0;
    try testing.expect(world.has(shot, .projectile));
    try testing.expect(!world.colliders[shot].is_static);
    try testing.expectEqual(0.5, world.transforms[shot].scale);
    try expectVec3(player.position.add(player.front), positionOf(&world, shot), 1e-5);
    try expectVec3(player.front.scale(40), velocityOf(&world, shot), 1e-5);
    try testing.expectEqual(FIRE_COOLDOWN, player.fire_cooldown);
    // The kick has already decayed by this frame's dt.
    try testing.expectApproxEqAbs(SHAKE_ON_FIRE - dt, player.shake_timer, 1e-6);
}

test "the cooldown drops a second click and holding the button never refires" {
    var world = World.init();
    var player = standingPlayer(-90, 0);
    var input: Input = .{};

    click(&input);
    player.update(&input, &world, TEST_GROUND_Y, 0.01);
    try testing.expectEqual(1, player.shots_fired);

    // 0.1 s into the 0.15 s cooldown: the click is dropped.
    input.beginFrame();
    click(&input);
    player.update(&input, &world, TEST_GROUND_Y, 0.1);
    try testing.expectEqual(1, player.shots_fired);
    try testing.expectEqual(1, world.liveCount());

    // Cooldown over, button held down since an earlier frame: no new press, no shot.
    input.beginFrame();
    input.mouseButton(.left, true);
    input.beginFrame();
    player.update(&input, &world, TEST_GROUND_Y, 0.1);
    try testing.expect(input.mouse_left);
    try testing.expectEqual(0, player.fire_cooldown);
    try testing.expectEqual(1, player.shots_fired);

    // A fresh click fires again.
    input.beginFrame();
    click(&input);
    player.update(&input, &world, TEST_GROUND_Y, 0.01);
    try testing.expectEqual(2, player.shots_fired);
    try testing.expectEqual(2, world.liveCount());
}

test "a shot the full world cannot spawn gives no feedback, and the next click retries" {
    var world = World.init();
    for (0..ecs.MAX_ENTITIES) |_| {
        const e = try world.spawn();
        world.setTransform(e, .{ .y = 100 }); // no collider: never blocks the player
    }
    var player = standingPlayer(-90, 0);
    var input: Input = .{};

    click(&input);
    player.update(&input, &world, TEST_GROUND_Y, 0.01);
    try testing.expectEqual(0, player.shots_fired);
    try testing.expectEqual(0, player.shake_timer);
    try testing.expectEqual(0, player.fire_cooldown);
    try testing.expectEqual(ecs.MAX_ENTITIES, world.liveCount());

    // A slot frees up: the very next click fires into it.
    world.despawn(17);
    input.beginFrame();
    click(&input);
    player.update(&input, &world, TEST_GROUND_Y, 0.01);
    try testing.expectEqual(1, player.shots_fired);
    try testing.expect(world.has(17, .projectile));
    try testing.expectEqual(FIRE_COOLDOWN, player.fire_cooldown);
}

test "colliders push the player out before the shot leaves from the corrected position" {
    var world = World.init();
    // 0.1 into the side of the eye's collision box (pen x 0.1 < y, z 0.6).
    _ = try scene.spawnStaticCube(&world, .init(0.7, STANDING_Y, 5));
    var player = standingPlayer(-90, 0);
    try testing.expectEqual(Vec3.init(0, STANDING_Y, 5), player.position);
    var input: Input = .{};

    click(&input);
    player.update(&input, &world, TEST_GROUND_Y, 0.01);

    try expectVec3(.init(-0.1, STANDING_Y, 5), player.position, 1e-5);
    const shot: Entity = 1;
    try testing.expect(world.has(shot, .projectile));
    try expectVec3(player.position.add(player.front), positionOf(&world, shot), 1e-5);
}

test "the player lands on a block and stays on top of it, at 60 Hz and at the 33 ms frame clamp" {
    // A bottom-row gallery block: top face at y = -9, so a resting eye sits CAM_RADIUS above it.
    const rest_y: f32 = -9.0 + CAM_RADIUS;
    for ([_]f32{ 1.0 / 60.0, 0.033 }) |dt| {
        for ([_]f32{ rest_y, rest_y + 0.7 }) |start_y| { // resting on it, and dropped onto it
            var world = World.init();
            _ = try scene.spawnStaticCube(&world, .init(0, -9.5, -5));
            var player = Player.init(null);
            player.position = .init(0, start_y, -5);
            const input: Input = .{};

            var t: f32 = 0;
            while (t < 5) : (t += dt) player.update(&input, &world, TEST_GROUND_Y, dt);

            try testing.expectEqual(0, player.position.x);
            try testing.expectEqual(-5, player.position.z);
            try testing.expectApproxEqAbs(rest_y, player.position.y, 0.05);
            try testing.expect(!player.grounded); // only the floor can be jumped from
        }
    }
}

test "a confirmed hit shows the hit marker, which fades at 5 per second" {
    var world = World.init();
    var player = standingPlayer(-90, 0);
    const input: Input = .{};

    player.onConfirmedHit();
    try testing.expectEqual(1, player.hit_marker_timer);
    player.update(&input, &world, TEST_GROUND_Y, 0.1);
    try testing.expectApproxEqAbs(0.5, player.hit_marker_timer, 1e-6);
    player.update(&input, &world, TEST_GROUND_Y, 0.15);
    try testing.expectEqual(0, player.hit_marker_timer); // clamped, never negative

    // A new hit re-arms it at full strength.
    player.onConfirmedHit();
    try testing.expectEqual(1, player.hit_marker_timer);
}

test "camera looks from the eye along front through the 45° perspective" {
    var player = Player.init(null);
    player.setLook(-60, 20);
    const aspect: f32 = 1.5;
    const cam = player.camera(aspect, 3.0);

    try expectPoint(.{ 0, 0, 0, 1 }, cam.view.transformPoint(player.position), 1e-5);
    try expectPoint(.{ 0, 0, -1, 1 }, cam.view.transformPoint(player.position.add(player.front)), 1e-5);
    try expectPoint(.{ 1, 0, 0, 1 }, cam.view.transformPoint(player.position.add(player.right)), 1e-5);
    try expectPoint(.{ 0, 1, 0, 1 }, cam.view.transformPoint(player.position.add(player.up)), 1e-5);
    const fov = std.math.degreesToRadians(@as(f32, 45));
    try testing.expectEqual(Mat4.perspective(fov, aspect, 0.1, 200), cam.proj);
    try testing.expectEqual(cam.proj.mul(cam.view), cam.view_proj);
}

test "screen shake moves only the eye: the aim point stays on the view axis" {
    var player = Player.init(null);
    player.shake_timer = SHAKE_ON_FIRE;
    const time: f32 = 0.37;
    const cam = player.camera(1.0, time);

    const intensity = SHAKE_ON_FIRE * SHAKE_AMPLITUDE;
    const t = time * SHAKE_RATE;
    const eye = player.position.add(.init(@sin(t * 7.3) * intensity, @sin(t * 11.1) * intensity, 0));
    try testing.expect(eye.sub(player.position).length() > 1e-3); // the shake really moved it
    try expectPoint(.{ 0, 0, 0, 1 }, cam.view.transformPoint(eye), 1e-5);
    const aim = cam.view.transformPoint(player.position.add(player.front));
    try testing.expectApproxEqAbs(0, aim[0], 1e-5);
    try testing.expectApproxEqAbs(0, aim[1], 1e-5);

    // Once the shake runs out, the eye is the player's position again.
    player.shake_timer = 0;
    try expectPoint(.{ 0, 0, 0, 1 }, player.camera(1.0, time).view.transformPoint(player.position), 1e-5);
}

test "gunModel faces the hands down the view, with idle sway and shot kickback" {
    var player = Player.init(null);
    const rest = player.gunModel(0);
    const turn = Mat4.rotationY(std.math.pi);
    for (turn.columns[0..3], rest.columns[0..3]) |expected, actual| {
        try testing.expectEqualSlices(f32, &expected, &actual);
    }
    // t = 0: the cosine sway is at its peak (+0.01 on x), the sine sway at 0.
    try expectPoint(.{ 0.31, -0.25, -0.7, 1 }, rest.columns[3], 1e-6);
    // A quarter period of the 3 rad/s vertical sway later, it peaks too.
    const t: f32 = std.math.pi / 6.0;
    try expectPoint(.{ 0.3 + @cos(1.5 * t) * 0.01, -0.24, -0.7, 1 }, player.gunModel(t).columns[3], 1e-6);
    // A fresh shot kicks the gun 0.09 back towards the eye.
    player.shake_timer = SHAKE_ON_FIRE;
    try testing.expectApproxEqAbs(-0.61, player.gunModel(0).columns[3][2], 1e-6);
}
