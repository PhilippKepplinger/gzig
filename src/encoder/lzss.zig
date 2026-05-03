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
    hash_head: [search_buffer_size]?u16 = undefined,
    hash_prev: [search_buffer_size]?u16 = undefined,
    
    candidate_indices: std.ArrayList(u16),
    max_candidates: u8 = 32,
    
    pub fn init(allocator: std.mem.Allocator, packager: *Packager, buffer: []u8) !LZSS {
        return .{
            .buffer = RingBuffer.init(buffer),
            .packager = packager,
            .allocator = allocator,
            .candidate_indices = try std.ArrayList(u16).initCapacity(allocator, std.math.maxInt(u8)),
        };
    }
    
    pub fn process(self: *LZSS, literal: u8) !void {
        self.buffer.add(literal);
        try self.encode();
        std.log.debug("==============================", .{});
    }
    
    fn encode(self: *LZSS) !void {
        const literal_index: u16 = @intCast(self.buffer.getLastSetIndex());
        const literal = self.buffer.getCurrent();
        std.log.debug("literal: ({c}) at: {}", .{literal, literal_index});

        // whe have at least 3 symbols, start computing hashes
        if (self.buffer.getMaxOffset() >= 2) {
            const a = try self.buffer.getOffset(2);
            const b = try self.buffer.getOffset(1);
            const hash = hash3(a, b, literal);
            const hash_index: u16 = if (literal_index >= 2) literal_index - 2 else @intCast(self.buffer.len() + literal_index - 2); // because we look back 2 symbols 
            self.hash_prev[hash_index] = self.hash_head[hash];
            self.hash_head[hash] = hash_index;
            // std.log.debug("set hash at {d} to ({c}{c}{c})", .{hash_index, a, b, literal});

            if (self.hash_prev[hash_index] != null) {
                std.log.debug("prev candidate: {d}", .{self.hash_prev[hash_index].?});
            }
        } else {
            // always emit literal, there can be no backreference
            std.log.debug("no serach buffer, emit: ({c})", .{literal});
            try self.emitLiteral(literal);
            return;
        }
        
        // memorize current search
        self.current_search[self.search_progress] = literal;
        self.search_progress += 1;
        
        std.log.debug("current serach [{d}]: ({s})", .{self.search_progress, self.current_search[0..self.search_progress]});

        // once we have long enough search, check candidates
        if (self.search_progress >= 3) {
            const search_hash = hash3(self.current_search[0], self.current_search[1], self.current_search[2]);
            const head_index = self.hash_head[search_hash];
            // no candidates for this 3 char search
            if (head_index == null) {
                std.log.debug("no candidate, emit {c}", .{self.current_search[0]});
                // emit first search char and shift others to left, then wait for next literal
                try self.emitLiteral(self.current_search[0]);
                self.current_search[0] = self.current_search[1];
                self.current_search[1] = self.current_search[2];
                self.search_progress -= 1;
                std.log.debug("new search: ({s})", .{self.current_search[0..self.search_progress]});
                return;
            }
            
            var best_candidate_index: u16 = undefined;
            var longest_match: u16 = 0;
            var depth: u16 = 0;
            var candidate_index = self.hash_prev[head_index.?];
            
            while (candidate_index != null and depth < self.max_candidates) {
                //std.log.debug("found candidate at: ({d})", .{candidate_index.?});
                
                const dist = self.buffer.getDistance(candidate_index.?);
                // prevents to find candidates in hashes created during the current search
                if (dist <= self.search_progress) {
                    // next candidate
                    std.log.debug("purge candidate_index: {d}, search progress: {d}, literal_index: {d}, dist: {d}", .{ candidate_index.?, self.search_progress, literal_index, dist});
                    candidate_index = self.hash_prev[candidate_index.?];
                    continue;
                }

                depth += 1;

                // count the actual match length of the candidate
                var match_len: u16 = 0;
                for (0..self.search_progress) |i| {
                    // std.log.debug("check ({c}) == ({c})", .{self.buffer.getAt(candidate_index.? + i), self.current_search[i]});
                    
                    // check missmatch
                    if (self.current_search[i] != self.buffer.getAt(candidate_index.? + i)) {
                        break;
                    }

                    match_len += 1;
                }

                // remember best match
                if (match_len > longest_match) {
                    longest_match = match_len;
                    best_candidate_index = candidate_index.?;
                }

                // next candidate
                candidate_index = self.hash_prev[candidate_index.?];
            }
            
            // candidates not good enough
            if (longest_match < 3) {
                std.log.debug("no long enough candidates, emit {c}", .{self.current_search[0]});
                // emit first search char and shift others to left, then wait for next literal
                try self.emitLiteral(self.current_search[0]);
                self.current_search[0] = self.current_search[1];
                self.current_search[1] = self.current_search[2];
                self.search_progress -= 1;
                std.log.debug("new search: ({s})", .{self.current_search[0..self.search_progress]});
            } else if (longest_match < self.search_progress) {
                // no candidate equals current search, but candidate at least length 3
                const dist = self.buffer.getDistance(best_candidate_index) - longest_match; // distance from starting symbol index, not current literal index
                var consumed= try self.allocator.alloc(u8, longest_match);
                @memcpy(consumed[0..longest_match], self.current_search[0..longest_match]);
                
                std.log.debug("emit: dist: {d}, len: {d}, consumed: ({s})", .{dist, longest_match, consumed});
                
                try self.emit(.{ 
                    .match = .{
                        .dist = @intCast(dist),
                        .len = longest_match,
                        .consumed = consumed,
                    }
                });

                // init new search with the current literal
                self.current_search[0] = literal;
                self.search_progress = 1;
                
                std.log.debug("candidates found for ({s}), new search: ({s})", .{consumed, self.current_search[0..self.search_progress]});
            } else if (longest_match == max_lookahead_window) {
                // max window length reached, stop search and emit candidate
                std.log.debug("max lookahead reached, candiate index: ({d})", .{best_candidate_index});
                std.log.debug("search progress: ({d})", .{self.search_progress});
                std.log.debug("distance in buffer: ({d})", .{self.buffer.getDistance(best_candidate_index)});
                const dist = self.buffer.getDistance(best_candidate_index) - self.search_progress + 1; // distance from starting symbol index, not current literal index + 1 because the literal is included in the reference!
                var consumed= try self.allocator.alloc(u8, longest_match);
                @memcpy(consumed[0..longest_match], self.current_search[0..longest_match]);
                
                std.log.debug("emit: dist: {d}, len: {d}, consumed: ({s})", .{dist, longest_match, consumed});
                
                try self.emit(.{
                    .match = .{
                        .dist = @intCast(dist),
                        .len = longest_match,
                        .consumed = consumed,
                    }
                });

                // start new search on next literal
                self.search_progress = 0;
            }
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
        // if there is search progress, just emit literals for testing now...
        // TODO should also check for current candidates later
        if (self.search_progress > 0) {
            for (self.current_search[0..self.search_progress]) |literal| {
                try self.emitLiteral(literal);
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
    
    /// bit-packed direct hash
    /// creates a hash that fits into u16
    /// does not avoid collisions but is good enough for LZSS
    fn hash3(a: u8, b: u8, c: u8) u16 {
        return (
            (@as(u16, a) << 10) ^
            (@as(u16, b) << 5) ^ 
            (@as(u16, c))
        ) & (search_buffer_size - 1); // 32767
    }
};
