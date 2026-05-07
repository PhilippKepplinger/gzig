const std = @import("std");

/// The `BitWriter` allows to write single bits into an output `Io.Writer`.
/// The bits are stored in a `u8` byte buffer and written once the buffer is full or `flush` is called.
pub const BitWriter = struct {
    // 64 bit shift integer
    bitbuf: u64 = 0,
    bitcount: u6 = 0,

    writer: *std.Io.Writer,
    
    pub fn init(writer: *std.Io.Writer) BitWriter {
        return .{
            .writer = writer
        };
    }
    
    /// Writes bit LSB first into the `buffer` byte
    pub fn writeBit(self: *BitWriter, bit: u1) !void {
        // move the bit to the current position (self.bits)
        // bitwise OR sets the bit if 1, does nothing if zero
        self.bitbuf |= (@as(u64, bit) << self.bitcount);
        self.bitcount += 1;
        
        try self.checkBuffer();
    }
    
    /// Writes the bits as LSB first (<= right to left)
    /// Always writes the full `@bitSize` of the integer type. 
    /// For example `u8` always writes 8 bits including leading zeros
    pub fn writeBits(self: *BitWriter, comptime T: type, bits: T) !void {
        self.bitbuf |= (@as(u64, bits) << self.bitcount);
        self.bitcount += @bitSizeOf(T);
        
        try self.checkBuffer();
    }
    
    /// Writes each byte LSB first
    pub fn writeBytes(self: *BitWriter, bytes: []u8) !void {
        for (bytes) |byte| {
            try self.writeLengthLSB(byte, 8);
        }
    }
    
    /// Writes `len` bits MSB first from the given `value`
    pub fn writeLengthMSB(self: *BitWriter, value: u32, len: u6) !void {
        const reversedValue = @bitReverse(value) >> @as(u5, @intCast(32 - len));
        self.bitbuf |= (@as(u64, reversedValue) << self.bitcount);
        self.bitcount += len;
        
        try self.checkBuffer();
    }

    pub fn writeLengthLSB(self: *BitWriter, value: u32, len: u6) !void {
        self.bitbuf |= (@as(u64, value) << self.bitcount);
        self.bitcount += len;

        try self.checkBuffer();
    }
    
    /// Write the bit buffer to the writer. This may include "undefined" bits.
    /// To ensure the written byte is defined, only write in multiples of 8.
    pub fn flush(self: *BitWriter) !void {
        std.log.debug("flush bits: {d}", .{self.bitcount});
        
        try self.writeBuffer();
        
        if (self.bitcount != 0) {
            const last_byte: u8 = @truncate(self.bitbuf);
            try self.writer.writeByte(last_byte);

            self.bitbuf = 0;
            self.bitcount = 0;
        }
        
        try self.writer.flush();
    }
    
    fn checkBuffer(self: *BitWriter) !void {
        // only write once buffer is half full
        if (self.bitcount >= 32) {
            try self.writeBuffer();
        }
    }
    
    // writes the buffer to the writer
    fn writeBuffer(self: *BitWriter) !void {
        while (self.bitcount >= 8) {
            const byte: u8 = @truncate(self.bitbuf);
            try self.writer.writeByte(byte);

            self.bitbuf >>= 8;
            self.bitcount -= 8;
        }
    }
};

// tests
// ================================================================================================================== //

// test "writeBit" {
//     var output_buffer: [1]u8 = undefined;
//     var writer = std.Io.File.stdout().writer(std.testing.io, &output_buffer).interface;
//     var bit_writer = BitWriter.init(&writer);
// 
//     try bit_writer.writeBit(0);
//     try bit_writer.writeBit(0);
//     try bit_writer.writeBit(0);
//     try bit_writer.writeBit(0);
//     try bit_writer.writeBit(0);
//     try bit_writer.writeBit(0);
//     try bit_writer.writeBit(0);
//     try bit_writer.writeBit(1);
// 
//     // bits are written LSB first into the byte buffer
//     try std.testing.expectEqual(0b10000000, output_buffer[0]);
// }
// 
// test "writeBits" {
//     var output_buffer: [6]u8 = undefined;
//     var writer = std.Io.File.stdout().writer(std.testing.io, &output_buffer).interface;
//     var bit_writer = BitWriter.init(&writer);
// 
//     try bit_writer.writeBits(u8, 1);
//     try bit_writer.writeBits(u8, 2);
//     try bit_writer.writeBits(u16, 50000);
//     try bit_writer.writeBits(u16, 8);
// 
//     // always writes the full memory with of the integer type
//     try std.testing.expectEqual(0b000000001, output_buffer[0]);
//     try std.testing.expectEqual(0b000000010, output_buffer[1]);
//     try std.testing.expectEqual(0b01010000, output_buffer[2]);
//     try std.testing.expectEqual(0b11000011, output_buffer[3]);
//     try std.testing.expectEqual(0b00001000, output_buffer[4]);
//     try std.testing.expectEqual(0b00000000, output_buffer[5]);
// }
// 
// test "writeBytes" {
//     var output_buffer: [3]u8 = undefined;
//     var writer = std.Io.File.stdout().writer(std.testing.io, &output_buffer).interface;
//     var bit_writer = BitWriter.init(&writer);
// 
//     var bytes = [_]u8 { 1, 2, 3};
//     try bit_writer.writeBytes(bytes[0..]);
// 
//     // bytes are written as-is
//     try std.testing.expectEqualDeep(bytes, output_buffer);
// }
// 
// test "writeLength" {
//     var output_buffer: [2]u8 = undefined;
//     var writer = std.Io.File.stdout().writer(std.testing.io, &output_buffer).interface;
//     var bit_writer = BitWriter.init(&writer);
// 
//     const value: u16 = 446; // 00000001 10111110
//     try bit_writer.writeLength(value, 9);
//     try bit_writer.writeBits(u7, 0b0000101);
// 
//     // write the value MSB first, but starting from the 9th bit (from the right, LSB side), not the full bit-width (u16)
//     try std.testing.expectEqualDeep(0b11111011, output_buffer[0]);
//     try std.testing.expectEqualDeep(0b00001010, output_buffer[1]);
// }
// 
// test "writeValue" {
//     var output_buffer: [2]u8 = undefined;
//     var writer = std.Io.File.stdout().writer(std.testing.io, &output_buffer).interface;
//     var bit_writer = BitWriter.init(&writer);
// 
//     try bit_writer.writeValue(0b0000000100000000);
//     try bit_writer.writeValue(0b01011111);
// 
//     try std.testing.expectEqual(0b00000000, output_buffer[0]);
//     try std.testing.expectEqual(0b10111111, output_buffer[1]);
// }
// 
// test "writeLengthLSB" {
//     var output_buffer: [1]u8 = undefined;
//     var writer = std.Io.File.stdout().writer(std.testing.io, &output_buffer).interface;
//     var bit_writer = BitWriter.init(&writer);
// 
//     try bit_writer.writeBit(1);
//     try bit_writer.writeLengthLSB(1, 6);
//     try bit_writer.writeBit(1);
// 
//     try std.testing.expectEqual(0b10000011, output_buffer[0]);
// }
// 
// test "flush" {
//     var output_buffer: [1]u8 = undefined;
//     var writer = std.Io.File.stdout().writer(std.testing.io, &output_buffer).interface;
//     var bit_writer = BitWriter.init(&writer);
// 
//     try bit_writer.writeBit(1);
//     try bit_writer.writeBit(0);
//     try bit_writer.writeBit(1);
//     try bit_writer.flush();
// 
//     // undefined bits are zero
//     try std.testing.expectEqual(0b00000101, output_buffer[0]);
// }