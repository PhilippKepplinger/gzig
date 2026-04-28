const std = @import("std");

pub const BitWriter = struct {
    buffer: u8 = 0x0,
    bits: u3 = 0,
    
    /// Writes bit LSB first into the `buffer` byte
    pub fn writeBit(self: *BitWriter, bit: u1, writer: *std.Io.Writer) !void {
        // move the bit to the current position (self.bits)
        // bitwise OR sets the bit if 1, does nothing if zero
        self.buffer |= (@as(u8, bit) << self.bits);
        
        if (self.bits == 7) {
            try self.writeBuffer(writer);
            self.buffer = 0;
        }

        // +%= prevents int overflow. eqt (bits + 1) % 8, meaning if bits is 7, (7+1) % 8 = 0
        self.bits +%= 1; 
    }
    
    /// Writes the bits as LSB first
    /// Always writes the full `@bitSize` of the integer type. 
    /// For example `u8` always writes 8 bits including leading zeros
    pub fn writeBits(self: *BitWriter, comptime T: type, bits: T, writer: *std.Io.Writer) !void {
        const bit_length = @bitSizeOf(T);
        
        for (0..bit_length) |pos| {
            // move the bit at pos to the leftmost side, starting with the LSB
            // bitwise AND with 0b00000001 returns 1 if bit at pos is 1, 0 otherwise
            const bit: u1 = @intCast((bits >> @intCast(pos)) & 0b00000001);
            try self.writeBit(bit, writer);
        }
    }
    
    /// Writes each byte LSB first
    pub fn writeBytes(self: *BitWriter, bytes: []u8, writer: *std.Io.Writer) !void {
        for (bytes) |byte| {
            try self.writeBits(u8, byte, writer);
        }
    }
    
    /// Writes `len` bits MSB first from the given `value`
    pub fn writeLength(self: *BitWriter, value: u16, len: u4, writer: *std.Io.Writer) !void {
        for (0..len) |i| {
            // move the bit at pos to the leftmost side, starting with the MSB at len
            const pos = len - i - 1; // invert so it goes MSB first (left to right)
            
            // // bitwise AND with 0b00000001 returns 1 if bit at pos is 1, 0 otherwise
            const bit: u1 = @intCast((value >> @intCast(pos)) & 0b00000001);
            try self.writeBit(bit, writer);
        }
    }
    
    /// Write the bit buffer to the writer. This may include "undefined" bits.
    /// To ensure the written byte is defined, only write in multiples of 8.
    pub fn flush(self: *BitWriter, writer: *std.Io.Writer) !void {
        if (self.bits != 0) {
            try self.writeBuffer(writer);
        }
    }
    
    fn writeBuffer(self: *BitWriter, writer: *std.Io.Writer) !void {
        std.log.info("byte: {b:0>8} => 0x{X}", .{self.buffer, self.buffer});
        try writer.writeByte(self.buffer);
    }
};

test "writeBit" {
    var output_buffer: [1]u8 = undefined;
    var writer = std.Io.File.stdout().writer(std.testing.io, &output_buffer).interface;
    var bit_writer = BitWriter{};

    try bit_writer.writeBit(0, &writer);
    try bit_writer.writeBit(0, &writer);
    try bit_writer.writeBit(0, &writer);
    try bit_writer.writeBit(0, &writer);
    try bit_writer.writeBit(0, &writer);
    try bit_writer.writeBit(0, &writer);
    try bit_writer.writeBit(0, &writer);
    try bit_writer.writeBit(1, &writer);

    // bits are written LSB first into the byte buffer
    try std.testing.expectEqual(0b10000000, output_buffer[0]);
}

test "writeBits" {
    var output_buffer: [6]u8 = undefined;
    var writer = std.Io.File.stdout().writer(std.testing.io, &output_buffer).interface;
    var bit_writer = BitWriter{};

    try bit_writer.writeBits(u8, 1, &writer);
    try bit_writer.writeBits(u8, 2, &writer);
    try bit_writer.writeBits(u16, 50000, &writer);
    try bit_writer.writeBits(u16, 8, &writer);

    // always writes the full memory with of the integer type
    try std.testing.expectEqual(0b000000001, output_buffer[0]);
    try std.testing.expectEqual(0b000000010, output_buffer[1]);
    try std.testing.expectEqual(0b01010000, output_buffer[2]);
    try std.testing.expectEqual(0b11000011, output_buffer[3]);
    try std.testing.expectEqual(0b00001000, output_buffer[4]);
    try std.testing.expectEqual(0b00000000, output_buffer[5]);
}

test "writeBytes" {
    var output_buffer: [3]u8 = undefined;
    var writer = std.Io.File.stdout().writer(std.testing.io, &output_buffer).interface;
    var bit_writer = BitWriter{};

    var bytes = [_]u8 { 1, 2, 3};
    try bit_writer.writeBytes(bytes[0..], &writer);

    // bytes are written as-is
    try std.testing.expectEqualDeep(bytes, output_buffer);
}

test "writeLength" {
    var output_buffer: [2]u8 = undefined;
    var writer = std.Io.File.stdout().writer(std.testing.io, &output_buffer).interface;
    var bit_writer = BitWriter{};

    const value: u16 = 446; // 00000001 10111110
    try bit_writer.writeLength(value, 9, &writer);
    try bit_writer.writeBits(u7, 0b0000101, &writer);

    // write the value MSB first, but starting from the 9th bit (from the right, LSB side), not the full bit-width (u16)
    try std.testing.expectEqualDeep(0b11111011, output_buffer[0]);
    try std.testing.expectEqualDeep(0b00001010, output_buffer[1]);
}

test "flush" {
    var output_buffer: [1]u8 = undefined;
    var writer = std.Io.File.stdout().writer(std.testing.io, &output_buffer).interface;
    var bit_writer = BitWriter{};

    try bit_writer.writeBit(1, &writer);
    try bit_writer.writeBit(0, &writer);
    try bit_writer.writeBit(1, &writer);
    try bit_writer.flush(&writer);

    // undefined bits are zero
    try std.testing.expectEqual(0b00000101, output_buffer[0]);
}