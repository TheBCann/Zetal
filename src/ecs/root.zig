<<<<<<< HEAD
//! Entity-component system: the parallel-array World and the systems that run over it.

// Every file in this directory, pub-imported so src/root.zig's test discovery reaches it.

/// Entities, components, masks, AABBs and the World container.
pub const world = @import("world.zig");
/// The per-frame rules: spin, hit flash, hitscan, projectile lifetime, collision response, floor,
/// cleanup, camera collision and the instance build.
pub const systems = @import("systems.zig");

/// Fixed-capacity entity store: one array per component plus a bitmask per slot.
pub const World = world.World;
/// An entity: a slot index into the World's arrays.
pub const Entity = world.Entity;
/// Slot capacity of a World (also the GPU physics and instance buffer capacity).
pub const MAX_ENTITIES = world.MAX_ENTITIES;
/// Component kinds; each tag is the component's bit index in a ComponentMask.
pub const Component = world.Component;
/// One bit per Component.
pub const ComponentMask = world.ComponentMask;
/// The mask bit of one component.
pub const bit = world.bit;
/// The union of several components' bits (comptime-callable).
pub const mask = world.mask;
/// True when a mask has every required bit.
pub const hasMask = world.hasMask;
||||||| empty tree
=======
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
>>>>>>> Zetal/main
