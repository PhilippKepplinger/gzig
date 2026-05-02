const std = @import("std");
const model = @import("model.zig");
const Packager = @import("packager.zig").Packager;
const RingBuffer = @import("ring-buffer.zig").RingBuffer;

pub const max_lookahead_window: u16 = 258;
pub const search_buffer_size: u16 = 32768;

pub const LZSS = struct {
    buffer: RingBuffer,
    packager: *Packager,
    allocator: std.mem.Allocator,
    search_progress: u16 = 0,
    current_search: [max_lookahead_window]u8 = undefined,
    candidate_indices: std.ArrayList(u16),
    
    pub fn init(allocator: std.mem.Allocator, packager: *Packager, buffer: []u8) !LZSS {
        return .{
            .buffer = RingBuffer.init(buffer),
            .packager = packager,
            .allocator = allocator,
            .candidate_indices = try std.ArrayList(u16).initCapacity(allocator, 4096),
        };
    }
    
    pub fn process(self: *LZSS, literal: u8) !void {
        self.buffer.add(literal);
        try self.encode();
        std.log.debug("==============================", .{});
    }
    
    fn encode(self: *LZSS) !void {
        const literal = self.buffer.getCurrent();
        std.log.debug("literal: ({c}) {d}", .{literal, literal});

        // no candidates exist, find all candidates inside the search buffer window
        if (self.candidate_indices.items.len == 0) {
            const max_offset = @min(search_buffer_size, self.buffer.getMaxOffset());
            if (max_offset == 0) {
                std.log.debug("first character, no check needed", .{});
                try self.emitLiteral(literal);
                return;
            }
            
            try self.initCandidates(literal);
        } else {
            // validate existing candidates
            var best_removed: ?u16 = null;
            var index = self.candidate_indices.items.len - 1;

            while (index >= 0 and self.candidate_indices.items.len > 0) {
                const candidate_index = self.candidate_indices.items[index];
                const candidate_literal = try self.buffer.getOffset(candidate_index);
                std.log.debug("check candidate: ({c}) at offset: {d}", .{candidate_literal, candidate_index});
                
                // the candidate does not match anymore, remove it
                if (candidate_literal != literal) {
                    std.log.debug("({c}) != ({c}) => remove", .{candidate_literal, literal});
                    _ = self.candidate_indices.swapRemove(index);
                    if (best_removed == null or candidate_index < best_removed.?) {
                        best_removed = candidate_index;
                    }
                }
                
                if (index == 0) {
                    break;
                }
                
                if (index > 0) {
                    index -= 1;
                }
            }
            
            // no candidates left, if at least length 3, choose the best
            if (self.candidate_indices.items.len == 0 and best_removed != null) {
                if (self.search_progress >= 3) {
                    std.log.debug("no cancidates left, choose best {d}", .{best_removed.?});
                    const candidate_match = try self.createCandidateMatch(best_removed.?);
                    try self.emit(candidate_match);
                } else {
                    // search too short, emit as literals
                    // TODO a started search could still match with a substring of the search. In the future, maybe restart with the first character of the search removed..
                    for (self.current_search[0..self.search_progress]) |symbol| {
                        try self.emitLiteral(symbol);
                    }
                }

                std.log.debug("no valid match found, reset search and search new candidates for: ({c})", .{literal});
                try self.initCandidates(literal);
            } else if (self.candidate_indices.items.len > 0) {
                // still candidates left, save literal and continue searching
                self.current_search[self.search_progress] = literal;
                self.search_progress += 1;
                std.log.debug("still valid candidates, continue search. current: {s}", .{self.current_search[0..self.search_progress]});
            }
            
            // lookahead window full, emit nearest candidate
            if (self.search_progress == max_lookahead_window) {
                std.log.debug("lookahead window full", .{});
                const candidate_match = try self.getBestCandidateMatch();
                try self.emit(candidate_match);
                self.candidate_indices.clearRetainingCapacity();
            }
        }
    }
    
    fn initCandidates(self: *LZSS, literal: u8) !void {
        const max_offset = @min(search_buffer_size, self.buffer.getMaxOffset());
        for (1..max_offset + 1) |offset| {
            const candidate = try self.buffer.getOffset(offset);
            //std.log.debug("check: ({c})", .{candidate});
            if (candidate == literal) {
                try self.candidate_indices.append(self.allocator, @intCast(offset));
                //std.log.debug("found: ({c}) at offset: {d}, candidates size: {d}", .{candidate, offset, self.candidate_indices.items.len});
            }
        }

        // no match => just emit literal
            if (self.candidate_indices.items.len == 0) {
            std.log.debug("no candidates found for ({c})", .{literal});
            try self.emitLiteral(literal);
        } else {
            // there are candidates, init lookahead search
            self.current_search[0] = literal;
            self.search_progress = 1;
        }
    }

    /// pushes a length/distance token into the packager
    fn emit(self: *LZSS, token: model.LZToken) !void {
        try self.packager.add(token);
    }

    /// pushes a literal as token into the packager
    fn emitLiteral(self: *LZSS, literal: u8) !void {
        std.log.debug("emit literal: ({c})", .{literal});
        try self.packager.add(.{ .literal = literal });
    }

    /// no data will be added anymore to the buffer
    /// run through the rest of the lookahead data and then package
    pub fn finish(self: *LZSS) !void {
        if (self.search_progress > 0) {
            if (self.search_progress < 3 or (self.candidate_indices.items.len == 0)) {
                // no candidates, just emit the current search as literals
                for (self.current_search[0..self.search_progress]) |literal| {
                    try self.emitLiteral(literal);
                }
            } else if (self.candidate_indices.items.len > 0) {
                // just take the best candidate and emit that
                const candidate_match = try self.getBestCandidateMatch();
                try self.emit(candidate_match);
            }
        }
        
        // package data and clear candidates buffer
        try self.packager.package(true);
        self.candidate_indices.clearAndFree(self.allocator);
    }
    
    fn getBestCandidateMatch(self: *LZSS) !model.LZToken {
        const distance = std.mem.min(u16, self.candidate_indices.items);
        return try self.createCandidateMatch(distance);
    }
    
    fn createCandidateMatch(self: *LZSS, distance: u16) !model.LZToken {
        const len = self.search_progress;
        var consumed= try self.allocator.alloc(u8, len);
        @memcpy(consumed[0..len], self.current_search[0..len]);
        
        std.log.debug("emit: dist: {d}, len: {d}, consumed: {s}", .{distance, len, consumed});
        
        return .{
            .match = .{
                .len = len,
                .dist = distance,
                .consumed = consumed,
            }
        };
    }
};
