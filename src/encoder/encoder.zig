const std = @import("std");
const Io = std.Io;
const log = std.log;
const Allocator = std.mem.Allocator;

const model = @import("model.zig");
const PrefixCodes = @import("prefix-codes.zig").PrefixCodes;
const BitWriter = @import("bit-writer.zig").BitWriter;
const Packager = @import("packager.zig").Packager;
const lzss = @import("lzss.zig");

pub const read_buffer_size: u16 = 65535; // 65535
pub const search_buffer_size: u32 = 32768; // 32768
pub const checkpoint_size: u16 = (read_buffer_size + 1) / 4; // 16384
pub const lookahead_size: u16 = 258;

pub const Encoder = struct {
    io: Io,
    allocator: Allocator,
    input: Io.File = undefined,
    reader: Io.File.Reader = undefined,
    output: Io.File = undefined,
    writer: Io.File.Writer = undefined,
    bit_writer: BitWriter = undefined,
    crc32: CRC32 = undefined,

    pub fn init(io: Io, allocator: Allocator) Encoder {
        return .{
            .io = io,
            .allocator = allocator,
        };
    }
    
    pub fn encode(self: *Encoder, file_path: []const u8) !void {
        self.crc32 = .{};
        self.input = try Io.Dir.cwd().openFile(self.io, file_path, .{});
        defer self.input.close(self.io);
        
        self.output = try self.createOutputFile(file_path);
        defer self.output.close(self.io);

        var output_buf: [read_buffer_size]u8 = undefined;
        self.writer = self.output.writer(self.io, &output_buf);
        self.bit_writer = BitWriter.init(&self.writer.interface);

        var reader_buf: [read_buffer_size]u8 = undefined;
        self.reader = self.input.reader(self.io, &reader_buf);

        const header = model.GzHeader{};
        log.info("Header: {X} {X} {X} {X} {X} {X} {X}", .{ header.id1, header.id2, header.cm, header.flags, header.mtime, header.xfl, header.os });
        log.info("Header: {b:0>8} {b:0>8} {b:0>8} {b:0>8} {b:0>8} {b:0>8} {b:0>8}", .{ header.id1, header.id2, header.cm, header.flags, header.mtime, header.xfl, header.os });
        var header_bytes: [10]u8 = @bitCast(header);
        try self.bit_writer.writeBytes(header_bytes[0..]);
        try self.bit_writer.flush();

        var packager = try Packager.init(self.allocator, &self.bit_writer);
        defer packager.deinit();
        var lzss_buffer: [lzss.search_buffer_size]u8 = undefined;
        var lzss_encoder = try lzss.LZSS.init(self.allocator, &packager, &lzss_buffer);
        
        // write blocks per block to file
        var read_buf: [read_buffer_size]u8 = undefined;
        var is_last = self.reader.atEnd();

        while (!is_last) {
            const bytes_read = try self.reader.interface.readSliceShort(&read_buf);
            is_last = self.reader.atEnd();

            if (bytes_read > 0) {
                const read_chunk = read_buf[0..bytes_read]; // for when read < read_buf.len, usually at EOF
                
                std.log.info("read new chunk from input file: {d}", .{bytes_read});
                
                for (read_chunk) |literal| {
                   try lzss_encoder.process(literal);
                }
                
                self.crc32.update(read_chunk);
            }
            
            if (is_last) {
                try lzss_encoder.finish();
            }
        }

        const input_length = try self.reader.file.length(self.io);
        const footer = try getFooter(self.crc32.final(), input_length);
        log.info("CRC: 0x{X}, ISIZE: 0x{X}", .{ footer.crc32, footer.isize });
        var footer_bytes: [8]u8 = @bitCast(footer);
        try self.bit_writer.writeBytes(footer_bytes[0..]);
        try self.bit_writer.flush(); // empty the bit_writer buffer
        try self.writer.flush(); // flush data to output writer
    }

    fn createOutputFile(self: *Encoder, file_path: []const u8) !Io.File {
        const items = [_][]const u8{file_path, ".gz"};
        const new_file_path = try std.mem.join(self.allocator, "", &items);
        defer self.allocator.free(new_file_path);
        
        return try Io.Dir.cwd().createFile(self.io, new_file_path, .{});
    }
    
    fn getFooter(crc32: u32, input_length: usize) !model.GzFooter {
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

// tests
// ================================================================================================================== //
