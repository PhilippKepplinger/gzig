const std = @import("std");

/// The `BitWriter` allows to write single bits into an output `Io.Writer`.
/// The bits are shifted in a `u64` buffer integer and then drained into a [1024]u8 byte buffer.
/// Once the byte buffer is full, or the writer is flushed, the buffer is written to the passed writer.
pub const BitWriter = struct {
    // 64 bit shift integer
    bit_buffer: u64 = 0,
    bit_count: u6 = 0,

    writer: *std.Io.Writer,
    
    pub fn init(writer: *std.Io.Writer) BitWriter {
        return .{
            .writer = writer
        };
    }
    
    /// Writes bit LSB first into the `buffer` byte
    pub fn writeBit(self: *BitWriter, bit: u1) !void {
        // move the bit to the current position at `bit_count`
        // bitwise OR sets the bit if 1, does nothing if 0
        self.bit_buffer |= (@as(u64, bit) << self.bit_count);
        self.bit_count += 1;
        
        try self.checkBitBuffer();
    }
    
    /// Writes the bits as LSB first (<= right to left)
    /// Always writes the full `@bitSizeOf` of the integer type. 
    /// For example `u8` always writes 8 bits including leading zeros
    pub fn writeBits(self: *BitWriter, comptime T: type, bits: T) !void {
        self.bit_buffer |= (@as(u64, bits) << self.bit_count);
        self.bit_count += @bitSizeOf(T);
        
        try self.checkBitBuffer();
    }
    
    /// Writes each byte LSB first
    pub fn writeBytes(self: *BitWriter, bytes: []u8) !void {
        for (bytes) |byte| {
            try self.writeLengthLSB(byte, 8);
        }
    }

    /// writes the first `len` bits of a `u32` into the bit-buffer MSB first
    pub fn writeLengthMSB(self: *BitWriter, value: u32, len: u6) !void {
        // reverse the bits and then shift all not needed bits out to the right so only `len` bits remain 
        const value_reversed = @bitReverse(value) >> @as(u5, @intCast(32 - len));
        self.bit_buffer |= (@as(u64, value_reversed) << self.bit_count);
        self.bit_count += len;
        
        try self.checkBitBuffer();
    }

    /// writes the first `len` bits of a `u32` into the bit-buffer LSB first
    pub fn writeLengthLSB(self: *BitWriter, value: u32, len: u6) !void {
        self.bit_buffer |= (@as(u64, value) << self.bit_count);
        self.bit_count += len;

        try self.checkBitBuffer();
    }
    
    /// Writes the current stored byte buffer to the output writer.
    pub fn flush(self: *BitWriter) !void {
        std.log.debug("flush bits: {d}", .{self.bit_count});
        
        try self.writeBitBuffer();
        
        if (self.bit_count != 0) {
            try self.writer.writeByte(@truncate(self.bit_buffer));
            self.bit_buffer = 0;
            self.bit_count = 0;
        }
    }
    
    fn checkBitBuffer(self: *BitWriter) !void {
        // only write once buffer is half full
        if (self.bit_count >= 32) {
            try self.writeBitBuffer();
        }
    }
    
    // writes the buffer to the writer
    fn writeBitBuffer(self: *BitWriter) !void {
        while (self.bit_count >= 8) {
            try self.writer.writeByte(@truncate(self.bit_buffer));
            self.bit_buffer >>= 8;
            self.bit_count -= 8;
        }
    }
};

// tests
// ================================================================================================================== //

test "writeBit" {
    var output_buffer: [1]u8 = undefined;
    var writer = std.Io.File.stdout().writer(std.testing.io, &output_buffer).interface;
    var bit_writer = BitWriter.init(&writer);

    try bit_writer.writeBit(0);
    try bit_writer.writeBit(0);
    try bit_writer.writeBit(0);
    try bit_writer.writeBit(0);
    try bit_writer.writeBit(0);
    try bit_writer.writeBit(0);
    try bit_writer.writeBit(0);
    try bit_writer.writeBit(1);
    try bit_writer.flush();

    // bits are written LSB first into the byte buffer
    try std.testing.expectEqual(0b10000000, output_buffer[0]);
}

test "writeBits" {
    var output_buffer: [6]u8 = undefined;
    var writer = std.Io.File.stdout().writer(std.testing.io, &output_buffer).interface;
    var bit_writer = BitWriter.init(&writer);

    try bit_writer.writeBits(u8, 1);
    try bit_writer.writeBits(u8, 2);
    try bit_writer.writeBits(u16, 50000);
    try bit_writer.writeBits(u16, 8);
    try bit_writer.flush();
    
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
    var bit_writer = BitWriter.init(&writer);

    var bytes = [_]u8 { 1, 2, 3};
    try bit_writer.writeBytes(bytes[0..]);
    try bit_writer.flush();

    // bytes are written as-is
    try std.testing.expectEqualDeep(bytes, output_buffer);
}

test "writeLengthMSB" {
    var output_buffer: [2]u8 = undefined;
    var writer = std.Io.File.stdout().writer(std.testing.io, &output_buffer).interface;
    var bit_writer = BitWriter.init(&writer);

    const value: u16 = 446; // 00000001 10111110
    try bit_writer.writeLengthMSB(value, 9);
    try bit_writer.writeBits(u7, 0b0000101);
    try bit_writer.flush();

    // write the value MSB first, but starting from the 9th bit (from the right, LSB side), not the full bit-width (u16)
    try std.testing.expectEqualDeep(0b11111011, output_buffer[0]);
    try std.testing.expectEqualDeep(0b00001010, output_buffer[1]);
}

test "writeLengthLSB" {
    var output_buffer: [1]u8 = undefined;
    var writer = std.Io.File.stdout().writer(std.testing.io, &output_buffer).interface;
    var bit_writer = BitWriter.init(&writer);

    try bit_writer.writeBit(1);
    try bit_writer.writeLengthLSB(1, 6);
    try bit_writer.writeBit(1);
    try bit_writer.flush();

    try std.testing.expectEqual(0b10000011, output_buffer[0]);
}