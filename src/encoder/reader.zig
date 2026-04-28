const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Reads the full content of the file.
/// Probably not a good idea for large files
/// @deprecated
pub fn readFile(io: Io, allocator: Allocator, path: []const u8) ![]u8 {
    const file = try Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);

    const file_length = try file.length(io);
    var file_buffer: [1024]u8 = undefined;
    var reader = file.reader(io, &file_buffer);
    const data = try reader.interface.readAlloc(allocator, file_length);
    return data;
}