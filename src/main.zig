const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const gzig = @import("gzig");
const reader = @import("encoder/reader.zig");
const compressor = @import("encoder/compressor.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = Io.Dir.cwd();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) { // first arg is program name
        return error.NoFileSpecified;
    }
    
    const file_path = args[1];
    print("File: {s}\n", .{ file_path });

    const basename = std.fs.path.basename(file_path);
    print("basename: {s}\n", .{basename});
    
    const filename = std.fs.path.stem(file_path);
    print("filename: {s}\n", .{filename});
    
    var new_file_path: []u8 = undefined;

    const items = [_][]const u8{file_path, ".gz"};
    new_file_path = try std.mem.join(gpa, "", &items);
    
    defer gpa.free(new_file_path);
    const file = try cwd.openFile(io, file_path, .{});
    defer file.close(io);

    const output = try cwd.createFile(io, new_file_path, .{});
    defer output.close(io);
    
    try compressor.encode(io, gpa, &file, &output);
}
