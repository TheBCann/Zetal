pub const types = @import("types.zig");
pub const pass = @import("pass.zig");
pub const pipeline = @import("pipeline.zig");
pub const vertex = @import("vertex.zig");
pub const shader = @import("shader.zig");
pub const math = @import("math.zig");

// Re-export common types for easier access
pub const MTLClearColor = types.MTLClearColor;
pub const MTLLoadAction = types.MTLLoadAction;
pub const MTLStoreAction = types.MTLStoreAction;
pub const MetalRenderPassDescriptor = pass.MetalRenderPassDescriptor;
pub const MetalRenderCommandEncoder = pass.MetalRenderCommandEncoder;
pub const MetalRenderPipelineDescriptor = pipeline.MetalRenderPipelineDescriptor;
pub const MetalRenderPipeLineState = pipeline.MetalRenderPipelineState;
