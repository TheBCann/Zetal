//! GPU compute physics: Metal kernels integrate, box and broad-phase pair the World's bodies each step.

const std = @import("std");
const objc = @import("../objc.zig");
const metal = @import("metal.zig");
const physics_layout = @import("physics_layout.zig");
const ecs = @import("../ecs/world.zig");

const World = ecs.World;
const GPUTransform = physics_layout.GPUTransform;
const GPUVelocity = physics_layout.GPUVelocity;
const GPUCollider = physics_layout.GPUCollider;
const GPUAABB = physics_layout.GPUAABB;
const CollisionPair = physics_layout.CollisionPair;
const PhysicsParams = physics_layout.PhysicsParams;

const log = std.log.scoped(.zetal);

// ============================================================
// Tunables (shared with shaders/physics.msl through the generated prelude)
// ============================================================

/// Capacity of the pair buffer; overlaps beyond it are counted (droppedPairs) but not stored.
pub const MAX_PAIRS: u32 = 4096;
/// Buckets in the spatial hash grid (a prime, to spread the hashed cells evenly).
pub const GRID_SIZE: u32 = 4099;
/// Edge of a grid cell. INVARIANT: every collider half-extent is <= CELL_SIZE / 2, otherwise the
/// broad phase's 3x3x3 cell neighbourhood can miss overlapping pairs (upload asserts it).
pub const CELL_SIZE: f32 = 2.0;
/// Gravity on dynamic colliders, in units/s² along y.
pub const GRAVITY: f32 = -15.0;
/// Threads per compute threadgroup.
pub const THREADS_PER_GROUP: u64 = 64;

// Bodies that get an AABB, a grid entry and pairs (the kernels' COLLIDER_MASK).
const collider_mask = ecs.mask(&.{ .transform, .collider });

// Every physics buffer has one slot that all five kernels share (each declares only the slots it
// reads), so a step binds each buffer once and only switches kernels between dispatches.
const Slot = enum(u64) {
    transforms,
    velocities,
    colliders,
    masks,
    aabbs,
    pairs,
    pair_count,
    cell_heads,
    next_nodes,
    params,
};

// ============================================================
// Shader source
// ============================================================

/// The physics MSL: a generated #define prelude, then shaders/physics.msl. The prelude carries every
/// constant, mask bit, buffer slot and struct size the kernels share with this file, so they can't drift.
pub const shader_source: [:0]const u8 = prelude ++ @embedFile("shaders/physics.msl");

// `#line` makes the Metal compiler's diagnostics point at lines of physics.msl itself.
const prelude = std.fmt.comptimePrint(
    \\#define MAX_PAIRS {[max_pairs]d}u
    \\#define GRID_SIZE {[grid_size]d}u
    \\#define CELL_SIZE {[cell_size]s}
    \\#define MASK_TRANSFORM 0x{[mask_transform]x}u
    \\#define MASK_VELOCITY 0x{[mask_velocity]x}u
    \\#define MASK_COLLIDER 0x{[mask_collider]x}u
    \\#define BUFFER_TRANSFORMS {[transforms]d}
    \\#define BUFFER_VELOCITIES {[velocities]d}
    \\#define BUFFER_COLLIDERS {[colliders]d}
    \\#define BUFFER_MASKS {[masks]d}
    \\#define BUFFER_AABBS {[aabbs]d}
    \\#define BUFFER_PAIRS {[pairs]d}
    \\#define BUFFER_PAIR_COUNT {[pair_count]d}
    \\#define BUFFER_CELL_HEADS {[cell_heads]d}
    \\#define BUFFER_NEXT_NODES {[next_nodes]d}
    \\#define BUFFER_PARAMS {[params]d}
    \\#define SIZEOF_GPU_TRANSFORM {[sizeof_transform]d}
    \\#define SIZEOF_GPU_VELOCITY {[sizeof_velocity]d}
    \\#define SIZEOF_GPU_COLLIDER {[sizeof_collider]d}
    \\#define SIZEOF_GPU_AABB {[sizeof_aabb]d}
    \\#define SIZEOF_COLLISION_PAIR {[sizeof_pair]d}
    \\#define SIZEOF_PHYSICS_PARAMS {[sizeof_params]d}
    \\#line 1 "physics.msl"
    \\
, .{
    .max_pairs = MAX_PAIRS,
    .grid_size = GRID_SIZE,
    .cell_size = mslFloat(CELL_SIZE),
    .mask_transform = ecs.bit(.transform),
    .mask_velocity = ecs.bit(.velocity),
    .mask_collider = ecs.bit(.collider),
    .transforms = @backingInt(Slot.transforms),
    .velocities = @backingInt(Slot.velocities),
    .colliders = @backingInt(Slot.colliders),
    .masks = @backingInt(Slot.masks),
    .aabbs = @backingInt(Slot.aabbs),
    .pairs = @backingInt(Slot.pairs),
    .pair_count = @backingInt(Slot.pair_count),
    .cell_heads = @backingInt(Slot.cell_heads),
    .next_nodes = @backingInt(Slot.next_nodes),
    .params = @backingInt(Slot.params),
    .sizeof_transform = @sizeOf(GPUTransform),
    .sizeof_velocity = @sizeOf(GPUVelocity),
    .sizeof_collider = @sizeOf(GPUCollider),
    .sizeof_aabb = @sizeOf(GPUAABB),
    .sizeof_pair = @sizeOf(CollisionPair),
    .sizeof_params = @sizeOf(PhysicsParams),
});

/// Returns `value` as an MSL float literal: its shortest round-trip digits, a ".0" when they have no
/// point (`{d}` prints 2.0 as "2", which MSL would read as an int), and the `f` suffix.
fn mslFloat(comptime value: f32) []const u8 {
    return comptime blk: {
        const digits = std.fmt.comptimePrint("{d}", .{value});
        break :blk if (std.mem.findScalar(u8, digits, '.') == null) digits ++ ".0f" else digits ++ "f";
    };
}

// ============================================================
// Compute physics
// ============================================================

// Instance-buffer INVARIANT: the renderer's instance buffers are single-buffered (StorageModeShared).
// That is safe because main passes the SAME CommandQueue to Renderer and ComputePhysics, step ALWAYS
// commits and waits (even with 0 entities), on a frame that runs no physics substep main commits and
// waits on an empty fence command buffer on that queue instead, buildInstances runs after the frame's
// last step, and there is at most one drawFrame per loop iteration. Metal reports a queue's completions
// in commit order, so once step's (or the fence's) wait returns, the previous frame's render command
// buffer is done with those buffers too. See renderer.zig for the full list.

/// GPU rigid-body physics for one World: shared-storage mirrors of its bodies, the hash grid, the pair
/// list and the five kernels. A physics tick is upload, step, download, then resolving pairs() on the CPU.
pub const ComputePhysics = struct {
    /// Borrowed; must also be the renderer's queue (see the invariant above).
    queue: metal.CommandQueue,
    /// Entity slots every per-entity buffer holds.
    capacity: u32,
    /// Slots the last upload filled in; step processes and download copies back no more than these.
    uploaded: u32 = 0,

    // Shared storage (zero-copy on Apple silicon); one entry per entity slot unless noted.
    transform_buf: metal.Buffer,
    velocity_buf: metal.Buffer,
    collider_buf: metal.Buffer,
    mask_buf: metal.Buffer, // ECS ComponentMask widened to u32
    aabb_buf: metal.Buffer,
    pairs_buf: metal.Buffer, // MAX_PAIRS entries
    pair_count_buf: metal.Buffer, // one u32: pairs found, dropped ones included
    params_buf: metal.Buffer, // one PhysicsParams
    cell_heads_buf: metal.Buffer, // GRID_SIZE bucket list heads
    next_nodes_buf: metal.Buffer, // per-slot bucket list links

    integrate_pipe: metal.ComputePipelineState,
    aabb_pipe: metal.ComputePipelineState,
    clear_grid_pipe: metal.ComputePipelineState,
    build_grid_pipe: metal.ComputePipelineState,
    broad_phase_pipe: metal.ComputePipelineState,

    /// Allocates the buffers for `capacity` (> 0) entity slots and compiles the kernels. `queue` is
    /// borrowed and must outlive the physics.
    pub fn init(device: metal.Device, queue: metal.CommandQueue, capacity: u32) !ComputePhysics {
        const slots: usize = capacity;
        const transform_buf = try device.newBuffer(slots * @sizeOf(GPUTransform), .shared);
        errdefer transform_buf.release();
        const velocity_buf = try device.newBuffer(slots * @sizeOf(GPUVelocity), .shared);
        errdefer velocity_buf.release();
        const collider_buf = try device.newBuffer(slots * @sizeOf(GPUCollider), .shared);
        errdefer collider_buf.release();
        const mask_buf = try device.newBuffer(slots * @sizeOf(u32), .shared);
        errdefer mask_buf.release();
        const aabb_buf = try device.newBuffer(slots * @sizeOf(GPUAABB), .shared);
        errdefer aabb_buf.release();
        const pairs_buf = try device.newBuffer(MAX_PAIRS * @sizeOf(CollisionPair), .shared);
        errdefer pairs_buf.release();
        const pair_count_buf = try device.newBuffer(@sizeOf(u32), .shared);
        errdefer pair_count_buf.release();
        const params_buf = try device.newBuffer(@sizeOf(PhysicsParams), .shared);
        errdefer params_buf.release();
        const cell_heads_buf = try device.newBuffer(GRID_SIZE * @sizeOf(u32), .shared);
        errdefer cell_heads_buf.release();
        const next_nodes_buf = try device.newBuffer(slots * @sizeOf(u32), .shared);
        errdefer next_nodes_buf.release();

        // The pipeline states keep what they need of the library and its functions.
        const library = try device.newLibrary(shader_source);
        defer library.release();
        const integrate_pipe = try newKernel(device, library, "integrate_velocity");
        errdefer integrate_pipe.release();
        const aabb_pipe = try newKernel(device, library, "compute_aabbs");
        errdefer aabb_pipe.release();
        const clear_grid_pipe = try newKernel(device, library, "clear_grid");
        errdefer clear_grid_pipe.release();
        const build_grid_pipe = try newKernel(device, library, "build_grid");
        errdefer build_grid_pipe.release();
        const broad_phase_pipe = try newKernel(device, library, "broad_phase");

        return .{
            .queue = queue,
            .capacity = capacity,
            .transform_buf = transform_buf,
            .velocity_buf = velocity_buf,
            .collider_buf = collider_buf,
            .mask_buf = mask_buf,
            .aabb_buf = aabb_buf,
            .pairs_buf = pairs_buf,
            .pair_count_buf = pair_count_buf,
            .params_buf = params_buf,
            .cell_heads_buf = cell_heads_buf,
            .next_nodes_buf = next_nodes_buf,
            .integrate_pipe = integrate_pipe,
            .aabb_pipe = aabb_pipe,
            .clear_grid_pipe = clear_grid_pipe,
            .build_grid_pipe = build_grid_pipe,
            .broad_phase_pipe = broad_phase_pipe,
        };
    }

    /// Releases the pipelines and buffers (not the borrowed queue).
    pub fn deinit(self: *ComputePhysics) void {
        self.broad_phase_pipe.release();
        self.build_grid_pipe.release();
        self.clear_grid_pipe.release();
        self.aabb_pipe.release();
        self.integrate_pipe.release();
        self.next_nodes_buf.release();
        self.cell_heads_buf.release();
        self.params_buf.release();
        self.pair_count_buf.release();
        self.pairs_buf.release();
        self.aabb_buf.release();
        self.mask_buf.release();
        self.collider_buf.release();
        self.velocity_buf.release();
        self.transform_buf.release();
        self.* = undefined;
    }

    /// Copies slots [0, world.count) of the World (transforms, velocities, colliders, masks) into the
    /// GPU buffers and discards the previous step's pairs, which index the old state.
    pub fn upload(self: *ComputePhysics, world: *const World) void {
        // Asserted, not clamped: main sizes the physics with ecs.MAX_ENTITIES, the World's own slot
        // count, so this holds by construction (fast and small builds do not check it). Everything
        // downstream (step, download) trusts `uploaded`.
        std.debug.assert(world.count <= self.capacity);
        const n = world.count;

        for (self.transform_buf.slice(GPUTransform, n), world.transforms[0..n]) |*gpu, t| {
            gpu.* = .{ .x = t.x, .y = t.y, .z = t.z, .scale = t.scale, .rot_x = t.rot_x, .rot_y = t.rot_y, .rot_z = t.rot_z };
        }
        for (self.velocity_buf.slice(GPUVelocity, n), world.velocities[0..n]) |*gpu, v| {
            gpu.* = .{ .x = v.x, .y = v.y, .z = v.z };
        }
        for (self.collider_buf.slice(GPUCollider, n), world.colliders[0..n], world.masks[0..n]) |*gpu, c, m| {
            // See CELL_SIZE: a bigger box can be missed by the broad phase.
            if (ecs.hasMask(m, collider_mask)) std.debug.assert(@max(c.half_x, c.half_y, c.half_z) <= CELL_SIZE / 2);
            gpu.* = .{ .half_x = c.half_x, .half_y = c.half_y, .half_z = c.half_z, .is_static = @intFromBool(c.is_static) };
        }
        for (self.mask_buf.slice(u32, n), world.masks[0..n]) |*gpu, m| gpu.* = m;

        self.pairCount().* = 0;
        self.uploaded = n;
    }

    /// Runs one physics step of `dt` seconds over slots [0, entity_count) — integrate, AABBs, clear
    /// grid, build grid, broad phase — in one serial compute pass on the borrowed queue. ALWAYS commits
    /// and waits, even with no entities (the instance-buffer invariant above relies on that wait).
    pub fn step(self: *ComputePhysics, dt: f32, entity_count: u32) !void {
        // The kernels index the buffers by slot unchecked, so never past what upload filled in.
        // Asserted, not clamped: main passes the count it has just uploaded (fast and small builds do
        // not check it).
        std.debug.assert(entity_count <= self.uploaded);
        self.params_buf.slice(PhysicsParams, 1)[0] = .{ .dt = dt, .gravity = GRAVITY, .entity_count = entity_count };
        self.pairCount().* = 0;

        const cmd = try self.queue.commandBuffer();
        // Nothing is dispatched for an empty world: Metal validation aborts on 0 threadgroups.
        const encoded: error{MetalCreateFailed}!void = if (entity_count > 0) self.encode(cmd, entity_count) else {};
        // Committed and awaited on every path, a failed encoder included, to keep the invariant.
        cmd.commit();
        cmd.waitUntilCompleted();
        try encoded;
        if (objc.msgSend(?objc.Object, cmd.handle, "error", .{})) |err| {
            const text = objc.msgSend(?objc.Object, err, "localizedDescription", .{});
            log.err("physics step failed on the GPU: {s}", .{if (text) |t| objc.fromNSString(t) else "(no description)"});
            return error.CommandBufferFailed;
        }
    }

    /// Copies positions and velocities back into the World for the slots the last upload filled in.
    pub fn download(self: *ComputePhysics, world: *World) void {
        const n = @min(world.count, self.uploaded);
        for (world.transforms[0..n], self.transform_buf.slice(GPUTransform, n)) |*t, gpu| {
            t.x = gpu.x;
            t.y = gpu.y;
            t.z = gpu.z;
        }
        for (world.velocities[0..n], self.velocity_buf.slice(GPUVelocity, n)) |*v, gpu| {
            v.* = .{ .x = gpu.x, .y = gpu.y, .z = gpu.z };
        }
    }

    /// Returns the last step's overlapping pairs (a < b, every penetration > 0) in no particular
    /// order, at most MAX_PAIRS of them. The slice aliases GPU memory: valid until the next upload or step.
    pub fn pairs(self: *const ComputePhysics) []const CollisionPair {
        return self.pairs_buf.slice(CollisionPair, @min(self.pairCount().*, MAX_PAIRS));
    }

    /// Returns how many of the last step's pairs did not fit in the MAX_PAIRS buffer.
    pub fn droppedPairs(self: *const ComputePhysics) u32 {
        return self.pairCount().* -| MAX_PAIRS;
    }

    /// Returns the pair counter the broad phase bumps (it keeps counting past MAX_PAIRS).
    fn pairCount(self: *const ComputePhysics) *u32 {
        return &self.pair_count_buf.slice(u32, 1)[0];
    }

    /// Encodes the five kernels over `count` (> 0) slots into one compute encoder on `cmd`.
    fn encode(self: *const ComputePhysics, cmd: metal.CommandBuffer, count: u32) error{MetalCreateFailed}!void {
        const encoder = try cmd.computeCommandEncoder();
        // Bindings survive kernel switches within an encoder, so each buffer is bound once; the
        // encoder dispatches serially, so every kernel sees what the previous one wrote.
        bind(encoder, self.transform_buf, .transforms);
        bind(encoder, self.velocity_buf, .velocities);
        bind(encoder, self.collider_buf, .colliders);
        bind(encoder, self.mask_buf, .masks);
        bind(encoder, self.aabb_buf, .aabbs);
        bind(encoder, self.pairs_buf, .pairs);
        bind(encoder, self.pair_count_buf, .pair_count);
        bind(encoder, self.cell_heads_buf, .cell_heads);
        bind(encoder, self.next_nodes_buf, .next_nodes);
        bind(encoder, self.params_buf, .params);

        dispatch(encoder, self.integrate_pipe, count);
        dispatch(encoder, self.aabb_pipe, count);
        dispatch(encoder, self.clear_grid_pipe, GRID_SIZE);
        dispatch(encoder, self.build_grid_pipe, count);
        dispatch(encoder, self.broad_phase_pipe, count);
        encoder.endEncoding();
    }
};

/// Returns the compute pipeline state (+1) for the kernel `name` in `library`.
fn newKernel(device: metal.Device, library: metal.Library, name: [:0]const u8) !metal.ComputePipelineState {
    const function = try library.newFunction(name);
    defer function.release();
    return device.newComputePipelineState(function);
}

/// Binds `buffer` (from offset 0) at its kernel buffer slot.
fn bind(encoder: metal.ComputeCommandEncoder, buffer: metal.Buffer, slot: Slot) void {
    encoder.setBuffer(buffer, 0, @backingInt(slot));
}

/// Runs `pipeline` over at least `threads` threads, rounded up to whole threadgroups; the kernels
/// bounds-check their thread id.
fn dispatch(encoder: metal.ComputeCommandEncoder, pipeline: metal.ComputePipelineState, threads: u32) void {
    encoder.setComputePipelineState(pipeline);
    const groups = (@as(u64, threads) + THREADS_PER_GROUP - 1) / THREADS_PER_GROUP;
    encoder.dispatchThreadgroups(
        .{ .width = groups, .height = 1, .depth = 1 },
        .{ .width = THREADS_PER_GROUP, .height = 1, .depth = 1 },
    );
}

// ============================================================
// Tests (GPU ones need a Metal device and skip without one; no window server)
// ============================================================

const testing = std.testing;
const AutoreleasePool = @import("../platform/autorelease.zig").AutoreleasePool;

/// A ComputePhysics on the system GPU, inside its own autorelease pool.
const TestRig = struct {
    pool: AutoreleasePool,
    device: metal.Device,
    queue: metal.CommandQueue,
    physics: ComputePhysics,

    /// Builds physics for `capacity` slots, or skips the test on a machine without Metal.
    fn init(capacity: u32) !TestRig {
        const pool = AutoreleasePool.init();
        errdefer pool.deinit();
        const device = metal.Device.createSystemDefault() orelse return error.SkipZigTest;
        errdefer device.release();
        const queue = try device.newCommandQueue();
        errdefer queue.release();
        const physics = try ComputePhysics.init(device, queue, capacity);
        return .{ .pool = pool, .device = device, .queue = queue, .physics = physics };
    }

    fn deinit(self: *TestRig) void {
        self.physics.deinit();
        self.queue.release();
        self.device.release();
        self.pool.deinit();
    }

    /// One physics tick over every slot, as main runs it: upload, step, download.
    fn tick(self: *TestRig, world: *World, dt: f32) !void {
        self.physics.upload(world);
        try self.physics.step(dt, world.count);
        self.physics.download(world);
    }
};

/// Spawns a dynamic unit cube like scene.spawnDynamicCube: transform, velocity, dynamic collider.
fn spawnDynamic(world: *World, x: f32, y: f32, z: f32) !ecs.Entity {
    const e = try world.spawn();
    world.setTransform(e, .{ .x = x, .y = y, .z = z });
    world.setVelocity(e, .{});
    world.setCollider(e, .{ .is_static = false });
    return e;
}

/// Spawns a static unit cube like scene.spawnStaticCube: transform and static collider, no velocity.
fn spawnStatic(world: *World, x: f32, y: f32, z: f32) !ecs.Entity {
    const e = try world.spawn();
    world.setTransform(e, .{ .x = x, .y = y, .z = z });
    world.setCollider(e, .{ .is_static = true });
    return e;
}

/// Returns a random multiple of 1/8 in [lo / 8, hi / 8] (exact in f32).
fn eighths(random: std.Random, lo: i32, hi: i32) f32 {
    return @as(f32, @floatFromInt(random.intRangeAtMost(i32, lo, hi))) / 8;
}

/// Returns every pair the broad phase must report, found by brute force with the ECS's CPU AABB
/// code, in (a, b) order.
fn bruteForcePairs(gpa: std.mem.Allocator, world: *const World) !std.ArrayList(CollisionPair) {
    var found: std.ArrayList(CollisionPair) = .empty;
    errdefer found.deinit(gpa);
    for (0..world.count) |i| {
        if (!ecs.hasMask(world.masks[i], collider_mask)) continue;
        const box_a = ecs.AABB.fromTransformCollider(&world.transforms[i], &world.colliders[i]);
        for (i + 1..world.count) |j| {
            if (!ecs.hasMask(world.masks[j], collider_mask)) continue;
            if (world.colliders[i].is_static and world.colliders[j].is_static) continue;
            const box_b = ecs.AABB.fromTransformCollider(&world.transforms[j], &world.colliders[j]);
            const pen = box_a.penetration(box_b);
            if (pen.x <= 0 or pen.y <= 0 or pen.z <= 0) continue;
            try found.append(gpa, .{ .a = @intCast(i), .b = @intCast(j), .pen_x = pen.x, .pen_y = pen.y, .pen_z = pen.z });
        }
    }
    return found;
}

fn pairLessThan(_: void, lhs: CollisionPair, rhs: CollisionPair) bool {
    return if (lhs.a != rhs.a) lhs.a < rhs.a else lhs.b < rhs.b;
}

test "mslFloat writes MSL float literals that round-trip" {
    try testing.expectEqualStrings("2.0f", mslFloat(2.0));
    try testing.expectEqualStrings("-15.0f", mslFloat(-15.0));
    try testing.expectEqualStrings("2.25f", mslFloat(2.25));
    inline for (.{ 0.1, 1.0 / 3.0, 1e-7, 3e9 }) |value| {
        const literal = mslFloat(value);
        try testing.expect(std.mem.endsWith(u8, literal, "f"));
        try testing.expect(std.mem.findScalar(u8, literal, '.') != null);
        try testing.expectEqual(@as(f32, value), try std.fmt.parseFloat(f32, literal[0 .. literal.len - 1]));
    }
}

test "shader_source is the generated prelude followed by physics.msl" {
    try testing.expect(std.mem.startsWith(u8, shader_source, "#define MAX_PAIRS 4096u\n#define GRID_SIZE 4099u\n"));
    const expected_lines = [_][]const u8{
        "\n#define CELL_SIZE 2.0f\n",
        "\n#define MASK_TRANSFORM 0x1u\n#define MASK_VELOCITY 0x8u\n#define MASK_COLLIDER 0x10u\n",
        "\n#define BUFFER_TRANSFORMS 0\n",
        "\n#define BUFFER_PARAMS 9\n",
        "\n#define SIZEOF_GPU_TRANSFORM 32\n",
        "\n#define SIZEOF_COLLISION_PAIR 24\n",
        "\n#line 1 \"physics.msl\"\n",
    };
    for (expected_lines) |line| {
        if (std.mem.find(u8, shader_source, line) == null) {
            std.debug.print("shader prelude lacks {s}\n", .{line});
            return error.TestUnexpectedResult;
        }
    }
    try testing.expect(std.mem.endsWith(u8, shader_source, @embedFile("shaders/physics.msl")));
}

test "a resting dynamic cube falls for one step of gravity" {
    var rig = try TestRig.init(16);
    defer rig.deinit();
    var world = World.init();
    const cube = try spawnDynamic(&world, 0, 0, 0);

    try rig.tick(&world, 0.1);

    // Semi-implicit Euler: v.y = -15 * 0.1 first, then y moves by the new v.y * 0.1.
    try testing.expectApproxEqAbs(@as(f32, -1.5), world.velocities[cube].y, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.15), world.transforms[cube].y, 1e-6);
    try testing.expectEqual(@as(f32, 0), world.velocities[cube].x);
    try testing.expectEqual(@as(f32, 0), world.velocities[cube].z);
    try testing.expectEqual(@as(f32, 0), world.transforms[cube].x);
    try testing.expectEqual(@as(f32, 0), world.transforms[cube].z);
    try testing.expectEqual(0, rig.physics.pairs().len);
}

test "gravity pulls only dynamic colliders; other moving bodies just drift" {
    var rig = try TestRig.init(16);
    defer rig.deinit();
    var world = World.init();
    // Flies and falls, like a projectile.
    const flying = try spawnDynamic(&world, 0, 0, 0);
    world.setVelocity(flying, .{ .x = 4, .z = -2 });
    // A velocity but no collider: drifts.
    const drifter = try world.spawn();
    world.setTransform(drifter, .{ .x = 10 });
    world.setVelocity(drifter, .{ .y = 1 });
    // A static collider with a velocity: drifts, static bodies don't fall.
    const sliding = try spawnStatic(&world, 20, 0, 0);
    world.setVelocity(sliding, .{ .z = 3 });
    // No velocity component: never integrated, whatever the array holds.
    const fixed = try spawnStatic(&world, 30, 0, 0);
    world.velocities[fixed] = .{ .y = 5 };

    try rig.tick(&world, 0.5); // dyadic values: every result below is exact

    try testing.expectEqual(ecs.Velocity{ .x = 4, .y = -7.5, .z = -2 }, world.velocities[flying]);
    try testing.expectEqual(ecs.Transform{ .x = 2, .y = -3.75, .z = -1 }, world.transforms[flying]);
    try testing.expectEqual(ecs.Velocity{ .y = 1 }, world.velocities[drifter]);
    try testing.expectEqual(ecs.Transform{ .x = 10, .y = 0.5 }, world.transforms[drifter]);
    try testing.expectEqual(ecs.Velocity{ .z = 3 }, world.velocities[sliding]);
    try testing.expectEqual(ecs.Transform{ .x = 20, .z = 1.5 }, world.transforms[sliding]);
    try testing.expectEqual(ecs.Velocity{ .y = 5 }, world.velocities[fixed]);
    try testing.expectEqual(ecs.Transform{ .x = 30 }, world.transforms[fixed]);
}

test "two overlapping dynamic cubes make exactly one pair with their penetration" {
    var rig = try TestRig.init(16);
    defer rig.deinit();
    var world = World.init();
    const a = try spawnDynamic(&world, 0, 0, 0);
    const b = try spawnDynamic(&world, 0.75, 0.5, -0.25);

    try rig.tick(&world, 0); // dt 0: nothing moves, the boxes stay exactly as placed

    const found = rig.physics.pairs();
    try testing.expectEqual(1, found.len);
    try testing.expectEqual(CollisionPair{ .a = a, .b = b, .pen_x = 0.25, .pen_y = 0.5, .pen_z = 0.75 }, found[0]);
    try testing.expectEqual(0, rig.physics.droppedPairs());

    // A fresh upload discards the old pairs; moved apart, the next step finds none.
    world.transforms[b].x = 5;
    rig.physics.upload(&world);
    try testing.expectEqual(0, rig.physics.pairs().len);
    try rig.physics.step(0, world.count);
    try testing.expectEqual(0, rig.physics.pairs().len);
}

test "overlapping static cubes make no pair, a dynamic cube against one does, touching is not overlap" {
    var rig = try TestRig.init(16);
    defer rig.deinit();
    var world = World.init();
    const left = try spawnStatic(&world, 0, 0, 0);
    _ = try spawnStatic(&world, 0.5, 0, 0);

    try rig.tick(&world, 0);
    try testing.expectEqual(0, rig.physics.pairs().len);

    // Overlaps the left cube by 0.5 and only touches the right one (x = 0 faces).
    const ball = try spawnDynamic(&world, -0.5, 0, 0);
    try rig.tick(&world, 0);
    const found = rig.physics.pairs();
    try testing.expectEqual(1, found.len);
    try testing.expectEqual(CollisionPair{ .a = left, .b = ball, .pen_x = 0.5, .pen_y = 1, .pen_z = 1 }, found[0]);
}

test "a despawned slot (mask 0) is neither integrated nor paired" {
    var rig = try TestRig.init(16);
    defer rig.deinit();
    var world = World.init();
    const ghost = try spawnDynamic(&world, 0, 0, 0);
    world.velocities[ghost] = .{ .x = 3 };
    const solid = try spawnDynamic(&world, 0.5, 0, 0);
    world.despawn(ghost);

    try rig.tick(&world, 0.1);

    try testing.expectEqual(0, rig.physics.pairs().len);
    try testing.expectEqual(ecs.Transform{}, world.transforms[ghost]);
    try testing.expectEqual(ecs.Velocity{ .x = 3 }, world.velocities[ghost]);
    try testing.expectApproxEqAbs(@as(f32, -1.5), world.velocities[solid].y, 1e-6); // the live one falls
}

test "an empty world steps without dispatching and reports nothing" {
    var rig = try TestRig.init(16);
    defer rig.deinit();
    // Before any upload, then a world with no slots at all.
    try rig.physics.step(0.1, 0);
    var world = World.init();
    try rig.tick(&world, 0.1);
    try testing.expectEqual(0, rig.physics.pairs().len);
    try testing.expectEqual(0, rig.physics.droppedPairs());

    // Slots below the high-water mark that are all dead.
    const e = try spawnDynamic(&world, 0, 0, 0);
    _ = try spawnDynamic(&world, 0.1, 0, 0);
    world.despawn(e);
    world.despawn(e + 1);
    try rig.tick(&world, 0.1);
    try testing.expectEqual(0, rig.physics.pairs().len);
}

const COMMAND_BUFFER_STATUS_COMPLETED: u64 = 4; // MTLCommandBufferStatusCompleted
/// NSRange, as -fillBuffer:range:value: takes it.
const NSRange = extern struct { location: u64, length: u64 };

test "step with 0 entities still commits and waits, and returns only after the queue's earlier work" {
    // Pins clauses 2 and 4 of the instance-buffer invariant (renderer.zig): step commits and waits
    // even for an empty world, and the shared queue completes its command buffers in commit order.
    // An empty step's command buffer is also exactly main's zero-substep fence. If this fails on
    // other hardware, clause 4 no longer holds: wait on the last render command buffer first, or
    // double-buffer the instances.
    var rig = try TestRig.init(16);
    defer rig.deinit();
    var world = World.init();
    rig.physics.upload(&world);

    // Real GPU work standing in for the previous frame's render: committed, never waited on.
    const fill_len: u64 = 64 << 20;
    const scratch = try rig.device.newBuffer(fill_len, .private);
    defer scratch.release();
    var checked: u32 = 0;
    for (0..3) |_| {
        const earlier = try rig.queue.commandBuffer();
        const blit = objc.msgSend(?objc.Object, earlier.handle, "blitCommandEncoder", .{}) orelse
            return error.TestUnexpectedResult;
        objc.msgSend(void, blit, "fillBuffer:range:value:", .{
            scratch.handle, NSRange{ .location = 0, .length = fill_len }, @as(u8, 0xAB),
        });
        objc.msgSend(void, blit, "endEncoding", .{});
        earlier.commit();
        // Already finished before step even ran: this round would prove nothing.
        if (objc.msgSend(u64, earlier.handle, "status", .{}) == COMMAND_BUFFER_STATUS_COMPLETED) continue;

        try rig.physics.step(0.001, 0);
        try testing.expectEqual(COMMAND_BUFFER_STATUS_COMPLETED, objc.msgSend(u64, earlier.handle, "status", .{}));
        checked += 1;
    }
    if (checked == 0) return error.SkipZigTest; // the GPU outran every round
}

test "regression: a pair reachable through hash-colliding neighbour cells is emitted once" {
    // A sits in cell (0,0,0) and B in (-1,-1,-1). Negating two odd coordinates keeps the hash, so B's
    // bucket is also the bucket of A's neighbours (1,1,-1), (1,-1,1) and (-1,1,1): the original
    // kernel walked it four times and emitted this pair 4x.
    var rig = try TestRig.init(16);
    defer rig.deinit();
    var world = World.init();
    const a = try spawnDynamic(&world, 0.2, 0.2, 0.2);
    const b = try spawnDynamic(&world, -0.2, -0.2, -0.2);

    try rig.tick(&world, 0);

    const found = rig.physics.pairs();
    try testing.expectEqual(1, found.len);
    try testing.expectEqual(a, found[0].a);
    try testing.expectEqual(b, found[0].b);
    try testing.expectApproxEqAbs(@as(f32, 0.6), found[0].pen_x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.6), found[0].pen_y, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.6), found[0].pen_z, 1e-6);
}

test "pairs past MAX_PAIRS are counted as dropped, not stored" {
    var rig = try TestRig.init(128);
    defer rig.deinit();
    var world = World.init();
    // 100 cubes in one spot all overlap: 100 * 99 / 2 = 4950 pairs, 854 more than fit.
    const cubes = 100;
    for (0..cubes) |_| _ = try spawnDynamic(&world, 0, 0, 0);

    try rig.tick(&world, 0);

    const found = rig.physics.pairs();
    try testing.expectEqual(MAX_PAIRS, found.len);
    try testing.expectEqual(cubes * (cubes - 1) / 2 - MAX_PAIRS, rig.physics.droppedPairs());
    var seen: [cubes][cubes]bool = @splat(@splat(false));
    for (found) |p| {
        try testing.expect(p.a < p.b and p.b < cubes);
        try testing.expect(!seen[p.a][p.b]); // stored once each
        seen[p.a][p.b] = true;
        try testing.expectEqual(CollisionPair{ .a = p.a, .b = p.b, .pen_x = 1, .pen_y = 1, .pen_z = 1 }, p);
    }
}

test "the broad phase reports exactly the pairs a brute-force search finds" {
    const gpa = testing.allocator;
    var rig = try TestRig.init(512);
    defer rig.deinit();
    var world = World.init();

    // Centres and half-extents on a 1/8 grid keep every bound and penetration exact in f32, so the
    // GPU and the CPU reference agree bit for bit, and many boxes sit right on cell borders or just
    // touch. Centres span cells -3..3 around the origin, where hash-colliding neighbours live, and
    // half-extents go up to the CELL_SIZE / 2 limit.
    var prng: std.Random.DefaultPrng = .init(0x2e7a1);
    const random = prng.random();
    for (0..400) |_| {
        const e = try world.spawn();
        world.setTransform(e, .{ .x = eighths(random, -48, 48), .y = eighths(random, -48, 48), .z = eighths(random, -48, 48) });
        const kind = random.uintLessThan(u32, 8);
        if (kind == 0) {
            world.setVelocity(e, .{}); // moves, never collides
            continue;
        }
        world.setCollider(e, .{
            .half_x = eighths(random, 1, 8),
            .half_y = eighths(random, 1, 8),
            .half_z = eighths(random, 1, 8),
            .is_static = kind <= 2,
        });
        if (kind > 2) world.setVelocity(e, .{});
    }
    var dead: ecs.Entity = 0;
    while (dead < world.count) : (dead += 9) world.despawn(dead);

    // dt 0 checks the exact placements; 0.05 then lets the dynamic boxes fall off the 1/8 grid.
    for ([_]f32{ 0, 0.05 }) |dt| {
        try rig.tick(&world, dt);
        // From the downloaded positions: exactly the floats the GPU boxed.
        var expected = try bruteForcePairs(gpa, &world);
        defer expected.deinit(gpa);
        const actual = try gpa.dupe(CollisionPair, rig.physics.pairs());
        defer gpa.free(actual);
        std.mem.sort(CollisionPair, actual, {}, pairLessThan);

        try testing.expect(expected.items.len > 100); // a meaningful sample, well under MAX_PAIRS
        try testing.expectEqual(0, rig.physics.droppedPairs());
        try testing.expectEqualSlices(CollisionPair, expected.items, actual);
    }
}
