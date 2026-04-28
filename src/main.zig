const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const gzig = @import("gzig");
const encoder = @import("encoder/encoder.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) { // first arg is program name
        return error.NoFileSpecified;
    }
    
    const file_path = args[1];
    var compressor = encoder.Encoder{
        .file_path = file_path
    };
    
    try compressor.encode(io, gpa);
}

// tests
// ================================================== //

const testing = std.testing;

test "test encoding+decoding equals input file" {
    const io = testing.io;
    var compressor = encoder.Encoder{
        .file_path = "src/tests/loremipsum.txt"
    };
    var input_buf: [1024]u8 = undefined;
    const input_file = try Io.Dir.cwd().openFile(io, "./src/tests/loremipsum.txt", .{});
    const input_file_length = try input_file.length(io);
    var input_file_reader = input_file.reader(io, &input_buf);
    const input_content = try input_file_reader.interface.readAlloc(testing.allocator, input_file_length);
    defer testing.allocator.free(input_content);
    defer input_file.close(io);
    try compressor.encode(io, testing.allocator);
    
    var buffer: [std.compress.flate.max_window_len]u8 = undefined;
    const file = try Io.Dir.cwd().openFile(io, "src/tests/loremipsum.txt.gz", .{});
    var reader_buffer: [1024]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);

    var decompress = std.compress.flate.Decompress.init(&reader.interface, std.compress.flate.Container.gzip, &buffer);
    const output = try decompress.reader.readAlloc(testing.allocator, input_file_length);
    defer testing.allocator.free(output);
    try Io.Dir.cwd().deleteFile(io, "src/tests/loremipsum.txt.gz");

    try testing.expectEqualDeep(input_content, output);
}

