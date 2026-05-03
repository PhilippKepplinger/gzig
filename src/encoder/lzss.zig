const std = @import("std");
const model = @import("model.zig");
const Packager = @import("packager.zig").Packager;
const RingBuffer = @import("ring-buffer.zig").RingBuffer;

pub const max_lookahead_window: u16 = 258;
pub const search_buffer_size: u16 = 32768;

pub const LZSS = struct {
    processed_bytes: u64 = 0,
    buffer: RingBuffer,
    packager: *Packager,
    allocator: std.mem.Allocator,
    search_progress: u16 = 0,
    current_search: [max_lookahead_window]u8 = undefined,
    hash_head: [search_buffer_size]?u64 = undefined,
    hash_prev: [search_buffer_size]?u64 = undefined,
    max_candidates: u8 = 32,
    
    pub fn init(allocator: std.mem.Allocator, packager: *Packager, buffer: []u8) !LZSS {
        return .{
            .buffer = RingBuffer.init(buffer),
            .packager = packager,
            .allocator = allocator
        };
    }
    
    pub fn process(self: *LZSS, literal: u8) !void {
        self.buffer.add(literal);
        try self.encode();
        std.log.debug("==============================", .{});
    }
    
    fn encode(self: *LZSS) !void {
        self.processed_bytes += 1;
        const literal_index: u16 = @intCast(self.buffer.getLastSetIndex());
        const literal = self.buffer.getCurrent();
        std.log.debug("literal: ({c}) at: {}", .{literal, literal_index});

        // whe have at least 3 symbols, start computing hashes
        if (self.buffer.getMaxOffset() >= 2) {
            const a = try self.buffer.getOffset(2);
            const b = try self.buffer.getOffset(1);
            const hash = hash3(a, b, literal);
            const hash_index = self.processed_bytes - 3; // -3 because we have three symbols 
            const prev_index = hash_index % self.buffer.len();
            self.hash_prev[prev_index] = self.hash_head[hash];
            self.hash_head[hash] = hash_index;
            
            std.log.debug("set hash at {d} to ({c}{c}{c})", .{hash_index, a, b, literal});
            if (self.hash_prev[prev_index] != null) {
                std.log.debug("set prev at {d} to ({d})", .{prev_index, self.hash_head[hash].?});
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
            const hash = hash3(self.current_search[0], self.current_search[1], self.current_search[2]);
            var candidate_index = self.hash_head[hash];
            // no candidates for this 3 char search
            if (candidate_index == null) {
                std.log.debug("no candidate, emit {c}", .{self.current_search[0]});
                // emit first search char and shift others to left, then wait for next literal
                try self.emitLiteral(self.current_search[0]);
                self.current_search[0] = self.current_search[1];
                self.current_search[1] = self.current_search[2];
                self.search_progress -= 1;
                std.log.debug("new search: ({s})", .{self.current_search[0..self.search_progress]});
                return;
            }
            
            var best_candidate_index: u64 = undefined;
            var longest_match: u16 = 0;
            var depth: u16 = 0;
            
            while (candidate_index != null and depth < self.max_candidates) {
                if (self.processed_bytes - candidate_index.? > self.buffer.len()) {
                    break;
                }

                const buffer_idx = candidate_index.? % self.buffer.len();
                std.log.debug("found candidate for: {d} => ({d})", .{candidate_index.?, buffer_idx});

                const dist = self.buffer.getDistance(buffer_idx);
                // prevents to find candidates in hashes created during the current search
                if (dist <= self.search_progress) {
                    // next candidate
                    std.log.debug("purge candidate_index: {d}, search progress: {d}, literal_index: {d}, dist: {d}", .{ buffer_idx, self.search_progress, literal_index, dist});
                    const temp_idx = candidate_index.?;
                    candidate_index = self.hash_prev[buffer_idx];
                    if (candidate_index != null and candidate_index.? == temp_idx) {
                        return error.CircularHash;
                    }
                    continue;
                }

                depth += 1;

                // count the actual match length of the candidate
                var match_len: u16 = 0;
                for (0..self.search_progress) |i| {
                    // std.log.debug("check ({c}) == ({c})", .{self.buffer.getAt(candidate_index.? + i), self.current_search[i]});
                    
                    // check missmatch
                    if (self.current_search[i] != self.buffer.getAt(buffer_idx + i)) {
                        break;
                    }

                    match_len += 1;
                }

                // remember best match
                if (match_len > longest_match) {
                    longest_match = match_len;
                    best_candidate_index = buffer_idx;
                }

                // next candidate
                candidate_index = self.hash_prev[buffer_idx];
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
        std.log.debug("finish LZSS encoding", .{});
        // if there is search progress, just emit literals for testing now...
        // TODO should also check for current candidates later
        if (self.search_progress > 0) {
            for (self.current_search[0..self.search_progress]) |literal| {
                try self.emitLiteral(literal);
            }
        }

        // package data and clear candidates buffer
        try self.packager.package(true);
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
