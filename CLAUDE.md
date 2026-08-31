# Zetal

## What this is

A macOS Metal 3D FPS engine written entirely in **nightly Zig**, talking to the
Objective-C runtime directly (`objc_msgSend`) — no external bindings or wrapper
libraries. The demo app is a shooting gallery: GPU compute physics, an ECS, a
two-pass Metal renderer (shadow + main), and a dual-weapon FPS player
controller (left-click hitscan, right-click projectile).

## Commands

- `zig build` — compile library + app
- `zig build run` — build and launch the game (`-Doptimize=ReleaseFast` etc. as usual; args after `--` are passed through)
- `zig build test` — run unit tests

Tests live next to the code they test; discovery is wired through the `test`
block at the bottom of `src/root.zig` (`refAllDecls` + `_ = module;`
references). If you add tests to a new file, reference it there or they will
silently not run.

## Zig toolchain — read this before writing any Zig

This project intentionally tracks **bleeding-edge nightly Zig** (see
`minimum_zig_version` in build.zig.zon; check `zig version` before reasoning
about syntax). Stable-Zig idioms from training data are often wrong here.
Current API shapes this codebase relies on:

- `main` signature: `pub fn main(init: std.process.Init) !void` — no allocator
  param; use `init.arena.allocator()`, I/O capability via `init.io`.
- `std.Io` capability-based I/O: `Io.Dir.cwd().openFile(io, ...)`,
  `Io.Clock.Timestamp.now(io, .awake)` — not `std.fs.cwd()` / `std.time`.
- `@splat(val)` for fixed-size array init — `.{val} ** N` no longer parses.
  Works for structs (`@splat(Transform{})`) and nests (`@splat(@splat(0))`).
- `@Fn(&param_types, &param_attrs, Ret, .{ .@"callconv" = ... })` synthesizes
  function pointer types at comptime — the msgSend bridge depends on it.
- `std.lang` replaces `std.builtin` (deprecated alias):
  `std.lang.Type.Fn.ParamAttributes`, `std.lang.CallingConvention`.
- `@typeInfo(T).@"struct"` has **no `.fields`** — use the parallel slices
  `field_names` / `field_types` / `field_attrs`.
- ArrayList is unmanaged-style: allocator passed to `append`/`deinit`, not
  stored in the list.
- Build system: `b.args` is gone — `run_cmd.addPassthruArgs()` forwards
  `zig build run -- ...` args.

Automated reviewers checking against older std trees flag `field_types`,
`ParamAttributes`, etc. as nonexistent APIs — those are false positives.
When in doubt, read existing call sites and match their shape; prefer that
over recalling syntax. A broader reference lives at
`~/programming/zig-programming/reference-guide/zig-bleeding-edge-reference.md`.

## Architecture

Two-module build (build.zig): the **Zetal library** (root `src/root.zig`,
links Foundation/Metal/MetalKit/AppKit/QuartzCore + libobjc) and the **app
executable** (`src/main.zig`, imports `Zetal`).

- `src/objc.zig` — the foundation: typed `msgSend(Ret, target, "selector:", .{args})`
  builds a correctly-typed C function pointer for `objc_msgSend` at comptime.
- `src/platform/` — Cocoa window + event polling (`window.zig`), frame
  orchestration and render passes (`engine.zig`), autorelease pool.
- `src/render/` — Metal device/buffers/pipelines, math, GPU compute physics
  (`compute.zig` + `compute.msl` with spatial-grid broad phase), shaders
  embedded via `@embedFile` (`shader.msl`, `crosshair.msl`, `compute.msl`).
- `src/ecs/` — parallel-array World with component bitmasks (`world.zig`),
  systems (`systems.zig`): hitscan, hit-timer decay, collision resolution with
  impact conversion, floor enforcement, cleanupFallen, instance-buffer build.
  Entity slots are recycled through a LIFO free-list: always despawn via
  `world.despawn(e)`, never zero masks by hand.
- `src/scene.zig` — scene construction (gallery, enemies, projectiles);
  `src/player.zig` — FPS controller (look/move/jump, dual-weapon fire,
  screen shake, hit marker); `src/main.zig` — game loop (note the 33ms dt
  clamp: don't remove it, it prevents projectile tunneling on window hitches).

Memory model: buffers use `StorageModeShared` — zero-copy CPU/GPU on Apple
Silicon; CPU writes are visible to the GPU without blits. Changes to the
compute pipeline touch both the `.msl` shader and the Zig dispatch code.

Assets (`cube.obj`, `hands.obj`, `gunshot.wav`, `test.ppm`) load from the cwd,
so run from the repo root.
