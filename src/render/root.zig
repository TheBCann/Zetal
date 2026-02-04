pub const types = @import("types.zig");
pub const pass = @import("pass.zig");

// Re-export common types for easier access
pub const MTLClearColor = types.MTLClearColor;
pub const MTLLoadAction = types.MTLloadAction;
pub const MTLStoreAction = types.MTLStoreAction;
pub const MetalRenderPassDescriptor = pass.MetalRenderPassDescriptor;
pub const MetalRenderCommandEncoder = pass.MetalRenderCommandEncoder;
