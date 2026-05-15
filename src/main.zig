const std = @import("std");
const Io = std.Io;

const gzig = @import("gzig");
const encoder = @import("encoder/encoder.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
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

test "duptest.txt" {
    try testFile("src/tests/duptest.txt", "src/tests/duptest.txt.gz");
}

test "example.txt" {
    try testFile("src/tests/example.txt", "src/tests/example.txt.gz");
}

test "test.txt" {
    try testFile("src/tests/test.txt", "src/tests/test.txt.gz");
}

test "lorem.txt" {
    try testFile("src/tests/lorem.txt", "src/tests/lorem.txt.gz");
}

test "DSC01560.jpg" {
    try testFile("src/tests/DSC01560.jpg", "src/tests/DSC01560.jpg.gz");
}

// These tests reference files not in the repository
// test "2-4mb.jpg" {
//     try testFile("test-files/2-4mb.jpg", "test-files/2-4mb.jpg.gz");
// }
// 
// test "2-5mb.jpg" {
//     try testFile("test-files/2-5mb.jpg", "test-files/2-5mb.jpg.gz");
// }
// 
// test "3-2mb.jpg" {
//     try testFile("test-files/3-2mb.jpg", "test-files/3-2mb.jpg.gz");
// }
// 
// test "4-3mb.jpg" {
//     try testFile("test-files/4-3mb.jpg", "test-files/4-3mb.jpg.gz");
// }
// 
// test "4-6mb.jpg" {
//     try testFile("test-files/4-6mb.jpg", "test-files/4-6mb.jpg.gz");
// }
// 
// test "4-8mb.jpg" {
//     try testFile("test-files/4-8mb.jpg", "test-files/4-8mb.jpg.gz");
// }
// 
// test "5mb.jpg" {
//     try testFile("test-files/5mb.jpg", "test-files/5mb.jpg.gz");
// }

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

    
    var child = try std.process.spawn(io, .{
        .argv = &[_][]const u8{ "gzip", "-t", "-v",  output_file_path }
    });

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| try testing.expectEqual(0, code),
        else => try testing.expect(false)
    }

    try Io.Dir.cwd().deleteFile(io, output_file_path);
}
