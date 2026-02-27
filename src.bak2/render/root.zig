pub const types = @import("types.zig");
pub const pass = @import("pass.zig");
pub const pipeline = @import("pipeline.zig");
pub const vertex = @import("vertex.zig");
pub const shader = @import("shader.zig");
pub const math = @import("math.zig");
pub const device = @import("device.zig");
pub const skybox = @import("skybox.zig");

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
