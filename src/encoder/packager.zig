const std = @import("std");
const model = @import("model.zig");
const BitWriter = @import("bit-writer.zig").BitWriter;
const PrefixCodes = @import("prefix-codes.zig").PrefixCodes;

pub const eob_symbol: u16 = 256;
pub const max_uncompressed_length: u16 = std.math.maxInt(u16);
pub const distance_code_bits: u8 = 5;


/// The `Packager` keeps track of a slice of input data and an a list of LZSS encoded tokens.
/// It can decided what block type matches best given the current LZSS data compared to the raw input.
pub const Packager = struct {
    io: std.Io,
    bit_writer: *BitWriter,
    lzss_stream: std.ArrayList(model.LZToken),
    max_size: u16 = max_uncompressed_length,
    read: u32 = 0,
    allocator: std.mem.Allocator,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, bit_writer: *BitWriter) !Packager {
        return .{
            .io = io,
            .allocator = allocator,
            .bit_writer = bit_writer,
            .lzss_stream = try std.ArrayList(model.LZToken).initCapacity(allocator, std.math.maxInt(u16))
        };
    }
    
    pub fn add(self: *Packager, token: model.LZToken) !void {
        const consumed = if (token == .literal) 1 else token.match.len;
        
        // if this token would exceed buffer limit => package first
        if (self.read + consumed >= self.max_size) {
            try self.package(false);
        }

        self.read += consumed;
        try self.lzss_stream.append(self.allocator, token);
    }
    
    /// Checks if now is a good time to package the data
    pub fn check() void {
        // TODO
    }
    
    /// packages the current data into the optimal block types and writes them to the output via the `BitWriter`
    pub fn package(self: *Packager, is_last: bool) !void {
        // TODO decide block dynamically and over ranges of the data, not all at once
        const btype: u2 = 0x01;
        
        const tokens = self.lzss_stream.items;
        
        std.log.debug("package {d} tokens", .{self.lzss_stream.items.len});

        switch (btype) {
            0 => try self.storeUncompressed(tokens, is_last),
            1 => try self.storeFixed(tokens, is_last),
            2 => {
            },
            else => {
            }
        }
        
        // reset for new data to come in
        self.read = 0;
        self.lzss_stream.clearRetainingCapacity();
        
        if (is_last) {
            // flush to byte align the data stream
            std.log.info("flush bit-writer to byte align data stream", .{});
            try self.bit_writer.flush();
        }
    }

    /// block type 00
    fn storeUncompressed(self: *Packager, tokens: []model.LZToken, is_last: bool) !void {
        const input_size = lengthOf(tokens);

        if (input_size >= max_uncompressed_length) {
            return error.BlockLengthExceeded;
        }

        const block_header: model.UncompressedBlockHeader = .{
            .bfinal = is_last,
            .len = input_size,
            .nlen = ~input_size
        };
        var header_bytes: [5]u8 = @bitCast(block_header);
        _ = try self.bit_writer.writeBytes(header_bytes[0..]);
        
        for (tokens) |token| {
            if (token == .literal) {
                _ = try self.bit_writer.writeBits(u8, token.literal);
            } else {
                _ = try self.bit_writer.writeBytes(token.match.consumed);
                self.allocator.free(token.match.consumed);
            }
        }
    }

    fn lengthOf(tokens: []model.LZToken) u16 {
        var length: u16 = 0;

        for (tokens) |token| {
            length += if (token == .literal) 1 else token.match.len;
        }

        return length;
    }

    /// block type 01
    fn storeFixed(self: *Packager, tokens: []model.LZToken, is_last: bool) !void {
        const prefix_codes = try PrefixCodes.getFixedPrefixCodes();

        const block_header: model.CompressedBlockHeader = .{
            .bfinal = @intFromBool(is_last),
            .btype = 0x01, // fixed 01
        };
        try self.bit_writer.writeBit(block_header.bfinal);
        try self.bit_writer.writeBits(u2, block_header.btype);
        
        for (tokens) |token| {
            if (token == .literal) {
                // write literals as prefix codes
                if (token.literal < eob_symbol) {
                    const code = prefix_codes[token.literal];
                    //std.log.debug("write literal code: ({b:0>7})", .{code.code});
                    try self.bit_writer.writeLength(code.code, code.length);
                }
            } else {
                //std.log.debug("({d}:{d})", .{token.match.len, token.match.dist});
                defer self.allocator.free(token.match.consumed); // this is not needed
                
                // write length part
                const length_code = try PrefixCodes.getLengthCode(token.match.len);
                const length_prefix_code = prefix_codes[length_code.code];
                std.log.info("write length code [{d}]: {d}:({b:0>7}), offset: {d}, extra_bits: {d}", .{token.match.len, length_prefix_code.code, length_prefix_code.code, length_code.offset, length_code.extra_bits});
                try self.bit_writer.writeLength(length_prefix_code.code, length_prefix_code.length);
                if (length_code.extra_bits > 0) {
                    try self.bit_writer.writeLengthLSB(length_code.offset, length_code.extra_bits);
                }
                
                // write distance part
                const distance_code = try PrefixCodes.getDistanceCode(token.match.dist);
                std.log.info("write distance code [{d}]: ({b:0>5}), offset: {d}, extra_bits: {d}", .{token.match.dist, distance_code.code, distance_code.offset, distance_code.extra_bits});
                try self.bit_writer.writeLength(distance_code.code, distance_code_bits);
                if (distance_code.extra_bits > 0) {
                    try self.bit_writer.writeLengthLSB(distance_code.offset, distance_code.extra_bits);
                }
            }
        }
        
        // write EOB
        const eob = prefix_codes[eob_symbol];
        try self.bit_writer.writeLength(eob.code, eob.length);
    }

    pub fn deinit(self: *Packager) void {
        self.lzss_stream.deinit(self.allocator);
    }
};