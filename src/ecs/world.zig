<<<<<<< HEAD
//! ECS world: parallel component arrays, per-entity component bitmasks and LIFO slot recycling.

const std = @import("std");

// ============================================================
// ENTITY
// ============================================================

/// An entity is a slot index into the World's parallel arrays.
pub const Entity = u32;

/// Slot capacity of a World; also sizes the GPU physics and instance buffers.
pub const MAX_ENTITIES: u32 = 4096;

// ============================================================
// COMPONENTS
// ============================================================

/// Position, Euler rotation in radians and uniform scale.
pub const Transform = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    rot_x: f32 = 0,
    rot_y: f32 = 0,
    rot_z: f32 = 0,
    scale: f32 = 1,
};

/// Constant Y rotation: spinSystem sets rot_y = speed * time + offset.
pub const Spin = struct {
    speed: f32 = 1,
    offset: f32 = 0,
};

/// Which mesh and texture draw the entity.
pub const MeshRenderer = struct {
    mesh_id: u16 = 0,
    texture_id: u16 = 0,
};

/// Linear velocity in units per second.
pub const Velocity = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

/// Axis-aligned box centred on the transform; static bodies are never pushed.
pub const Collider = struct {
    half_x: f32 = 0.5,
    half_y: f32 = 0.5,
    half_z: f32 = 0.5,
    is_static: bool = true,
};

/// Hit points plus the hit-flash timer the renderer tints with.
pub const Health = struct {
    hp: f32 = 100,
    max_hp: f32 = 100,
    hit_timer: f32 = 0,
};

/// Marks hitscan-targetable enemies; carries no data.
pub const EnemyTag = struct {};

/// A fired projectile; projectileLifetimeSystem despawns it after `lifetime` seconds.
pub const Projectile = struct {
    age: f32 = 0,
    lifetime: f32 = 10.0,
};

// ============================================================
// COMPONENT MASK (one bit per component type)
// ============================================================

/// Component kinds; the tag value is the component's bit index in a ComponentMask. The physics
/// shader gets bit(.transform), bit(.velocity) and bit(.collider) as generated defines, so these
/// positions are part of the GPU contract.
pub const Component = enum(u4) {
    transform = 0,
    spin = 1,
    mesh_renderer = 2,
    velocity = 3,
    collider = 4,
    health = 5,
    enemy_tag = 6,
    projectile = 7,
};

/// One bit per Component. A u4 tag is exactly Log2Int(u16), so shifts need no casts.
pub const ComponentMask = u16;

/// The mask bit of one component.
pub fn bit(c: Component) ComponentMask {
    return @as(ComponentMask, 1) << @backingInt(c);
}

/// The union of the components' bits; comptime-callable, so systems keep masks as container consts.
pub fn mask(components: []const Component) ComponentMask {
    var m: ComponentMask = 0;
    for (components) |c| m |= bit(c);
    return m;
}

/// True when entity_mask has every bit of required (an empty requirement matches anything).
pub fn hasMask(entity_mask: ComponentMask, required: ComponentMask) bool {
    return (entity_mask & required) == required;
}

// ============================================================
// AABB (computed from Transform + Collider)
// ============================================================

/// Axis-aligned bounding box in world space.
pub const AABB = struct {
    min_x: f32,
    min_y: f32,
    min_z: f32,
    max_x: f32,
    max_y: f32,
    max_z: f32,

    /// The collider's box around the transform position (rotation and scale are ignored, as on the GPU).
    pub fn fromTransformCollider(t: *const Transform, c: *const Collider) AABB {
        return .{
            .min_x = t.x - c.half_x,
            .min_y = t.y - c.half_y,
            .min_z = t.z - c.half_z,
            .max_x = t.x + c.half_x,
            .max_y = t.y + c.half_y,
            .max_z = t.z + c.half_z,
        };
    }

    /// True when the boxes intersect or touch on all three axes.
    pub fn overlaps(a: AABB, b: AABB) bool {
        return (a.min_x <= b.max_x and a.max_x >= b.min_x) and
            (a.min_y <= b.max_y and a.max_y >= b.min_y) and
            (a.min_z <= b.max_z and a.max_z >= b.min_z);
    }

    /// Overlap depth per axis: positive = overlapping, negative = the gap on a separated axis.
    pub fn penetration(a: AABB, b: AABB) struct { x: f32, y: f32, z: f32 } {
        return .{
            .x = @min(a.max_x, b.max_x) - @max(a.min_x, b.min_x),
            .y = @min(a.max_y, b.max_y) - @max(a.min_y, b.min_y),
            .z = @min(a.max_z, b.max_z) - @max(a.min_z, b.min_z),
        };
    }
};

// ============================================================
// WORLD — the ECS container
// ============================================================

/// Fixed-capacity entity store: one array per component type indexed by Entity, plus a
/// component bitmask per slot. A slot counts as dead once its mask is 0.
pub const World = struct {
    /// High-water mark: every slot ever handed out is < count. Systems and the GPU physics
    /// dispatch scan 0..count; despawned slots inside that range have mask 0.
    count: u32 = 0,
    /// Component membership per slot: bit(c) set = the slot has component c.
    masks: [MAX_ENTITIES]ComponentMask = @splat(0),

    /// LIFO stack of despawned slots; spawn() pops it before growing count.
    free_list: [MAX_ENTITIES]Entity = @splat(0),
    free_count: u32 = 0,

    transforms: [MAX_ENTITIES]Transform = @splat(Transform{}),
    spins: [MAX_ENTITIES]Spin = @splat(Spin{}),
    mesh_renderers: [MAX_ENTITIES]MeshRenderer = @splat(MeshRenderer{}),
    velocities: [MAX_ENTITIES]Velocity = @splat(Velocity{}),
    colliders: [MAX_ENTITIES]Collider = @splat(Collider{}),
    healths: [MAX_ENTITIES]Health = @splat(Health{}),
    enemy_tags: [MAX_ENTITIES]EnemyTag = @splat(EnemyTag{}),
    projectiles: [MAX_ENTITIES]Projectile = @splat(Projectile{}),

    /// An empty world (about 376 KiB, so pass it by pointer).
    pub fn init() World {
        return .{};
    }

    // --- Entity management ---

    /// Hands out the most recently despawned slot, else the next unused one; fails once all
    /// MAX_ENTITIES slots are live. The entity starts with no components: set at least one,
    /// because despawn treats a zero mask as already dead.
    pub fn spawn(self: *World) error{MaxEntitiesReached}!Entity {
        if (self.free_count > 0) {
            self.free_count -= 1;
            return self.free_list[self.free_count];
        }
        if (self.count >= MAX_ENTITIES) return error.MaxEntitiesReached;
        const e = self.count;
        self.count += 1;
        return e;
    }

    /// Clears e's mask, so no system sees it any more, and pushes its slot on the free list.
    /// Idempotent: a slot whose mask is already 0 is skipped, so it can't enter the list twice.
    pub fn despawn(self: *World, e: Entity) void {
        if (self.masks[e] == 0) return;
        self.masks[e] = 0;
        self.free_list[self.free_count] = e;
        self.free_count += 1;
    }

    /// True when e currently has component c.
    pub fn has(self: *const World, e: Entity, c: Component) bool {
        return hasMask(self.masks[e], bit(c));
    }

    // --- Component setters: store the value, add the bit ---

    /// Sets e's Transform.
    pub fn setTransform(self: *World, e: Entity, t: Transform) void {
        self.transforms[e] = t;
        self.masks[e] |= bit(.transform);
    }

    /// Sets e's Spin.
    pub fn setSpin(self: *World, e: Entity, s: Spin) void {
        self.spins[e] = s;
        self.masks[e] |= bit(.spin);
    }

    /// Sets e's MeshRenderer.
    pub fn setMeshRenderer(self: *World, e: Entity, m: MeshRenderer) void {
        self.mesh_renderers[e] = m;
        self.masks[e] |= bit(.mesh_renderer);
    }

    /// Sets e's Velocity.
    pub fn setVelocity(self: *World, e: Entity, v: Velocity) void {
        self.velocities[e] = v;
        self.masks[e] |= bit(.velocity);
    }

    /// Sets e's Collider.
    pub fn setCollider(self: *World, e: Entity, c: Collider) void {
        self.colliders[e] = c;
        self.masks[e] |= bit(.collider);
    }

    /// Sets e's Health.
    pub fn setHealth(self: *World, e: Entity, h: Health) void {
        self.healths[e] = h;
        self.masks[e] |= bit(.health);
    }

    /// Tags e as an enemy.
    pub fn setEnemyTag(self: *World, e: Entity) void {
        self.enemy_tags[e] = .{};
        self.masks[e] |= bit(.enemy_tag);
    }

    /// Sets e's Projectile.
    pub fn setProjectile(self: *World, e: Entity, p: Projectile) void {
        self.projectiles[e] = p;
        self.masks[e] |= bit(.projectile);
    }

    // --- Queries ---

    /// Fills buf, in ascending order, with the slots below count whose mask has every required
    /// bit (required == 0 also matches dead slots) and returns the filled prefix (≤ buf.len).
    pub fn query(self: *const World, required: ComponentMask, buf: []Entity) []Entity {
        var n: usize = 0;
        for (self.masks[0..self.count], 0..) |m, i| {
            if (n == buf.len) break;
            if (!hasMask(m, required)) continue;
            buf[n] = @intCast(i);
            n += 1;
        }
        return buf[0..n];
    }

    /// How many slots below count have every required bit.
    pub fn countMatching(self: *const World, required: ComponentMask) u32 {
        var n: u32 = 0;
        for (self.masks[0..self.count]) |m| {
            if (hasMask(m, required)) n += 1;
        }
        return n;
    }

    /// Live entities: slots handed out minus slots waiting on the free list.
    pub fn liveCount(self: *const World) u32 {
        return self.count - self.free_count;
    }
};

// ============================================================
// TESTS — entity lifecycle, masks, AABBs, queries
// ============================================================

const testing = std.testing;

test "spawn reuses a despawned slot instead of growing count" {
    var w = World.init();
    const e0 = try w.spawn();
    w.setTransform(e0, .{});
    const e1 = try w.spawn();
    w.setTransform(e1, .{});
    const e2 = try w.spawn();
    w.setTransform(e2, .{});

    w.despawn(e1);
    const reused = try w.spawn();

    try testing.expectEqual(e1, reused);
    try testing.expectEqual(@as(u32, 3), w.count);
}

test "despawn clears the component mask" {
    var w = World.init();
    const e = try w.spawn();
    w.setTransform(e, .{});
    w.setVelocity(e, .{});
    try testing.expect(w.masks[e] != 0);

    w.despawn(e);

    try testing.expectEqual(@as(ComponentMask, 0), w.masks[e]);
}

test "despawning the same entity twice does not hand out the slot twice" {
    var w = World.init();
    const e0 = try w.spawn();
    w.setTransform(e0, .{});

    w.despawn(e0);
    w.despawn(e0);

    const a = try w.spawn();
    w.setTransform(a, .{});
    const b = try w.spawn();
    w.setTransform(b, .{});

    try testing.expect(a != b);
}

test "world full of despawned entities can keep spawning" {
    var w = World.init();
    for (0..MAX_ENTITIES) |_| {
        const e = try w.spawn();
        w.setTransform(e, .{});
    }
    try testing.expectError(error.MaxEntitiesReached, w.spawn());

    w.despawn(5);
    const reused = try w.spawn();

    try testing.expectEqual(@as(Entity, 5), reused);
    try testing.expectError(error.MaxEntitiesReached, w.spawn());
}

test "recycled slots come back last-despawned first" {
    var w = World.init();
    for (0..4) |_| {
        const e = try w.spawn();
        w.setTransform(e, .{});
    }

    w.despawn(1);
    w.despawn(3);

    try testing.expectEqual(@as(Entity, 3), try w.spawn());
    try testing.expectEqual(@as(Entity, 1), try w.spawn());
    try testing.expectEqual(@as(Entity, 4), try w.spawn()); // free list empty: count grows
    try testing.expectEqual(@as(u32, 5), w.count);
}

test "liveCount is count minus the slots on the free list" {
    var w = World.init();
    try testing.expectEqual(@as(u32, 0), w.liveCount());

    var ids: [3]Entity = undefined;
    for (&ids) |*id| {
        id.* = try w.spawn();
        w.setTransform(id.*, .{});
    }
    try testing.expectEqual(@as(u32, 3), w.liveCount());

    w.despawn(ids[0]);
    w.despawn(ids[0]); // idempotent: freed once
    try testing.expectEqual(@as(u32, 2), w.liveCount());
    try testing.expectEqual(@as(u32, 3), w.count); // the high-water mark never shrinks

    const again = try w.spawn();
    try testing.expectEqual(ids[0], again);
    try testing.expectEqual(@as(u32, 3), w.liveCount());
}

test "has reports exactly the components that were set" {
    var w = World.init();
    const e = try w.spawn();
    w.setTransform(e, .{ .x = 1 });
    w.setCollider(e, .{ .is_static = false });
    w.setEnemyTag(e);

    try testing.expect(w.has(e, .transform));
    try testing.expect(w.has(e, .collider));
    try testing.expect(w.has(e, .enemy_tag));
    try testing.expect(!w.has(e, .velocity));
    try testing.expect(!w.has(e, .spin));
    try testing.expect(!w.has(e, .projectile));

    w.despawn(e);
    try testing.expect(!w.has(e, .transform));
}

test "every setter stores its component and sets its own bit" {
    var w = World.init();
    const e = try w.spawn();
    w.setTransform(e, .{ .y = 2 });
    w.setSpin(e, .{ .speed = 3 });
    w.setMeshRenderer(e, .{ .texture_id = 4 });
    w.setVelocity(e, .{ .z = 5 });
    w.setCollider(e, .{ .half_x = 0.25 });
    w.setHealth(e, .{ .hp = 6 });
    w.setEnemyTag(e);
    w.setProjectile(e, .{ .lifetime = 7 });

    try testing.expectEqual(mask(std.enums.values(Component)), w.masks[e]);
    try testing.expectEqual(@as(f32, 2), w.transforms[e].y);
    try testing.expectEqual(@as(f32, 1), w.transforms[e].scale); // untouched fields keep defaults
    try testing.expectEqual(@as(f32, 3), w.spins[e].speed);
    try testing.expectEqual(@as(u16, 4), w.mesh_renderers[e].texture_id);
    try testing.expectEqual(@as(f32, 5), w.velocities[e].z);
    try testing.expectEqual(@as(f32, 0.25), w.colliders[e].half_x);
    try testing.expect(w.colliders[e].is_static);
    try testing.expectEqual(@as(f32, 6), w.healths[e].hp);
    try testing.expectEqual(@as(f32, 7), w.projectiles[e].lifetime);
    try testing.expectEqual(@as(f32, 0), w.projectiles[e].age);
}

test "bit positions match the physics shader's mask contract" {
    try testing.expectEqual(@as(ComponentMask, 0x01), bit(.transform));
    try testing.expectEqual(@as(ComponentMask, 0x08), bit(.velocity));
    try testing.expectEqual(@as(ComponentMask, 0x10), bit(.collider));
    try testing.expectEqual(@as(ComponentMask, 0x80), bit(.projectile));
    // The original kernel hard-coded these two masks.
    try testing.expectEqual(@as(ComponentMask, 0x09), mask(&.{ .transform, .velocity }));
    try testing.expectEqual(@as(ComponentMask, 0x11), mask(&.{ .transform, .collider }));
}

test "mask unions bits, ignores duplicates and evaluates at comptime" {
    const Masks = struct {
        const physics = mask(&.{ .transform, .collider });
        const none = mask(&.{});
    };
    comptime std.debug.assert(Masks.physics == 0x11);
    try testing.expectEqual(@as(ComponentMask, 0), Masks.none);
    try testing.expectEqual(bit(.spin), mask(&.{ .spin, .spin }));
    // Eight distinct, contiguous bits.
    try testing.expectEqual(@as(ComponentMask, 0xFF), mask(std.enums.values(Component)));

    var runtime_list = [_]Component{ .health, .enemy_tag };
    _ = &runtime_list;
    try testing.expectEqual(@as(ComponentMask, 0x60), mask(&runtime_list));
}

test "hasMask needs every required bit" {
    const m = mask(&.{ .transform, .velocity, .collider });
    try testing.expect(hasMask(m, mask(&.{ .transform, .collider })));
    try testing.expect(hasMask(m, m));
    try testing.expect(!hasMask(m, mask(&.{ .transform, .spin })));
    try testing.expect(!hasMask(0, bit(.transform)));
    try testing.expect(hasMask(m, 0));
}

test "AABB spans the position plus or minus the half extents" {
    const t: Transform = .{ .x = 1, .y = -2, .z = 3, .scale = 5 };
    const c: Collider = .{ .half_x = 0.5, .half_y = 1, .half_z = 0.25 };
    const box = AABB.fromTransformCollider(&t, &c);

    try testing.expectApproxEqAbs(@as(f32, 0.5), box.min_x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -3), box.min_y, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2.75), box.min_z, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.5), box.max_x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1), box.max_y, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 3.25), box.max_z, 1e-6);
}

test "AABB overlap counts touching faces and rejects any separated axis" {
    const c: Collider = .{};
    const origin: Transform = .{};
    const a = AABB.fromTransformCollider(&origin, &c);

    const inside: Transform = .{ .x = 0.5, .y = -0.5, .z = 0.25 };
    const touching: Transform = .{ .x = 1 };
    const apart_x: Transform = .{ .x = 1.5 };
    const apart_y: Transform = .{ .y = -1.01 };
    const apart_z: Transform = .{ .x = 0.2, .z = 2 };

    try testing.expect(a.overlaps(AABB.fromTransformCollider(&inside, &c)));
    try testing.expect(a.overlaps(AABB.fromTransformCollider(&touching, &c)));
    try testing.expect(!a.overlaps(AABB.fromTransformCollider(&apart_x, &c)));
    try testing.expect(!a.overlaps(AABB.fromTransformCollider(&apart_y, &c)));
    try testing.expect(!a.overlaps(AABB.fromTransformCollider(&apart_z, &c)));
    // Symmetric.
    try testing.expect(!AABB.fromTransformCollider(&apart_x, &c).overlaps(a));
}

test "AABB penetration is the per-axis overlap depth" {
    const c: Collider = .{};
    const t_a: Transform = .{};
    const t_b: Transform = .{ .x = 0.75, .y = 0.2, .z = -0.1 };
    const a = AABB.fromTransformCollider(&t_a, &c);
    const b = AABB.fromTransformCollider(&t_b, &c);

    const pen = a.penetration(b);
    try testing.expectApproxEqAbs(@as(f32, 0.25), pen.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.8), pen.y, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.9), pen.z, 1e-6);

    const back = b.penetration(a);
    try testing.expectApproxEqAbs(pen.x, back.x, 1e-6);
    try testing.expectApproxEqAbs(pen.y, back.y, 1e-6);
    try testing.expectApproxEqAbs(pen.z, back.z, 1e-6);

    // Unit cubes at (0.2, 0.2, 0.2) and (-0.2, -0.2, -0.2): the physics de-dup regression pair.
    const t_p: Transform = .{ .x = 0.2, .y = 0.2, .z = 0.2 };
    const t_q: Transform = .{ .x = -0.2, .y = -0.2, .z = -0.2 };
    const diag = AABB.fromTransformCollider(&t_p, &c).penetration(AABB.fromTransformCollider(&t_q, &c));
    try testing.expectApproxEqAbs(@as(f32, 0.6), diag.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.6), diag.y, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.6), diag.z, 1e-6);

    // A separated axis reports the gap as a negative depth.
    const t_far: Transform = .{ .x = 3 };
    const gap = a.penetration(AABB.fromTransformCollider(&t_far, &c));
    try testing.expectApproxEqAbs(@as(f32, -2), gap.x, 1e-6);
}

test "query and countMatching skip dead slots and respect the buffer" {
    var w = World.init();
    for (0..5) |i| {
        const e = try w.spawn();
        w.setTransform(e, .{});
        if (i % 2 == 0) w.setVelocity(e, .{});
    }
    const dynamic = mask(&.{ .transform, .velocity });
    var buf: [8]Entity = undefined;

    try testing.expectEqual(@as(u32, 3), w.countMatching(dynamic));
    try testing.expectEqualSlices(Entity, &.{ 0, 2, 4 }, w.query(dynamic, &buf));

    w.despawn(2);
    try testing.expectEqual(@as(u32, 2), w.countMatching(dynamic));
    try testing.expectEqual(@as(u32, 4), w.countMatching(bit(.transform)));
    try testing.expectEqualSlices(Entity, &.{ 0, 4 }, w.query(dynamic, &buf));

    var one: [1]Entity = undefined;
    try testing.expectEqualSlices(Entity, &.{0}, w.query(dynamic, &one));
    try testing.expectEqual(@as(usize, 0), w.query(dynamic, buf[0..0]).len);
}
||||||| empty tree
=======
const std = @import("std");

// ============================================================
// ENTITY
// ============================================================
pub const Entity = u32;
pub const MAX_ENTITIES: usize = 4096;

// ============================================================
// COMPONENTS
// ============================================================

pub const Transform = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    rot_x: f32 = 0,
    rot_y: f32 = 0,
    rot_z: f32 = 0,
    scale: f32 = 1.0,
};

pub const Spin = struct {
    speed: f32 = 1.0,
    offset: f32 = 0,
};

pub const MeshRenderer = struct {
    mesh_id: u16 = 0,
    texture_id: u16 = 0,
};

pub const Velocity = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

pub const Collider = struct {
    half_x: f32 = 0.5, // Half-extents (AABB)
    half_y: f32 = 0.5,
    half_z: f32 = 0.5,
    is_static: bool = true, // Static objects don't get pushed
};

pub const Health = struct {
    hp: f32 = 100,
    max_hp: f32 = 100,
    hit_timer: f32 = 0,
};

pub const EnemyTag = struct {
    _pad: u8 = 0,
};

// ============================================================
// COMPONENT MASK (bitfield — one bit per component type)
// ============================================================

pub const Component = enum(u8) {
    transform = 0,
    spin = 1,
    mesh_renderer = 2,
    velocity = 3,
    collider = 4,
    health = 5,
    enemy_tag = 6,
};

pub const ComponentMask = u16;

pub fn mask(components: []const Component) ComponentMask {
    var m: ComponentMask = 0;
    for (components) |c| {
        m |= @as(ComponentMask, 1) << @as(u4, @intCast(@intFromEnum(c)));
    }
    return m;
}

pub fn hasMask(entity_mask: ComponentMask, required: ComponentMask) bool {
    return (entity_mask & required) == required;
}

// ============================================================
// AABB — Axis-Aligned Bounding Box (computed from Transform + Collider)
// ============================================================

pub const AABB = struct {
    min_x: f32,
    min_y: f32,
    min_z: f32,
    max_x: f32,
    max_y: f32,
    max_z: f32,

    pub fn fromTransformCollider(t: *const Transform, c: *const Collider) AABB {
        return AABB{
            .min_x = t.x - c.half_x,
            .min_y = t.y - c.half_y,
            .min_z = t.z - c.half_z,
            .max_x = t.x + c.half_x,
            .max_y = t.y + c.half_y,
            .max_z = t.z + c.half_z,
        };
    }

    pub fn overlaps(a: AABB, b: AABB) bool {
        return (a.min_x <= b.max_x and a.max_x >= b.min_x) and
            (a.min_y <= b.max_y and a.max_y >= b.min_y) and
            (a.min_z <= b.max_z and a.max_z >= b.min_z);
    }

    /// Returns the penetration depth on each axis. Positive = overlapping.
    pub fn penetration(a: AABB, b: AABB) struct { x: f32, y: f32, z: f32 } {
        const ox = @min(a.max_x, b.max_x) - @max(a.min_x, b.min_x);
        const oy = @min(a.max_y, b.max_y) - @max(a.min_y, b.min_y);
        const oz = @min(a.max_z, b.max_z) - @max(a.min_z, b.min_z);
        return .{ .x = ox, .y = oy, .z = oz };
    }
};

// ============================================================
// WORLD — The ECS container
// ============================================================

pub const World = struct {
    count: u32 = 0,
    masks: [MAX_ENTITIES]ComponentMask = @splat(0),

    // LIFO stack of despawned slots, recycled by spawn() before growing count.
    free_list: [MAX_ENTITIES]Entity = @splat(0),
    free_count: u32 = 0,

    transforms: [MAX_ENTITIES]Transform = @splat(Transform{}),
    spins: [MAX_ENTITIES]Spin = @splat(Spin{}),
    mesh_renderers: [MAX_ENTITIES]MeshRenderer = @splat(MeshRenderer{}),
    velocities: [MAX_ENTITIES]Velocity = @splat(Velocity{}),
    colliders: [MAX_ENTITIES]Collider = @splat(Collider{}),
    healths: [MAX_ENTITIES]Health = @splat(Health{}),
    enemy_tags: [MAX_ENTITIES]EnemyTag = @splat(EnemyTag{}),

    pub fn init() World {
        return World{};
    }

    // --- Entity Management ---

    pub fn spawn(self: *World) !Entity {
        if (self.free_count > 0) {
            self.free_count -= 1;
            return self.free_list[self.free_count];
        }
        if (self.count >= MAX_ENTITIES) return error.MaxEntitiesReached;
        const id = self.count;
        self.count += 1;
        return id;
    }

    /// Despawn an entity: clear its mask (it stops matching every query) and
    /// push its slot onto the free-list for reuse. Idempotent — an entity whose
    /// mask is already 0 is skipped, so the slot can't enter the list twice.
    /// That guard relies on spawn helpers setting at least one component.
    pub fn despawn(self: *World, e: Entity) void {
        if (self.masks[e] == 0) return;
        self.masks[e] = 0;
        self.free_list[self.free_count] = e;
        self.free_count += 1;
    }

    // --- Component Setters ---

    pub fn setTransform(self: *World, e: Entity, t: Transform) void {
        self.transforms[e] = t;
        self.masks[e] |= @as(ComponentMask, 1) << @as(u4, @intCast(@intFromEnum(Component.transform)));
    }

    pub fn setSpin(self: *World, e: Entity, s: Spin) void {
        self.spins[e] = s;
        self.masks[e] |= @as(ComponentMask, 1) << @as(u4, @intCast(@intFromEnum(Component.spin)));
    }

    pub fn setMeshRenderer(self: *World, e: Entity, m: MeshRenderer) void {
        self.mesh_renderers[e] = m;
        self.masks[e] |= @as(ComponentMask, 1) << @as(u4, @intCast(@intFromEnum(Component.mesh_renderer)));
    }

    pub fn setVelocity(self: *World, e: Entity, v: Velocity) void {
        self.velocities[e] = v;
        self.masks[e] |= @as(ComponentMask, 1) << @as(u4, @intCast(@intFromEnum(Component.velocity)));
    }

    pub fn setCollider(self: *World, e: Entity, c: Collider) void {
        self.colliders[e] = c;
        self.masks[e] |= @as(ComponentMask, 1) << @as(u4, @intCast(@intFromEnum(Component.collider)));
    }

    pub fn setHealth(self: *World, e: Entity, h: Health) void {
        self.healths[e] = h;
        self.masks[e] |= @as(ComponentMask, 1) << @as(u4, @intCast(@intFromEnum(Component.health)));
    }

    pub fn setEnemyTag(self: *World, e: Entity) void {
        self.enemy_tags[e] = EnemyTag{};
        self.masks[e] |= @as(ComponentMask, 1) << @as(u4, @intCast(@intFromEnum(Component.enemy_tag)));
    }

    // --- Component Getters ---

    pub fn getTransform(self: *World, e: Entity) *Transform {
        return &self.transforms[e];
    }

    pub fn getSpin(self: *World, e: Entity) *Spin {
        return &self.spins[e];
    }

    pub fn getCollider(self: *World, e: Entity) *Collider {
        return &self.colliders[e];
    }

    pub fn getHealth(self: *World, e: Entity) *Health {
        return &self.healths[e];
    }

    // --- Queries ---

    pub fn query(self: *World, required: ComponentMask, buf: []Entity) []Entity {
        var n: usize = 0;
        for (0..self.count) |i| {
            if (hasMask(self.masks[i], required) and n < buf.len) {
                buf[n] = @intCast(i);
                n += 1;
            }
        }
        return buf[0..n];
    }

    pub fn countMatching(self: *World, required: ComponentMask) u32 {
        var n: u32 = 0;
        for (0..self.count) |i| {
            if (hasMask(self.masks[i], required)) n += 1;
        }
        return n;
    }
};

// ============================================================
// TESTS — entity lifecycle and slot reuse
// ============================================================

const testing = std.testing;

test "spawn reuses a despawned slot instead of growing count" {
    var w = World.init();
    const e0 = try w.spawn();
    w.setTransform(e0, .{});
    const e1 = try w.spawn();
    w.setTransform(e1, .{});
    const e2 = try w.spawn();
    w.setTransform(e2, .{});

    w.despawn(e1);
    const reused = try w.spawn();

    try testing.expectEqual(e1, reused);
    try testing.expectEqual(@as(u32, 3), w.count);
}

test "despawn clears the component mask" {
    var w = World.init();
    const e = try w.spawn();
    w.setTransform(e, .{});
    w.setVelocity(e, .{});
    try testing.expect(w.masks[e] != 0);

    w.despawn(e);

    try testing.expectEqual(@as(ComponentMask, 0), w.masks[e]);
}

test "despawning the same entity twice does not hand out the slot twice" {
    var w = World.init();
    const e0 = try w.spawn();
    w.setTransform(e0, .{});

    w.despawn(e0);
    w.despawn(e0);

    const a = try w.spawn();
    w.setTransform(a, .{});
    const b = try w.spawn();
    w.setTransform(b, .{});

    try testing.expect(a != b);
}

test "world full of despawned entities can keep spawning" {
    var w = World.init();
    for (0..MAX_ENTITIES) |_| {
        const e = try w.spawn();
        w.setTransform(e, .{});
    }
    try testing.expectError(error.MaxEntitiesReached, w.spawn());

    w.despawn(5);
    const reused = try w.spawn();

    try testing.expectEqual(@as(Entity, 5), reused);
}
>>>>>>> Zetal/main
