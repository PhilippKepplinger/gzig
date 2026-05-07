const std = @import("std");
const model = @import("model.zig");
const Packager = @import("packager.zig").Packager;
const RingBuffer = @import("ring-buffer.zig").RingBuffer;

pub const max_lookahead_window: u16 = 258;
pub const search_buffer_size: u16 = 32768;
pub const search_buffer_max_index = search_buffer_size - 1;

pub const LZSS = struct {
    processed_bytes: u64 = 0,
    ring_buffer: RingBuffer,
    packager: *Packager,
    allocator: std.mem.Allocator,
    search_progress: u16 = 0,
    current_search: [max_lookahead_window]u8 = undefined,
    hash_head: [search_buffer_size]?u64 = undefined,
    hash_prev: [search_buffer_size]?u64 = undefined,
    max_candidates: u8 = 32,
    
    pub fn init(allocator: std.mem.Allocator, packager: *Packager, buffer: []u8) !LZSS {
        return .{
            .ring_buffer = RingBuffer.init(buffer),
            .packager = packager,
            .allocator = allocator
        };
    }
    
    pub fn process(self: *LZSS, literal: u8) !void {
        // add the literal to the ring-buffer and increase the global counter
        self.ring_buffer.add(literal);
        self.processed_bytes += 1;

        if (self.processed_bytes < 3) {
            // always emit literal, there can be no backreference
            @branchHint(std.builtin.BranchHint.cold);
            try self.packager.add(.{ .literal = literal });
            return;
        }
        
        // whe have at least 3 symbols, start computing hashes
        const a = try self.ring_buffer.getOffset(2);
        const b = try self.ring_buffer.getOffset(1);
        const hash = hash3(a, b, literal);
        const hash_index = self.processed_bytes - 3; // -3 because we have three symbols 
        const prev_index = hash_index % self.ring_buffer.len;
        self.hash_prev[prev_index] = self.hash_head[hash];
        self.hash_head[hash] = hash_index;

        // memorize current search
        self.current_search[self.search_progress] = literal;
        self.search_progress += 1;
        
        // once we have long enough search, check candidates
        if (self.search_progress >= 3) {
            const search_hash = hash3(self.current_search[0], self.current_search[1], self.current_search[2]);
            var candidate_index = self.hash_head[search_hash];
            
            // no candidates for this 3-char search
            if (candidate_index == null) {
                // emit first search char and shift others to left, then wait for next literal
                try self.packager.add(.{ .literal = literal });
                self.current_search[0] = self.current_search[1];
                self.current_search[1] = self.current_search[2];
                self.search_progress -= 1;
                return;
            }
            
            var best_candidate_index: u64 = undefined;
            var longest_match: u16 = 0;
            var depth: u16 = 0;
            
            while (candidate_index != null and depth < self.max_candidates) {
                // cache is outside the search_buffer, so stop here
                if (self.processed_bytes - candidate_index.? > self.ring_buffer.len) {
                    break;
                }
                
                const buffer_idx = candidate_index.? % self.ring_buffer.len;
                const global_dist = self.processed_bytes - candidate_index.?; // distance between current global position and candidate global position
                                                                       // 
                // prevents to find candidates in hashes created during the current search
                if (global_dist <= self.search_progress) {
                    // next candidate
                    const temp_idx = candidate_index.?;
                    candidate_index = self.hash_prev[buffer_idx];

                    // TODO remove this check once everything works (for performance)
                    if (candidate_index != null and candidate_index.? == temp_idx) {
                        return error.CircularHash;
                    }
                    continue;
                }

                depth += 1;

                // count the actual match length of the candidate
                var match_len: u16 = 0;
                for (0..self.search_progress) |i| {
                    // check missmatch
                    if (self.current_search[i] != self.ring_buffer.getAt(buffer_idx + i)) {
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
                // emit first search char and shift others to left, then wait for next literal
                try self.packager.add(.{ .literal = self.current_search[0] });
                self.current_search[0] = self.current_search[1];
                self.current_search[1] = self.current_search[2];
                self.search_progress -= 1;
            } else if (longest_match < self.search_progress) {
                // no candidate equals current search, but candidate at least length 3
                const dist = self.ring_buffer.getDistance(best_candidate_index) - longest_match; // distance from starting symbol index, not current literal index
                
                try self.packager.add(.{ 
                    .match = .{
                        .dist = @intCast(dist),
                        .len = longest_match,
                    }
                });

                // init new search with the current literal
                self.current_search[0] = literal;
                self.search_progress = 1;
                
                //std.log.debug("candidates found, new search: ({s})", .{self.current_search[0..self.search_progress]});
            } else if (longest_match == max_lookahead_window) {
                // max window length reached, stop search and emit candidate
                const dist = self.ring_buffer.getDistance(best_candidate_index) - self.search_progress + 1; // distance from starting symbol index, not current literal index + 1 because the literal is included in the reference!
                
                try self.packager.add(.{
                    .match = .{
                        .dist = @intCast(dist),
                        .len = longest_match,
                    }
                });

                // start new search on next literal
                self.search_progress = 0;
            }
        }
    }

    /// no data will be added anymore to the buffer
    /// run through the rest of the lookahead data and then package
    pub fn finish(self: *LZSS) !void {
        std.log.debug("finish LZSS encoding", .{});
        // if there is search progress, just emit literals for testing now...
        // TODO should also check for current candidates later
        if (self.search_progress > 0) {
            for (self.current_search[0..self.search_progress]) |literal| {
                try self.packager.add(.{ .literal = literal });
            }
        }

        // package data and clear candidates buffer
        try self.packager.package(true);
    }
    
    /// bit-packed direct hash
    /// creates a hash that fits into u16
    /// does not avoid collisions but is good enough for LZSS
    fn hash3(a: u8, b: u8, c: u8) u16 {
        return (
            (@as(u16, a) << 10) ^
            (@as(u16, b) << 5) ^ 
            (@as(u16, c))
        ) & (search_buffer_max_index); // 32767
    }
};
