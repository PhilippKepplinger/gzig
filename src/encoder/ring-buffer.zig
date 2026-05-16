const std = @import("std");
const BranchHint = std.builtin.BranchHint;

/// simple ring buffer that continuously fills the given buffer
/// tracks current position and how much of the buffer is currently set
pub fn RingBuffer(comptime BUFFER_SIZE: usize) type {
    return struct {
        const Self = @This();
        
        buffer: [BUFFER_SIZE * 2]u8 = undefined, // creates a mirrored buffer
        len: usize = BUFFER_SIZE,
        current_pos: usize = undefined,
        next_pos: usize = 0,
        filled: usize = 0,

        /// push a single byte into the buffer and advance the current position
        pub fn add(self: *Self, byte: u8) void {
            self.buffer[self.next_pos] = byte;
            self.buffer[self.next_pos + BUFFER_SIZE] = byte;
            self.current_pos = self.next_pos;
            self.next_pos = (self.next_pos + 1) & (BUFFER_SIZE - 1); // bitwise & wraps the index

            if (self.filled < BUFFER_SIZE) {
                self.filled += 1;
            }
        }

        pub fn getCurrent(self: *Self) u8 {
            return self.buffer[self.current_pos];
        }

        pub fn getLastSetIndex(self: *Self) usize {
            return self.current_pos;
        }

        pub fn getAt(self: *Self, index: usize) u8 {
            return self.buffer[index % BUFFER_SIZE];
        }

        pub fn getTri(self: *Self, index: usize) u32 {
            return @truncate(
                @as(u32, self.buffer[index % BUFFER_SIZE]) << 16 |
                    @as(u32, self.buffer[(index + 1) % BUFFER_SIZE]) << 8 |
                    @as(u32, self.buffer[(index + 2) % BUFFER_SIZE])
            );
        }

        pub fn getDistance(self: *Self, index: usize) usize {
            if (index < self.current_pos) {
                return self.current_pos - index;
            }

            return BUFFER_SIZE - (index - self.current_pos);
        }

        pub fn getMatchLen(self: *Self, index_a: u64, index_b: u64, length: u16) u16 {
            const slot_a = index_a % BUFFER_SIZE;
            const slot_b = index_b % BUFFER_SIZE;
            
            var match_len: u16 = 0;
            for (0..length) |i| {
                // check missmatch
                if (self.buffer[slot_a + i] != self.buffer[slot_b + i]) {
                    return match_len;
                }

                match_len += 1;
            }

            return match_len;
        }
    };
}

test "add" {
    var ring_buffer = RingBuffer(4){};
    
    ring_buffer.add(1);
    ring_buffer.add(2);
    try std.testing.expectEqual(1, ring_buffer.buffer[0]);
    try std.testing.expectEqual(2, ring_buffer.buffer[1]);
    try std.testing.expectEqual(2, ring_buffer.next_pos);
    try std.testing.expectEqual(2, ring_buffer.filled);

    ring_buffer.add(3);
    ring_buffer.add(4);
    try std.testing.expectEqual(3, ring_buffer.buffer[2]);
    try std.testing.expectEqual(4, ring_buffer.buffer[3]);
    try std.testing.expectEqual(0, ring_buffer.next_pos);
    try std.testing.expectEqual(4, ring_buffer.filled);
}

test "getLastSetIndex" {
    var ring_buffer = RingBuffer(8){};

    ring_buffer.add(1);
    ring_buffer.add(2);
    ring_buffer.add(3);
    try std.testing.expectEqual(2, ring_buffer.getLastSetIndex());
}

test "getAt" {
    var ring_buffer = RingBuffer(4){};

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
    var ring_buffer = RingBuffer(8){};

    ring_buffer.add(1);
    ring_buffer.add(2);
    ring_buffer.add(3);
    try std.testing.expectEqual(3, ring_buffer.getCurrent());
}

test "getDistance" {
    var ring_buffer = RingBuffer(4){};

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
    var ring_buffer = RingBuffer(32768){};

    ring_buffer.add(1);

    try std.testing.expectEqual(0, ring_buffer.getLastSetIndex());
    try std.testing.expectEqual(32768, ring_buffer.getDistance(0));
}