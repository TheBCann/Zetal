//! Rendering and GPU compute: Metal wrappers, shared GPU layouts, pipelines, the frame renderer and the physics kernels.

// Every file in this directory, pub-imported so src/root.zig's test discovery reaches it.

/// Thin typed Metal wrappers (device, queue, encoders, buffers, textures) and the SDK enums.
pub const metal = @import("metal.zig");
/// GPU physics buffer structs, byte for byte those of shaders/physics.msl.
pub const physics_layout = @import("physics_layout.zig");
/// The vertex layout and the built-in ground, skybox and crosshair geometry.
pub const geometry = @import("geometry.zig");
/// Uniform blocks of the scene and crosshair shaders.
pub const uniforms = @import("uniforms.zig");
/// Render pipelines, depth states, binding slots and the generated shader sources.
pub const pipelines = @import("pipelines.zig");
/// Static GPU meshes and textures, and the per-instance buffers.
pub const resources = @import("resources.zig");
/// The two-pass (shadow + main) frame renderer.
pub const renderer = @import("renderer.zig");
/// GPU compute physics: integration, AABBs and the spatial-hash broad phase.
pub const physics = @import("physics.zig");

/// Draws frames: shadow pass, then sky, world, gun and crosshair.
pub const Renderer = renderer.Renderer;
/// Everything one frame needs besides the static resources and the instance buffers.
pub const FrameData = renderer.FrameData;
/// GPU rigid-body physics for one World.
pub const ComputePhysics = physics.ComputePhysics;
/// Geometry and textures uploaded once at startup.
pub const StaticResources = resources.StaticResources;
/// The per-instance matrices and hit timers of the instanced cube draws.
pub const InstanceBuffers = resources.InstanceBuffers;
/// One mesh vertex, laid out like the MSL `Vertex`.
pub const Vertex = geometry.Vertex;
