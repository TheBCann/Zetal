<<<<<<< HEAD
//! Asset loaders: Wavefront OBJ meshes and binary PPM images.

// Every file in this directory, pub-imported so src/root.zig's test discovery reaches it.

/// OBJ text into an indexed triangle mesh of render vertices.
pub const obj = @import("obj.zig");
/// Binary PPM (P6) into RGBA8 pixels.
pub const ppm = @import("ppm.zig");

/// An indexed triangle mesh (CPU copy).
pub const Mesh = obj.Mesh;
/// An RGBA8 image (CPU copy).
pub const Image = ppm.Image;
||||||| empty tree
=======
pub const loader = @import("loader.zig");
pub const texture = @import("texture.zig");
>>>>>>> Zetal/main
