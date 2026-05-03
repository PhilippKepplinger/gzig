const std = @import("std");
const model = @import("model.zig");

pub const max_alphabet_symbol: u16 = 288;
pub const max_prefixcode_bits: u8 = 15;
const length_table = [_]model.CodeLookup{
    .{ .min = 3,   .max = 3,   .base_code = 257, .extra_bits = 0 },
    .{ .min = 4,   .max = 4,   .base_code = 258, .extra_bits = 0 },
    .{ .min = 5,   .max = 5,   .base_code = 259, .extra_bits = 0 },
    .{ .min = 6,   .max = 6,   .base_code = 260, .extra_bits = 0 },
    .{ .min = 7,   .max = 7,   .base_code = 261, .extra_bits = 0 },
    .{ .min = 8,   .max = 8,   .base_code = 262, .extra_bits = 0 },
    .{ .min = 9,   .max = 9,   .base_code = 263, .extra_bits = 0 },
    .{ .min = 10,  .max = 10,  .base_code = 264, .extra_bits = 0 },
    .{ .min = 11,  .max = 12,  .base_code = 265, .extra_bits = 1 },
    .{ .min = 13,  .max = 14,  .base_code = 266, .extra_bits = 1 },
    .{ .min = 15,  .max = 16,  .base_code = 267, .extra_bits = 1 },
    .{ .min = 17,  .max = 18,  .base_code = 268, .extra_bits = 1 },
    .{ .min = 19,  .max = 22,  .base_code = 269, .extra_bits = 2 },
    .{ .min = 23,  .max = 26,  .base_code = 270, .extra_bits = 2 },
    .{ .min = 27,  .max = 30,  .base_code = 271, .extra_bits = 2 },
    .{ .min = 31,  .max = 34,  .base_code = 272, .extra_bits = 2 },
    .{ .min = 35,  .max = 42,  .base_code = 273, .extra_bits = 3 },
    .{ .min = 43,  .max = 50,  .base_code = 274, .extra_bits = 3 },
    .{ .min = 51,  .max = 58,  .base_code = 275, .extra_bits = 3 },
    .{ .min = 59,  .max = 66,  .base_code = 276, .extra_bits = 3 },
    .{ .min = 67,  .max = 82,  .base_code = 277, .extra_bits = 4 },
    .{ .min = 83,  .max = 98,  .base_code = 278, .extra_bits = 4 },
    .{ .min = 99,  .max = 114, .base_code = 279, .extra_bits = 4 },
    .{ .min = 115, .max = 130, .base_code = 280, .extra_bits = 4 },
    .{ .min = 131, .max = 162, .base_code = 281, .extra_bits = 5 },
    .{ .min = 163, .max = 194, .base_code = 282, .extra_bits = 5 },
    .{ .min = 195, .max = 226, .base_code = 283, .extra_bits = 5 },
    .{ .min = 227, .max = 257, .base_code = 284, .extra_bits = 5 },
    .{ .min = 258, .max = 258, .base_code = 285, .extra_bits = 0 },
};

const distance_table = [_]model.CodeLookup{
    .{ .min = 1,     .max = 1,     .base_code = 0,  .extra_bits = 0 },
    .{ .min = 2,     .max = 2,     .base_code = 1,  .extra_bits = 0 },
    .{ .min = 3,     .max = 3,     .base_code = 2,  .extra_bits = 0 },
    .{ .min = 4,     .max = 4,     .base_code = 3,  .extra_bits = 0 },
    .{ .min = 5,     .max = 6,     .base_code = 4,  .extra_bits = 1 },
    .{ .min = 7,     .max = 8,     .base_code = 5,  .extra_bits = 1 },
    .{ .min = 9,     .max = 12,    .base_code = 6,  .extra_bits = 2 },
    .{ .min = 13,    .max = 16,    .base_code = 7,  .extra_bits = 2 },
    .{ .min = 17,    .max = 24,    .base_code = 8,  .extra_bits = 3 },
    .{ .min = 25,    .max = 32,    .base_code = 9,  .extra_bits = 3 },
    .{ .min = 33,    .max = 48,    .base_code = 10, .extra_bits = 4 },
    .{ .min = 49,    .max = 64,    .base_code = 11, .extra_bits = 4 },
    .{ .min = 65,    .max = 96,    .base_code = 12, .extra_bits = 5 },
    .{ .min = 97,    .max = 128,   .base_code = 13, .extra_bits = 5 },
    .{ .min = 129,   .max = 192,   .base_code = 14, .extra_bits = 6 },
    .{ .min = 193,   .max = 256,   .base_code = 15, .extra_bits = 6 },
    .{ .min = 257,   .max = 384,   .base_code = 16, .extra_bits = 7 },
    .{ .min = 385,   .max = 512,   .base_code = 17, .extra_bits = 7 },
    .{ .min = 513,   .max = 768,   .base_code = 18, .extra_bits = 8 },
    .{ .min = 769,   .max = 1024,  .base_code = 19, .extra_bits = 8 },
    .{ .min = 1025,  .max = 1536,  .base_code = 20, .extra_bits = 9 },
    .{ .min = 1537,  .max = 2048,  .base_code = 21, .extra_bits = 9 },
    .{ .min = 2049,  .max = 3072,  .base_code = 22, .extra_bits = 10 },
    .{ .min = 3073,  .max = 4096,  .base_code = 23, .extra_bits = 10 },
    .{ .min = 4097,  .max = 6144,  .base_code = 24, .extra_bits = 11 },
    .{ .min = 6145,  .max = 8192,  .base_code = 25, .extra_bits = 11 },
    .{ .min = 8193,  .max = 12288, .base_code = 26, .extra_bits = 12 },
    .{ .min = 12289, .max = 16384, .base_code = 27, .extra_bits = 12 },
    .{ .min = 16385, .max = 24576, .base_code = 28, .extra_bits = 13 },
    .{ .min = 24577, .max = 32768, .base_code = 29, .extra_bits = 13 },
};

pub const PrefixCodes = struct {
    
    pub fn getFixedPrefixCodes() ![max_alphabet_symbol]model.PrefixCode {
        var code_lengths: [max_alphabet_symbol]u4 = undefined;
        
        for (0..max_alphabet_symbol) |symbol| {
            code_lengths[symbol] = try getFixedCodeLength(symbol);
        }
        
        return getPrefixCodes(code_lengths);
    }
    
    /// standard algorithm for calculating prefix codes according to RFC1951 3.2.2
    /// https://datatracker.ietf.org/doc/html/rfc1951#page-7
    pub fn getPrefixCodes(code_lengths: [max_alphabet_symbol]u4) [max_alphabet_symbol]model.PrefixCode {
        var prefix_codes: [max_alphabet_symbol]model.PrefixCode = undefined;

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
        } else if (value < max_alphabet_symbol) {
            return 8;
        } else {
            return error.UnsupportedSymbol;
        }
    }
    
    pub fn getLengthCode(length: u16) !model.LDCode {
        const length_lookup = try getLengthCodeLookup(length);
        
        return .{
            .code = length_lookup.base_code,
            .offset = length - length_lookup.min,
            .extra_bits = length_lookup.extra_bits
        };
    }

    fn getLengthCodeLookup(len: u16) !model.CodeLookup {
        for (length_table) |entry| {
            if (len >= entry.min and len <= entry.max)
                return entry;
        }

        return error.InvalidLength;
    }

    pub fn getDistanceCode(dist: u32) !model.LDCode {
        const distance_lookup = try getDistanceCodeLookup(dist);

        return .{
            .code = distance_lookup.base_code,
            .offset = dist - distance_lookup.min,
            .extra_bits = distance_lookup.extra_bits
        };
    }
    
    fn getDistanceCodeLookup(dist: u32) !model.CodeLookup {
        for (distance_table) |entry| {
            if (dist >= entry.min and dist <= entry.max)
                return entry;
        }

        return error.InvalidDistance;
    }
};

// tests
// ================================================================================================================== //

const testing = std.testing;

test "getLengthCode" {
    var length_code = try PrefixCodes.getLengthCode(10);
    try testing.expectEqual(264, length_code.code);
    try testing.expectEqual(0, length_code.extra_bits);
    try testing.expectEqual(0, length_code.offset);

    length_code = try PrefixCodes.getLengthCode(20);
    try testing.expectEqual(269, length_code.code);
    try testing.expectEqual(2, length_code.extra_bits);
    try testing.expectEqual(1, length_code.offset);

    length_code = try PrefixCodes.getLengthCode(95);
    try testing.expectEqual(278, length_code.code);
    try testing.expectEqual(4, length_code.extra_bits);
    try testing.expectEqual(12, length_code.offset);

    length_code = try PrefixCodes.getLengthCode(258);
    try testing.expectEqual(285, length_code.code);
    try testing.expectEqual(0, length_code.extra_bits);
    try testing.expectEqual(0, length_code.offset);
}

test "getDistanceCode" {
    var distance_code = try PrefixCodes.getDistanceCode(1025);
    try testing.expectEqual(20, distance_code.code);
    try testing.expectEqual(9, distance_code.extra_bits);
    try testing.expectEqual(0, distance_code.offset);

    distance_code = try PrefixCodes.getDistanceCode(24578);
    try testing.expectEqual(29, distance_code.code);
    try testing.expectEqual(13, distance_code.extra_bits);
    try testing.expectEqual(1, distance_code.offset);

    distance_code = try PrefixCodes.getDistanceCode(9);
    try testing.expectEqual(6, distance_code.code);
    try testing.expectEqual(2, distance_code.extra_bits);
    try testing.expectEqual(0, distance_code.offset);

    distance_code = try PrefixCodes.getDistanceCode(19260);
    try testing.expectEqual(28, distance_code.code);
    try testing.expectEqual(13, distance_code.extra_bits);
    try testing.expectEqual(2875, distance_code.offset);
    
    distance_code = try PrefixCodes.getDistanceCode(32768);
    try testing.expectEqual(29, distance_code.code);
    try testing.expectEqual(13, distance_code.extra_bits);
    try testing.expectEqual(8191, distance_code.offset);
}

test "test fixed prefix codes for block type 01" {
    var code_lengths: [max_alphabet_symbol]u4 = undefined;
    for (0..max_alphabet_symbol) |i| {
        code_lengths[i] = try PrefixCodes.getFixedCodeLength(i);
    }

    const code_table = PrefixCodes.getPrefixCodes(code_lengths);

    try testing.expectEqual(48, code_table[0].code);
    try testing.expectEqual(113, code_table[65].code);
    try testing.expectEqual(191, code_table[143].code);
    try testing.expectEqual(400, code_table[144].code);
    try testing.expectEqual(400, code_table[144].code);
    try testing.expectEqual(511, code_table[255].code);
    try testing.expectEqual(0, code_table[256].code);
    try testing.expectEqual(23, code_table[279].code);
    try testing.expectEqual(192, code_table[280].code);
    try testing.expectEqual(197, code_table[285].code);
    try testing.expectEqual(199, code_table[287].code);
}