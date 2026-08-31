const std = @import("std");
const objc = @import("objc.zig");
const window = @import("platform/window.zig");
const ecs = @import("ecs/world.zig");
const systems = @import("ecs/systems.zig");
const scene = @import("scene.zig");
const math = @import("render/math.zig");

const Vec3 = math.Vec3;
const Mat4x4 = math.Mat4x4;

// ============================================================
// Gameplay constants — match values from the original main.zig
// ============================================================

const PROJECTILE_SPEED: f32 = 40.0;
const FIRE_COOLDOWN: f32 = 0.15;

const MOVE_SPEED: f32 = 5.0;
const MOUSE_SENSITIVITY: f32 = 0.1;
const CAM_RADIUS: f32 = 0.3;

const PLAYER_HEIGHT: f32 = 2.0;
const JUMP_FORCE: f32 = 18.0;
const GRAVITY: f32 = -45.0;

const SHAKE_ON_FIRE: f32 = 0.06;
const HIT_MARKER_ON_HIT: f32 = 1.0;
const HIT_MARKER_DECAY_RATE: f32 = 5.0;

const FOV_DEG: f32 = 45.0;
const NEAR_PLANE: f32 = 0.1;
const FAR_PLANE: f32 = 200.0;

const PITCH_LIMIT: f32 = 89.0;

pub const Camera = struct {
    view: Mat4x4,
    proj: Mat4x4,
    view_proj: Mat4x4,
};

pub const Player = struct {
    // Camera
    pos: Vec3,
    yaw: f32,
    pitch: f32,
    front: Vec3,
    right: Vec3,
    up: Vec3,

    // Player physics
    vy: f32,
    is_grounded: bool,

    // FPS state
    fire_cooldown: f32,
    shake_timer: f32,
    hit_marker_timer: f32,

    // Audio
    gunshot_sound: ?objc.Object,

    pub fn init() Player {
        return Player{
            .pos = Vec3.init(0, -8, 5),
            .yaw = -90.0,
            .pitch = 0.0,
            .front = Vec3.init(0, 0, -1),
            .right = Vec3.init(1, 0, 0),
            .up = Vec3.init(0, 1, 0),

            .vy = 0.0,
            .is_grounded = false,

            .fire_cooldown = 0.0,
            .shake_timer = 0.0,
            .hit_marker_timer = 0.0,

            .gunshot_sound = loadNSSound("gunshot.wav"),
        };
    }

    pub fn update(
        self: *Player,
        app: *const window.App,
        world: *ecs.World,
        ground_y: f32,
        dt: f32,
    ) void {
        self.updateLook(app);
        self.updateMovement(app, dt);
        self.updateGravity(dt, ground_y);
        self.resolveAgainstWorld(world);
        self.updateFire(app, world, dt);
        self.decayTimers(dt);
    }

    pub fn onConfirmedHit(self: *Player) void {
        self.hit_marker_timer = HIT_MARKER_ON_HIT;
    }

    /// Build view-projection matrices including screen shake.
    pub fn camera(self: *const Player, aspect: f32, time_sec: f32) Camera {
        var shake = Vec3.init(0, 0, 0);
        if (self.shake_timer > 0) {
            const intensity = self.shake_timer * 0.3;
            const t = time_sec * 120.0;
            shake = Vec3.init(@sin(t * 7.3) * intensity, @sin(t * 11.1) * intensity, 0);
        }

        const shaken_pos = Vec3.add(self.pos, shake);
        const center = Vec3.add(self.pos, self.front);
        const view = Mat4x4.lookAt(shaken_pos, center, self.up);
        const proj = Mat4x4.perspective(std.math.degreesToRadians(FOV_DEG), aspect, NEAR_PLANE, FAR_PLANE);
        return .{ .view = view, .proj = proj, .view_proj = Mat4x4.mul(proj, view) };
    }

    /// Viewmodel transform — caller multiplies by camera proj only (glued to screen).
    pub fn gunModel(self: *const Player, time_sec: f32) Mat4x4 {
        // Face camera (the source .obj is modeled looking the other way).
        var m = Mat4x4.rotateY(std.math.pi);

        const sway_y = @sin(time_sec * 3.0) * 0.01;
        const sway_x = @cos(time_sec * 1.5) * 0.01;
        const kickback = self.shake_timer * 1.5;

        m.columns[3][0] = 0.3 + sway_x;
        m.columns[3][1] = -0.25 + sway_y;
        m.columns[3][2] = -0.7 + kickback;
        return m;
    }

    // --- internals ---

    fn updateLook(self: *Player, app: *const window.App) void {
        self.yaw += app.mouse_dx * MOUSE_SENSITIVITY;
        self.pitch -= app.mouse_dy * MOUSE_SENSITIVITY;
        if (self.pitch > PITCH_LIMIT) self.pitch = PITCH_LIMIT;
        if (self.pitch < -PITCH_LIMIT) self.pitch = -PITCH_LIMIT;

        const yaw_rad = std.math.degreesToRadians(self.yaw);
        const pitch_rad = std.math.degreesToRadians(self.pitch);

        self.front = Vec3.norm(Vec3.init(
            @cos(yaw_rad) * @cos(pitch_rad),
            @sin(pitch_rad),
            @sin(yaw_rad) * @cos(pitch_rad),
        ));

        const world_up = Vec3.init(0, 1, 0);
        self.right = Vec3.norm(Vec3.cross(self.front, world_up));
        self.up = Vec3.norm(Vec3.cross(self.right, self.front));
    }

    fn updateMovement(self: *Player, app: *const window.App, dt: f32) void {
        const step = MOVE_SPEED * dt;
        const flat_front = Vec3.norm(Vec3.init(self.front.x, 0, self.front.z));

        if (app.isPressed(.W)) self.pos = Vec3.add(self.pos, Vec3.scale(flat_front, step));
        if (app.isPressed(.S)) self.pos = Vec3.sub(self.pos, Vec3.scale(flat_front, step));
        if (app.isPressed(.A)) self.pos = Vec3.sub(self.pos, Vec3.scale(self.right, step));
        if (app.isPressed(.D)) self.pos = Vec3.add(self.pos, Vec3.scale(self.right, step));

        if (app.isPressed(.Space) and self.is_grounded) {
            self.vy = JUMP_FORCE;
            self.is_grounded = false;
        }
    }

    fn updateGravity(self: *Player, dt: f32, ground_y: f32) void {
        self.vy += GRAVITY * dt;
        self.pos.y += self.vy * dt;

        const floor = ground_y + PLAYER_HEIGHT;
        if (self.pos.y <= floor) {
            self.pos.y = floor;
            self.vy = 0;
            self.is_grounded = true;
        } else {
            self.is_grounded = false;
        }
    }

    fn resolveAgainstWorld(self: *Player, world: *ecs.World) void {
        const resolved = systems.resolveCamera(world, self.pos.x, self.pos.y, self.pos.z, CAM_RADIUS);
        self.pos = Vec3.init(resolved.x, resolved.y, resolved.z);
    }

    fn updateFire(self: *Player, app: *const window.App, world: *ecs.World, dt: f32) void {
        self.fire_cooldown -= dt;
        if (self.fire_cooldown < 0) self.fire_cooldown = 0;

        if (!(app.mouse_left_pressed and self.fire_cooldown <= 0)) return;

        const spawn_offset: f32 = 1.0;
        const spawn_pos = Vec3.add(self.pos, Vec3.scale(self.front, spawn_offset));
        _ = scene.spawnProjectile(
            world,
            spawn_pos.x,
            spawn_pos.y,
            spawn_pos.z,
            self.front.x * PROJECTILE_SPEED,
            self.front.y * PROJECTILE_SPEED,
            self.front.z * PROJECTILE_SPEED,
        ) catch {};

        self.shake_timer = SHAKE_ON_FIRE;
        if (self.gunshot_sound) |snd| playNSSound(snd);
        self.fire_cooldown = FIRE_COOLDOWN;
    }

    fn decayTimers(self: *Player, dt: f32) void {
        self.shake_timer -= dt;
        if (self.shake_timer < 0) self.shake_timer = 0;

        self.hit_marker_timer -= dt * HIT_MARKER_DECAY_RATE;
        if (self.hit_marker_timer < 0) self.hit_marker_timer = 0;
    }
};

// ============================================================
// NSSound helpers
// ============================================================

fn loadNSSound(path: [*:0]const u8) ?objc.Object {
    const ns_str = objc.msgSend(
        ?objc.Object,
        objc.class("NSString"),
        "stringWithUTF8String:",
        .{path},
    ) orelse return null;

    const raw = objc.msgSend(?objc.Object, objc.class("NSSound"), "alloc", .{}) orelse return null;
    return objc.msgSend(
        ?objc.Object,
        raw,
        "initWithContentsOfFile:byReference:",
        .{ ns_str, true },
    );
}

fn playNSSound(sound: objc.Object) void {
    objc.msgSend(void, sound, "stop", .{});
    _ = objc.msgSend(bool, sound, "play", .{});
}
