//! Game layer: scene construction (the shooting gallery) and the first-person player.

// Every file in this directory, pub-imported so src/root.zig's test discovery reaches it.

/// Spawn helpers, the shooting gallery and the legacy cube field.
pub const scene = @import("scene.zig");
/// The FPS controller: look, move, jump, projectile fire, shake, hit marker, gun viewmodel.
pub const player = @import("player.zig");

/// The first-person player.
pub const Player = player.Player;
/// One frame's camera matrices.
pub const Camera = player.Camera;
