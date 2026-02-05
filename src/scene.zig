const std = @import("std");

pub const GameObject = struct {
    x: f32,
    y: f32,
    z: f32,
    rot_y: f32,
    scale: f32,
};

pub const Scene = struct {
    objects: std.ArrayList(GameObject),
    allocator: std.mem.Allocator,

    // CHANGED: Returns !Scene because initCapacity can fail
    pub fn init(allocator: std.mem.Allocator) !Scene {
        return Scene{
            // CHANGED: init -> try initCapacity
            .objects = try std.ArrayList(GameObject).initCapacity(allocator, 0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Scene) void {
        self.objects.deinit();
    }

    pub fn add(self: *Scene, x: f32, y: f32, z: f32) !void {
        try self.objects.append(self.allocator, GameObject{ // Explicit allocator passing
            .x = x,
            .y = y,
            .z = z,
            .rot_y = 0.0,
            .scale = 1.0,
        });
    }
};
