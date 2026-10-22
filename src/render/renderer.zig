//! Frame renderer: one command buffer per frame, a depth-only shadow pass then the main pass (sky, world, gun, crosshair).

const std = @import("std");
const objc = @import("../objc.zig");
const math = @import("../math.zig");
const metal = @import("metal.zig");
const uniforms = @import("uniforms.zig");
const Pipelines = @import("pipelines.zig").Pipelines;
const binding = @import("pipelines.zig").binding;
const DEPTH_FORMAT = @import("pipelines.zig").DEPTH_FORMAT;
const StaticResources = @import("resources.zig").StaticResources;
const InstanceBuffers = @import("resources.zig").InstanceBuffers;

const Mat4 = math.Mat4;

/// Side of the square shadow map in texels; the shaders get it as SHADOW_MAP_SIZE (the PCF tap step).
pub const SHADOW_MAP_SIZE: u64 = 2048;

/// Where the main pass splits its window depth range: the world draws into [split, 1] and the gun
/// into [0, split], so the gun stays in front of the world yet still depth-tests against itself.
pub const VIEWMODEL_DEPTH_SPLIT: f64 = 0.05;

/// Everything one frame needs besides the static resources and the instance buffers.
pub const FrameData = struct {
    /// Camera projection · view, for the world and the sky.
    view_proj: Mat4,
    /// Camera projection alone: the gun's MVP is proj · gun_model, which glues it to the screen.
    proj: Mat4,
    /// The shadow light's orthographic projection · view.
    light_view_proj: Mat4,
    light: uniforms.LightUniforms,
    sky: uniforms.SkyUniforms,
    /// Instances to draw from the instance buffers; encodeFrame draws at most their capacity.
    instance_count: u32,
    /// The gun's model matrix in VIEW space; it also stands in for its world matrix when lighting
    /// (the original lights the gun in view space).
    gun_model: Mat4,
    crosshair: uniforms.CrosshairUniforms,
    clear_color: metal.ClearColor,
};

// INSTANCE-BUFFER INVARIANT. `Renderer.instances` is single-buffered shared memory: the CPU rewrites
// it every frame (systems.buildInstances) and nothing fences the previous frame's render command
// buffer, which reads it on the GPU. That is safe only while all of these hold:
//   1. main passes the SAME CommandQueue to this Renderer and to ComputePhysics;
//   2. ComputePhysics.step ALWAYS commits and waitUntilCompleted, even with 0 entities, and on a
//      frame that runs no physics substep main commits and waits on an empty fence command buffer
//      on that queue instead (main.zig);
//   3. buildInstances runs after the frame's last physics step, and drawFrame runs at most once per
//      loop iteration;
//   4. Metal reports a queue's command-buffer completions in commit order (observed on the M3, not
//      documented; physics.zig's "step with 0 entities" test checks it), so when step's or the
//      fence's wait returns, the previous frame's render buffer has completed too, even though the
//      two may overlap on the GPU.
// Break one (a second queue, an early-out in step, dropping main's zero-substep fence, a second
// drawFrame) and the CPU can overwrite matrices the GPU is still reading: then wait on the last
// render command buffer first, or double-buffer the instances.

/// Draws frames with the shadow-mapped Blinn-Phong pipeline. Main-thread only.
pub const Renderer = struct {
    /// Borrowed: the caller keeps it alive until after `deinit`.
    device: metal.Device,
    /// Borrowed; the same queue ComputePhysics commits to (instance-buffer invariant above).
    queue: metal.CommandQueue,
    pipelines: Pipelines,
    resources: StaticResources,
    /// Single-buffered; see the instance-buffer invariant above.
    instances: InstanceBuffers,
    /// Depth32Float, private: written by the shadow pass, sampled by fragment_main.
    shadow_map: metal.Texture,
    /// Main-pass depth target sized like the last frame's target; null before the first frame.
    depth: ?metal.Texture,
    depth_width: u64,
    depth_height: u64,

    /// Builds the pipelines, `instance_capacity` instance slots and the shadow map. On success the
    /// renderer owns `resources` and `deinit` releases them; on error they are still the caller's,
    /// so scope the caller's errdefer for them to this call (e.g. inside a labeled block).
    /// Call inside an autorelease pool.
    pub fn init(
        device: metal.Device,
        queue: metal.CommandQueue,
        resources: StaticResources,
        instance_capacity: u32,
    ) !Renderer {
        var pipelines = try Pipelines.init(device);
        errdefer pipelines.deinit();
        var instances = try InstanceBuffers.init(device, instance_capacity);
        errdefer instances.deinit();
        const shadow_map = try device.newTexture2D(
            DEPTH_FORMAT,
            SHADOW_MAP_SIZE,
            SHADOW_MAP_SIZE,
            .{ .render_target = true, .shader_read = true },
            .private,
        );
        return .{
            .device = device,
            .queue = queue,
            .pipelines = pipelines,
            .resources = resources,
            .instances = instances,
            .shadow_map = shadow_map,
            .depth = null,
            .depth_width = 0,
            .depth_height = 0,
        };
    }

    /// Releases everything the renderer owns (not the borrowed device and queue). Frames still in
    /// flight stay valid: command buffers retain the resources they use.
    pub fn deinit(self: *Renderer) void {
        if (self.depth) |depth| depth.release();
        self.shadow_map.release();
        self.instances.deinit();
        self.resources.deinit();
        self.pipelines.deinit();
        self.* = undefined;
    }

    /// Encodes the shadow pass and the main pass for `frame` into `cmd`, drawing into `target` (an
    /// MTLTexture in pipelines.COLOR_FORMAT, e.g. a drawable's texture) at its pixel size. Neither
    /// presents nor commits, so it also renders offscreen. Fails only when Metal cannot create a
    /// pass, an encoder or the depth target; `cmd` is then left uncommitted.
    pub fn encodeFrame(self: *Renderer, cmd: metal.CommandBuffer, target: objc.Object, frame: FrameData) !void {
        // A borrowed view of the target, only to read its size; never released here.
        const target_texture: metal.Texture = .{ .handle = target };
        const width = target_texture.width();
        const height = target_texture.height();
        const depth = try self.depthTarget(width, height);

        // Clamped at run time, in every build mode (no assert: the optimizer would take it as a
        // promise and drop the clamp): drawing past the capacity would read beyond the instance
        // buffers on the GPU, and FrameData comes from the caller.
        const instance_count = @min(frame.instance_count, self.instances.capacity);

        try self.encodeShadowPass(cmd, &frame, instance_count);
        try self.encodeMainPass(cmd, target, depth, width, height, &frame, instance_count);
    }

    /// Renders `frame` into `drawable` (a CAMetalDrawable, e.g. from Window.nextDrawable), presents it
    /// and commits: one command buffer per frame. Call inside the frame's autorelease pool.
    pub fn drawFrame(self: *Renderer, drawable: objc.Object, frame: FrameData) !void {
        const texture = objc.msgSend(?objc.Object, drawable, "texture", .{}) orelse return error.DrawableHasNoTexture;
        const cmd = try self.queue.commandBuffer();
        try self.encodeFrame(cmd, texture, frame);
        cmd.presentDrawable(drawable);
        cmd.commit();
    }

    /// Returns the main-pass depth texture for a `width` x `height` target, replacing the cached one
    /// when the size changed (and releasing it: the original leaked one per resize).
    fn depthTarget(self: *Renderer, width: u64, height: u64) !metal.Texture {
        if (self.depth) |depth| {
            if (self.depth_width == width and self.depth_height == height) return depth;
        }
        const depth = try self.device.newTexture2D(DEPTH_FORMAT, width, height, .{ .render_target = true }, .private);
        // A frame still in flight keeps the old texture alive: command buffers retain what they use.
        if (self.depth) |old| old.release();
        self.depth = depth;
        self.depth_width = width;
        self.depth_height = height;
        return depth;
    }

    /// Depth-only pass from the sun into the shadow map. No viewport is set: the default (the whole
    /// 2048² map, depth 0..1) stores exactly the light-space NDC z that shadowCalc compares against.
    fn encodeShadowPass(
        self: *const Renderer,
        cmd: metal.CommandBuffer,
        frame: *const FrameData,
        instance_count: u32,
    ) !void {
        const pass = try metal.RenderPassDescriptor.create();
        pass.setDepthAttachment(self.shadow_map.handle, .clear, .store, 1.0);
        const encoder = try cmd.renderCommandEncoder(pass);
        defer encoder.endEncoding();

        // OBJ front faces wind counter-clockwise, so this keeps the light-facing faces: the same
        // triangles as the original's `cull front` under Metal's default clockwise winding. The ground
        // quad winds clockwise seen from above, so it is culled either way and never enters the shadow
        // map, as in the original (its draw below is kept for parity).
        encoder.setFrontFacingWinding(.counter_clockwise);
        encoder.setCullMode(.back);
        encoder.setDepthStencilState(self.pipelines.depth_default);

        const cube = self.resources.cube;
        if (instance_count > 0) { // Metal validation rejects an instanced draw of 0 instances
            encoder.setRenderPipelineState(self.pipelines.shadow_instanced);
            encoder.setVertexBuffer(cube.vertices, 0, binding.VERTICES);
            encoder.setVertexBuffer(self.instances.shadow_mvp, 0, binding.SHADOW_MVP);
            encoder.drawIndexed(.triangle, cube.index_count, .uint32, cube.indices, 0, instance_count);
        }

        // The ground's model matrix is the identity, so its light MVP is the light view-projection.
        const ground = self.resources.ground;
        encoder.setRenderPipelineState(self.pipelines.shadow_single);
        encoder.setVertexBuffer(ground.vertices, 0, binding.VERTICES);
        encoder.setVertexBytes(Mat4, &frame.light_view_proj, binding.SHADOW_MVP);
        encoder.drawIndexed(.triangle, ground.index_count, .uint32, ground.indices, 0, 1);
    }

    /// Colour + depth pass into `target`: sky, instanced cubes, ground, gun, crosshair. No culling, as
    /// the original.
    fn encodeMainPass(
        self: *const Renderer,
        cmd: metal.CommandBuffer,
        target: objc.Object,
        depth: metal.Texture,
        width: u64,
        height: u64,
        frame: *const FrameData,
        instance_count: u32,
    ) !void {
        const pass = try metal.RenderPassDescriptor.create();
        pass.setColorAttachment(0, target, .clear, .store, frame.clear_color);
        pass.setDepthAttachment(depth.handle, .clear, .dont_care, 1.0);
        const encoder = try cmd.renderCommandEncoder(pass);
        defer encoder.endEncoding();

        // Viewports in pixels of the target; the two depth ranges keep the gun in front of the world.
        const w: f64 = @floatFromInt(width);
        const h: f64 = @floatFromInt(height);
        const world_viewport = fullViewport(w, h, VIEWMODEL_DEPTH_SPLIT, 1);
        const gun_viewport = fullViewport(w, h, 0, VIEWMODEL_DEPTH_SPLIT);

        // Sky first, at depth 1: LessEqual passes against the 1.0 clear and writes nothing, so the
        // world covers it wherever it is drawn.
        encoder.setViewport(world_viewport);
        encoder.setDepthStencilState(self.pipelines.depth_sky);
        encoder.setRenderPipelineState(self.pipelines.sky);
        encoder.setVertexBuffer(self.resources.skybox, 0, binding.VERTICES);
        encoder.setVertexBytes(Mat4, &frame.view_proj, binding.SKY_VIEW_PROJ);
        encoder.setFragmentBytes(uniforms.SkyUniforms, &frame.sky, binding.SKY_UNIFORMS);
        encoder.drawPrimitives(.triangle, 0, self.resources.skybox_vertex_count);

        // Lit world. The light, the shadow map and the light view-projection stay bound for the gun.
        encoder.setDepthStencilState(self.pipelines.depth_default);
        encoder.setFragmentTexture(self.resources.world_texture, binding.ALBEDO_TEXTURE);
        encoder.setFragmentTexture(self.shadow_map, binding.SHADOW_MAP_TEXTURE);
        encoder.setFragmentBytes(uniforms.LightUniforms, &frame.light, binding.LIGHT_UNIFORMS);
        encoder.setVertexBytes(Mat4, &frame.light_view_proj, binding.LIGHT_VIEW_PROJ);

        const cube = self.resources.cube;
        if (instance_count > 0) {
            encoder.setRenderPipelineState(self.pipelines.scene_instanced);
            encoder.setVertexBuffer(cube.vertices, 0, binding.VERTICES);
            encoder.setVertexBuffer(self.instances.mvp, 0, binding.MVP);
            encoder.setVertexBuffer(self.instances.model, 0, binding.MODEL);
            encoder.setVertexBuffer(self.instances.hit_timer, 0, binding.HIT_TIMERS);
            encoder.drawIndexed(.triangle, cube.index_count, .uint32, cube.indices, 0, instance_count);
        }

        // Ground: identity model, so its MVP is the view-projection.
        const ground = self.resources.ground;
        encoder.setRenderPipelineState(self.pipelines.scene_single);
        encoder.setVertexBuffer(ground.vertices, 0, binding.VERTICES);
        encoder.setVertexBytes(Mat4, &frame.view_proj, binding.MVP);
        encoder.setVertexBytes(Mat4, &Mat4.identity, binding.MODEL);
        encoder.drawIndexed(.triangle, ground.index_count, .uint32, ground.indices, 0, 1);

        // Gun: its own depth range in front of the world, depth-tested against itself (the original
        // drew it with Always + write, so it never self-occluded). It draws with depth_default (set
        // before the cubes) and scene_single (set for the ground), both still bound: binding either
        // again is a redundant-state warning that MTL_DEBUG_LAYER_WARNING_MODE=assert aborts on.
        const gun = self.resources.gun;
        const gun_mvp = frame.proj.mul(frame.gun_model);
        encoder.setViewport(gun_viewport);
        encoder.setFragmentTexture(self.resources.gun_texture, binding.ALBEDO_TEXTURE);
        encoder.setVertexBuffer(gun.vertices, 0, binding.VERTICES);
        encoder.setVertexBytes(Mat4, &gun_mvp, binding.MVP);
        encoder.setVertexBytes(Mat4, &frame.gun_model, binding.MODEL);
        encoder.drawIndexed(.triangle, gun.index_count, .uint32, gun.indices, 0, 1);

        // Crosshair overlay last, never depth-tested.
        encoder.setViewport(world_viewport);
        encoder.setDepthStencilState(self.pipelines.depth_overlay);
        encoder.setRenderPipelineState(self.pipelines.crosshair);
        encoder.setVertexBuffer(self.resources.crosshair, 0, binding.VERTICES);
        encoder.setVertexBytes(uniforms.CrosshairUniforms, &frame.crosshair, binding.CROSSHAIR_UNIFORMS);
        encoder.drawPrimitives(.triangle, 0, self.resources.crosshair_vertex_count);
    }
};

/// Returns a viewport over the whole `width` x `height` target (pixels) that maps clip depth [0, 1]
/// onto window depth [znear, zfar].
fn fullViewport(width: f64, height: f64, znear: f64, zfar: f64) metal.Viewport {
    return .{ .origin_x = 0, .origin_y = 0, .width = width, .height = height, .znear = znear, .zfar = zfar };
}

// ============================================================
// Tests (need a Metal device; skipped without one, no window server)
// ============================================================

const testing = std.testing;
const geometry = @import("geometry.zig");
const COLOR_FORMAT = @import("pipelines.zig").COLOR_FORMAT;
const AutoreleasePool = @import("../platform/autorelease.zig").AutoreleasePool;
const Vec3 = math.Vec3;
const Vertex = geometry.Vertex;

// main.zig's sun and camera lens, so the offscreen frames are lit like the game.
const TEST_SUN_POS = Vec3.init(10, 20, 10);
const TEST_SUN_TARGET = Vec3.init(0, -5, -10);
const TEST_LIGHT_COLOR = [3]f32{ 1, 0.95, 0.9 };
const TEST_FOV_Y: f32 = std.math.degreesToRadians(@as(f32, 45));
/// Puts the test gun behind the camera, where it is clipped away.
const GUN_HIDDEN = Mat4.translation(0, 0, 10);
const COMMAND_BUFFER_STATUS_COMPLETED: u64 = 4; // MTLCommandBufferStatusCompleted

/// A white unit cube with per-face normals; every face winds counter-clockwise seen from outside,
/// like the OBJ meshes.
const TestCube = struct {
    vertices: [24]Vertex,
    indices: [36]u32,

    fn init() TestCube {
        // (normal, u, v) per face with u × v = normal, so the corners -u-v, +u-v, +u+v, -u+v run
        // counter-clockwise seen from outside.
        const faces = [6][3][3]f32{
            .{ .{ 1, 0, 0 }, .{ 0, 0, -1 }, .{ 0, 1, 0 } },
            .{ .{ -1, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 1, 0 } },
            .{ .{ 0, 1, 0 }, .{ 1, 0, 0 }, .{ 0, 0, -1 } },
            .{ .{ 0, -1, 0 }, .{ 1, 0, 0 }, .{ 0, 0, 1 } },
            .{ .{ 0, 0, 1 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } },
            .{ .{ 0, 0, -1 }, .{ -1, 0, 0 }, .{ 0, 1, 0 } },
        };
        const corners = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
        var cube: TestCube = undefined;
        for (faces, 0..) |face, f| {
            const n = face[0];
            for (corners, 0..) |c, k| {
                var position: [4]f32 = .{ 0, 0, 0, 1 };
                for (0..3) |axis| position[axis] = 0.5 * (n[axis] + c[0] * face[1][axis] + c[1] * face[2][axis]);
                cube.vertices[f * 4 + k] = .{
                    .position = position,
                    .color = .{ 1, 1, 1, 1 },
                    .uv = @splat(0),
                    .normal = .{ n[0], n[1], n[2], 0 },
                };
            }
            const base: u32 = @intCast(f * 4);
            cube.indices[f * 6 ..][0..6].* = .{ base, base + 1, base + 2, base, base + 2, base + 3 };
        }
        return cube;
    }
};

/// The test gun: two 0.2 x 0.2 quads facing +z, green at z = +0.1 drawn first and blue at z = -0.1
/// drawn second, so the blue one only wins when depth testing is broken.
const TestGun = struct {
    vertices: [8]Vertex,
    indices: [12]u32 = .{ 0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7 },

    fn init() TestGun {
        var gun: TestGun = .{ .vertices = undefined };
        const quads = [2]struct { z: f32, color: [4]f32 }{
            .{ .z = 0.1, .color = .{ 0, 1, 0, 1 } },
            .{ .z = -0.1, .color = .{ 0, 0, 1, 1 } },
        };
        const corners = [4][2]f32{ .{ -0.1, -0.1 }, .{ 0.1, -0.1 }, .{ 0.1, 0.1 }, .{ -0.1, 0.1 } };
        for (quads, 0..) |quad, q| {
            for (corners, 0..) |c, k| {
                gun.vertices[q * 4 + k] = .{
                    .position = .{ c[0], c[1], quad.z, 1 },
                    .color = quad.color,
                    .uv = @splat(0),
                    .normal = .{ 0, 0, 1, 0 },
                };
            }
        }
        return gun;
    }
};

/// A Renderer over TestCube, TestGun and 1 x 1 white textures, inside a fresh autorelease pool.
const TestRig = struct {
    pool: objc.Object,
    device: metal.Device,
    queue: metal.CommandQueue,
    renderer: Renderer,

    fn init() !TestRig {
        const raw_pool = objc.msgSend(?objc.Object, objc.class("NSAutoreleasePool"), "alloc", .{});
        const pool = objc.msgSend(?objc.Object, raw_pool, "init", .{}) orelse return error.PoolInitFailed;
        errdefer objc.msgSend(void, pool, "drain", .{});
        const device = metal.Device.createSystemDefault() orelse return error.SkipZigTest;
        errdefer device.release();
        const queue = try device.newCommandQueue();
        errdefer queue.release();

        var cube = TestCube.init();
        var gun = TestGun.init();
        var world_rgba = [4]u8{ 255, 255, 255, 255 };
        var gun_rgba = [4]u8{ 255, 255, 255, 255 };
        var static = try StaticResources.init(
            device,
            .{ .vertices = &cube.vertices, .indices = &cube.indices },
            .{ .vertices = &gun.vertices, .indices = &gun.indices },
            .{ .width = 1, .height = 1, .rgba = &world_rgba },
            .{ .width = 1, .height = 1, .rgba = &gun_rgba },
        );
        errdefer static.deinit();
        const renderer = try Renderer.init(device, queue, static, 16);
        return .{ .pool = pool, .device = device, .queue = queue, .renderer = renderer };
    }

    fn deinit(self: *TestRig) void {
        self.renderer.deinit();
        self.queue.release();
        self.device.release();
        objc.msgSend(void, self.pool, "drain", .{});
    }

    /// Writes instance `index` the way systems.buildInstances does: `model`, its MVP and light MVP
    /// for `frame`, and the hit timer.
    fn setInstance(self: *TestRig, frame: FrameData, index: usize, model: Mat4, hit_timer: f32) void {
        const instances = self.renderer.instances;
        instances.mvps()[index] = frame.view_proj.mul(model);
        instances.models()[index] = model;
        instances.shadowMvps()[index] = frame.light_view_proj.mul(model);
        instances.hitTimers()[index] = hit_timer;
    }

    /// Encodes `frame` into a fresh `width` x `height` BGRA8 target, waits for the GPU and copies the
    /// pixels (BGRA, row 0 at the top) into `pixels`.
    fn render(self: *TestRig, frame: FrameData, width: u64, height: u64, pixels: []u8) !void {
        std.debug.assert(pixels.len == width * height * 4);
        // Shared, so getBytes can read it back once the GPU is done.
        const usage: metal.TextureUsage = .{ .render_target = true, .shader_read = true };
        const target = try self.device.newTexture2D(COLOR_FORMAT, width, height, usage, .shared);
        defer target.release();
        const cmd = try self.queue.commandBuffer();
        try self.renderer.encodeFrame(cmd, target.handle, frame);
        try commitAndWait(cmd);
        target.getBytes(pixels.ptr, width * 4, .rect2D(width, height));
    }

    /// Encodes `frame` into a fresh `width` x `height` target through a command buffer that keeps no
    /// references, inside its own autorelease pool, and waits for the GPU. Afterwards only the
    /// renderer (and whatever the caller retained) still holds the attachments, so retain counts
    /// show what the renderer owns.
    fn renderUnretained(self: *TestRig, frame: FrameData, width: u64, height: u64) !void {
        const pool = AutoreleasePool.init();
        defer pool.deinit();
        const usage: metal.TextureUsage = .{ .render_target = true, .shader_read = true };
        const target = try self.device.newTexture2D(COLOR_FORMAT, width, height, usage, .shared);
        defer target.release(); // runs after the wait: an unretained command buffer does not keep it alive
        const handle = objc.msgSend(?objc.Object, self.queue.handle, "commandBufferWithUnretainedReferences", .{}) orelse
            return error.MetalCreateFailed;
        const cmd: metal.CommandBuffer = .{ .handle = handle };
        try self.renderer.encodeFrame(cmd, target.handle, frame);
        try commitAndWait(cmd);
    }
};

/// Returns `obj`'s retain count; only the change across one operation means anything.
fn retainCount(obj: objc.Object) u64 {
    return objc.msgSend(u64, obj, "retainCount", .{});
}

/// Returns the storage mode a buffer or texture was created with.
fn storageModeOf(resource: objc.Object) metal.StorageMode {
    return @fromBackingInt(objc.msgSend(u64, resource, "storageMode", .{}));
}

/// Commits `cmd`, waits for it and fails unless the GPU completed it without an error.
fn commitAndWait(cmd: metal.CommandBuffer) !void {
    cmd.commit();
    cmd.waitUntilCompleted();
    if (objc.msgSend(?objc.Object, cmd.handle, "error", .{})) |err| {
        const description = objc.msgSend(?objc.Object, err, "localizedDescription", .{}) orelse return error.CommandBufferFailed;
        std.debug.print("command buffer failed: {s}\n", .{objc.fromNSString(description)});
        return error.CommandBufferFailed;
    }
    try testing.expectEqual(COMMAND_BUFFER_STATUS_COMPLETED, objc.msgSend(u64, cmd.handle, "status", .{}));
}

/// A frame as main.zig builds one: 45° perspective for a square target, the sun's orthographic
/// shadow light, a black clear colour, no hit marker, and the gun hidden behind the camera.
fn testFrame(eye: Vec3, target: Vec3, up: Vec3, instance_count: u32) FrameData {
    const proj = Mat4.perspective(TEST_FOV_Y, 1, 0.1, 200);
    const light_view = Mat4.lookAt(TEST_SUN_POS, TEST_SUN_TARGET, .init(0, 1, 0));
    const light_proj = Mat4.orthographic(-30, 30, -30, 30, 0.1, 60);
    const sun = TEST_SUN_POS.normalize();
    return .{
        .view_proj = proj.mul(Mat4.lookAt(eye, target, up)),
        .proj = proj,
        .light_view_proj = light_proj.mul(light_view),
        .light = .{
            .light_pos = .{ TEST_SUN_POS.x, TEST_SUN_POS.y, TEST_SUN_POS.z },
            .view_pos = .{ eye.x, eye.y, eye.z },
            .light_color = TEST_LIGHT_COLOR,
            .ambient_strength = 0.15,
            .specular_strength = 0.5,
            .shininess = 32,
        },
        .sky = .{ .sun_dir = .{ sun.x, sun.y, sun.z, 0 } },
        .instance_count = instance_count,
        .gun_model = GUN_HIDDEN,
        .crosshair = .{ .aspect = 1, .hit_marker = 0 },
        .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 },
    };
}

/// The point where the centre of pixel (x, y) of a `size`-pixel square testFrame target meets the
/// plane z = `plane_z`, for a camera at `eye` looking down -z with +y up.
fn pixelOnPlaneZ(eye: Vec3, size: f32, x: f32, y: f32, plane_z: f32) Vec3 {
    const tan_half = @tan(TEST_FOV_Y / 2);
    const ndc_x = (x + 0.5) / size * 2 - 1;
    const ndc_y = 1 - (y + 0.5) / size * 2;
    const dir = Vec3.init(ndc_x * tan_half, ndc_y * tan_half, -1);
    return eye.add(dir.scale(eye.z - plane_z));
}

/// The ground point under the centre of pixel (x, y) of a `size`-pixel square testFrame target, for
/// a camera at `eye` looking straight down with screen up = -z (so screen right = +x).
fn pixelOnGround(eye: Vec3, size: f32, x: f32, y: f32) Vec3 {
    const tan_half = @tan(TEST_FOV_Y / 2);
    const ndc_x = (x + 0.5) / size * 2 - 1;
    const ndc_y = 1 - (y + 0.5) / size * 2;
    const height = eye.y - geometry.GROUND_Y;
    return .init(eye.x + ndc_x * tan_half * height, geometry.GROUND_Y, eye.z - ndc_y * tan_half * height);
}

/// skybox_fragment's gradient (no sun term) for a unit view direction with this y component.
fn expectedSky(y: f32) [3]f32 {
    const horizon = [3]f32{ 0.6, 0.7, 0.85 };
    const end = if (y > 0) [3]f32{ 0.15, 0.25, 0.55 } else [3]f32{ 0.2, 0.2, 0.18 };
    const t = if (y > 0) std.math.pow(f32, y, 0.4) else std.math.pow(f32, @min(-y, 1), 0.5);
    var out: [3]f32 = undefined;
    for (&out, horizon, end) |*o, a, b| o.* = a + (b - a) * t;
    return out;
}

/// fragment_main for an UNSHADOWED fragment at `p` with normal `n`, viewed from `eye`, under the
/// testFrame light, with a white texture and vertex colour `albedo`.
fn expectedLit(p: Vec3, n: Vec3, eye: Vec3, albedo: [3]f32) [3]f32 {
    const light_dir = TEST_SUN_POS.sub(p).normalize();
    const view_dir = eye.sub(p).normalize();
    const diffuse = @max(n.dot(light_dir), 0);
    const specular = std.math.pow(f32, @max(n.dot(light_dir.add(view_dir).normalize()), 0), 32);
    const intensity = 0.15 + diffuse + 0.5 * specular;
    var out: [3]f32 = undefined;
    for (&out, TEST_LIGHT_COLOR, albedo) |*o, light, a| o.* = intensity * light * a;
    return out;
}

/// Returns pixel (x, y) of a BGRA8 image `width` pixels wide as RGB bytes.
fn rgbAt(pixels: []const u8, width: usize, x: usize, y: usize) [3]u8 {
    const p = pixels[(y * width + x) * 4 ..][0..4];
    return .{ p[2], p[1], p[0] };
}

/// Fails unless pixel (x, y) is within `tolerance` of the linear colour `expected` (unorm8, no sRGB).
fn expectRgbNear(pixels: []const u8, width: usize, x: usize, y: usize, expected: [3]f32, tolerance: u8) !void {
    const actual = rgbAt(pixels, width, x, y);
    for (actual, expected) |a, e| {
        const want: u8 = @round(std.math.clamp(e, 0, 1) * 255);
        if (@max(a, want) - @min(a, want) > tolerance) {
            std.debug.print("pixel ({d},{d}) is RGB {any}, expected about {any} +-{d}\n", .{ x, y, actual, expected, tolerance });
            return error.TestUnexpectedResult;
        }
    }
}

test "offscreen frame: sky gradient on top, lit instanced cubes, the hit flash, nothing left black" {
    var rig = try TestRig.init();
    defer rig.deinit();

    const eye = Vec3.init(0, 0, 6);
    const frame = testFrame(eye, Vec3.zero, .init(0, 1, 0), 2);
    rig.setInstance(frame, 0, Mat4.translation(-1.2, 0, 0), 0);
    rig.setInstance(frame, 1, Mat4.translation(1.2, 0, 0), 1);

    const size = 64;
    var pixels: [size * size * 4]u8 = undefined;
    try rig.render(frame, size, size, &pixels);

    // Top centre: the sky (the sun is behind the camera, so no disc or glow; the sun-disc test below
    // covers those).
    const top_dir = pixelOnPlaneZ(eye, size, 32, 0, eye.z - 1).sub(eye).normalize();
    try expectRgbNear(&pixels, size, 32, 0, expectedSky(top_dir.y), 3);

    // Instance 0: the front face (z = 0.5) of the left cube, unshadowed Blinn-Phong on white.
    const left = pixelOnPlaneZ(eye, size, 15, 32, 0.5);
    try expectRgbNear(&pixels, size, 15, 32, expectedLit(left, .init(0, 0, 1), eye, .{ 1, 1, 1 }), 4);

    // Instance 1 (hit timer 1): the same lighting mixed 70% towards the flash red.
    const right = pixelOnPlaneZ(eye, size, 48, 32, 0.5);
    var flashed = expectedLit(right, .init(0, 0, 1), eye, .{ 1, 1, 1 });
    for (&flashed, [3]f32{ 1, 0.2, 0.2 }) |*c, flash| c.* += (flash - c.*) * 0.7;
    try expectRgbNear(&pixels, size, 48, 32, flashed, 4);

    // The sky box surrounds the camera, so no pixel keeps the black clear colour.
    for (0..size) |y| {
        for (0..size) |x| try testing.expect(!std.meta.eql(rgbAt(&pixels, size, x, y), .{ 0, 0, 0 }));
    }
}

test "offscreen frame: a cube's shadow falls on the ground through the shadow map" {
    var rig = try TestRig.init();
    defer rig.deinit();

    // The light's axis carries a cube at (0, -6, 0) onto the ground at (-2.4, GROUND_Y, -4.8); the
    // camera looks straight down at that point (screen up = -z).
    const eye = Vec3.init(-2.4, 10, -4.8);
    const frame = testFrame(eye, .init(-2.4, geometry.GROUND_Y, -4.8), .init(0, 0, -1), 1);
    rig.setInstance(frame, 0, Mat4.translation(0, -6, 0), 0);

    const size = 64;
    var pixels: [size * size * 4]u8 = undefined;
    try rig.render(frame, size, size, &pixels);

    // Centre: ground fully in shadow, so only ambient · light colour · ground colour remains.
    const ground_color = geometry.ground_vertices[0].color;
    var ambient: [3]f32 = undefined;
    for (&ambient, TEST_LIGHT_COLOR, ground_color[0..3]) |*c, light, g| c.* = 0.15 * light * g;
    try expectRgbNear(&pixels, size, 32, 32, ambient, 2);

    // About 7 units further along -z, clear of the shadow: the ground is lit, several times brighter.
    const lit = rgbAt(&pixels, size, 32, 6);
    try testing.expect(lit[1] > 60);
}

test "offscreen frame: shadowCalc's edge rules: shadowed past the light's far plane, lit outside its footprint" {
    var rig = try TestRig.init();
    defer rig.deinit();

    // No instances, so the shadow map holds only its 1.0 clear (the shadow pass culls the ground).
    // Each camera looks straight down at one ground point (screen up = -z).
    const Case = struct { x: f32, z: f32, shadowed: bool };
    const cases = [_]Case{
        // Inside the light's x/y footprint but past its far plane (light NDC z ~1.02, beyond far plus
        // the 0.005 bias): every tap beats the 1.0 clear, so it is shadowed (the original's dark band).
        // A `z > 1 -> lit` rule would light it.
        .{ .x = -20, .z = -38, .shadowed = true },
        // Past the far plane as well (z ~1.22) but outside the footprint (uv.y ~ -0.06): lit, because
        // the footprint test returns before any tap. Without it the clamped taps would shadow it.
        .{ .x = -45, .z = -45, .shadowed = false },
        // Outside the footprint on the light's near side (uv.y ~1.27): lit.
        .{ .x = 45, .z = 30, .shadowed = false },
    };
    const ground_color = geometry.ground_vertices[0].color[0..3].*;
    var ambient: [3]f32 = undefined;
    for (&ambient, TEST_LIGHT_COLOR, ground_color) |*c, light, g| c.* = 0.15 * light * g;

    const size = 64;
    var pixels: [size * size * 4]u8 = undefined;
    for (cases) |case| {
        const eye = Vec3.init(case.x, 10, case.z);
        try rig.render(testFrame(eye, .init(case.x, geometry.GROUND_Y, case.z), .init(0, 0, -1), 0), size, size, &pixels);
        if (case.shadowed) {
            try expectRgbNear(&pixels, size, 32, 32, ambient, 2);
        } else {
            const ground = pixelOnGround(eye, size, 32, 32);
            try expectRgbNear(&pixels, size, 32, 32, expectedLit(ground, .init(0, 1, 0), eye, ground_color), 4);
        }
    }
}

test "offscreen frame: the sky draws the sun disc where SkyUniforms.sun_dir points" {
    var rig = try TestRig.init();
    defer rig.deinit();

    // Looking along normalize(TEST_SUN_POS): pixel (32, 32) is about 0.5 degrees off that axis, so it
    // shows the full disc (1, 0.95, 0.8) plus 0.3 x glow (1, 0.8, 0.4), which saturates to ~(1, 1, 0.92).
    const sun = TEST_SUN_POS.normalize();
    const eye = Vec3.init(0, 0, 6);
    var frame = testFrame(eye, eye.add(sun), .init(0, 1, 0), 0);
    const size = 64;
    var pixels: [size * size * 4]u8 = undefined;
    try rig.render(frame, size, size, &pixels);
    try expectRgbNear(&pixels, size, 32, 32, .{ 1, 1, 0.92 }, 3);

    // Same view, sun uniform pointed straight up: no disc and no visible glow there any more, just
    // the gradient (0.5 degrees off sun.y moves it by less than one 8-bit step), so the disc follows
    // the uniform rather than a direction baked into the shader.
    frame.sky.sun_dir = .{ 0, 1, 0, 0 };
    try rig.render(frame, size, size, &pixels);
    try expectRgbNear(&pixels, size, 32, 32, expectedSky(sun.y), 3);
}

test "encodeFrame draws at most the instance buffers' capacity" {
    var rig = try TestRig.init();
    defer rig.deinit();
    const instances = &rig.renderer.instances;
    const buffer_slots = instances.capacity;
    const half = buffer_slots / 2;

    // The first half of the slots holds a cube on the left, the second half a cube on the right.
    var frame = testFrame(.init(0, 0, 6), Vec3.zero, .init(0, 1, 0), buffer_slots);
    for (0..buffer_slots) |i| rig.setInstance(frame, i, Mat4.translation(if (i < half) -1.2 else 1.2, 0, 0), 0);
    const size = 32;
    var both: [size * size * 4]u8 = undefined;
    try rig.render(frame, size, size, &both);

    // Then claim only the first half as the capacity. An over-long count that got past the clamp
    // would draw the right cube from the second half, which the GPU can still read. (Reading past a
    // buffer's real end would prove nothing: on the M3 such reads drew nothing, even under shader
    // validation.)
    instances.capacity = half;
    defer instances.capacity = buffer_slots;
    frame.instance_count = half;
    var left: [size * size * 4]u8 = undefined;
    try rig.render(frame, size, size, &left);
    try testing.expect(!std.mem.eql(u8, &both, &left)); // the right cube shows whenever it is drawn

    frame.instance_count = buffer_slots;
    var clamped: [size * size * 4]u8 = undefined;
    try rig.render(frame, size, size, &clamped);
    try testing.expectEqualSlices(u8, &left, &clamped);
}

test "offscreen frame: the gun draws over nearer world geometry and occludes itself" {
    var rig = try TestRig.init();
    defer rig.deinit();

    // The cube's front face is 1.0 in front of the eye and fills the view; the gun's quads sit behind
    // it in true depth, at 1.2 (green, drawn first) and 1.4 (blue, drawn last).
    const eye = Vec3.init(0, 0, 1.5);
    var frame = testFrame(eye, Vec3.zero, .init(0, 1, 0), 1);
    frame.gun_model = Mat4.translation(0, 0, -1.3);
    rig.setInstance(frame, 0, Mat4.identity, 0);

    const size = 64;
    var pixels: [size * size * 4]u8 = undefined;
    try rig.render(frame, size, size, &pixels);

    // Centre: the green quad, lit as the original lights the gun (view space standing in for world).
    // Without the depth split the cube would cover it; under Always + write the blue quad would.
    const gun_point = pixelOnPlaneZ(Vec3.zero, size, 32, 32, -1.2);
    try expectRgbNear(&pixels, size, 32, 32, expectedLit(gun_point, .init(0, 0, 1), eye, .{ 0, 1, 0 }), 4);

    // Beyond the quads: the cube's lit front face.
    const face = pixelOnPlaneZ(eye, size, 32, 4, 0.5);
    try expectRgbNear(&pixels, size, 32, 4, expectedLit(face, .init(0, 0, 1), eye, .{ 1, 1, 1 }), 4);
}

test "offscreen frame: crosshair arms always, the hit marker only while its timer runs, x scaled by aspect" {
    var rig = try TestRig.init();
    defer rig.deinit();

    // 1024² so the 0.003-NDC-thick arms cover whole pixels: pixel (520, 511) sits on the right arm
    // (x = 0.0166 NDC), pixel (520, 503) on the hit marker's top-right diagonal (x = y = 0.0166 NDC).
    const size = 1024;
    const pixels = try testing.allocator.alloc(u8, size * size * 4);
    defer testing.allocator.free(pixels);
    const white = [3]u8{ 255, 255, 255 };
    // No instances: also exercises the frame that skips both instanced draws.
    var frame = testFrame(.init(0, 0, 6), Vec3.zero, .init(0, 1, 0), 0);

    try rig.render(frame, size, size, pixels);
    try testing.expectEqual(white, rgbAt(pixels, size, 520, 511));
    try testing.expect(!std.meta.eql(white, rgbAt(pixels, size, 520, 503)));

    frame.crosshair.hit_marker = 1;
    try rig.render(frame, size, size, pixels);
    try testing.expectEqual(white, rgbAt(pixels, size, 520, 503));

    // Aspect 2 halves every x: the right arm now ends inside x = 0.0166 NDC.
    frame.crosshair = .{ .aspect = 2, .hit_marker = 0 };
    try rig.render(frame, size, size, pixels);
    try testing.expect(!std.meta.eql(white, rgbAt(pixels, size, 520, 511)));
    try testing.expectEqual(white, rgbAt(pixels, size, 515, 511));
}

test "encodeFrame keeps the depth target while the size holds and replaces it on resize" {
    var rig = try TestRig.init();
    defer rig.deinit();
    const frame = testFrame(.init(0, 0, 6), Vec3.zero, .init(0, 1, 0), 0);
    try testing.expectEqual(null, rig.renderer.depth);

    var square: [64 * 64 * 4]u8 = undefined;
    try rig.render(frame, 64, 64, &square);
    const first = rig.renderer.depth orelse return error.TestUnexpectedResult;
    try testing.expectEqual(64, rig.renderer.depth_width);
    try testing.expectEqual(64, rig.renderer.depth_height);
    // GPU-only depth targets; CPU-visible albedo textures (replaceRegion needs that).
    try testing.expectEqual(.private, storageModeOf(first.handle));
    try testing.expectEqual(.private, storageModeOf(rig.renderer.shadow_map.handle));
    try testing.expectEqual(.shared, storageModeOf(rig.renderer.resources.world_texture.handle));
    try testing.expectEqual(.shared, storageModeOf(rig.renderer.resources.gun_texture.handle));
    try rig.render(frame, 64, 64, &square);
    try testing.expectEqual(first.handle, (rig.renderer.depth orelse return error.TestUnexpectedResult).handle);

    var wide: [48 * 32 * 4]u8 = undefined;
    try rig.render(frame, 48, 32, &wide);
    const second = rig.renderer.depth orelse return error.TestUnexpectedResult;
    try testing.expect(second.handle != first.handle);
    try testing.expectEqual(48, rig.renderer.depth_width);
    try testing.expectEqual(32, rig.renderer.depth_height);
    try testing.expectEqual(48, second.width());
    try testing.expectEqual(32, second.height());
    // The resized frame still renders: its top centre is sky, not the black clear colour.
    try testing.expect(!std.meta.eql(rgbAt(&wide, 48, 24, 0), .{ 0, 0, 0 }));
}

test "encodeFrame releases the depth target it replaces, and deinit releases the last one" {
    var rig = try TestRig.init();
    var rig_live = true;
    defer if (rig_live) rig.deinit();
    const frame = testFrame(.init(0, 0, 6), Vec3.zero, .init(0, 1, 0), 0);

    // Our own retain keeps each texture alive to be counted; the renderer holds the other reference.
    try rig.renderUnretained(frame, 64, 64);
    const first = objc.retain((rig.renderer.depth orelse return error.TestUnexpectedResult).handle);
    defer objc.release(first);
    const first_held = retainCount(first);
    try rig.renderUnretained(frame, 48, 32); // a new size: a new depth target
    try testing.expectEqual(first_held - 1, retainCount(first));

    const last = objc.retain((rig.renderer.depth orelse return error.TestUnexpectedResult).handle);
    defer objc.release(last);
    try testing.expect(last != first);
    const last_held = retainCount(last);
    rig_live = false;
    rig.deinit();
    try testing.expectEqual(last_held - 1, retainCount(last));
}

test "drawFrame renders into a CAMetalLayer drawable and commits it" {
    var rig = try TestRig.init();
    defer rig.deinit();

    // A layer outside any window still vends drawables (no window server needed); framebufferOnly
    // NO lets a blit read the drawable back.
    const layer = objc.msgSend(?objc.Object, objc.class("CAMetalLayer"), "layer", .{}) orelse return error.SkipZigTest;
    objc.msgSend(void, layer, "setDevice:", .{rig.device.handle});
    objc.msgSend(void, layer, "setPixelFormat:", .{@backingInt(COLOR_FORMAT)});
    objc.msgSend(void, layer, "setFramebufferOnly:", .{false});
    const size = 64;
    objc.msgSend(void, layer, "setDrawableSize:", .{objc.CGSize{ .width = size, .height = size }});
    // Autoreleased into the rig's pool, so the drawable and its texture outlive the readback below.
    const drawable = objc.msgSend(?objc.Object, layer, "nextDrawable", .{}) orelse return error.SkipZigTest;
    const texture = objc.msgSend(?objc.Object, drawable, "texture", .{}) orelse return error.TestUnexpectedResult;

    const eye = Vec3.init(0, 0, 6);
    try rig.renderer.drawFrame(drawable, testFrame(eye, Vec3.zero, .init(0, 1, 0), 0));
    try testing.expectEqual(size, rig.renderer.depth_width);
    try testing.expectEqual(size, rig.renderer.depth_height);

    // A later command buffer on the same queue copies the drawable out. It sees the frame only if
    // drawFrame committed it: a buffer that is never committed never runs. (The present itself has
    // no visible effect on a layer outside any window, which is also why nothing recycles the
    // drawable before this copy.)
    const copy = try rig.device.newTexture2D(COLOR_FORMAT, size, size, .{ .shader_read = true }, .shared);
    defer copy.release();
    const cmd = try rig.queue.commandBuffer();
    const blit = objc.msgSend(?objc.Object, cmd.handle, "blitCommandEncoder", .{}) orelse return error.TestUnexpectedResult;
    objc.msgSend(void, blit, "copyFromTexture:toTexture:", .{ texture, copy.handle });
    objc.msgSend(void, blit, "endEncoding", .{});
    try commitAndWait(cmd);

    var pixels: [size * size * 4]u8 = undefined;
    copy.getBytes(&pixels, size * 4, .rect2D(size, size));
    const top_dir = pixelOnPlaneZ(eye, size, 32, 0, eye.z - 1).sub(eye).normalize();
    try expectRgbNear(&pixels, size, 32, 0, expectedSky(top_dir.y), 3);
}
