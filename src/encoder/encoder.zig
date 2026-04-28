const std = @import("std");
const Io = std.Io;
const log = std.log;
const BitWriter = @import("bit-writer.zig").BitWriter;
const Allocator = std.mem.Allocator;

pub const max_alphabet_symbol = 288;
pub const eob_symbol = 256;
pub const max_prefixcode_bits = 15;
pub const distnace_code_bits = 5;

const buf_size = 1024 * 64;

pub const Encoder = struct {
    file_path: []const u8 = undefined,
    input: Io.File = undefined,
    reader: Io.File.Reader = undefined,
    
    output: Io.File = undefined,
    writer: Io.File.Writer = undefined,
    
    crc32: CRC32 = undefined,

    pub fn encode(self: *Encoder, io: Io, allocator: Allocator) !void {
        self.crc32 = .{};
        self.input = try Io.Dir.cwd().openFile(io, self.file_path, .{});
        defer self.input.close(io);
        
        self.output = try self.createOutputFile(io, allocator);
        defer self.output.close(io);

        var output_buf: [buf_size]u8 = undefined;
        self.writer = self.output.writer(io, &output_buf);

        var reader_buf: [buf_size]u8 = undefined;
        self.reader = self.input.reader(io, &reader_buf);
        const input_length = try self.reader.file.length(io);

        const header = GzHeader{};
        log.debug("Header: {X} {X} {X} {X} {X} {X} {X}", .{ header.id1, header.id2, header.cm, header.flags, header.mtime, header.xfl, header.os });
        log.debug("Header: {b:0>8} {b:0>8} {b:0>8} {b:0>8} {b:0>8} {b:0>8} {b:0>8}", .{ header.id1, header.id2, header.cm, header.flags, header.mtime, header.xfl, header.os });
        var header_bytes: [10]u8 = @bitCast(header);
        var bit_writer = BitWriter.init(&self.writer.interface);
        try bit_writer.writeBytes(header_bytes[0..]);
        log.debug("0x{X}\n", .{ header_bytes });
        try self.writer.flush();

        // write blocks per block to file
        var read_buf: [buf_size]u8 = undefined;
        while (!self.reader.atEnd()) {
            const read = try self.reader.interface.readSliceShort(read_buf[0..]);

            if (read > 0) {
                const chunk = read_buf[0..read]; // for when read < read_buf.len
                self.crc32.update(chunk);
                log.debug("block: {d}", .{chunk.len});
                try self.storeFixed(chunk, self.reader.atEnd());
                // try self.storeUncompressed(chunk, self.reader.atEnd());
            }
        }

        const footer = try getFooter(self.crc32.final(), input_length);
        log.debug("CRC: 0x{X}, ISIZE: 0x{X}", .{ footer.crc32, footer.isize });
        var footer_bytes: [8]u8 = @bitCast(footer);
        try bit_writer.writeBytes(footer_bytes[0..]);
        try self.writer.flush();
    }

    fn createOutputFile(self: *Encoder, io: Io, allocator: Allocator) !Io.File {
        const items = [_][]const u8{self.file_path, ".gz"};
        const new_file_path = try std.mem.join(allocator, "", &items);
        defer allocator.free(new_file_path);
        
        return try Io.Dir.cwd().createFile(io, new_file_path, .{});
    }
    
    fn storeUncompressed(self: *Encoder, data: []u8, is_last: bool) !void {
        const input_size = data.len;
        const maxLen = std.math.maxInt(u16);
    
        if (input_size >= maxLen) {
            return error.BlockLengthExceeded;
        }
    
        const input_len: u16 = @intCast(input_size);
    
        const block_header: UncompressedBlockHeader = .{
            .bfinal = is_last, 
            .len = input_len, 
            .nlen = ~input_len
        };
        const header_bits: u40 = @bitCast(block_header);
        _ = try self.writer.interface.writeInt(u40, header_bits, std.builtin.Endian.little);
        _ = try self.writer.interface.writeAll(data);
        try self.writer.flush();
    }
    
    fn storeFixed(self: *Encoder, data: []u8, is_last: bool) !void {
        // setup code_lengths for the alphabet
        var code_lengths: [max_alphabet_symbol]u4 = undefined;
        for (0..max_alphabet_symbol) |symbol| {
            code_lengths[symbol] = try getFixedCodeLength(symbol);
        }
        const prefix_codes = getFixedPrefixCodes(code_lengths);
        
        const block_header: CompressedBlockHeader = .{
            .bfinal = @intFromBool(is_last),
            .btype = 0x01, // fixed 01
        };
        
        var bit_writer = BitWriter.init(&self.writer.interface);
        try bit_writer.writeBit(block_header.bfinal);
        try bit_writer.writeBits(u2, block_header.btype);

        // TODO apply LZSS length/distance encoding
        
        // write literals as codes
        for (data) |literal| {
            if (literal < eob_symbol) {
                const code = prefix_codes[literal];
                try bit_writer.writeLength(code.code, code.length);
            }
            // TODO encode length/distance codes with offsets as prefix codes
        }
        
        // write EOB
        const eob = prefix_codes[eob_symbol];
        try bit_writer.writeLength(eob.code, eob.length);
        try bit_writer.flush();
    }
    
    fn getFooter(crc32: u32, input_length: usize) !GzFooter {
        return .{
            .crc32 = crc32,
            .isize = @intCast(input_length % @as(u32, std.math.maxInt(u32) - 1))
        };
    }
};

/// standard algorithm for calculating prefix codes according to RFC1951 3.2.2
/// https://datatracker.ietf.org/doc/html/rfc1951#page-7
pub fn getFixedPrefixCodes(code_lengths: [max_alphabet_symbol]u4) [max_alphabet_symbol]PrefixCode {
    var prefix_codes: [max_alphabet_symbol]PrefixCode = undefined;
    
    // step 1
    // count occurrences of each code length. max 15 bit 
    var bitlength_count = std.mem.zeroes([max_prefixcode_bits + 1]u9);
    for (code_lengths) |value| {
        bitlength_count[value] += 1;
    }

    // step 2
    // initialize the start code for each code length with the smallest code
    var code: u16 = 0;
    var next_code: [max_prefixcode_bits + 1]u16 = undefined;
    for (1..(max_prefixcode_bits + 1)) |bits| {
        // last code + amount of previous bit length codes 
        code = (code + bitlength_count[bits - 1]) << 1;
        next_code[bits] = code;
    }

    // step 3
    // assign consecutive code values for all codes of the same code length with the base values from step 2
    for (code_lengths, 0..) |bitlength, symbol| {
        if (bitlength > 0) {
            prefix_codes[symbol] = .{
                .code = next_code[bitlength],
                .length = bitlength,
            };
            next_code[bitlength] += 1;
        }
    }
    
    return prefix_codes;
}

/// fixed code lengths according to RFC1951 3.2.6
/// https://datatracker.ietf.org/doc/html/rfc1951#page-12
pub fn getFixedCodeLength(value: usize) !u4 {
    if (value <= 143) {
        return 8;
    } else if (value <= 255) {
        return 9;
    } else if (value <= 279) {
        return 7;
    } else  if (value < max_alphabet_symbol){
        return 8;
    } else {
        return error.UnsupportedSymbol;
    }
}

/// wrapper around std.hash.Crc32
const CRC32 = struct {
    crc: std.hash.Crc32 = std.hash.Crc32.init(),
    
    pub fn update(self: *CRC32, data: []u8) void {
        if (data.len > 0) {
            self.crc.update(data);
        }
    }
    
    pub fn final(self: *CRC32) u32 {
        return self.crc.final();
    }
};

// =================== //
// ===== structs ===== //
// =================== //

/// .gz file header.
const GzHeader = packed struct {
    id1: u8 = 0x1f, // fixed magic number of .gz
    id2: u8 = 0x8b, // fixed magic number of .gz
    cm: u8 = 0x08, // deflate, no other compression supported
    flags: u8 = 0x00, // all flags disabled by default
    mtime: u32 = 0x00000000, // no modification time by default
    xfl: u8 = 0x00, // all extra flags disabled by default
    os: u8 = 0x03, // defaults to unix
};

/// .gz file footer
const GzFooter = packed struct {
    crc32: u32,
    isize: u32,
};

/// block type 00
const UncompressedBlockHeader = packed struct {
    bfinal: bool, // true if last block 
    btype: u2 = 0x0, // 0 = uncompressed
    padding: u5 = 0x0, // fixed 5 bits zero padding
    len: u16, // length of the data
    nlen: u16, // complement of length
};

/// block type 01 and 01
const CompressedBlockHeader = packed struct {
    bfinal: u1, // true if last block 
    btype: u2 = 0x0, // 0 = uncompressed
};

const PrefixCode = struct {
    length: u4,
    code: u16,
};

const testing = std.testing;
test "test fixed prefix codes for block type 01" {
    var code_lengths: [max_alphabet_symbol]u4 = undefined;
    for (0..max_alphabet_symbol) |i| {
        code_lengths[i] = try getFixedCodeLength(i);
    }

    const code_table = getFixedPrefixCodes(code_lengths);

    try testing.expectEqual(48, code_table[0].code);
    try testing.expectEqual(113, code_table[65].code);
    try testing.expectEqual(191, code_table[143].code);
    try testing.expectEqual(400, code_table[144].code);
    try testing.expectEqual(400, code_table[144].code);
    try testing.expectEqual(511, code_table[255].code);
    try testing.expectEqual(0, code_table[256].code);
    try testing.expectEqual(23, code_table[279].code);
    try testing.expectEqual(192, code_table[280].code);
    try testing.expectEqual(199, code_table[287].code);
}