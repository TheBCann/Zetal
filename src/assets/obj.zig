//! Wavefront OBJ loader: positions, texture coordinates, normals and polygon faces into an indexed triangle mesh.

const std = @import("std");
const geometry = @import("../render/geometry.zig");

const Vertex = geometry.Vertex;

/// An indexed triangle mesh; both slices belong to the allocator that loaded it.
pub const Mesh = struct {
    vertices: []Vertex,
    indices: []u32,

    /// Frees both slices; `gpa` must be the allocator that loaded the mesh.
    pub fn deinit(self: *Mesh, gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.indices);
        self.* = undefined;
    }
};

/// Errors from `parse`. InvalidFormat: a statement lacks values or a face has fewer than three corners.
/// InvalidIndex: a face index is 0, out of range, or refers to an element not defined yet.
/// InvalidCharacter: a malformed number.
pub const ParseError = error{ ReadFailed, StreamTooLong } || std.mem.Allocator.Error ||
    std.fmt.ParseFloatError || error{ InvalidFormat, InvalidIndex };

/// Errors from `load`; a failed read reports the file's own error rather than ReadFailed.
pub const LoadError = std.Io.File.OpenError || std.Io.File.Reader.Error || ParseError;

/// Read buffer for `load`: a line plus its '\n' must fit, longer lines fail with error.StreamTooLong.
const LINE_BUFFER_LEN = 4096;

/// Loads the OBJ file at `path`, relative to the current working directory.
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) LoadError!Mesh {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [LINE_BUFFER_LEN]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    return parse(gpa, &file_reader.interface) catch |err| switch (err) {
        // The generic reader can only say ReadFailed; the file reader kept the actual cause.
        error.ReadFailed => return file_reader.err.?,
        else => |e| return e,
    };
}

/// Parses OBJ text: `v`/`vt`/`vn` elements and `f` polygons (fan-triangulated), with one mesh vertex per
/// distinct (v, vt, vn) corner. All other statements are ignored.
pub fn parse(gpa: std.mem.Allocator, reader: *std.Io.Reader) ParseError!Mesh {
    var builder: Builder = .{};
    defer builder.deinit(gpa);

    while (try reader.takeDelimiter('\n')) |line| {
        // '#' starts a comment, whether it opens the line or trails a statement.
        const statement = line[0 .. std.mem.findScalar(u8, line, '#') orelse line.len];
        var tokens = std.mem.tokenizeAny(u8, statement, " \t\r");
        const tag = tokens.next() orelse continue;
        if (std.mem.eql(u8, tag, "v")) {
            const p = try parseFloats(3, &tokens);
            try builder.positions.append(gpa, .{ p[0], p[1], p[2], 1 });
        } else if (std.mem.eql(u8, tag, "vt")) {
            const t = try parseFloats(2, &tokens);
            // OBJ's v axis points up the image; Metal's texture rows run top-down.
            try builder.uvs.append(gpa, .{ t[0], 1 - t[1], 0, 0 });
        } else if (std.mem.eql(u8, tag, "vn")) {
            const n = try parseFloats(3, &tokens);
            try builder.normals.append(gpa, .{ n[0], n[1], n[2], 0 });
        } else if (std.mem.eql(u8, tag, "f")) {
            try builder.addFace(gpa, &tokens);
        }
        // o, g, s, mtllib, usemtl, l, ... contribute no triangles.
    }

    const vertices = try builder.vertices.toOwnedSlice(gpa);
    errdefer gpa.free(vertices);
    const indices = try builder.indices.toOwnedSlice(gpa);
    return .{ .vertices = vertices, .indices = indices };
}

// ============================================================
// Parser internals
// ============================================================

const Tokens = std.mem.TokenIterator(u8, .any);

/// Stands in for a corner's missing texture coordinate or normal.
const NONE: u32 = std.math.maxInt(u32);

/// A face corner's 0-based element indices, and the vertex de-duplication key: a corner without a vt or
/// vn never shares a vertex with one that has it.
const Corner = struct { v: u32, vt: u32, vn: u32 };

/// Parse state: the OBJ element pools and the mesh being assembled from them.
const Builder = struct {
    positions: std.ArrayList([4]f32) = .empty,
    uvs: std.ArrayList([4]f32) = .empty,
    normals: std.ArrayList([4]f32) = .empty,
    vertices: std.ArrayList(Vertex) = .empty,
    indices: std.ArrayList(u32) = .empty,
    vertex_of: std.AutoHashMapUnmanaged(Corner, u32) = .empty,

    fn deinit(self: *Builder, gpa: std.mem.Allocator) void {
        self.positions.deinit(gpa);
        self.uvs.deinit(gpa);
        self.normals.deinit(gpa);
        self.vertices.deinit(gpa);
        self.indices.deinit(gpa);
        self.vertex_of.deinit(gpa);
    }

    /// Adds a polygon as a triangle fan: corners c0 c1 c2 c3 ... become (c0 c1 c2), (c0 c2 c3), ...
    fn addFace(self: *Builder, gpa: std.mem.Allocator, tokens: *Tokens) ParseError!void {
        var corner_count: usize = 0;
        var first: u32 = 0;
        var prev: u32 = 0;
        while (tokens.next()) |token| : (corner_count += 1) {
            const vertex = try self.vertexFor(gpa, try self.parseCorner(token));
            if (corner_count == 0) first = vertex;
            if (corner_count >= 2) try self.indices.appendSlice(gpa, &.{ first, prev, vertex });
            prev = vertex;
        }
        if (corner_count < 3) return error.InvalidFormat;
    }

    /// Resolves a corner written `v`, `v/vt`, `v//vn` or `v/vt/vn` against the elements defined so far.
    fn parseCorner(self: *const Builder, token: []const u8) ParseError!Corner {
        var fields = std.mem.splitScalar(u8, token, '/');
        const v = fields.first();
        const vt = fields.next() orelse "";
        const vn = fields.next() orelse "";
        if (v.len == 0 or fields.next() != null) return error.InvalidFormat;
        return .{
            .v = try resolveIndex(v, self.positions.items.len),
            .vt = if (vt.len == 0) NONE else try resolveIndex(vt, self.uvs.items.len),
            .vn = if (vn.len == 0) NONE else try resolveIndex(vn, self.normals.items.len),
        };
    }

    /// Returns the mesh vertex for `corner`, appending it the first time this (v, vt, vn) triple appears.
    fn vertexFor(self: *Builder, gpa: std.mem.Allocator, corner: Corner) ParseError!u32 {
        const entry = try self.vertex_of.getOrPut(gpa, corner);
        if (entry.found_existing) return entry.value_ptr.*;
        // Mesh indices are u32; a mesh with more distinct corners cannot be indexed.
        const index = std.math.cast(u32, self.vertices.items.len) orelse return error.InvalidIndex;
        entry.value_ptr.* = index;
        try self.vertices.append(gpa, .{
            .position = self.positions.items[corner.v],
            .color = .{ 1, 1, 1, 1 },
            .uv = if (corner.vt == NONE) .{ 0, 0, 0, 0 } else self.uvs.items[corner.vt],
            .normal = if (corner.vn == NONE) .{ 0, 1, 0, 0 } else self.normals.items[corner.vn],
        });
        return index;
    }
};

/// Parses the next `n` tokens as floats; anything after them (like a `v` line's optional w) is ignored.
fn parseFloats(comptime n: usize, tokens: *Tokens) ParseError![n]f32 {
    var values: [n]f32 = undefined;
    for (&values) |*value| {
        value.* = try std.fmt.parseFloat(f32, tokens.next() orelse return error.InvalidFormat);
    }
    return values;
}

/// Turns a 1-based OBJ index, or a negative one counting back from the newest element, into a 0-based
/// index below `count`.
fn resolveIndex(text: []const u8, count: usize) ParseError!u32 {
    const raw = std.fmt.parseInt(i32, text, 10) catch |err| switch (err) {
        error.Overflow => return error.InvalidIndex,
        error.InvalidCharacter => return error.InvalidCharacter,
    };
    const index: usize = if (raw > 0)
        @intCast(raw - 1)
    else if (raw < 0 and @abs(raw) <= count)
        count - @abs(raw)
    else
        return error.InvalidIndex;
    // NONE is reserved for a missing vt/vn, so it can never name a real element.
    if (index >= count or index >= NONE) return error.InvalidIndex;
    return @intCast(index);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn parseText(text: []const u8) ParseError!Mesh {
    var reader: std.Io.Reader = .fixed(text);
    return parse(testing.allocator, &reader);
}

test "parse: cube shares one vertex per distinct corner" {
    var mesh = try parseText(
        \\v -0.5 -0.5  0.5
        \\v  0.5 -0.5  0.5
        \\v -0.5  0.5  0.5
        \\v  0.5  0.5  0.5
        \\v -0.5  0.5 -0.5
        \\v  0.5  0.5 -0.5
        \\v -0.5 -0.5 -0.5
        \\v  0.5 -0.5 -0.5
        \\vt 0.0 0.0
        \\vt 1.0 0.0
        \\vt 0.0 1.0
        \\vt 1.0 1.0
        \\vn  0.0  0.0  1.0
        \\vn  0.0  0.0 -1.0
        \\vn  0.0  1.0  0.0
        \\vn  0.0 -1.0  0.0
        \\vn  1.0  0.0  0.0
        \\vn -1.0  0.0  0.0
        \\f 1/1/1 2/2/1 3/3/1
        \\f 3/3/1 2/2/1 4/4/1
        \\f 5/1/2 6/2/2 7/3/2
        \\f 7/3/2 6/2/2 8/4/2
        \\f 3/1/3 4/2/3 5/3/3
        \\f 5/3/3 4/2/3 6/4/3
        \\f 7/1/4 8/2/4 1/3/4
        \\f 1/3/4 8/2/4 2/4/4
        \\f 2/1/5 8/2/5 4/3/5
        \\f 4/3/5 8/2/5 6/4/5
        \\f 7/1/6 1/2/6 5/3/6
        \\f 5/3/6 1/2/6 3/4/6
        \\
    );
    defer mesh.deinit(testing.allocator);

    // 6 faces x 4 distinct corners; each face's two triangles share the corners on their diagonal.
    try testing.expectEqual(24, mesh.vertices.len);
    try testing.expectEqual(36, mesh.indices.len);
    for (0..6) |face| {
        const k: u32 = @intCast(4 * face);
        try testing.expectEqualSlices(u32, &.{ k, k + 1, k + 2, k + 2, k + 1, k + 3 }, mesh.indices[6 * face ..][0..6]);
    }

    // Corner 1/1/1: vt (0, 0) becomes uv (0, 1) after the v flip.
    const first = mesh.vertices[0];
    try testing.expectEqualSlices(f32, &.{ -0.5, -0.5, 0.5, 1 }, &first.position);
    try testing.expectEqualSlices(f32, &.{ 1, 1, 1, 1 }, &first.color);
    try testing.expectEqualSlices(f32, &.{ 0, 1, 0, 0 }, &first.uv);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 1, 0 }, &first.normal);
    // Corner 4/4/1: vt (1, 1) becomes uv (1, 0).
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.5, 0.5, 1 }, &mesh.vertices[3].position);
    try testing.expectEqualSlices(f32, &.{ 1, 0, 0, 0 }, &mesh.vertices[3].uv);
}

test "parse: polygons are fan-triangulated" {
    var quad = try parseText("v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n");
    defer quad.deinit(testing.allocator);
    try testing.expectEqual(4, quad.vertices.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 0, 2, 3 }, quad.indices);
    // Corners without vt/vn get the default uv and an upward normal.
    try testing.expectEqualSlices(f32, &.{ 1, 1, 0, 1 }, &quad.vertices[2].position);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, &quad.vertices[2].uv);
    try testing.expectEqualSlices(f32, &.{ 0, 1, 0, 0 }, &quad.vertices[2].normal);

    var pentagon = try parseText("v 0 0 0\nv 1 0 0\nv 2 1 0\nv 1 2 0\nv 0 1 0\nf 1 2 3 4 5\n");
    defer pentagon.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 0, 2, 3, 0, 3, 4 }, pentagon.indices);
}

test "parse: negative indices count back from the newest element" {
    var relative = try parseText(
        \\v 0 0 0
        \\v 1 0 0
        \\v 0 1 0
        \\vt 0 0
        \\vt 1 1
        \\vn 0 0 1
        \\f -3/-2/-1 -2/-1/-1 -1/-2/-1
        \\v 1 1 0
        \\f -4 -3 -1
        \\
    );
    defer relative.deinit(testing.allocator);
    var absolute = try parseText(
        \\v 0 0 0
        \\v 1 0 0
        \\v 0 1 0
        \\vt 0 0
        \\vt 1 1
        \\vn 0 0 1
        \\f 1/1/1 2/2/1 3/1/1
        \\v 1 1 0
        \\f 1 2 4
        \\
    );
    defer absolute.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5 }, relative.indices);
    try testing.expectEqualSlices(u32, absolute.indices, relative.indices);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(absolute.vertices), std.mem.sliceAsBytes(relative.vertices));
    // "-1" in the second face is the fourth position, defined after the first face.
    try testing.expectEqualSlices(f32, &.{ 1, 1, 0, 1 }, &relative.vertices[5].position);
}

test "parse: v//vn corners take the normal and the default uv" {
    var mesh = try parseText("v 0 0 0\nv 1 0 0\nv 0 1 0\nvn 1 0 0\nf 1//1 2//1 3//1\n");
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(3, mesh.vertices.len);
    for (mesh.vertices) |v| {
        try testing.expectEqualSlices(f32, &.{ 1, 0, 0, 0 }, &v.normal);
        try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, &v.uv);
    }
}

test "parse: a corner without vt never shares a vertex with one that has it" {
    var mesh = try parseText("v 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0.25 0.75\nf 1 2 3\nf 1/1 2/1 3/1\n");
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(6, mesh.vertices.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5 }, mesh.indices);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, &mesh.vertices[0].uv);
    try testing.expectEqualSlices(f32, &.{ 0.25, 0.25, 0, 0 }, &mesh.vertices[3].uv);
}

test "parse: bad face indices are errors" {
    const tri = "v 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nvn 0 0 1\n";
    try testing.expectError(error.InvalidIndex, parseText(tri ++ "f 1 2 4\n")); // past the last position
    try testing.expectError(error.InvalidIndex, parseText(tri ++ "f 0 1 2\n")); // OBJ counts from 1
    try testing.expectError(error.InvalidIndex, parseText(tri ++ "f -4 1 2\n")); // reaches back too far
    try testing.expectError(error.InvalidIndex, parseText(tri ++ "f 1/2 2/1 3/1\n")); // only one vt
    try testing.expectError(error.InvalidIndex, parseText(tri ++ "f 1//2 2//1 3//1\n")); // only one vn
    try testing.expectError(error.InvalidIndex, parseText(tri ++ "f 1 2 99999999999\n")); // beyond i32
    try testing.expectError(error.InvalidIndex, parseText("f 1 2 3\n" ++ tri)); // used before defined
}

test "parse: malformed statements are errors" {
    try testing.expectError(error.InvalidFormat, parseText("v 1 2\n"));
    try testing.expectError(error.InvalidCharacter, parseText("v 1 x 3\n"));
    try testing.expectError(error.InvalidFormat, parseText("vt 0.5\n"));
    try testing.expectError(error.InvalidFormat, parseText("vn 0 1\n"));
    const tri = "v 0 0 0\nv 1 0 0\nv 0 1 0\n";
    try testing.expectError(error.InvalidFormat, parseText(tri ++ "f 1 2\n")); // not a polygon
    try testing.expectError(error.InvalidFormat, parseText(tri ++ "f 1/1/1/1 2 3\n")); // four fields
    try testing.expectError(error.InvalidFormat, parseText(tri ++ "f /1 2 3\n")); // no position
    try testing.expectError(error.InvalidCharacter, parseText(tri ++ "f a b c\n"));
}

test "parse: comments, ignored statements, CRLF and an unterminated last line" {
    var mesh = try parseText("# exported by hand\r\n" ++
        "mtllib hands.mtl\r\no Thing\r\ng part\r\ns 1\r\nusemtl metal\r\n" ++
        "\r\n" ++
        "v 0 0 0 # trailing comment\r\n" ++
        "\tv 1 0 0\r\n" ++
        "v 0 1 0 1.0\r\n" ++ // the optional w is ignored
        "vn 0 0 1\r\n" ++
        "f 1//1 2//1 3//1");
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(3, mesh.vertices.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, mesh.indices);
    try testing.expectEqualSlices(f32, &.{ 0, 1, 0, 1 }, &mesh.vertices[2].position);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 1, 0 }, &mesh.vertices[2].normal);
}

test "parse: no faces gives an empty mesh" {
    var mesh = try parseText("# only elements\nv 1 2 3\nvn 0 1 0\n");
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(0, mesh.vertices.len);
    try testing.expectEqual(0, mesh.indices.len);
}

test "load: reads a file relative to the cwd and reports open/read errors" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "quad.obj", .data = "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n" });
    const filler: [LINE_BUFFER_LEN]u8 = @splat('x');
    try tmp.dir.writeFile(io, .{ .sub_path = "long.obj", .data = "#" ++ filler ++ "\n" });

    // tmpDir lives at <cwd>/.zig-cache/tmp/<sub_path>, so it is reachable through load()'s cwd-relative path.
    var path_buf: [256]u8 = undefined;
    var mesh = try load(testing.allocator, io, try std.mem.print(&path_buf, ".zig-cache/tmp/{s}/quad.obj", .{&tmp.sub_path}));
    defer mesh.deinit(testing.allocator);
    try testing.expectEqual(4, mesh.vertices.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 0, 2, 3 }, mesh.indices);

    try testing.expectError(error.FileNotFound, load(testing.allocator, io, "no/such/mesh.obj"));
    // A directory opens fine and fails on the first read, surfacing the file's error instead of ReadFailed.
    const dir_path = try std.mem.print(&path_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    try testing.expectError(error.IsDir, load(testing.allocator, io, dir_path));
    const long_path = try std.mem.print(&path_buf, ".zig-cache/tmp/{s}/long.obj", .{&tmp.sub_path});
    try testing.expectError(error.StreamTooLong, load(testing.allocator, io, long_path));
}
