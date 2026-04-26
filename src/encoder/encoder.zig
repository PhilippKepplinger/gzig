const std = @import("std");
const Io = std.Io;
const log = std.log;
const Allocator = std.mem.Allocator;

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
        
        self.output = try self.create_output_file(io, allocator);
        defer self.output.close(io);

        const buf_size = 1024 * 1024; // 1 MiB
        var output_buf: [buf_size]u8 = undefined;
        self.writer = self.output.writer(io, &output_buf);

        var reader_buf: [buf_size]u8 = undefined;
        self.reader = self.input.reader(io, &reader_buf);
        const input_length = try self.reader.file.length(io);

        const header = GzHeader{};
        log.debug("Header: {b} {b} {b} {b} {b} {b} {b}\n", .{ header.id1, header.id2, header.cm, header.flags, header.mtime, header.xfl, header.os });
        const header_bits: u80 = @bitCast(header);
        log.debug("0X{X}\n", .{ header_bits });
        _ = try self.writer.interface.writeInt(u80, header_bits, std.builtin.Endian.little);
        try self.writer.flush();

        // write blocks per block to file
        var read_buf: [buf_size]u8 = undefined;
        while (!self.reader.atEnd()) {
            const read = try self.reader.interface.readSliceShort(read_buf[0..]);

            if (read > 0) {
                const chunk = read_buf[0..read]; // for when read < read_buf.len
                self.crc32.update(chunk);
                try self.store_uncompressed(chunk, self.reader.atEnd());
            }
        }

        const footer = try getFooter(self.crc32.final(), input_length);
        log.debug("CRC: 0x{X}, ISIZE: 0x{X}\n", .{ footer.crc32, footer.isize });
        const footer_bits: u64 = @bitCast(footer);
        _ = try self.writer.interface.writeInt(u64, footer_bits, std.builtin.Endian.little);
        try self.writer.flush();
    }

    fn create_output_file(self: *Encoder, io: Io, allocator: Allocator) !Io.File {
        const items = [_][]const u8{self.file_path, ".gz"};
        const new_file_path = try std.mem.join(allocator, "", &items);
        defer allocator.free(new_file_path);
        
        return try Io.Dir.cwd().createFile(io, new_file_path, .{});
    }
    
    fn store_uncompressed(self: *Encoder, data: []u8, is_last: bool) !void {
        const input_size = data.len;
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
        _ = try self.writer.interface.writeInt(u40, header_bits, std.builtin.Endian.little);
        _ = try self.writer.interface.writeAll(data);
        try self.writer.flush();
    }

    fn getFooter(crc32: u32, input_length: usize) !GzFooter {
        return .{
            .crc32 = crc32,
            .isize = @intCast(input_length % @as(u32, std.math.maxInt(u32) - 1))
        };
    }
};

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
    is_last: bool, // true if last block 
    btype: u2 = 0x0, // 0 = uncompressed
    padding: u5 = 0x0, // fixed 5 bits zero padding
    len: u16, // length of the data
    nlen: u16, // complement of length
};