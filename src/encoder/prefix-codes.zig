const std = @import("std");
const model = @import("model.zig");

pub const max_alphabet_symbol: u16 = 288;
pub const max_prefixcode_bits: u8 = 15;

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
};

// tests
// ================================================================================================================== //

const testing = std.testing;
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
    try testing.expectEqual(199, code_table[287].code);
}