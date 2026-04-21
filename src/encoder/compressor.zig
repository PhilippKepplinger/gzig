const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn encode(
    io: Io, 
    allocator: Allocator, 
    input: *const Io.File, 
    output: *const Io.File
) !void {
    _ = allocator;
    
    const buf_size = 2^20; // 1 MiB
    var output_buf: [buf_size]u8 = undefined;
    var writer = output.writer(io, &output_buf);
    
    var reader_buf: [buf_size]u8 = undefined;
    var reader = input.reader(io, &reader_buf);
    
    const header = Header{};
    std.debug.print("{b} {b} {b} {b} {b} {b} {b}\n", .{ header.id1, header.id2, header.cm, header.flags, header.mtime, header.xfl, header.os });
    const header_bits: u80 = @bitCast(header);
    _ = try writer.interface.writeInt(u80, header_bits, std.builtin.Endian.little);
    try writer.flush();
    
    // write blocks per block to file
    var read_buf: [buf_size]u8 = undefined;
    while (!reader.atEnd()) {
        const read = try reader.interface.readSliceShort(read_buf[0..]);
        
        if (read > 0) {
           try store(read_buf[0..read], reader.atEnd(), &writer.interface);
        }
    }
    
    const footer = try getFooter(io, input);
    std.debug.print("{d} {d}\n", .{ footer.crc32, footer.isize });
    std.debug.print("{b} {b}\n", .{ footer.crc32, footer.isize });
    std.debug.print("0x{X} 0x{X}\n", .{ footer.crc32, footer.isize });
    const footer_bits: u64 = @bitCast(footer);
    _ = try writer.interface.writeInt(u64, footer_bits, std.builtin.Endian.little);
    try writer.flush();
}

/// creates a single 00 type block in the .gz bitstream
fn store(input: []u8, is_last: bool, writer: *Io.Writer) !void {
    const input_size = input.len;
    std.debug.print("block: {s}\n", .{input});
    const maxLen = std.math.maxInt(u16);

    if (input_size >= maxLen) {
        return error.BlockLengthExceeded;
    }

    const input_len: u16 = @intCast(input_size);
    
    const block_header: UncompressedBlockHeader = .{
        .is_last = is_last, 
        .len = input_len, 
        .nlen = ~input_len
    };
    const header_bits: u40 = @bitCast(block_header);
    _ = try writer.writeInt(u40, header_bits, std.builtin.Endian.little);
    _ = try writer.writeAll(input);
    try writer.flush();
}

fn getFooter(io: Io, input: *const Io.File) !Footer {
    const input_length = try input.length(io);
    
    return .{
        .crc32 = try crc32(io, input), 
        .isize = @intCast(input_length % @as(u32, std.math.maxInt(u32) - 1)) 
    };
}

fn crc32(io: Io, input: *const Io.File) !u32 {
    const buffer_size = 1024 * 1024; // 1 Mib

    var crc = std.hash.Crc32.init();
    var buffer: [buffer_size]u8 = undefined;
    var reader = input.reader(io, &buffer);
    
    var buf: [buffer_size]u8 = undefined;

    while (!reader.atEnd()) {
        const read = try reader.interface.readSliceShort(buf[0..]);
        if (read > 0) {
            crc.update(buf[0..read]);
        }
    }
    
    return crc.final();
}

// =================== //
// ===== structs ===== //
// =================== //

/// .gz file header.
const Header = packed struct {
    id1: u8 = 0x1f, // fixed magic number of .gz
    id2: u8 = 0x8b, // fixed magic number of .gz
    cm: u8 = 0x08, // deflate, no other compression supported
    flags: u8 = 0x00, // all flags disabled by default
    mtime: u32 = 0x00000000, // no modification time by default
    xfl: u8 = 0x00, // all extra flags disabled by default
    os: u8 = 0x03, // defaults to unix
};

/// .gz file footer
const Footer = packed struct {
    crc32: u32,
    isize: u32,
};

const UncompressedBlockHeader = packed struct {
    is_last: bool,
    btype: u2 = 0x0, // fixed
    padding: u5 = 0x0, // 5 bits zero padding
    len: u16, // length of the data
    nlen: u16, // bit inversion of length
};