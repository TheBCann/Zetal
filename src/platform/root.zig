<<<<<<< HEAD
//! Platform layer: NSApplication and input, the game window, autorelease pools and NSSound playback.

// Every file in this directory, pub-imported so src/root.zig's test discovery reaches it.

/// NSApplication bootstrap, the per-frame event pump and the `Input` state it fills.
pub const app = @import("app.zig");
/// The NSWindow + MTKView the game renders into.
pub const window = @import("window.zig");
/// NSAutoreleasePool scopes.
pub const autorelease = @import("autorelease.zig");
/// NSSound effects.
pub const sound = @import("sound.zig");

/// The shared NSApplication plus the input its events feed.
pub const App = app.App;
/// Keyboard and mouse state, rebuilt from events every frame.
pub const Input = app.Input;
/// Virtual key codes the game reads by name.
pub const KeyCode = app.KeyCode;
/// The mouse buttons `Input` tracks.
pub const MouseButton = app.MouseButton;
/// The game's only window.
pub const Window = window.Window;
/// One NSAutoreleasePool scope.
pub const AutoreleasePool = autorelease.AutoreleasePool;
/// One loaded sound file.
pub const Sound = sound.Sound;
||||||| empty tree
=======
pub const window = @import("window.zig");
pub const engine = @import("engine.zig");
pub const autoreleasepool = @import("autoreleasepool.zig");

pub const AutoreleasePool = autoreleasepool.AutoreleasePool;
>>>>>>> Zetal/main
