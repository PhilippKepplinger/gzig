const std = @import("std");
const model = @import("model.zig");
const BitWriter = @import("bit-writer.zig").BitWriter;
const pc = @import("prefix-codes.zig");

pub const eob_symbol: u16 = 256;
pub const max_uncompressed_length: u16 = 32767;
pub const package_threshold: u32 = 65535;

const store_threshold = 0.01;
const fixed_threshold = 0.015;

/// The `Packager` keeps track of a slice of input data and an a list of LZSS encoded tokens.
/// It can decided what block type matches best given the current LZSS data compared to the raw input.
pub const Packager = struct {
    io: std.Io,
    bit_writer: *BitWriter,
    allocator: std.mem.Allocator,

    literal_stream: [package_threshold + 512]u8 = undefined, // tracks literals for potential stored blocks (+ overflow buffer)
    literals: u32 = 0, // how many literals are tracked

    tokens: u32 = 0,
    lzss_stream: [package_threshold]model.LZToken = undefined,
    literals_read: u32 = 0, // how many literals the lzss token stream represents

    ll_frequencies: [pc.unique_symbols]u16 = @splat(0),
    distance_frequencies: [pc.unique_distance_codes]u16 = @splat(0),

    pub fn init(io: std.Io, allocator: std.mem.Allocator, bit_writer: *BitWriter) !Packager {
        return .{
            .io = io,
            .allocator = allocator,
            .bit_writer = bit_writer,
        };
    }
    
    pub fn trackLiteral(self: *Packager, literal: u8) void {
        self.literal_stream[self.literals] = literal;
        self.literals += 1;
    }
    
    /// add a new token to the LZ Token stream
    pub fn add(self: *Packager, token: model.LZToken) !void {
        const consumed = if (token == .literal) 1 else token.match.length;

        // if this token would exceed buffer limit => package first
        if (self.literals_read <= max_uncompressed_length and self.literals_read + consumed > max_uncompressed_length) {
            try self.checkStoreUncompressed();
        }
        
        // if this token would exceed buffer limit => package first
        if (self.literals_read + consumed >= package_threshold) {
            try self.package(false);
        }
        
        // count length and distance symbol frequencies (for dynamic prefix codes)
        if (token == .literal) {
            self.ll_frequencies[token.literal] += 1;
        } else {
            self.ll_frequencies[token.match.length_symbol.symbol] += 1;
            self.distance_frequencies[token.match.distance_symbol.symbol] += 1;
        }

        self.literals_read += consumed;
        self.lzss_stream[self.tokens] = token;
        self.tokens += 1;
    }
    
    pub fn checkStoreUncompressed(self: *Packager) !void {
        if (self.getTokenRatio() <= store_threshold) {
            try self.storeUncompressed(self.literal_stream[0..self.literals_read], false);
        }
    }
    
    /// packages the current data into the optimal block types and writes them to the output via the `BitWriter`
    pub fn package(self: *Packager, is_last: bool) !void {
        const start = std.Io.Timestamp.now(self.io, std.Io.Clock.real);
        
        const tokens = self.lzss_stream[0..self.tokens];
        const token_ratio: f32 = self.getTokenRatio();
        
        if (self.literals_read > 1024 and token_ratio > fixed_threshold) {
            try self.storeDynamic(tokens, is_last);
        } else {
            try self.storeFixed(tokens, is_last);
        }

        if (is_last) {
            // flush to byte align the data stream
            std.log.debug("flush bit-writer to byte align data stream", .{});
            try self.bit_writer.flush();
        }
        
        const end = std.Io.Timestamp.now(self.io, std.Io.Clock.real);
        const duration = start.durationTo(end);
        std.log.debug("packaged {d} tokens in {d}ms", .{self.tokens, duration.toMilliseconds()});

        self.resetCounters();
    }

    fn getTokenRatio(self: *Packager) f32 {
        const savings_from_references = @as(f32, @floatFromInt(self.literals_read - self.tokens));
        return savings_from_references / @as(f32, @floatFromInt(self.literals_read));
    }
    
    /// block type 00
    fn storeUncompressed(self: *Packager, data: []u8, is_last: bool) !void {
        if (data.len > max_uncompressed_length) {
            return error.BlockLengthExceeded;
        }

        const length: u16 = @intCast(data.len);
        
        const block_header: model.UncompressedBlockHeader = .{
            .bfinal = @intFromBool(is_last),
            .len = length,
            .nlen = ~length
        };
        
        var header_bytes: [5]u8 = @bitCast(block_header);
        try self.bit_writer.writeBit(block_header.bfinal);
        try self.bit_writer.writeBits(u2, block_header.btype);
        try self.bit_writer.zeroPad();
        try self.bit_writer.writeBytes(header_bytes[1..]);
        try self.bit_writer.writeBytes(data);
        
        self.resetCounters();
    }
    
    fn resetCounters(self: *Packager) void {
        // shift remaining literal stream back to 0
        self.literals -= self.literals_read;
        for (0..self.literals) |i| {
            // we processed literals_read data, so we shift 
            self.literal_stream[i] = self.literal_stream[self.literals_read + i];
        }

        // reset for new data to come in
        self.literals_read = 0;
        self.tokens = 0;

        // reset frequency counters
        for (0..self.ll_frequencies.len) |i| {
            self.ll_frequencies[i] = 0;
        }
        for (0..self.distance_frequencies.len) |i| {
            self.distance_frequencies[i] = 0;
        }
    }

    /// block type 01
    fn storeFixed(self: *Packager, tokens: []model.LZToken, is_last: bool) !void {
        const ll_codes = try pc.PrefixCodes.getFixedPrefixCodes();

        const block_header: model.CompressedBlockHeader = .{
            .bfinal = @intFromBool(is_last),
            .btype = 0x01, // fixed 01
        };
        try self.bit_writer.writeBit(block_header.bfinal);
        try self.bit_writer.writeBits(u2, block_header.btype);
        
        for (tokens) |token| {
            if (token == .literal) {
                // write literals as prefix codes
                const code = ll_codes[token.literal];
                try self.bit_writer.writeLengthMSB(code.code, code.length);
            } else {
                // write length part
                const length_code = token.match.length_symbol;
                const length_prefix_code = ll_codes[length_code.symbol];
                try self.bit_writer.writeLengthMSB(length_prefix_code.code, length_prefix_code.length);
                if (length_code.extra_bits > 0) {
                    try self.bit_writer.writeLengthLSB(length_code.offset, length_code.extra_bits);
                }
                
                // write distance part
                const distance_code = token.match.distance_symbol;
                try self.bit_writer.writeLengthMSB(distance_code.symbol, pc.distance_code_bits);
                if (distance_code.extra_bits > 0) {
                    try self.bit_writer.writeLengthLSB(distance_code.offset, distance_code.extra_bits);
                }
            }
        }
        
        // write EOB
        const eob = ll_codes[eob_symbol];
        try self.bit_writer.writeLengthMSB(eob.code, eob.length);
    }
    
    fn storeDynamic(self: *Packager, tokens: []model.LZToken, is_last: bool) !void {
        self.ll_frequencies[eob_symbol] = 1; // there always needs to be exactly one EOB symbol at the end

        // 1. create ll codes
        const ll_code_lengths = pc.PrefixCodes.getCodeLengths(pc.unique_symbols, self.ll_frequencies[0..]);
        const ll_codes = pc.PrefixCodes.getPrefixCodes(pc.unique_symbols,ll_code_lengths);
        var ll_codes_used: u16 = ll_codes.len;
        while (ll_codes_used > 0 and ll_codes[ll_codes_used - 1].length == 0) {
            ll_codes_used -= 1;
        }
        const hlit: u5 = @intCast(ll_codes_used - 257);

        // 2. create distance codes
        const distance_code_lengths = pc.PrefixCodes.getCodeLengths(pc.unique_distance_codes, self.distance_frequencies[0..]);
        const distance_codes = pc.PrefixCodes.getPrefixCodes(pc.unique_distance_codes,distance_code_lengths);
        var dist_codes_used: u16 = distance_codes.len;
        while (dist_codes_used > 1 and distance_codes[dist_codes_used - 1].length == 0) {
            dist_codes_used -= 1;
        }
        const hdist: u5 = @intCast(dist_codes_used - 1);

        // 3. count cl frequencies and build cl token stream
        const total_ll_dist_symbols: u16 = ll_codes_used + dist_codes_used;
        var cl_frequencies: [pc.unique_cl_codes]u16 = @splat(0);
        var cl_stream: [30 + 286]model.LDCode = undefined;
        var cl_count: u16 = 0;
        var current_code_length: u8 = ll_code_lengths[0];
        var repetitions: u16 = 0;
        var covered_symbols: u16 = 0;

        // use a combined for loop for ll and distance code lengths
        for (1..total_ll_dist_symbols) |i| {
            // get current symbol from ll or distance code lengths
            var new_code_length: u8 = 0;
            if (i < ll_codes_used) {
                new_code_length = ll_code_lengths[i];
            } else {
                new_code_length = distance_code_lengths[i - ll_codes_used];
            }

            // same length, count repetition
            if (current_code_length == new_code_length) {
                repetitions += 1;
            }
            
            // different code_length or last element => construct cl_symbols
            if (current_code_length != new_code_length or i == (total_ll_dist_symbols - 1)) {
                // non-zero code lengths
                if (current_code_length > 0) {
                    // write symbol as preparation for repetitions
                    cl_stream[cl_count] = .{.symbol = current_code_length, .offset = 0, .extra_bits = 0};
                    cl_count += 1;
                    cl_frequencies[current_code_length] += 1;
                    covered_symbols += 1;
                    
                    while (repetitions >= 6) {
                        cl_stream[cl_count] = try pc.PrefixCodes.getCLSymbol(current_code_length, 6);
                        cl_frequencies[cl_stream[cl_count].symbol] += 1;
                        cl_count += 1;
                        covered_symbols += 6;
                        repetitions -= 6;
                        
                        // if there are still repetitions, repeat symbol and reduce repetitions
                        if (repetitions > 0) {
                            cl_stream[cl_count] = .{.symbol = current_code_length, .offset = 0, .extra_bits = 0};
                            cl_count += 1;
                            cl_frequencies[current_code_length] += 1;
                            covered_symbols += 1;
                            repetitions -= 1;
                        }
                    }
                    
                    if (repetitions >= 3) {
                        covered_symbols += repetitions;
                        cl_stream[cl_count] = try pc.PrefixCodes.getCLSymbol(current_code_length, repetitions);
                        cl_frequencies[cl_stream[cl_count].symbol] += 1;
                        cl_count += 1;
                    } else {
                        // too few repetitions, just write one by one
                        for (0..repetitions) |_| {
                            cl_stream[cl_count] = .{.symbol = current_code_length, .offset = 0, .extra_bits = 0};
                            cl_count += 1;
                            cl_frequencies[current_code_length] += 1;
                            covered_symbols += 1;
                        }
                    }
                    
                    repetitions = 0;
                } else { // zero code length
                    var zero_count = repetitions + 1;
                    while (zero_count >= 138) {
                        covered_symbols += 138;
                        cl_stream[cl_count] = try pc.PrefixCodes.getCLSymbol(0, 138);
                        cl_frequencies[cl_stream[cl_count].symbol] += 1;
                        cl_count += 1;
                        zero_count -= 138;
                    }
                    
                    if (zero_count >= 11) {
                        covered_symbols += zero_count;
                        cl_stream[cl_count] = try pc.PrefixCodes.getCLSymbol(0, zero_count);
                        cl_frequencies[cl_stream[cl_count].symbol] += 1;
                        cl_count += 1;
                    } else if (zero_count >= 3) {
                        covered_symbols += zero_count;
                        cl_stream[cl_count] = try pc.PrefixCodes.getCLSymbol(0, zero_count);
                        cl_frequencies[cl_stream[cl_count].symbol] += 1;
                        cl_count += 1;
                    } else {
                        // too few repetitions, just write one by one
                        for (0..zero_count) |_| {
                            covered_symbols += 1;
                            cl_stream[cl_count] = .{.symbol = 0, .offset = 0, .extra_bits = 0};
                            cl_count += 1;
                            cl_frequencies[0] += 1;
                        }
                    }
                    
                    repetitions = 0;
                }
                
                // last symbol is different but also the last => write the new (last symbol)
                if (current_code_length != new_code_length and i == (total_ll_dist_symbols - 1)) {
                    cl_stream[cl_count] = .{.symbol = new_code_length, .offset = 0, .extra_bits = 0};
                    cl_count += 1;
                    cl_frequencies[new_code_length] += 1;
                    covered_symbols += 1;
                }
                
                current_code_length = new_code_length;
            }
        }

        // 4. create cl codes
        const cl_code_lengths = pc.PrefixCodes.getCodeLengths(pc.unique_cl_codes, cl_frequencies[0..]);
        const cl_codes = pc.PrefixCodes.getPrefixCodes(pc.unique_cl_codes,cl_code_lengths);
        var cl_codes_used: u16 = cl_codes.len; // order: 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
        for (0..8) |i| {
            if (cl_codes[15 - i].length == 0) cl_codes_used -= 1 else break;
            if (cl_codes[1 + i].length == 0) cl_codes_used -= 1 else break;
        }
        const hclen: u4 = @intCast(cl_codes_used - 4);

        // 5. write header
        const header = model.DynamicBlockHeader {
            .bfinal = @intFromBool(is_last),
            .btype = 0x02, //fixed
            .hlit = hlit, // ll codes - 257 (values: 0 - 29)
            .hdist = hdist, // dist codes - 1 => (values: 0 - 29)
            .hclen = hclen
        };
        
        try self.bit_writer.writeBit(header.bfinal);
        try self.bit_writer.writeBits(u2, header.btype);
        try self.bit_writer.writeBits(u5, header.hlit);
        try self.bit_writer.writeBits(u5, header.hdist);
        try self.bit_writer.writeBits(u4, header.hclen);

        // 6. write cl code lengths in order: 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
        try self.bit_writer.writeLengthLSB(cl_code_lengths[16], 3);
        try self.bit_writer.writeLengthLSB(cl_code_lengths[17], 3);
        try self.bit_writer.writeLengthLSB(cl_code_lengths[18], 3);
        try self.bit_writer.writeLengthLSB(cl_code_lengths[0], 3);
        for (0..hclen) |i| {
            const increment = i / 2;
            if (i % 2 == 0) {
                try self.bit_writer.writeLengthLSB(cl_code_lengths[8 + increment], 3);
            } else {
                try self.bit_writer.writeLengthLSB(cl_code_lengths[7 - increment], 3);
            }
        }
        
        // write ll and distance codes with cl codes
        for (0..cl_count) | i | {
            const ld_code = cl_stream[i];
            const cl_code = cl_codes[ld_code.symbol];
            
            try self.bit_writer.writeLengthMSB(cl_code.code, cl_code.length);
            if (ld_code.extra_bits > 0) {
                try self.bit_writer.writeLengthLSB(ld_code.offset, ld_code.extra_bits);
            }
        }

         // 9. tokens
         for (tokens) |token| {
            if (token == .literal) {
                // write literals as prefix codes
                const code = ll_codes[token.literal];
                try self.bit_writer.writeLengthMSB(code.code, code.length);
            } else {
                // write length part
                const length_code = token.match.length_symbol;
                const length_prefix_code = ll_codes[length_code.symbol];
                try self.bit_writer.writeLengthMSB(length_prefix_code.code, length_prefix_code.length);
                if (length_code.extra_bits > 0) {
                    try self.bit_writer.writeLengthLSB(length_code.offset, length_code.extra_bits);
                }

                // write distance part
                const distance_code = token.match.distance_symbol;
                const distance_prefix_code = distance_codes[distance_code.symbol];
                try self.bit_writer.writeLengthMSB(distance_prefix_code.code, distance_prefix_code.length);
                if (distance_code.extra_bits > 0) {
                    try self.bit_writer.writeLengthLSB(distance_code.offset, distance_code.extra_bits);
                }
            }
        }

        // write EOB
        const eob = ll_codes[eob_symbol];
        try self.bit_writer.writeLengthMSB(eob.code, eob.length);
    }
};