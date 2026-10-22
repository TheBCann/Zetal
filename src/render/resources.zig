//! GPU copies of what the renderer draws: static meshes, sky and crosshair vertices, albedo textures, instance buffers.

const std = @import("std");
const objc = @import("../objc.zig");
const math = @import("../math.zig");
const metal = @import("metal.zig");
const geometry = @import("geometry.zig");
const obj = @import("../assets/obj.zig");
const ppm = @import("../assets/ppm.zig");

const Device = metal.Device;
const Buffer = metal.Buffer;
const Texture = metal.Texture;
const Vertex = geometry.Vertex;

// The 2D texture size limit of Apple-silicon GPUs; larger descriptors abort under Metal validation.
const MAX_TEXTURE_SIDE: u64 = 16384;

// ============================================================
// Meshes
// ============================================================

/// An indexed triangle mesh in shared GPU buffers (+1 each; `release` frees both).
pub const GpuMesh = struct {
    /// geometry.Vertex array, bound at binding.VERTICES.
    vertices: Buffer,
    /// u32 triangle-list indices into `vertices`.
    indices: Buffer,
    index_count: u32,

    /// Uploads copies of `vertices` and `indices` (a u32 triangle list). error.InvalidMesh when either
    /// is empty or an index points past the vertices: the GPU would read out of bounds.
    pub fn upload(device: Device, vertices: []const Vertex, indices: []const u32) !GpuMesh {
        if (vertices.len == 0 or indices.len == 0) return error.InvalidMesh;
        for (indices) |index| {
            if (index >= vertices.len) return error.InvalidMesh;
        }
        const index_count = std.math.cast(u32, indices.len) orelse return error.InvalidMesh;

        const vertex_buffer = try device.newBufferWithBytes(std.mem.sliceAsBytes(vertices), .shared);
        errdefer vertex_buffer.release();
        const index_buffer = try device.newBufferWithBytes(std.mem.sliceAsBytes(indices), .shared);
        return .{ .vertices = vertex_buffer, .indices = index_buffer, .index_count = index_count };
    }

    /// Releases both buffers.
    pub fn release(self: GpuMesh) void {
        self.vertices.release();
        self.indices.release();
    }
};

// ============================================================
// Static resources (uploaded once at startup)
// ============================================================

/// Geometry and textures that never change after startup (+1 each; `deinit` releases them).
pub const StaticResources = struct {
    cube: GpuMesh,
    gun: GpuMesh,
    /// geometry.ground_vertices / ground_indices.
    ground: GpuMesh,
    /// geometry.skybox_vertices as float4 positions.
    skybox: Buffer,
    skybox_vertex_count: u32,
    /// geometry.crosshair_vertices as float4 NDC positions (w tags crosshair vs hit marker).
    crosshair: Buffer,
    crosshair_vertex_count: u32,
    /// Albedo of the cubes and the ground.
    world_texture: Texture,
    /// Albedo of the gun.
    gun_texture: Texture,

    /// Uploads the two meshes, the built-in geometry and the two images. The CPU copies stay the
    /// caller's and can be freed as soon as this returns.
    pub fn init(
        device: Device,
        cube: obj.Mesh,
        gun: obj.Mesh,
        world_image: ppm.Image,
        gun_image: ppm.Image,
    ) !StaticResources {
        const cube_mesh = try GpuMesh.upload(device, cube.vertices, cube.indices);
        errdefer cube_mesh.release();
        const gun_mesh = try GpuMesh.upload(device, gun.vertices, gun.indices);
        errdefer gun_mesh.release();
        const ground_mesh = try GpuMesh.upload(device, &geometry.ground_vertices, &geometry.ground_indices);
        errdefer ground_mesh.release();

        const skybox = try device.newBufferWithBytes(std.mem.asBytes(&geometry.skybox_vertices), .shared);
        errdefer skybox.release();
        const crosshair = try device.newBufferWithBytes(std.mem.asBytes(&geometry.crosshair_vertices), .shared);
        errdefer crosshair.release();

        const world_texture = try uploadTexture(device, world_image);
        errdefer world_texture.release();
        const gun_texture = try uploadTexture(device, gun_image);

        return .{
            .cube = cube_mesh,
            .gun = gun_mesh,
            .ground = ground_mesh,
            .skybox = skybox,
            .skybox_vertex_count = geometry.skybox_vertices.len,
            .crosshair = crosshair,
            .crosshair_vertex_count = geometry.crosshair_vertices.len,
            .world_texture = world_texture,
            .gun_texture = gun_texture,
        };
    }

    /// Releases every buffer and texture.
    pub fn deinit(self: *StaticResources) void {
        self.cube.release();
        self.gun.release();
        self.ground.release();
        self.skybox.release();
        self.crosshair.release();
        self.world_texture.release();
        self.gun_texture.release();
        self.* = undefined;
    }
};

/// Returns a shader-readable RGBA8 texture (+1) holding `image`. error.InvalidImage when the pixel
/// slice is not exactly width * height * 4 bytes (replaceRegion would read past it) or a side
/// exceeds the GPU limit.
fn uploadTexture(device: Device, image: ppm.Image) !Texture {
    const width: u64 = image.width;
    const height: u64 = image.height;
    if (width > MAX_TEXTURE_SIDE or height > MAX_TEXTURE_SIDE) return error.InvalidImage;
    if (image.rgba.len != width * height * 4) return error.InvalidImage;
    // Shared, never private: replaceRegion needs CPU-visible storage (a private texture would
    // silently receive nothing).
    const texture = try device.newTexture2D(.rgba8_unorm, width, height, .{ .shader_read = true }, .shared);
    texture.replaceRegion(.rect2D(width, height), image.rgba.ptr, width * 4);
    return texture;
}

// ============================================================
// Per-instance buffers (rewritten by the CPU every frame)
// ============================================================

/// Matrices and hit timers for the instanced cube draws, `capacity` entries each (+1 per buffer).
/// Shared storage, so CPU writes are visible to the GPU without a blit. Single-buffered: see the
/// instance-buffer invariant in renderer.zig before changing who writes them, or when.
pub const InstanceBuffers = struct {
    capacity: u32,
    /// view_proj · model per instance (vertex_main's MVPs).
    mvp: Buffer,
    /// Model matrix per instance (vertex_main's models).
    model: Buffer,
    /// light_view_proj · model per instance (shadow_vertex's light MVPs).
    shadow_mvp: Buffer,
    /// Hit-flash timer per instance (vertex_main's hit timers).
    hit_timer: Buffer,

    /// Allocates the four buffers; a capacity of 0 fails with error.MetalCreateFailed (Metal has no
    /// empty buffers).
    pub fn init(device: Device, capacity: u32) !InstanceBuffers {
        const matrix_bytes = @as(usize, capacity) * @sizeOf(math.Mat4);
        const mvp = try device.newBuffer(matrix_bytes, .shared);
        errdefer mvp.release();
        const model = try device.newBuffer(matrix_bytes, .shared);
        errdefer model.release();
        const shadow_mvp = try device.newBuffer(matrix_bytes, .shared);
        errdefer shadow_mvp.release();
        const hit_timer = try device.newBuffer(@as(usize, capacity) * @sizeOf(f32), .shared);
        return .{ .capacity = capacity, .mvp = mvp, .model = model, .shadow_mvp = shadow_mvp, .hit_timer = hit_timer };
    }

    /// Releases the four buffers.
    pub fn deinit(self: *InstanceBuffers) void {
        self.mvp.release();
        self.model.release();
        self.shadow_mvp.release();
        self.hit_timer.release();
        self.* = undefined;
    }

    /// Returns the MVP buffer as `capacity` matrices.
    pub fn mvps(self: InstanceBuffers) []math.Mat4 {
        return self.mvp.slice(math.Mat4, self.capacity);
    }

    /// Returns the model-matrix buffer as `capacity` matrices.
    pub fn models(self: InstanceBuffers) []math.Mat4 {
        return self.model.slice(math.Mat4, self.capacity);
    }

    /// Returns the light-MVP buffer as `capacity` matrices.
    pub fn shadowMvps(self: InstanceBuffers) []math.Mat4 {
        return self.shadow_mvp.slice(math.Mat4, self.capacity);
    }

    /// Returns the hit-timer buffer as `capacity` floats.
    pub fn hitTimers(self: InstanceBuffers) []f32 {
        return self.hit_timer.slice(f32, self.capacity);
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// The default device inside a fresh autorelease pool, or error.SkipZigTest without Metal.
const TestGpu = struct {
    pool: objc.Object,
    device: Device,

    fn begin() !TestGpu {
        const raw_pool = objc.msgSend(?objc.Object, objc.class("NSAutoreleasePool"), "alloc", .{});
        const pool = objc.msgSend(?objc.Object, raw_pool, "init", .{}) orelse return error.PoolInitFailed;
        errdefer objc.msgSend(void, pool, "drain", .{});
        const device = Device.createSystemDefault() orelse return error.SkipZigTest;
        return .{ .pool = pool, .device = device };
    }

    fn end(self: TestGpu) void {
        self.device.release();
        objc.msgSend(void, self.pool, "drain", .{});
    }
};

fn testVertex(x: f32, y: f32, z: f32) Vertex {
    return .{ .position = .{ x, y, z, 1 }, .color = .{ 1, 1, 1, 1 }, .uv = .{ 0, 0, 0, 0 }, .normal = .{ 0, 0, 1, 0 } };
}

test "GpuMesh.upload copies vertices and indices into shared buffers" {
    const gpu = try TestGpu.begin();
    defer gpu.end();

    const vertices = [_]Vertex{ testVertex(0, 0, 0), testVertex(1, 0, 0), testVertex(0, 1, 0), testVertex(1, 1, 0) };
    const indices = [_]u32{ 0, 1, 2, 2, 1, 3 };
    const mesh = try GpuMesh.upload(gpu.device, &vertices, &indices);
    defer mesh.release();

    try testing.expectEqual(6, mesh.index_count);
    try testing.expectEqual(4 * @sizeOf(Vertex), mesh.vertices.length());
    try testing.expectEqualSlices(u32, &indices, mesh.indices.slice(u32, indices.len));
    const uploaded = mesh.vertices.slice(Vertex, vertices.len);
    for (vertices, uploaded) |expected, actual| {
        try testing.expectEqualSlices(f32, &expected.position, &actual.position);
        try testing.expectEqualSlices(f32, &expected.normal, &actual.normal);
    }
}

test "GpuMesh.upload rejects empty meshes and out-of-range indices before touching Metal" {
    const gpu = try TestGpu.begin();
    defer gpu.end();

    const vertices = [_]Vertex{ testVertex(0, 0, 0), testVertex(1, 0, 0), testVertex(0, 1, 0) };
    try testing.expectError(error.InvalidMesh, GpuMesh.upload(gpu.device, &.{}, &.{ 0, 1, 2 }));
    try testing.expectError(error.InvalidMesh, GpuMesh.upload(gpu.device, &vertices, &.{}));
    try testing.expectError(error.InvalidMesh, GpuMesh.upload(gpu.device, &vertices, &.{ 0, 1, 3 }));
}

test "StaticResources.init uploads the meshes, built-in geometry and both textures" {
    const gpu = try TestGpu.begin();
    defer gpu.end();

    var cube_vertices = [_]Vertex{ testVertex(0, 0, 0), testVertex(1, 0, 0), testVertex(0, 1, 0) };
    var cube_indices = [_]u32{ 0, 1, 2 };
    var gun_vertices = [_]Vertex{ testVertex(0, 0, 0), testVertex(0, 1, 0), testVertex(1, 0, 0), testVertex(1, 1, 0) };
    var gun_indices = [_]u32{ 0, 1, 2, 2, 1, 3 };
    // 2 x 1 world image (red, green) and 1 x 1 gun image (grey).
    var world_rgba = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 };
    var gun_rgba = [_]u8{ 90, 90, 90, 255 };

    var static = try StaticResources.init(
        gpu.device,
        .{ .vertices = &cube_vertices, .indices = &cube_indices },
        .{ .vertices = &gun_vertices, .indices = &gun_indices },
        .{ .width = 2, .height = 1, .rgba = &world_rgba },
        .{ .width = 1, .height = 1, .rgba = &gun_rgba },
    );
    defer static.deinit();

    try testing.expectEqual(3, static.cube.index_count);
    try testing.expectEqual(6, static.gun.index_count);
    try testing.expectEqual(geometry.ground_indices.len, static.ground.index_count);
    try testing.expectEqualSlices(u32, &geometry.ground_indices, static.ground.indices.slice(u32, 6));
    try testing.expectEqual(36, static.skybox_vertex_count);
    try testing.expectEqual(54, static.crosshair_vertex_count);
    try testing.expectEqualSlices([4]f32, &geometry.skybox_vertices, static.skybox.slice([4]f32, 36));
    try testing.expectEqualSlices([4]f32, &geometry.crosshair_vertices, static.crosshair.slice([4]f32, 54));

    try testing.expectEqual(2, static.world_texture.width());
    try testing.expectEqual(1, static.world_texture.height());
    var world_back: [8]u8 = undefined;
    static.world_texture.getBytes(&world_back, 2 * 4, .rect2D(2, 1));
    try testing.expectEqualSlices(u8, &world_rgba, &world_back);
    var gun_back: [4]u8 = undefined;
    static.gun_texture.getBytes(&gun_back, 4, .rect2D(1, 1));
    try testing.expectEqualSlices(u8, &gun_rgba, &gun_back);
}

test "StaticResources.init rejects an image whose pixels do not match its size" {
    const gpu = try TestGpu.begin();
    defer gpu.end();

    var vertices = [_]Vertex{ testVertex(0, 0, 0), testVertex(1, 0, 0), testVertex(0, 1, 0) };
    var indices = [_]u32{ 0, 1, 2 };
    var good_rgba = [_]u8{ 1, 2, 3, 255 };
    var short_rgba = [_]u8{ 1, 2, 3, 255 }; // claims 2 x 1 below: 4 bytes short
    const mesh: obj.Mesh = .{ .vertices = &vertices, .indices = &indices };

    // Fails on the last upload, so every errdefer above it runs.
    try testing.expectError(error.InvalidImage, StaticResources.init(
        gpu.device,
        mesh,
        mesh,
        .{ .width = 1, .height = 1, .rgba = &good_rgba },
        .{ .width = 2, .height = 1, .rgba = &short_rgba },
    ));
}

test "InstanceBuffers expose capacity-sized views of shared buffers" {
    const gpu = try TestGpu.begin();
    defer gpu.end();

    var instances = try InstanceBuffers.init(gpu.device, 8);
    defer instances.deinit();

    try testing.expectEqual(8, instances.mvps().len);
    try testing.expectEqual(8, instances.models().len);
    try testing.expectEqual(8, instances.shadowMvps().len);
    try testing.expectEqual(8, instances.hitTimers().len);
    try testing.expectEqual(8 * @sizeOf(math.Mat4), instances.mvp.length());
    try testing.expectEqual(8 * @sizeOf(f32), instances.hit_timer.length());

    // Writes through a view land in the buffer the GPU reads (and a fresh view sees them).
    instances.models()[7] = math.Mat4.translation(1, 2, 3);
    instances.hitTimers()[3] = 0.5;
    const raw: [*]const f32 = @ptrCast(@alignCast(instances.model.contents()));
    try testing.expectEqualSlices(f32, &.{ 1, 2, 3, 1 }, raw[7 * 16 + 12 ..][0..4]);
    try testing.expectEqual(0.5, instances.hitTimers()[3]);

    try testing.expectError(error.MetalCreateFailed, InstanceBuffers.init(gpu.device, 0));
}
