//! Zetal engine library root: re-exports every subsystem; its one test block discovers every file's tests.

const std = @import("std");
const builtin = @import("builtin");

// ============================================================
// SUBSYSTEMS
// ============================================================

/// Comptime-typed Objective-C bridge: `msgSend`, cached selectors and classes, NSString helpers.
pub const objc = @import("objc.zig");
/// Vec3, column-major Mat4, Metal-clip-space projections, ray/AABB intersection.
pub const math = @import("math.zig");
/// NSApplication and input, the game window, autorelease pools, sound.
pub const platform = @import("platform/root.zig");
/// Metal wrappers, pipelines, the frame renderer and the GPU compute physics.
pub const render = @import("render/root.zig");
/// The ECS World and the systems that run over it.
pub const ecs = @import("ecs/root.zig");
/// OBJ mesh and PPM image loaders.
pub const assets = @import("assets/root.zig");
/// Scene construction and the first-person player.
pub const game = @import("game/root.zig");

// ============================================================
// CONVENIENCE ALIASES
// ============================================================

/// 3-component f32 vector.
pub const Vec3 = math.Vec3;
/// 4x4 column-major f32 matrix (MSL float4x4 layout).
pub const Mat4 = math.Mat4;
/// The ECS entity store.
pub const World = ecs.World;
/// An entity slot index.
pub const Entity = ecs.Entity;
/// The first-person player.
pub const Player = game.Player;
/// One frame's camera matrices.
pub const Camera = game.Camera;
/// The shared NSApplication plus its input state.
pub const App = platform.App;
/// Keyboard and mouse state.
pub const Input = platform.Input;
/// The game window.
pub const Window = platform.Window;
/// One NSAutoreleasePool scope.
pub const AutoreleasePool = platform.AutoreleasePool;
/// One loaded sound file.
pub const Sound = platform.Sound;
/// The two-pass frame renderer.
pub const Renderer = render.Renderer;
/// Per-frame renderer input.
pub const FrameData = render.FrameData;
/// GPU compute physics for one World.
pub const ComputePhysics = render.ComputePhysics;

// ============================================================
// TEST DISCOVERY
// ============================================================

// std.testing.refAllDeclsRecursive is gone and refAllDecls only goes one level deep, so this walks
// every container reachable through pub decls (every subsystem root.zig pub-imports each file in its
// directory) and refAllDecls each one: that runs every file's tests and type-checks pub fns no test
// calls. Generic and inline functions (msgSend, sel, set*Bytes, ...) are only analysed where called.
test {
    refAllDeclsRecursive(@This());
}

/// References the pub decls of every non-std container reachable from `Root`.
fn refAllDeclsRecursive(comptime Root: type) void {
    if (!builtin.is_test) return;
    inline for (comptime reachableContainers(Root)) |T| std.testing.refAllDecls(T);
}

/// Returns `Root` plus every struct/enum/union/opaque type reachable from it through pub decls,
/// each once (cycles are fine), std's own types excluded.
fn reachableContainers(comptime Root: type) []const type {
    return comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var found: []const type = &.{Root};
        var i: usize = 0;
        while (i < found.len) : (i += 1) {
            const T = found[i];
            for (std.meta.declarations(T)) |name| {
                if (@TypeOf(@field(T, name)) != type) continue;
                const D = @field(T, name);
                switch (@typeInfo(D)) {
                    .@"struct", .@"enum", .@"union", .@"opaque" => {},
                    else => continue,
                }
                if (isStd(D)) continue;
                for (found) |F| {
                    if (F == D) break;
                } else found = found ++ &[_]type{D};
            }
        }
        const out = found[0..found.len].*;
        break :blk &out;
    };
}

/// True for `std` itself and for every type declared inside it, instances of std generics included.
fn isStd(comptime T: type) bool {
    return comptime blk: {
        if (T == std) break :blk true;
        var ns: type = std;
        var it = std.mem.splitScalar(u8, @typeName(T), '.');
        while (it.next()) |seg| {
            const paren = std.mem.findScalar(u8, seg, '(');
            const decl = seg[0 .. paren orelse seg.len];
            if (!@hasDecl(ns, decl)) break :blk false;
            if (paren != null) break :blk true; // an instance of a std generic
            if (@TypeOf(@field(ns, decl)) != type) break :blk false;
            ns = @field(ns, decl);
            switch (@typeInfo(ns)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => {},
                else => break :blk false,
            }
        }
        break :blk ns == T;
    };
}
