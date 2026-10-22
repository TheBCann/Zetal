//! Binary PPM (P6) loader: 8-bit RGB images widened to RGBA for rgba8Unorm textures.

const std = @import("std");

/// An RGBA8 image, rows top to bottom; `rgba` (width * height * 4 bytes) belongs to the allocator that loaded it.
pub const Image = struct {
    width: u32,
    height: u32,
    rgba: []u8,

    /// Frees the pixels; `gpa` must be the allocator that loaded the image.
    pub fn deinit(self: *Image, gpa: std.mem.Allocator) void {
        gpa.free(self.rgba);
        self.* = undefined;
    }
};

/// Errors from `parse`. InvalidFormat: not a well-formed P6 header. InvalidDimensions: a zero side or
/// more than 16384 x 16384 pixels. UnsupportedMaxVal: samples are not 8-bit (maxval != 255).
/// EndOfStream: the header or raster is truncated.
pub const ParseError = std.Io.Reader.Error || std.mem.Allocator.Error ||
    error{ InvalidFormat, InvalidDimensions, UnsupportedMaxVal };

/// Errors from `load`; a failed read reports the file's own error rather than ReadFailed.
pub const LoadError = std.Io.File.OpenError || std.Io.File.Reader.Error || ParseError;

/// Largest accepted pixel count, 16384² (at most 1 GiB of RGBA): it bounds what a corrupt header can
/// make `parse` allocate. This caps the area only; the GPU's 16384-pixel limit per side is checked
/// when the image is uploaded (render/resources.zig).
const MAX_PIXELS: u64 = 16384 * 16384;

/// Loads the PPM file at `path`, relative to the current working directory.
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) LoadError!Image {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    return parse(gpa, &file_reader.interface) catch |err| switch (err) {
        // The generic reader can only say ReadFailed; the file reader kept the actual cause.
        error.ReadFailed => return file_reader.err.?,
        else => |e| return e,
    };
}

/// Decodes a binary PPM (P6, maxval 255) into RGBA with alpha 255.
pub fn parse(gpa: std.mem.Allocator, reader: *std.Io.Reader) ParseError!Image {
    if (!std.mem.eql(u8, try reader.takeArray(2), "P6")) return error.InvalidFormat;
    const width = try readHeaderNumber(reader);
    const height = try readHeaderNumber(reader);
    const max_val = try readHeaderNumber(reader);
    if (width == 0 or height == 0 or @as(u64, width) * height > MAX_PIXELS) return error.InvalidDimensions;
    if (max_val != 255) return error.UnsupportedMaxVal;
    // Exactly one whitespace byte ends the header: the raster may begin with bytes that look like more.
    if (!std.ascii.isWhitespace(try reader.takeByte())) return error.InvalidFormat;

    const pixel_count = @as(usize, width) * height;
    const rgba = try gpa.alloc(u8, pixel_count * 4);
    errdefer gpa.free(rgba);
    // Read the RGB raster into the last three quarters of `rgba`, then widen it in place front to back:
    // pixel i is written to bytes 4i..4i+3, which stay below pixel i+1's source at n+3i+3, so no second
    // buffer is needed.
    const rgb = rgba[pixel_count..];
    try reader.readSliceAll(rgb);
    for (0..pixel_count) |i| {
        const r = rgb[3 * i];
        const g = rgb[3 * i + 1];
        const b = rgb[3 * i + 2];
        rgba[4 * i ..][0..4].* = .{ r, g, b, 255 };
    }
    return .{ .width = width, .height = height, .rgba = rgba };
}

// ============================================================
// Header parsing
// ============================================================

/// Reads one header number: at least one separator (whitespace, or a `#` comment through the end of its
/// line), then ASCII digits. The value saturates at maxInt(u32), far above anything `parse` accepts.
fn readHeaderNumber(reader: *std.Io.Reader) ParseError!u32 {
    var separated = false;
    while (true) {
        const byte = try reader.peekByte();
        if (std.ascii.isWhitespace(byte)) {
            reader.toss(1);
        } else if (byte == '#') {
            _ = try reader.discardDelimiterInclusive('\n');
        } else break;
        separated = true;
    }
    if (!separated) return error.InvalidFormat;

    var value: u32 = 0;
    var digit_count: usize = 0;
    while (reader.peekByte()) |byte| {
        if (!std.ascii.isDigit(byte)) break;
        reader.toss(1);
        value = value *| 10 +| (byte - '0');
        digit_count += 1;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    if (digit_count == 0) return error.InvalidFormat;
    return value;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn parseBytes(bytes: []const u8) ParseError!Image {
    var reader: std.Io.Reader = .fixed(bytes);
    return parse(testing.allocator, &reader);
}

test "parse: 2x1 image with a header comment" {
    var image = try parseBytes("P6\n# made by hand\n2 1\n255\n" ++ "\x10\x20\x30\x40\x50\x60");
    defer image.deinit(testing.allocator);
    try testing.expectEqual(2, image.width);
    try testing.expectEqual(1, image.height);
    try testing.expectEqualSlices(u8, &.{ 0x10, 0x20, 0x30, 255, 0x40, 0x50, 0x60, 255 }, image.rgba);
}

test "parse: one-line header, and raster bytes that look like whitespace or comments are pixels" {
    var image = try parseBytes("P6 3 1 255 " ++ "\n #" ++ "\t\r\n" ++ "#\x00\xff");
    defer image.deinit(testing.allocator);
    try testing.expectEqual(3, image.width);
    try testing.expectEqualSlices(u8, &.{ '\n', ' ', '#', 255, '\t', '\r', '\n', 255, '#', 0x00, 0xff, 255 }, image.rgba);
}

test "parse: widening in place keeps every pixel" {
    const header = "P6\n4 3\n255\n";
    var bytes: [header.len + 4 * 3 * 3]u8 = undefined;
    @memcpy(bytes[0..header.len], header);
    for (bytes[header.len..], 0..) |*byte, i| byte.* = @intCast(i);

    var image = try parseBytes(&bytes);
    defer image.deinit(testing.allocator);
    try testing.expectEqual(4 * 3 * 4, image.rgba.len);
    for (0..4 * 3) |p| {
        const expected = [4]u8{ @intCast(3 * p), @intCast(3 * p + 1), @intCast(3 * p + 2), 255 };
        try testing.expectEqualSlices(u8, &expected, image.rgba[4 * p ..][0..4]);
    }
}

test "parse: bad magic and maxvals other than 255 are rejected" {
    try testing.expectError(error.InvalidFormat, parseBytes("P3\n1 1\n255\n0 0 0\n"));
    try testing.expectError(error.InvalidFormat, parseBytes("P5\n1 1\n255\n\x00"));
    try testing.expectError(error.UnsupportedMaxVal, parseBytes("P6\n1 1\n65535\n\x00\x00\x00\x00\x00\x00"));
    try testing.expectError(error.UnsupportedMaxVal, parseBytes("P6\n1 1\n15\n\x00\x00\x00"));
}

test "parse: truncated input is an error" {
    const short_raster: [11]u8 = @splat(0); // 2x2 RGB needs 12 bytes
    try testing.expectError(error.EndOfStream, parseBytes("P6\n2 2\n255\n" ++ short_raster));
    try testing.expectError(error.EndOfStream, parseBytes("P6\n2 2\n255"));
    try testing.expectError(error.EndOfStream, parseBytes("P6\n2 2\n# unterminated comment"));
    try testing.expectError(error.EndOfStream, parseBytes("P"));
    try testing.expectError(error.EndOfStream, parseBytes(""));
}

test "parse: zero and oversized dimensions are rejected before allocating" {
    try testing.expectError(error.InvalidDimensions, parseBytes("P6\n0 1\n255\n"));
    try testing.expectError(error.InvalidDimensions, parseBytes("P6\n1 0\n255\n"));
    try testing.expectError(error.InvalidDimensions, parseBytes("P6\n16385 16384\n255\n"));
    try testing.expectError(error.InvalidDimensions, parseBytes("P6\n99999999999 1\n255\n"));
}

test "parse: malformed header numbers are rejected" {
    try testing.expectError(error.InvalidFormat, parseBytes("P61 1 255 \x00\x00\x00")); // no separator after P6
    try testing.expectError(error.InvalidFormat, parseBytes("P6 1x1 255 \x00\x00\x00"));
    try testing.expectError(error.InvalidFormat, parseBytes("P6 -1 1 255 \x00\x00\x00"));
    try testing.expectError(error.InvalidFormat, parseBytes("P6 1 1 255#\x00\x00\x00")); // maxval needs whitespace
}

test "load: reads a file relative to the cwd" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "pixel.ppm", .data = "P6\n1 1\n255\n\x28\x28\x2d" });

    // tmpDir lives at <cwd>/.zig-cache/tmp/<sub_path>, so it is reachable through load()'s cwd-relative path.
    var path_buf: [256]u8 = undefined;
    var image = try load(testing.allocator, io, try std.mem.print(&path_buf, ".zig-cache/tmp/{s}/pixel.ppm", .{&tmp.sub_path}));
    defer image.deinit(testing.allocator);
    try testing.expectEqual(1, image.width);
    try testing.expectEqual(1, image.height);
    try testing.expectEqualSlices(u8, &.{ 0x28, 0x28, 0x2d, 255 }, image.rgba);

    try testing.expectError(error.FileNotFound, load(testing.allocator, io, "no/such/image.ppm"));
    const dir_path = try std.mem.print(&path_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    try testing.expectError(error.IsDir, load(testing.allocator, io, dir_path));
}
