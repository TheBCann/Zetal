<<<<<<< HEAD
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
||||||| empty tree
=======
pub const types = @import("types.zig");
pub const pass = @import("pass.zig");
pub const pipeline = @import("pipeline.zig");
pub const vertex = @import("vertex.zig");
pub const shader = @import("shader.zig");
pub const math = @import("math.zig");
pub const device = @import("device.zig");
pub const skybox = @import("skybox.zig");
pub const compute = @import("compute.zig");
pub const pipelines = @import("pipelines.zig");
pub const buffers = @import("buffers.zig");
pub const lighting = @import("lighting.zig");

// Re-export common types
pub const MTLClearColor = types.MTLClearColor;
pub const MTLLoadAction = types.MTLLoadAction;
pub const MTLStoreAction = types.MTLStoreAction;
pub const MetalRenderPassDescriptor = pass.MetalRenderPassDescriptor;
pub const MetalRenderCommandEncoder = pass.MetalRenderCommandEncoder;
pub const MetalRenderPipelineDescriptor = pipeline.MetalRenderPipelineDescriptor;
pub const MetalRenderPipelineState = pipeline.MetalRenderPipelineState;

// Re-export device types
pub const MetalDevice = device.MetalDevice;
pub const MetalBuffer = device.MetalBuffer;
pub const MetalTexture = device.MetalTexture;
pub const MetalLibrary = device.MetalLibrary;
pub const MetalCommandBuffer = device.MetalCommandBuffer;
pub const MetalCommandQueue = device.MetalCommandQueue;
pub const MetalFunction = device.MetalFunction;
pub const MTLRegion = device.MTLRegion;
pub const MTLOrigin = device.MTLOrigin;
pub const MTLSize = device.MTLSize;
pub const MTLResourceOptions = device.MTLResourceOptions;
pub const crosshair = @import("crosshair.zig");
>>>>>>> Zetal/main
