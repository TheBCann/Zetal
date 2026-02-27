# Zetal Engine

A from-scratch 3D game engine for macOS written in **Zig**, targeting the **Metal API** directly through the Objective-C runtime. No GLFW, no SDL, no bindings — just Zig talking to the system.

## Features

**Rendering**

- Direct Metal API access via Objective-C runtime calls
- Instanced rendering (100+ objects in a single draw call)
- GPU Compute Physics Pipeline (Metal compute kernels for parallel velocity integration and AABB broad-phase collision)
- Blinn-Phong lighting (ambient, diffuse, specular)
- Shadow mapping with 2048×2048 depth texture and 3×3 PCF filtering
- Procedural skybox with atmospheric gradient and directional sun disc
- Retina-aware rendering with dynamic window resize and fullscreen support
- Depth buffering with `Depth32Float` textures
- MSL shaders compiled natively at runtime via `@embedFile`

**Engine**

- Entity Component System with parallel arrays and bitmask queries
- Components: Transform, Spin, Velocity, MeshRenderer, Collider
- Systems: GPU compute dispatch, CPU collision response, rendering
- Zero-copy CPU/GPU memory sharing via `StorageModeShared` on Apple Silicon
- AABB collision detection with minimum translation vector resolution and bounce physics
- Camera-world collision (camera can't pass through objects)
- Ground plane with tiled texturing and floor enforcement

**Windowing & Input**

- Native `NSApplication` / `NSWindow` via Objective-C runtime
- FPS camera with mouse look and WASD + Q/E vertical movement
- Keyboard and mouse delta event polling

**Assets**

- OBJ mesh loading
- PPM texture loading
- Custom 3D math library (4×4 matrices, vectors, perspective/orthographic projection, lookAt)

## Build & Run

Requires **Zig Nightly** (tested on 0.16.0-dev).

```bash
zig build run
```
