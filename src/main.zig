const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const gzig = @import("gzig");
const encoder = @import("encoder/encoder.zig");

pub const std_options: std.Options = .{
    .log_level = .warn,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) { // first arg is program name
        return error.NoFileSpecified;
    }
    
    const file_path = args[1];
    var compressor = encoder.Encoder.init(io, gpa);
    
    try compressor.encode(file_path);
}

// tests
// ================================================================================================================== //

const testing = std.testing;

test "salad.txt" {
    try testFile("src/tests/salad.txt", "src/tests/salad.txt.gz");
}

test "test.txt" {
    try testFile("src/tests/test.txt", "src/tests/test.txt.gz");
}

test "duptest.txt" {
    try testFile("src/tests/duptest.txt", "src/tests/duptest.txt.gz");
}

test "lorem.txt" {
    try testFile("src/tests/lorem.txt", "src/tests/lorem.txt.gz");
}

fn testFile(input_file_path: []const u8, output_file_path: []const u8) !void {
    const io = testing.io;
    var compressor = encoder.Encoder.init(io, testing.allocator);
    var input_buf: [1024]u8 = undefined;
    const input_file = try Io.Dir.cwd().openFile(io, input_file_path, .{});
    const input_file_length = try input_file.length(io);
    var input_file_reader = input_file.reader(io, &input_buf);
    const input_content = try input_file_reader.interface.readAlloc(testing.allocator, input_file_length);
    defer testing.allocator.free(input_content);
    defer input_file.close(io);
    try compressor.encode(input_file_path);

    var buffer: [std.compress.flate.max_window_len]u8 = undefined;
    const file = try Io.Dir.cwd().openFile(io, output_file_path, .{});
    var reader_buffer: [1024]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);

    var decompress = std.compress.flate.Decompress.init(&reader.interface, std.compress.flate.Container.gzip, &buffer);
    const output = try decompress.reader.readAlloc(testing.allocator, input_file_length);
    defer testing.allocator.free(output);
    try Io.Dir.cwd().deleteFile(io, output_file_path);

    try testing.expectEqualDeep(input_content, output);
}
