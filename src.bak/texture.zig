const std = @import("std");
const Io = std.Io;

pub const TextureData = struct {
    width: u64,
    height: u64,
    pixels: []u8, // Raw RGB bytes
    allocator: std.mem.Allocator,

    pub fn deinit(self: TextureData) void {
        self.allocator.free(self.pixels);
    }
};

pub fn loadPPM(allocator: std.mem.Allocator, path: []const u8, io_cap: Io) !TextureData {
    const file = try Io.Dir.cwd().openFile(io_cap, path, .{});
    defer file.close(io_cap);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = Io.File.Reader.init(.{ .handle = file.handle }, io_cap, &read_buffer);
    const reader = &file_reader.interface;

    // 1. Parse Header "P6"
    const magic = (try reader.takeDelimiter('\n')) orelse return error.InvalidFormat;
    if (!std.mem.eql(u8, magic, "P6")) return error.InvalidFormat;

    // 2. Parse Dimensions "Width Height"
    const dim_line = (try reader.takeDelimiter('\n')) orelse return error.InvalidFormat;
    var dim_it = std.mem.tokenizeAny(u8, dim_line, " ");
    const width_str = dim_it.next() orelse return error.InvalidFormat;
    const height_str = dim_it.next() orelse return error.InvalidFormat;

    const width = try std.fmt.parseInt(u64, width_str, 10);
    const height = try std.fmt.parseInt(u64, height_str, 10);

    // 3. Parse MaxVal (usually 255)
    const max_line = (try reader.takeDelimiter('\n')) orelse return error.InvalidFormat;
    const max_val = try std.fmt.parseInt(u64, max_line, 10);
    if (max_val != 255) return error.UnsupportedColorDepth;

    // 4. Allocate Pixel Buffer (Width * Height * 3 bytes for RGB)
    const total_bytes = width * height * 3;
    const pixels = try allocator.alloc(u8, total_bytes);
    errdefer allocator.free(pixels);

    // 5. Read Binary Data
    try reader.readSliceAll(pixels);

    // 6. Convert RGB to RGBA (Metal expects 4 bytes)
    const rgba_pixels = try allocator.alloc(u8, width * height * 4);
    var i: usize = 0;
    var j: usize = 0;
    while (i < total_bytes) : (i += 3) {
        rgba_pixels[j] = pixels[i]; // R
        rgba_pixels[j + 1] = pixels[i + 1]; // G
        rgba_pixels[j + 2] = pixels[i + 2]; // B
        rgba_pixels[j + 3] = 255; // A (Full Alpha)
        j += 4;
    }

    // Free the old RGB buffer
    allocator.free(pixels);

    return TextureData{
        .width = width,
        .height = height,
        .pixels = rgba_pixels,
        .allocator = allocator,
    };
}
