const std = @import("std");
const Io = std.Io;
const render = @import("render/root.zig");
const Vertex = render.vertex.Vertex;

pub const Mesh = struct {
    vertices: []Vertex,
    indices: []u32, // NEW: The list of indices
    allocator: std.mem.Allocator,

    pub fn deinit(self: Mesh) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.indices);
    }
};

const FaceIndices = struct {
    v_idx: usize,
    vt_idx: usize,
    vn_idx: usize,
};

pub fn loadObj(allocator: std.mem.Allocator, path: []const u8, io_cap: Io) !Mesh {
    const file = try Io.Dir.cwd().openFile(io_cap, path, .{});
    defer file.close(io_cap);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = Io.File.Reader.init(.{ .handle = file.handle }, io_cap, &read_buffer);
    const in_stream = &file_reader.interface;

    // Temporary OBJ raw data
    var positions = try std.ArrayList([4]f32).initCapacity(allocator, 0);
    defer positions.deinit(allocator);
    var tex_coords = try std.ArrayList([4]f32).initCapacity(allocator, 0);
    defer tex_coords.deinit(allocator);
    var normals = try std.ArrayList([4]f32).initCapacity(allocator, 0);
    defer normals.deinit(allocator);

    // Final GPU data
    var vertices = try std.ArrayList(Vertex).initCapacity(allocator, 0);
    errdefer vertices.deinit(allocator);

    var indices = try std.ArrayList(u32).initCapacity(allocator, 0);
    errdefer indices.deinit(allocator);

    // Deduplication Map: Maps OBJ-Index-Triplet -> Final-Vertex-Index
    var unique_map = std.AutoHashMap(FaceIndices, u32).init(allocator);
    defer unique_map.deinit();

    while (try in_stream.takeDelimiter('\n')) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \r\t");
        const type_str = it.next() orelse continue;

        if (std.mem.eql(u8, type_str, "v")) {
            const x = try parseFloat(it.next());
            const y = try parseFloat(it.next());
            const z = try parseFloat(it.next());
            try positions.append(allocator, .{ x, y, z, 1.0 });
        } else if (std.mem.eql(u8, type_str, "vt")) {
            const u = try parseFloat(it.next());
            const v = try parseFloat(it.next());
            try tex_coords.append(allocator, .{ u, 1.0 - v, 0.0, 0.0 });
        } else if (std.mem.eql(u8, type_str, "vn")) {
            const x = try parseFloat(it.next());
            const y = try parseFloat(it.next());
            const z = try parseFloat(it.next());
            try normals.append(allocator, .{ x, y, z, 0.0 });
        } else if (std.mem.eql(u8, type_str, "f")) {
            const v1_chunk = it.next() orelse continue;
            const v1_idx = try parseFaceChunk(v1_chunk);

            var prev_chunk = it.next() orelse continue;
            var prev_idx = try parseFaceChunk(prev_chunk);

            while (it.next()) |curr_chunk| {
                const curr_idx = try parseFaceChunk(curr_chunk);

                try addIndexedVertex(allocator, &vertices, &indices, &unique_map, &positions, &tex_coords, &normals, v1_idx);
                try addIndexedVertex(allocator, &vertices, &indices, &unique_map, &positions, &tex_coords, &normals, prev_idx);
                try addIndexedVertex(allocator, &vertices, &indices, &unique_map, &positions, &tex_coords, &normals, curr_idx);

                prev_chunk = curr_chunk;
                prev_idx = curr_idx;
            }
        }
    }

    return Mesh{
        .vertices = try vertices.toOwnedSlice(allocator),
        .indices = try indices.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn addIndexedVertex(allocator: std.mem.Allocator, vertices: *std.ArrayList(Vertex), indices: *std.ArrayList(u32), unique_map: *std.AutoHashMap(FaceIndices, u32), positions: *std.ArrayList([4]f32), tex_coords: *std.ArrayList([4]f32), normals: *std.ArrayList([4]f32), face_indices: FaceIndices) !void {
    // Check if we already created a vertex for this exact pos/uv/norm combination
    if (unique_map.get(face_indices)) |existing_index| {
        try indices.append(allocator, existing_index);
        return;
    }

    // New vertex found!
    if (face_indices.v_idx >= positions.items.len) return;

    const pos = positions.items[face_indices.v_idx];
    const uv = if (tex_coords.items.len > face_indices.vt_idx) tex_coords.items[face_indices.vt_idx] else .{ 0, 0, 0, 0 };
    const norm = if (normals.items.len > face_indices.vn_idx) normals.items[face_indices.vn_idx] else .{ 0, 1, 0, 0 };

    const new_index = @as(u32, @intCast(vertices.items.len));

    try vertices.append(allocator, Vertex{
        .position = pos,
        .color = .{ 1.0, 1.0, 1.0, 1.0 },
        .uv = uv,
        .normal = norm,
    });

    try indices.append(allocator, new_index);
    try unique_map.put(face_indices, new_index);
}

fn parseFaceChunk(chunk: []const u8) !FaceIndices {
    var face_it = std.mem.splitScalar(u8, chunk, '/');
    const v_idx = (try parseInt(face_it.first())) - 1;
    const vt_idx = (try parseInt(face_it.next() orelse "0")) -| 1;
    const vn_idx = (try parseInt(face_it.next() orelse "0")) -| 1;
    return FaceIndices{ .v_idx = v_idx, .vt_idx = vt_idx, .vn_idx = vn_idx };
}

fn parseFloat(str: ?[]const u8) !f32 {
    if (str) |s| return std.fmt.parseFloat(f32, s);
    return error.InvalidFormat;
}

fn parseInt(str: []const u8) !usize {
    if (str.len == 0) return 0;
    return std.fmt.parseInt(usize, str, 10);
}
