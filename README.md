# Zetal Engine

A from-scratch 3D game engine for macOS written in **Zig**, targeting the
**Metal API** directly through the Objective-C runtime. No GLFW, no SDL,
no bindings — just Zig talking to the system.

The engine ships with a playable FPS demo: WASD movement, mouse look,
gravity and jumping, projectile physics with GPU-driven collision, hit
markers, screen shake, weapon viewmodel, and audio.

## Features

### Rendering

- Direct Metal API access via a comptime-typed Objective-C bridge
  (`msgSend(Ret, target, "selector:", .{args})`)
- Multi-pass rendering: shadow map → main scene → viewmodel → UI
- Instanced rendering (100+ objects in a single draw call)
- GPU compute physics pipeline: spatial hash grid broad-phase, parallel
  velocity integration, impact-to-projectile conversion
- Blinn-Phong lighting (ambient, diffuse, specular)
- Shadow mapping with 2048×2048 depth texture and 3×3 PCF filtering
- Procedural skybox with atmospheric gradient and directional sun disc
- Retina-aware rendering with dynamic window resize and fullscreen support
- Depth buffering with `Depth32Float` textures
- MSL shaders compiled natively at runtime via `@embedFile`

### Engine

- Entity Component System with parallel arrays and bitmask queries
- Components: Transform, Spin, Velocity, MeshRenderer, Collider, HitTimer
- Systems: GPU compute dispatch, CPU collision response, hit feedback,
  fallen-entity cleanup, rendering
- Zero-copy CPU/GPU memory sharing via `StorageModeShared` on Apple Silicon
- AABB collision detection with minimum translation vector resolution
  and bounce physics
- Camera-world collision (camera can't pass through objects)
- Player physics: gravity, jumping, ground detection, hard floor

### Gameplay

- FPS camera with mouse look and WASD movement
- Jump (space), with proper grounded-state tracking
- Left-click to fire physics-driven cube projectiles
- Hit detection with crosshair animation and screen shake feedback
- Audio playback via `NSSound` (gunshot SFX)
- Weapon viewmodel with sway, recoil kickback, and dedicated depth state

### Platform

- Native `NSApplication` / `NSWindow` via Objective-C runtime
- Keyboard and mouse delta event polling with typed `NSEventType` dispatch
- Custom 3D math library (4×4 matrices, vectors, perspective/orthographic
  projection, lookAt)

### Assets

- OBJ mesh loading (vertices + indices, supports `.mtl` references)
- PPM texture loading
- WAV audio via `NSSound`

docs: update README to reflect FPS gameplay and bridge refactor

- Document the playable FPS demo: jump, fire, hit detection, audio
- Add Architecture section with directory layout
- Add Controls table for the demo
- Add Status section noting active development and next steps
- Mention the comptime-typed Objective-C bridge as a design choice

## Architecture

The engine is organized into focused modules:


```
```
src/
├── main.zig              # Entry point, render loop, FPS gameplay
├── objc.zig              # Comptime-typed Objective-C bridge
├── scene.zig             # ECS scene composition
├── ecs/                  # Entity-component-system core
├── platform/             # NSWindow, NSApplication, input
├── render/               # Metal wrappers, shaders, math, compute
└── assets/               # OBJ/PPM/WAV loaders
```
```

The Objective-C bridge is the foundation: ...
The Objective-C bridge is the foundation: a single `msgSend(Ret, target,
"selector:", args)` helper builds typed C function pointers at comptime
via `@Fn`, with cached `sel()` and `class()` lookups. Wrong-typed
arguments fail at compile time instead of crashing at runtime — a real
improvement over the typical "cast `objc_msgSend` and pray" pattern.

## Build & Run

Requires **Zig 0.16.0-dev** or later (uses `std.Io`, `@Fn`, `std.process.Init`).

```bash
zig build run
```

For optimized builds:

```bash
zig build run -Doptimize=ReleaseFast
```

## Controls

| Input          | Action               |
|----------------|----------------------|
| W/A/S/D        | Move                 |
| Mouse          | Look                 |
| Space          | Jump                 |
| Left Click     | Fire projectile      |
| Escape         | Quit                 |

## Status

Active development on Zig nightly. Bridge layer recently migrated to a
comptime-typed `msgSend` helper. The next refactor passes will extract
the per-frame logic in `main.zig` into focused modules (Pipelines,
Buffers, Player) and add a proper per-frame autoreleasepool.
