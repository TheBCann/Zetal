pub const world = @import("world.zig");
pub const systems = @import("systems.zig");

// Re-export common types
pub const Entity = world.Entity;
pub const World = world.World;
pub const Transform = world.Transform;
pub const Spin = world.Spin;
pub const Velocity = world.Velocity;
pub const MeshRenderer = world.MeshRenderer;
pub const Collider = world.Collider;
pub const ComponentFlags = world.Component;
pub const mask = world.mask;
