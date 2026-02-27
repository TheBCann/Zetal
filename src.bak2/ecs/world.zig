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

// ============================================================
// COMPONENT MASK (bitfield — one bit per component type)
// ============================================================

pub const Component = enum(u8) {
    transform = 0,
    spin = 1,
    mesh_renderer = 2,
    velocity = 3,
    collider = 4,
};

pub const ComponentMask = u8;

pub fn mask(components: []const Component) ComponentMask {
    var m: ComponentMask = 0;
    for (components) |c| {
        m |= @as(ComponentMask, 1) << @as(u3, @intCast(@intFromEnum(c)));
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
    masks: [MAX_ENTITIES]ComponentMask = .{0} ** MAX_ENTITIES,

    transforms: [MAX_ENTITIES]Transform = .{Transform{}} ** MAX_ENTITIES,
    spins: [MAX_ENTITIES]Spin = .{Spin{}} ** MAX_ENTITIES,
    mesh_renderers: [MAX_ENTITIES]MeshRenderer = .{MeshRenderer{}} ** MAX_ENTITIES,
    velocities: [MAX_ENTITIES]Velocity = .{Velocity{}} ** MAX_ENTITIES,
    colliders: [MAX_ENTITIES]Collider = .{Collider{}} ** MAX_ENTITIES,

    pub fn init() World {
        return World{};
    }

    // --- Entity Management ---

    pub fn spawn(self: *World) !Entity {
        if (self.count >= MAX_ENTITIES) return error.MaxEntitiesReached;
        const id = self.count;
        self.count += 1;
        return id;
    }

    // --- Component Setters ---

    pub fn setTransform(self: *World, e: Entity, t: Transform) void {
        self.transforms[e] = t;
        self.masks[e] |= @as(ComponentMask, 1) << @as(u3, @intCast(@intFromEnum(Component.transform)));
    }

    pub fn setSpin(self: *World, e: Entity, s: Spin) void {
        self.spins[e] = s;
        self.masks[e] |= @as(ComponentMask, 1) << @as(u3, @intCast(@intFromEnum(Component.spin)));
    }

    pub fn setMeshRenderer(self: *World, e: Entity, m: MeshRenderer) void {
        self.mesh_renderers[e] = m;
        self.masks[e] |= @as(ComponentMask, 1) << @as(u3, @intCast(@intFromEnum(Component.mesh_renderer)));
    }

    pub fn setVelocity(self: *World, e: Entity, v: Velocity) void {
        self.velocities[e] = v;
        self.masks[e] |= @as(ComponentMask, 1) << @as(u3, @intCast(@intFromEnum(Component.velocity)));
    }

    pub fn setCollider(self: *World, e: Entity, c: Collider) void {
        self.colliders[e] = c;
        self.masks[e] |= @as(ComponentMask, 1) << @as(u3, @intCast(@intFromEnum(Component.collider)));
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
