const std = @import("std");

pub const BitWriter = struct {
    buffer: u8 = 0x0,
    bits: u3 = 0,
    
    /// writes bit LSB first into the buffer byte
    pub fn writeBit(self: *BitWriter, bit: u1, writer: *std.Io.Writer) !void {
        //std.log.debug("{d}: {d}", .{self.bits, bit});
        self.buffer |= (@as(u8, bit) << self.bits);

        //std.log.debug("write bit: {d}, buffer = {b:0>8}", .{bit, self.buffer});
        
        if (self.bits == 7) {
            try self.writeBuffer(writer);
            self.buffer = 0x0;
        }

        self.bits +%= 1; // eq to (bits + 1) % 8, meaning if bits is 7, (7+1) % 8 = 0
    }
    
    /// writes the byte LSB first
    pub fn writeBits(self: *BitWriter, comptime T: type, bits: T, writer: *std.Io.Writer) !void {
        const bit_length = @bitSizeOf(T);
        
        for (0..bit_length) |pos| {
            const bit: u1 = @intCast((bits >> @intCast(pos)) & 1);
            try self.writeBit(bit, writer);
        }
    }
    
    /// writes each byte LSB first
    pub fn writeBytes(self: *BitWriter, bytes: []u8, writer: *std.Io.Writer) !void {
        for (bytes) |byte| {
            try self.writeBits(u8, byte, writer);
        }
    }
    
    /// writes len bits MSB first from the given value
    pub fn writeLength(self: *BitWriter, value: u16, len: u4, writer: *std.Io.Writer) !void {
        //std.log.debug("write value: {d} => {b}, len: {d}", .{ value, value, len });
        for (0..len) |i| {
            // 00000001 10101010
            const pos = len - i - 1;
            const bit: u1 = @intCast((value >> @intCast(pos)) & 1);
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
