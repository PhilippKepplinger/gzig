const std = @import("std");

/// simple ring buffer that continuously fills the given buffer
/// tracks current position and how much of the buffer is currently set
pub const RingBuffer = struct {
    buffer: []u8,
    pos: usize,
    filled: usize,
    
    pub fn init(buffer: []u8) RingBuffer {
        return .{
            .buffer = buffer,
            .pos = 0,
            .filled = 0,
        };
    }
    
    /// push a single byte into the buffer and advance the current position
    pub fn advance(self: *RingBuffer, byte: u8) void {
        self.buffer[self.pos] = byte;
        self.pos +%= 1;
        
        if (self.filled < self.buffer.len) {
            self.filled += 1;
        }
    }
    
    pub fn current(self: *RingBuffer) u8 {
        return self.buffer[self.pos - 1];
    }
};