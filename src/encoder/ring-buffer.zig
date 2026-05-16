const std = @import("std");
const BranchHint = std.builtin.BranchHint;

/// simple ring buffer that continuously fills the given buffer
/// tracks current position and how much of the buffer is currently set
pub const RingBuffer = struct {
    buffer: []u8,
    current_pos: usize = undefined,
    next_pos: usize,
    filled: usize,
    len: usize, // for convenience
    
    pub fn init(buffer: []u8) RingBuffer {
        return .{
            .len = buffer.len,
            .buffer = buffer,
            .next_pos = 0,
            .filled = 0,
        };
    }
    
    /// push a single byte into the buffer and advance the current position
    pub fn add(self: *RingBuffer, byte: u8) void {
        self.buffer[self.next_pos] = byte;
        self.current_pos = self.next_pos;
        self.next_pos += 1;

        if (self.next_pos == self.buffer.len) {
            @branchHint(BranchHint.unlikely);
            self.next_pos = 0;
        }

        if (self.filled < self.buffer.len) {
            self.filled += 1;
        }
    }
    
    pub fn getCurrent(self: *RingBuffer) u8 {
        return self.buffer[self.current_pos];
    }
    
    pub fn getLastSetIndex(self: *RingBuffer) usize {
        return self.current_pos;
    }
    
    pub fn getAt(self: *RingBuffer, index: usize) u8 {
        return self.buffer[index % self.buffer.len];
    }
    
    pub fn getTri(self: *RingBuffer, index: usize) u32 {
        return @truncate(
            @as(u32, self.buffer[index % self.buffer.len]) << 16 |
            @as(u32, self.buffer[(index + 1) % self.buffer.len]) << 8 |
            @as(u32, self.buffer[(index + 2) % self.buffer.len])
        );
    }
    
    pub fn getDistance(self: *RingBuffer, index: usize) usize {
        if (index < self.current_pos) {
            return self.current_pos - index;
        }
        
        return self.buffer.len - (index - self.current_pos);
    }
    
    // TODO this needs to be improved
    // 1. no modulo anymore
    pub fn getMatchLen(self: *RingBuffer, index_a: u64, index_b: u64, length: u16) u16 {
        var match_len: u16 = 0;
        for (0..length) |i| {
            // check missmatch
            if (self.buffer[(index_a + i) % self.buffer.len] != self.buffer[(index_b + i) % self.buffer.len]) {
                return match_len;
            }

            match_len += 1;
        }
        
        return match_len;
    }
};

test "add" {
    var buffer: [3]u8 = undefined;
    var ring_buffer = RingBuffer.init(buffer[0..]);
    
    ring_buffer.add(1);
    ring_buffer.add(2);
    try std.testing.expectEqual(1, ring_buffer.buffer[0]);
    try std.testing.expectEqual(2, ring_buffer.buffer[1]);
    try std.testing.expectEqual(2, ring_buffer.next_pos);
    try std.testing.expectEqual(2, ring_buffer.filled);

    ring_buffer.add(3);
    try std.testing.expectEqual(3, ring_buffer.buffer[2]);
    try std.testing.expectEqual(0, ring_buffer.next_pos);
    try std.testing.expectEqual(3, ring_buffer.filled);
}

test "getLastSetIndex" {
    var buffer: [8]u8 = undefined;
    var ring_buffer = RingBuffer.init(buffer[0..]);

    ring_buffer.add(1);
    ring_buffer.add(2);
    ring_buffer.add(3);
    try std.testing.expectEqual(2, ring_buffer.getLastSetIndex());
}

test "getAt" {
    var buffer: [4]u8 = undefined;
    var ring_buffer = RingBuffer.init(buffer[0..]);

    ring_buffer.add(1);
    ring_buffer.add(2);
    ring_buffer.add(3);
    ring_buffer.add(4);
    
    try std.testing.expectEqual(1, ring_buffer.getAt(0));
    try std.testing.expectEqual(2, ring_buffer.getAt(1));
    try std.testing.expectEqual(3, ring_buffer.getAt(2));
    try std.testing.expectEqual(4, ring_buffer.getAt(3));
    try std.testing.expectEqual(1, ring_buffer.getAt(4));
}

test "getCurrent" {
    var buffer: [8]u8 = undefined;
    var ring_buffer = RingBuffer.init(buffer[0..]);

    ring_buffer.add(1);
    ring_buffer.add(2);
    ring_buffer.add(3);
    try std.testing.expectEqual(3, ring_buffer.getCurrent());
}

test "getDistance" {
    var buffer: [4]u8 = undefined;
    var ring_buffer = RingBuffer.init(buffer[0..]);

    ring_buffer.add(1);
    ring_buffer.add(2);
    ring_buffer.add(3);
    ring_buffer.add(4);
    ring_buffer.add(5);
    ring_buffer.add(6);

    try std.testing.expectEqual(1, ring_buffer.getLastSetIndex());
    try std.testing.expectEqual(1, ring_buffer.getDistance(0));
    try std.testing.expectEqual(4, ring_buffer.getDistance(1));
    try std.testing.expectEqual(3, ring_buffer.getDistance(2));
    try std.testing.expectEqual(2, ring_buffer.getDistance(3));
}

test "getDistance 32k" {
    const size = 32768;
    var buffer: [size]u8 = undefined;
    var ring_buffer = RingBuffer.init(buffer[0..]);

    ring_buffer.add(1);

    try std.testing.expectEqual(0, ring_buffer.getLastSetIndex());
    try std.testing.expectEqual(size, ring_buffer.getDistance(0));
}