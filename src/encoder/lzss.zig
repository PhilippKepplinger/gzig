const std = @import("std");
const model = @import("model.zig");
const Packager = @import("packager.zig").Packager;
const RingBuffer = @import("ring-buffer.zig").RingBuffer;

pub const LZSS = struct {
    buffer: RingBuffer,
    packager: *Packager,
    current_search: []u8 = undefined,
    
    pub fn init(packager: *Packager, buffer: []u8) LZSS {
        return .{
            .buffer = RingBuffer.init(buffer),
            .packager = packager,
        };
    }
    
    pub fn consume(self: *LZSS, literal: u8) !u32 {
        // for testing, emit literals only
        try self.emit(.{ .literal = literal });
        
        // 1. read first 3 symbols
        //    if no match, store first symbol as literal and read another symbol
        // 2. find candidates in the 32k search buffer
        // 3. read next symbol and validate candidates
        // 4. once lookahead full or no candidates, take closest candidate
        return 1;
    }

    /// pushes a length/distance Token into the packager
    fn emit(self: *LZSS, token: model.LZToken) !void {
        try self.packager.add(token);
    }
    
    pub fn finish(self: *LZSS) !void {
        try self.packager.package(true);
    }

};
