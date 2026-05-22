const device = @import("device.zig");
const vertex = @import("vertex.zig");
const crosshair = @import("crosshair.zig");
const math = @import("math.zig");
const loader = @import("../assets/loader.zig");
const texture_mod = @import("../assets/texture.zig");

const Vertex = vertex.Vertex;

// ============================================================
// Static world geometry — owned by StaticBuffers
// ============================================================

pub const GROUND_Y: f32 = -12.0;
const GROUND_SIZE: f32 = 50.0;

const ground_verts = [_]Vertex{
    .{ .position = .{ -GROUND_SIZE, GROUND_Y, -GROUND_SIZE, 1 }, .color = .{ 0.3, 0.35, 0.3, 1 }, .uv = .{ 0, 0, 0, 0 }, .normal = .{ 0, 1, 0, 0 } },
    .{ .position = .{ GROUND_SIZE, GROUND_Y, -GROUND_SIZE, 1 }, .color = .{ 0.3, 0.35, 0.3, 1 }, .uv = .{ 10, 0, 0, 0 }, .normal = .{ 0, 1, 0, 0 } },
    .{ .position = .{ GROUND_SIZE, GROUND_Y, GROUND_SIZE, 1 }, .color = .{ 0.3, 0.35, 0.3, 1 }, .uv = .{ 10, 10, 0, 0 }, .normal = .{ 0, 1, 0, 0 } },
    .{ .position = .{ -GROUND_SIZE, GROUND_Y, GROUND_SIZE, 1 }, .color = .{ 0.3, 0.35, 0.3, 1 }, .uv = .{ 0, 10, 0, 0 }, .normal = .{ 0, 1, 0, 0 } },
};
const ground_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };

// Skybox cube — inside-facing, 36 verts of float4 positions
pub const skybox_verts = [36][4]f32{
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

// ============================================================
// StaticBuffers — geometry + textures uploaded once at startup
// ============================================================

pub const StaticBuffers = struct {
    cube_vertex: device.MetalBuffer,
    cube_index: device.MetalBuffer,
    cube_index_count: u32,

    gun_vertex: device.MetalBuffer,
    gun_index: device.MetalBuffer,
    gun_index_count: u32,

    ground_vertex: device.MetalBuffer,
    ground_index: device.MetalBuffer,
    ground_index_count: u32,

    skybox_vertex: device.MetalBuffer,
    skybox_vertex_count: u32,

    crosshair_vertex: device.MetalBuffer,
    crosshair_vert_count: u32,

    world_texture: device.MetalTexture,
    gun_texture: device.MetalTexture,

    pub fn init(
        dev: device.MetalDevice,
        cube_mesh: loader.Mesh,
        gun_mesh: loader.Mesh,
        world_ppm: texture_mod.TextureData,
        gun_ppm: texture_mod.TextureData,
    ) !StaticBuffers {
        const cube_v = try uploadVertices(dev, cube_mesh.vertices);
        const cube_i = try uploadIndices(dev, cube_mesh.indices);

        const gun_v = try uploadVertices(dev, gun_mesh.vertices);
        const gun_i = try uploadIndices(dev, gun_mesh.indices);

        const ground_v = try uploadVertices(dev, &ground_verts);
        const ground_i = try uploadIndices(dev, &ground_indices);

        const sky_v = dev.createBuffer(@sizeOf([4]f32) * skybox_verts.len, .StorageModeShared) orelse return error.BufferFailed;
        @memcpy(
            @as([*][4]f32, @ptrCast(@alignCast(sky_v.contents())))[0..skybox_verts.len],
            &skybox_verts,
        );

        const ch_v = dev.createBuffer(@sizeOf([4]f32) * crosshair.VERT_COUNT, .StorageModeShared) orelse return error.BufferFailed;
        @memcpy(
            @as([*][4]f32, @ptrCast(@alignCast(ch_v.contents())))[0..crosshair.VERT_COUNT],
            &crosshair.vertices,
        );

        return StaticBuffers{
            .cube_vertex = cube_v,
            .cube_index = cube_i,
            .cube_index_count = @intCast(cube_mesh.indices.len),

            .gun_vertex = gun_v,
            .gun_index = gun_i,
            .gun_index_count = @intCast(gun_mesh.indices.len),

            .ground_vertex = ground_v,
            .ground_index = ground_i,
            .ground_index_count = @intCast(ground_indices.len),

            .skybox_vertex = sky_v,
            .skybox_vertex_count = skybox_verts.len,

            .crosshair_vertex = ch_v,
            .crosshair_vert_count = crosshair.VERT_COUNT,

            .world_texture = try uploadTexture(dev, world_ppm),
            .gun_texture = try uploadTexture(dev, gun_ppm),
        };
    }
};

fn uploadVertices(dev: device.MetalDevice, verts: []const Vertex) !device.MetalBuffer {
    const buf = dev.createBuffer(@sizeOf(Vertex) * verts.len, .StorageModeShared) orelse return error.BufferFailed;
    @memcpy(@as([*]Vertex, @ptrCast(@alignCast(buf.contents())))[0..verts.len], verts);
    return buf;
}

fn uploadIndices(dev: device.MetalDevice, indices: []const u32) !device.MetalBuffer {
    const buf = dev.createBuffer(@sizeOf(u32) * indices.len, .StorageModeShared) orelse return error.BufferFailed;
    @memcpy(@as([*]u32, @ptrCast(@alignCast(buf.contents())))[0..indices.len], indices);
    return buf;
}

fn uploadTexture(dev: device.MetalDevice, ppm: texture_mod.TextureData) !device.MetalTexture {
    const tex = dev.createTexture(ppm.width, ppm.height, 70) orelse return error.TextureFailed;
    const region = device.MTLRegion{
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .size = .{ .width = ppm.width, .height = ppm.height, .depth = 1 },
    };
    tex.replaceRegion(region, @ptrCast(ppm.pixels.ptr), ppm.width * 4);
    return tex;
}

// ============================================================
// InstanceBuffers — per-frame writable matrices and timers
// ============================================================

pub const InstanceBuffers = struct {
    mvp: device.MetalBuffer,
    model: device.MetalBuffer,
    shadow_mvp: device.MetalBuffer,
    hit_timer: device.MetalBuffer,
    capacity: u32,

    pub fn init(dev: device.MetalDevice, max: u32) !InstanceBuffers {
        const n: u64 = @intCast(max);
        return InstanceBuffers{
            .mvp = dev.createBuffer(@sizeOf(math.Mat4x4) * n, .StorageModeShared) orelse return error.BufferFailed,
            .model = dev.createBuffer(@sizeOf(math.Mat4x4) * n, .StorageModeShared) orelse return error.BufferFailed,
            .shadow_mvp = dev.createBuffer(@sizeOf(math.Mat4x4) * n, .StorageModeShared) orelse return error.BufferFailed,
            .hit_timer = dev.createBuffer(@sizeOf(f32) * n, .StorageModeShared) orelse return error.BufferFailed,
            .capacity = max,
        };
    }

    pub fn mvps(self: InstanceBuffers) [*]math.Mat4x4 {
        return @ptrCast(@alignCast(self.mvp.contents()));
    }
    pub fn models(self: InstanceBuffers) [*]math.Mat4x4 {
        return @ptrCast(@alignCast(self.model.contents()));
    }
    pub fn shadowMvps(self: InstanceBuffers) [*]math.Mat4x4 {
        return @ptrCast(@alignCast(self.shadow_mvp.contents()));
    }
    pub fn hitTimers(self: InstanceBuffers) [*]f32 {
        return @ptrCast(@alignCast(self.hit_timer.contents()));
    }
};
