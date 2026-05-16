const std = @import("std");
const BranchHint = std.builtin.BranchHint;

/// simple ring buffer that continuously fills the given buffer
/// tracks current position and how much of the buffer is currently set
pub fn RingBuffer(comptime BUFFER_SIZE: usize) type {
    // needs to be power of two for efficiency
    std.debug.assert(std.math.isPowerOfTwo(BUFFER_SIZE));
    
    const BUFFER_MASK = BUFFER_SIZE - 1; // used to create local index from global index via (& BUFFER_MASK)
    
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
            self.next_pos = (self.next_pos + 1) & BUFFER_MASK; // bitwise & wraps the index

            if (self.filled < BUFFER_SIZE) {
                self.filled += 1;
            }
        }

        pub fn getAt(self: *Self, index: usize) u8 {
            return self.buffer[index & BUFFER_MASK];
        }

        pub fn getTri(self: *Self, index: u16) u32 {
            return @truncate(
                @as(u32, self.buffer[index]) << 16 |
                    @as(u32, self.buffer[index + 1]) << 8 |
                    @as(u32, self.buffer[index + 2])
            );
        }

        pub fn getDistance(self: *Self, index: usize) usize {
            if (index < self.current_pos) {
                return self.current_pos - index;
            }

            return BUFFER_SIZE - (index - self.current_pos);
        }

        pub fn matches(self: *Self, index_a: u16, index_b: u16, length: u16) bool {
            const slice_a = self.buffer[index_a..index_a + length];
            const slice_b = self.buffer[index_b..index_b + length];

            for(0..length) |i| {
                if (slice_a[i] != slice_b[i])
                    return false;
            }
           
            return true;
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

test "getDistance" {
    var ring_buffer = RingBuffer(4){};

    ring_buffer.add(1);
    ring_buffer.add(2);
    ring_buffer.add(3);
    ring_buffer.add(4);
    ring_buffer.add(5);
    ring_buffer.add(6);

    try std.testing.expectEqual(1, ring_buffer.current_pos);
    try std.testing.expectEqual(1, ring_buffer.getDistance(0));
    try std.testing.expectEqual(4, ring_buffer.getDistance(1));
    try std.testing.expectEqual(3, ring_buffer.getDistance(2));
    try std.testing.expectEqual(2, ring_buffer.getDistance(3));
}

test "getDistance 32k" {
    var ring_buffer = RingBuffer(32768){};

    ring_buffer.add(1);

    try std.testing.expectEqual(0, ring_buffer.current_pos);
    try std.testing.expectEqual(32768, ring_buffer.getDistance(0));
}