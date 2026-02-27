const std = @import("std");
const objc = @import("../objc.zig");
const device = @import("device.zig");
const ecs = @import("../ecs/world.zig");

pub const compute_source: [:0]const u8 = @embedFile("compute.msl");

// ============================================================
// GPU-Compatible Structs (must match MSL layout exactly)
// All extern struct to guarantee C-compatible memory layout.
// ============================================================

pub const GPUTransform = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    scale: f32 = 1,
    rot_x: f32 = 0,
    rot_y: f32 = 0,
    rot_z: f32 = 0,
    _pad: f32 = 0,
};

pub const GPUVelocity = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    _pad: f32 = 0,
};

pub const GPUCollider = extern struct {
    half_x: f32 = 0.5,
    half_y: f32 = 0.5,
    half_z: f32 = 0.5,
    is_static: u32 = 1,
};

pub const GPUAABB = extern struct {
    min_x: f32 = 0,
    min_y: f32 = 0,
    min_z: f32 = 0,
    _pad0: f32 = 0,
    max_x: f32 = 0,
    max_y: f32 = 0,
    max_z: f32 = 0,
    _pad1: f32 = 0,
};

pub const CollisionPair = extern struct {
    a: u32 = 0,
    b: u32 = 0,
    pen_x: f32 = 0,
    pen_y: f32 = 0,
    pen_z: f32 = 0,
    _pad: f32 = 0,
};

pub const PhysicsParams = extern struct {
    dt: f32 = 0,
    gravity: f32 = -15.0,
    entity_count: u32 = 0,
    _pad: u32 = 0,
};

// ============================================================
// Compute Physics Pipeline
// ============================================================

pub const MAX_PAIRS: u32 = 4096;
const THREADS_PER_GROUP: u64 = 64;

pub const ComputePhysics = struct {
    // GPU buffers
    transform_buf: device.MetalBuffer,
    velocity_buf: device.MetalBuffer,
    collider_buf: device.MetalBuffer,
    mask_buf: device.MetalBuffer,
    aabb_buf: device.MetalBuffer,
    pairs_buf: device.MetalBuffer,
    pair_count_buf: device.MetalBuffer,
    params_buf: device.MetalBuffer,

    // Compute pipelines
    integrate_pipe: device.MetalComputePipelineState,
    aabb_pipe: device.MetalComputePipelineState,
    broad_phase_pipe: device.MetalComputePipelineState,

    // Device references
    dev: device.MetalDevice,
    queue: device.MetalCommandQueue,

    pub fn init(
        dev: device.MetalDevice,
        queue: device.MetalCommandQueue,
        max_entities: u32,
    ) !ComputePhysics {
        const n: u64 = @intCast(max_entities);

        // Allocate GPU buffers (StorageModeShared for CPU↔GPU access on Apple Silicon)
        const transform_buf = dev.createBuffer(@sizeOf(GPUTransform) * n, .StorageModeShared) orelse return error.BufferFailed;
        const velocity_buf = dev.createBuffer(@sizeOf(GPUVelocity) * n, .StorageModeShared) orelse return error.BufferFailed;
        const collider_buf = dev.createBuffer(@sizeOf(GPUCollider) * n, .StorageModeShared) orelse return error.BufferFailed;
        const mask_buf = dev.createBuffer(@sizeOf(u32) * n, .StorageModeShared) orelse return error.BufferFailed;
        const aabb_buf = dev.createBuffer(@sizeOf(GPUAABB) * n, .StorageModeShared) orelse return error.BufferFailed;
        const pairs_buf = dev.createBuffer(@sizeOf(CollisionPair) * MAX_PAIRS, .StorageModeShared) orelse return error.BufferFailed;
        const pair_count_buf = dev.createBuffer(@sizeOf(u32), .StorageModeShared) orelse return error.BufferFailed;
        const params_buf = dev.createBuffer(@sizeOf(PhysicsParams), .StorageModeShared) orelse return error.BufferFailed;

        // Compile compute shader library
        const lib = dev.createLibrary(compute_source) orelse return error.LibraryFailed;

        const integrate_fn = lib.getFunction("integrate_velocity") orelse return error.FunctionNotFound;
        const aabb_fn = lib.getFunction("compute_aabbs") orelse return error.FunctionNotFound;
        const broad_fn = lib.getFunction("broad_phase") orelse return error.FunctionNotFound;

        const integrate_pipe = dev.createComputePipelineState(integrate_fn) orelse return error.PipelineFailed;
        const aabb_pipe = dev.createComputePipelineState(aabb_fn) orelse return error.PipelineFailed;
        const broad_phase_pipe = dev.createComputePipelineState(broad_fn) orelse return error.PipelineFailed;

        return ComputePhysics{
            .transform_buf = transform_buf,
            .velocity_buf = velocity_buf,
            .collider_buf = collider_buf,
            .mask_buf = mask_buf,
            .aabb_buf = aabb_buf,
            .pairs_buf = pairs_buf,
            .pair_count_buf = pair_count_buf,
            .params_buf = params_buf,
            .integrate_pipe = integrate_pipe,
            .aabb_pipe = aabb_pipe,
            .broad_phase_pipe = broad_phase_pipe,
            .dev = dev,
            .queue = queue,
        };
    }

    // --------------------------------------------------------
    // Upload ECS world state → GPU buffers
    // --------------------------------------------------------
    pub fn uploadToGPU(self: *ComputePhysics, world: *ecs.World) void {
        const count = world.count;

        const gpu_t: [*]GPUTransform = @ptrCast(@alignCast(self.transform_buf.contents()));
        const gpu_v: [*]GPUVelocity = @ptrCast(@alignCast(self.velocity_buf.contents()));
        const gpu_c: [*]GPUCollider = @ptrCast(@alignCast(self.collider_buf.contents()));
        const gpu_m: [*]u32 = @ptrCast(@alignCast(self.mask_buf.contents()));

        for (0..count) |i| {
            const t = &world.transforms[i];
            gpu_t[i] = .{
                .x = t.x,
                .y = t.y,
                .z = t.z,
                .scale = t.scale,
                .rot_x = t.rot_x,
                .rot_y = t.rot_y,
                .rot_z = t.rot_z,
            };

            const v = &world.velocities[i];
            gpu_v[i] = .{ .x = v.x, .y = v.y, .z = v.z };

            const c = &world.colliders[i];
            gpu_c[i] = .{
                .half_x = c.half_x,
                .half_y = c.half_y,
                .half_z = c.half_z,
                .is_static = if (c.is_static) 1 else 0,
            };

            gpu_m[i] = @as(u32, world.masks[i]);
        }

        // Zero the pair counter
        const cnt: *u32 = @ptrCast(@alignCast(self.pair_count_buf.contents()));
        cnt.* = 0;
    }

    // --------------------------------------------------------
    // Dispatch all three compute passes on the GPU
    // --------------------------------------------------------
    pub fn dispatch(self: *ComputePhysics, dt: f32, entity_count: u32) void {
        // Write physics params
        const p: *PhysicsParams = @ptrCast(@alignCast(self.params_buf.contents()));
        p.* = .{ .dt = dt, .gravity = -15.0, .entity_count = entity_count };

        const cmd = self.queue.createCommandBuffer() orelse return;

        const tpg = device.MTLSize{ .width = THREADS_PER_GROUP, .height = 1, .depth = 1 };
        const groups = device.MTLSize{
            .width = (@as(u64, entity_count) + THREADS_PER_GROUP - 1) / THREADS_PER_GROUP,
            .height = 1,
            .depth = 1,
        };

        // Pass 1: Velocity integration (gravity + position update)
        if (cmd.createComputeCommandEncoder()) |enc| {
            enc.setComputePipelineState(self.integrate_pipe);
            enc.setBuffer(self.transform_buf, 0, 0);
            enc.setBuffer(self.velocity_buf, 0, 1);
            enc.setBuffer(self.collider_buf, 0, 2);
            enc.setBuffer(self.mask_buf, 0, 3);
            enc.setBuffer(self.params_buf, 0, 4);
            enc.dispatchThreadgroups(groups, tpg);
            enc.endEncoding();
        }

        // Pass 2: Build AABBs
        if (cmd.createComputeCommandEncoder()) |enc| {
            enc.setComputePipelineState(self.aabb_pipe);
            enc.setBuffer(self.transform_buf, 0, 0);
            enc.setBuffer(self.collider_buf, 0, 1);
            enc.setBuffer(self.mask_buf, 0, 2);
            enc.setBuffer(self.aabb_buf, 0, 3);
            enc.setBuffer(self.params_buf, 0, 4);
            enc.dispatchThreadgroups(groups, tpg);
            enc.endEncoding();
        }

        // Pass 3: Broad phase collision detection
        if (cmd.createComputeCommandEncoder()) |enc| {
            enc.setComputePipelineState(self.broad_phase_pipe);
            enc.setBuffer(self.aabb_buf, 0, 0);
            enc.setBuffer(self.mask_buf, 0, 1);
            enc.setBuffer(self.collider_buf, 0, 2);
            enc.setBuffer(self.pairs_buf, 0, 3);
            enc.setBuffer(self.pair_count_buf, 0, 4);
            enc.setBuffer(self.params_buf, 0, 5);
            enc.dispatchThreadgroups(groups, tpg);
            enc.endEncoding();
        }

        // Synchronous wait — CPU blocks until GPU finishes all three passes
        cmd.commit();
        cmd.waitUntilCompleted();
    }

    // --------------------------------------------------------
    // Download GPU results → ECS world
    // --------------------------------------------------------
    pub fn downloadToWorld(self: *ComputePhysics, world: *ecs.World) void {
        const count = world.count;
        const gpu_t: [*]const GPUTransform = @ptrCast(@alignCast(self.transform_buf.contents()));
        const gpu_v: [*]const GPUVelocity = @ptrCast(@alignCast(self.velocity_buf.contents()));

        for (0..count) |i| {
            world.transforms[i].x = gpu_t[i].x;
            world.transforms[i].y = gpu_t[i].y;
            world.transforms[i].z = gpu_t[i].z;

            world.velocities[i].x = gpu_v[i].x;
            world.velocities[i].y = gpu_v[i].y;
            world.velocities[i].z = gpu_v[i].z;
        }
    }

    // --------------------------------------------------------
    // Read collision pairs produced by broad phase
    // --------------------------------------------------------
    pub fn readPairs(self: *ComputePhysics) []const CollisionPair {
        const cnt: *const u32 = @ptrCast(@alignCast(self.pair_count_buf.contents()));
        const n = @min(cnt.*, MAX_PAIRS);
        const ptr: [*]const CollisionPair = @ptrCast(@alignCast(self.pairs_buf.contents()));
        return ptr[0..n];
    }
};
