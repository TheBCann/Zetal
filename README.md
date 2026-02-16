# Zetal Engine

A from-scratch 3D game engine for macOS written in **Zig**, targeting the **Metal API** directly through the Objective-C runtime. No GLFW, no SDL, no bindings — just Zig talking to the system.

## Features

**Rendering**

- Direct Metal API access via Objective-C runtime calls
- Instanced rendering (100+ objects in a single draw call)
- Blinn-Phong lighting (ambient, diffuse, specular)
- Shadow mapping with 2048×2048 depth texture and 3×3 PCF filtering
- Retina-aware rendering with dynamic window resize and fullscreen support
- Depth buffering with `Depth32Float` textures
- Runtime MSL shader compilation

**Engine**

- Entity Component System with parallel arrays and bitmask queries
- Components: Transform, Spin, Velocity, MeshRenderer, Collider
- Systems: spin, velocity, collision detection, rendering
- AABB collision detection with minimum translation vector resolution
- Camera-world collision (camera can't pass through objects)
- Ground plane with tiled texturing

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

```
zig build run
```

```
zig build test --summary all
```

## Project Structure

```
src/
├── main.zig          Game loop, camera, two-pass rendering
├── root.zig          Metal API wrappers (Device, Buffer, Texture, CommandQueue)
├── engine.zig        Core engine (window setup, shadow pass, main pass, resize)
├── window.zig        AppKit windowing, event polling, MetalView
├── objc.zig          Objective-C runtime FFI
├── ecs.zig           Entity Component System (entities, components, AABB)
├── systems.zig       ECS systems (spin, velocity, collision, render)
├── scene.zig         Entity spawning helpers
├── loader.zig        OBJ model loader
├── texture.zig       PPM texture loader
└── render/
    ├── root.zig      Render module exports
    ├── math.zig      Mat4x4, Vec3, perspective, ortho, lookAt
    ├── pipeline.zig  Render pipeline and depth stencil descriptors
    ├── pass.zig      Render pass descriptor and command encoder
    ├── shader.zig    MSL source (Blinn-Phong, shadow pass, instanced + single)
    ├── vertex.zig    Vertex struct and geometry data
    └── types.zig     Metal enum types
```

## Roadmap

### Done

- [x] System default Metal device
- [x] Native AppKit window
- [x] Runtime MSL shader compilation
- [x] Triangle and 3D geometry rendering
- [x] 3D transformations (uniform buffers, matrix math)
- [x] Depth buffering
- [x] Keyboard and mouse input
- [x] FPS camera (WASD + mouse look)
- [x] Texture mapping (PPM)
- [x] Model loading (OBJ)
- [x] Instanced rendering
- [x] Entity Component System
- [x] AABB collision detection
- [x] Camera-world collision
- [x] Ground plane
- [x] Blinn-Phong lighting
- [x] Shadow mapping (PCF)
- [x] Dynamic window resize / fullscreen

### Next

- [ ] Spatial partitioning (octree/BVH) for collision broad phase
- [ ] Multiple textures / materials per entity
- [ ] Normal mapping
- [ ] Skybox
- [ ] Animation system
- [ ] Audio integration
- [ ] UI system
