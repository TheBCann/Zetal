// ============================================================
// Zetal Engine — Module Root
// ============================================================

pub const objc = @import("objc.zig");
pub const platform = @import("platform/root.zig");
pub const render = @import("render/root.zig");
pub const ecs = @import("ecs/root.zig");
pub const assets = @import("assets/root.zig");
pub const scene = @import("scene.zig");
pub const player = @import("player.zig");

pub const Player = player.Player;
pub const Camera = player.Camera;
pub const AutoreleasePool = platform.AutoreleasePool;

// --- Convenience re-exports ---
pub const engine = platform.engine;
pub const window = platform.window;
pub const loader = assets.loader;
pub const texture = assets.texture;
pub const systems = ecs.systems;

// --- Device type re-exports ---
pub const MetalDevice = render.device.MetalDevice;
pub const MetalBuffer = render.device.MetalBuffer;
pub const MetalTexture = render.device.MetalTexture;
pub const MetalLibrary = render.device.MetalLibrary;
pub const MetalCommandBuffer = render.device.MetalCommandBuffer;
pub const MetalCommandQueue = render.device.MetalCommandQueue;
pub const MTLRegion = render.device.MTLRegion;
pub const MTLOrigin = render.device.MTLOrigin;
pub const MTLSize = render.device.MTLSize;
pub const MTLResourceOptions = render.device.MTLResourceOptions;

test {
    @import("std").testing.refAllDecls(render.math);
    @import("std").testing.refAllDecls(window);
    _ = ecs.world;
    _ = ecs.systems;
    _ = player;
}
