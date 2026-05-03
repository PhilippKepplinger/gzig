const std = @import("std");

/// simple ring buffer that continuously fills the given buffer
/// tracks current position and how much of the buffer is currently set
pub const RingBuffer = struct {
    buffer: []u8,
    next_pos: usize,
    filled: usize,
    
    pub fn init(buffer: []u8) RingBuffer {
        return .{
            .buffer = buffer,
            .next_pos = 0,
            .filled = 0,
        };
    }
    
    /// push a single byte into the buffer and advance the current position
    pub fn add(self: *RingBuffer, byte: u8) void {
        self.buffer[self.next_pos] = byte;
        self.next_pos += 1;

        if (self.next_pos == self.buffer.len) {
            self.next_pos = 0;
        }
        
        if (self.filled < self.buffer.len) {
            self.filled += 1;
        }
    }
    
    pub fn getCurrent(self: *RingBuffer) u8 {
        if (self.next_pos == 0) {
            return self.buffer[self.buffer.len - 1];
        }
        
        return self.buffer[self.next_pos - 1];
    }
    
    pub fn getLastSetIndex(self: *RingBuffer) usize {
        if (self.next_pos == 0) {
            return self.buffer.len - 1;
        }
        
        return self.next_pos - 1;
    }
    
    pub fn getAt(self: *RingBuffer, index: usize) u8 {
        return self.buffer[index % self.buffer.len];
    }
    
    pub fn getDistance(self: *RingBuffer, index: usize) usize {
        const last_set_index = self.getLastSetIndex();
        if (index < last_set_index) {
            return last_set_index - index;
        }
        
        return self.buffer.len - (index - last_set_index);
    }
    
    pub fn getOffset(self: *RingBuffer, offset: usize) !u8 {
        if (offset >= self.buffer.len) {
            @branchHint(std.builtin.BranchHint.unlikely);
            return error.OutOfRange;
        }

        const current_index = if (self.next_pos == 0) self.buffer.len - 1 else self.next_pos - 1;
        
        if (offset <= current_index) {
            return self.buffer[current_index - offset];
        } else {
            const pos = self.buffer.len + current_index - offset;
            if (pos >= self.filled) {
                return error.OutOfRange;
            } else {
                return self.buffer[pos];
            }
        }
    }
    
    pub fn getMaxOffset(self: *RingBuffer) usize {
        return self.filled - 1;
    }
    
    pub fn len(self: *RingBuffer) usize {
        return self.buffer.len;
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

test "getOffset" {
    var buffer: [4]u8 = undefined;
    var ring_buffer = RingBuffer.init(buffer[0..]);

    ring_buffer.add(1);
    ring_buffer.add(2);
    ring_buffer.add(3);
    try std.testing.expectEqual(3, ring_buffer.getOffset(0));
    try std.testing.expectEqual(2, ring_buffer.getOffset(1));
    try std.testing.expectEqual(1, ring_buffer.getOffset(2));
    try std.testing.expectError(error.OutOfRange, ring_buffer.getOffset(3));

    ring_buffer.add(4);
    try std.testing.expectEqual(1, ring_buffer.getOffset(3));
    try std.testing.expectError(error.OutOfRange, ring_buffer.getOffset(4));

    ring_buffer.add(5);
    ring_buffer.add(6);
    try std.testing.expectEqual(6, ring_buffer.getOffset(0));
    try std.testing.expectEqual(5, ring_buffer.getOffset(1));
    try std.testing.expectEqual(4, ring_buffer.getOffset(2));
    try std.testing.expectEqual(3, ring_buffer.getOffset(3));
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