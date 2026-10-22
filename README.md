<<<<<<< HEAD
# Zetal Engine

A from-scratch 3D game engine for macOS written in **nightly Zig**, driving the **Metal API**
directly through the Objective-C runtime. No GLFW, no SDL, no bindings or wrapper libraries: Zig
talks to AppKit, MetalKit and Metal itself through `objc_msgSend`.

The engine ships with a playable FPS demo, a shooting gallery: left-click fires physical projectiles
that knock the gallery's blocks loose through GPU compute physics, with mouse look, WASD movement,
jumping, screen shake, a hit marker, a gun viewmodel and a gunshot sound.

This is Zetal 0.2, a clean rewrite of the original engine against today's nightly standard library:
the same game and engine features, plus the fixes listed under [What changed in 0.2](#what-changed-in-02).

## Requirements

- macOS with a Metal GPU (developed on an Apple M3 under macOS 26.3).
- Zig nightly `0.18.0-dev.253+16d31ceed` or later (`minimum_zig_version` in `build.zig.zon`). The
  nightly std changes weekly; see [Nightly Zig](#nightly-zig).

## Build, run, test

```bash
zig build                        # library + game executable (zig-out/bin/Zetal)
zig build run                    # build and launch the game
zig build run -Doptimize=fast    # optimized build; `zig build run --release=fast` is equivalent
zig build test                   # every unit test (library and executable)
zig build test --summary all     # the same, with pass counts per test binary
zig build test -Dmetal-validation # the tests under Metal API + shader validation (any Metal warning aborts)
```

`-Dmetal-validation` sets `MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_WARNING_MODE=assert
MTL_SHADER_VALIDATION=1` on the test steps themselves, which puts them in the cache key; prefixing
`zig build test` with those variables would just reuse a cached plain pass. Metal's own "Metal API
Validation Enabled" / "Metal GPU Validation Enabled" lines on stderr are expected. For the smoke run
below, prefix the command with the variables instead (a run with arguments is never cached).

Optimize modes are `debug` (the default), `safe`, `fast` and `small`; the old `ReleaseFast`
spelling still parses but is deprecated.

`zig build run` starts the game with the repository root as its working directory, so `assets/`
resolves no matter where `zig` is invoked. To run `zig-out/bin/Zetal` directly, start it from the
repository root.

### Smoke mode

```bash
zig build run -- --frames 240 --autofire
```

- `--frames N` (or `--frames=N`, N >= 1) renders N frames and exits cleanly. After frame N/2 it resizes
  the window to 640x480 points, to exercise the resize path.
- `--autofire` aims at the gallery once (yaw -90, pitch 10 degrees) and clicks on every 12th frame,
  whenever the fire cooldown allows.

In smoke mode the game prints one summary line on exit:

```
Smoke run: <frames> frames, <shots> shots, <impacts> projectile impacts, <live> live entities, <recycled> recycled, drawable <w0>x<h0> -> <w1>x<h1>
```

`recycled` counts entity slots the projectile-lifetime and cleanup systems handed back to the free
list; the drawable sizes are the drawable texture's pixel size before and after the resize (they
must differ: a warning is logged when they do not). The counts depend on the display's refresh rate
and on the GPU's pair order, so never compare them exactly; with `--autofire`, the projectile
impacts should be above zero after about 240 frames.

An unknown argument, or a missing, malformed or zero frame count, prints a usage line and exits
with an error.

## Controls

| Input          | Action                                   |
|----------------|------------------------------------------|
| W / A / S / D  | Move (along the ground plane)            |
| Mouse          | Look                                     |
| Space          | Jump                                     |
| Left click     | Fire a projectile                        |
| Escape         | Quit (closing the window quits as well)  |

The cursor is hidden while the game is the active app (everywhere, not only over the window) and is
not captured.

## Features

### Rendering

- A comptime-typed Objective-C bridge: `msgSend(Ret, target, "selector:", .{args})` builds the
  method's exact C function-pointer type with `@Fn`, and every selector and class is looked up once
  and cached. Untyped number literals, bare `null`, slices, and x86_64 struct returns that would need
  `objc_msgSend_stret` are compile errors instead of runtime crashes.
- One command buffer per frame with two passes: a depth-only shadow pass into a 2048x2048
  `Depth32Float` shadow map, then the main pass: sky, instanced cubes (one draw call for every
  block and projectile), ground, gun viewmodel, crosshair.
- Blinn-Phong lighting (ambient, diffuse, specular) with 3x3 PCF shadows. The shader can also flash
  an entity red from its `Health.hit_timer`, but only the unwired hitscan system sets that timer, so
  no flash happens in normal play.
- A procedural sky: zenith-to-horizon gradient, sun disc and glow.
- The gun viewmodel draws into its own window-depth range ([0, 0.05], the world uses [0.05, 1]),
  so it always stays in front of the world and still occludes itself correctly.
- A crosshair overlay with a 45-degree hit marker that pops when a shot knocks a block loose.
- Rendering is paced by the display through `CAMetalLayer -nextDrawable`; window resizes carry
  through to the drawables and the main-pass depth target.
- MSL shaders are compiled at startup from `@embedFile`d sources. Binding slots, constants, mask
  bits and struct sizes are defined once in Zig and prepended as a generated `#define` prelude; the
  shaders `static_assert` their structs against it, so Zig and MSL cannot drift apart.

### GPU compute physics

- Five Metal kernels per step: velocity integration (gravity -15 on dynamic colliders), AABBs, grid
  clear, grid build, and a broad phase over a spatial hash grid (4099 buckets, 2-unit cells, a
  3x3x3 cell neighbourhood; a bucket shared by hash-colliding cells is walked once, so every pair is
  reported exactly once).
- `StorageModeShared` buffers: zero-copy between CPU and GPU on Apple silicon.
- Fixed 1 ms substeps. Pairs are resolved on the CPU: minimum-translation push-out with restitution,
  and impact conversion, where a dynamic body hitting a static block faster than 8 units/s knocks it
  loose (the block turns dynamic and takes 0.6x the impactor's velocity plus a 3 units/s pop).
- Up to 4096 pairs per step; overflow is counted (`droppedPairs`) and logged once.

### Entity-component system

- A fixed-capacity `World` of 4096 entity slots: parallel component arrays, a 16-bit component mask
  per slot, and LIFO free-list slot recycling.
- Components: Transform, Spin, MeshRenderer, Velocity, Collider, Health, EnemyTag, Projectile.
- Systems: spin, hit-flash decay (for the library-only hitscan system), projectile lifetime (10 s),
  collision response with impact conversion, an infinite floor with bounce and friction, fallen-body
  cleanup, camera collision and the per-instance matrix build. A hitscan system exists as a library
  capability; it is not wired to input.

### Gameplay

- The shooting gallery: 67 static blocks (a 5x5 back wall, two 4x3 side walls, an 8-high tower and
  a 4-3-2-1 pyramid) plus 4 enemies, 71 targets in all, at eye level.
- The FPS controller: mouse look (pitch limited to 89 degrees either way), WASD at 5 units/s,
  jumping under the player's own gravity, and collision against every collider.
- Left click fires a 40 units/s physical projectile (one shot per click, 0.15 s cooldown) with screen
  shake, gun kickback and an `NSSound` gunshot. The hit marker confirms shots that knock a block loose.

### Platform and assets

- `NSApplication` without `-run`: a regular foreground app that pumps its events without blocking,
  once before and once after the vsync wait of every frame. Mouse look keeps working while a button
  is held, keys held during Cmd-Tab are released, and key events never reach AppKit (no beep).
- One `NSWindow` around a paused `MTKView`; Escape, closing the window or a system quit request (the
  Dock's Quit, logout) shuts down cleanly, releasing every Metal and AppKit object the engine created.
- Wavefront OBJ loading (positions, UVs and normals; every face-corner form, negative indices,
  polygon fans, de-duplicated vertices, strict index checks), binary PPM (P6) textures, and WAV
  audio through `NSSound`.

## Architecture

```
ZetalV2/
├── build.zig  build.zig.zon  README.md  CLAUDE.md  .gitignore
├── assets/                   cube.obj  hands.obj  hands.mtl  test.ppm  gun_metal.ppm  gunshot.wav
├── tools/gen_texture.py      regenerates assets/test.ppm (byte-for-byte)
└── src/
    ├── root.zig              library root: re-exports every subsystem, discovers every file's tests
    ├── main.zig              the executable: options, startup, frame loop, smoke mode
    ├── objc.zig              comptime-typed Objective-C bridge
    ├── math.zig              Vec3, column-major Mat4, Metal projections, ray/AABB
    ├── platform/             app.zig (NSApplication, event pump, Input)   window.zig (NSWindow + MTKView)
    │                         autorelease.zig (NSAutoreleasePool)          sound.zig (NSSound)
    ├── render/               metal.zig (typed Metal wrappers)   physics_layout.zig (GPU physics structs)
    │                         geometry.zig (vertex layout, ground, sky, crosshair)   uniforms.zig
    │                         pipelines.zig (pipelines, depth states, binding slots, shader preludes)
    │                         resources.zig (meshes, textures, instance buffers)   renderer.zig (frames)
    │                         physics.zig (ComputePhysics)
    │                         shaders/scene.msl  shaders/crosshair.msl  shaders/physics.msl
    ├── ecs/                  world.zig (World, components, masks)   systems.zig
    ├── assets/               obj.zig  ppm.zig
    └── game/                 scene.zig (spawn helpers, the gallery)   player.zig (the FPS controller)
```

`build.zig` defines two modules: the **Zetal** library, rooted at `src/root.zig`, which links
Foundation, AppKit, Metal, MetalKit, QuartzCore and libobjc; and the **Zetal** executable
(`src/main.zig`), which uses the engine through `@import("Zetal")`.

Each frame `main.zig` drains events, waits for a drawable (the vsync wait), drains events again,
then updates the player, spins and fades, runs the physics substeps (upload, GPU step, download,
resolve pairs, floor), ages projectiles and cleans up fallen bodies, builds the instance matrices
and draws the frame (shadow pass and main pass in one command buffer).

## What changed in 0.2

- Projectiles despawn after 10 seconds instead of accumulating forever, and their slots are recycled.
- A shot the full world cannot spawn gives no feedback (no kick, sound or cooldown); the next click retries.
- One window (the original also opened a stray second one); closing it or pressing Escape quits cleanly.
- A system quit request (the Dock's Quit, logout, a quit Apple Event) ends the game loop normally
  instead of exiting from inside AppKit, which skipped all teardown: an app delegate cancels the
  termination and flags the quit (during logout macOS then reports that Zetal cancelled it; log out
  again once the game has closed).
- The player can stand on a block: being pushed up out of one clears his fall speed. With
  once-per-frame integration he was otherwise shoved off it within a second at 60 Hz (the original's
  ~1.6 kHz loop hid this); jumping still works only from the floor.
- Resizing works: the paused MTKView's drawable size is pushed to its layer by hand, and the old
  depth texture is released instead of leaked.
- Ray/AABB intersection no longer reports hits on rays that miss the box's Z extent.
- The perspective matrix targets Metal's [0, 1] clip depth (the old OpenGL-style matrix clipped
  everything nearer than about 0.2 instead of 0.1).
- The sky's sun direction is a full `float4` uniform in its own fragment slot.
- Selector and class lookups are really cached per name.
- Buffer storage modes are encoded correctly in `MTLResourceOptions` (storage mode << 4).
- The hit marker shows only for impacts caused by projectiles.
- Mouse look keeps working while a mouse button is held; held keys are released when the app loses focus.
- Key events are not forwarded to AppKit, which made it beep on every key press.
- The shadow map is sampled with a plain sampler (the original misused a comparison sampler; same look).
- The gun viewmodel has its own depth range: always in front, correctly self-occluding.
- The broad phase skips duplicate neighbour buckets (the original reported some pairs 2-4 times),
  and dropped pairs are counted.
- Shader constants, mask bits, binding slots and struct sizes are generated from Zig.
- The app becomes a regular foreground app and activates, so it gets keyboard focus when launched
  from a terminal.
- Frames are paced by the display (the original spun at about 1.6 thousand loop iterations a
  second), with physics in fixed 1 ms substeps to keep the original feel.
- One command buffer per frame; pipeline creation errors print Metal's reason; everything is
  released at shutdown; frames with nothing to draw or simulate issue no empty draws or dispatches.
- Assets live in `assets/`, and `zig build run` works from any subdirectory.

## Known quirks, kept on purpose

- The gallery floats 2 units above the ground (block bottoms at y = -10, the ground at -12).
- The gun is lit with its view-space matrix; the main pass does no back-face culling; textures use
  nearest filtering without mipmaps.
- Ground beyond the shadow light's far plane renders fully shadowed (a dark band on the far left).
- The sky's sun disc points about 13 degrees away from the direction shadows are cast from.
- The floor is infinite, and camera collision also pushes the player out of projectiles.
- The cursor is hidden but not captured.
- The player integrates once per rendered frame (a 60 Hz jump peaks about 4% lower than the
  original's 1.6 kHz loop).

