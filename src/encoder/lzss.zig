const std = @import("std");
const model = @import("model.zig");
const packager = @import("packager.zig");
const RingBuffer = @import("ring-buffer.zig").RingBuffer;
const BitWriter = @import("bit-writer.zig").BitWriter;
const pc = @import("prefix-codes.zig");

pub const max_lookahead_window: u16 = 258;
pub const search_buffer_size: u16 = 32768;
pub const hash_size: u16 = (search_buffer_size - 1) * 2 + 1;
pub const search_buffer_max_index = search_buffer_size - 1;

pub const LZSS = struct {
    allocator: std.mem.Allocator,
    packager: packager.Packager = undefined,
    ring_buffer: RingBuffer,
    processed_bytes: u64 = 0,
    
    search_index: usize = 2, // start at the 3rd symbol
    search_progress: u16 = 0,
    
    hash: u32 = 0,
    hash_head: [hash_size]?u64 = @splat(null),
    hash_prev: [search_buffer_size + max_lookahead_window]?u64 = @splat(null),
    max_candidates: u8 = 8,
    
    pub fn init(io: std.Io, allocator: std.mem.Allocator, bit_writer: *BitWriter, buffer: []u8) !LZSS {
        return .{
            .ring_buffer = RingBuffer.init(buffer),
            .packager = try packager.Packager.init(io, allocator, bit_writer),
            .allocator = allocator
        };
    }

    /// just for debugging to emit literals only
    pub fn processLiteral(self: *LZSS, literal: u8) !void {
        try self.packager.add(.{ .literal = literal });
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
        self.hash = ((self.hash << 8) | literal) & 0xFFFFFF; // rolling 3-byte hash
        const hash = hashSingle(self.hash);
        const hash_index = self.processed_bytes - 3; // - 3 because we have three symbols
        const prev_index = hash_index % self.ring_buffer.len;
        self.hash_prev[prev_index] = self.hash_head[hash];
        self.hash_head[hash] = hash_index;

        // count search length
        self.search_progress += 1;
        
        // once we have long enough search, check candidates
        if (self.search_progress >= 3) {
            const search_hash = hashSingle(self.ring_buffer.getTri(self.search_index));
            var candidate_index = self.hash_head[search_hash];
            
            // no candidates for this 3-char search
            if (candidate_index == null) {
                // emit first search char and shift others to left, then wait for next literal
                try self.packager.add(.{ .literal = self.ring_buffer.getAt(self.search_index) });
                self.search_progress -= 1;
                self.search_index += 1;
                return;
            }

            var longest_match: u16 = 0;
            var checked_candidates: u8 = 0;
            var best_candidate_index: u64 = undefined;
            
            while (candidate_index != null and checked_candidates < self.max_candidates) {
                checked_candidates += 1;
                
                const global_dist = self.processed_bytes - candidate_index.?;
                const buffer_idx = candidate_index.? % self.ring_buffer.len;
                
                // cache is outside the search_buffer => skip
                // cache inside current search => skip
                if (global_dist >= search_buffer_size or global_dist <= self.search_progress) {
                    candidate_index = self.hash_prev[buffer_idx];
                    continue;
                }

                // count the actual match length of the candidate
                const match_len= self.ring_buffer.getMatchLen(self.search_index, buffer_idx, self.search_progress);

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
                try self.packager.add(.{ .literal = self.ring_buffer.getAt(self.search_index) });
                self.search_progress -= 1;
                self.search_index += 1;
            } else if (longest_match < self.search_progress) {
                // no candidate equals current search, but candidate at least length 3
                const dist = self.ring_buffer.getDistance(best_candidate_index) - self.search_progress + 1; // distance from starting symbol index (go back search_progress + 1), not current literal index

                try self.packager.add(.{ 
                    .match = .{
                        .length = longest_match,
                        .distance_symbol = try pc.PrefixCodes.getDistanceLookupCode(@intCast(dist)),
                        .length_symbol = try pc.PrefixCodes.getLengthCode(longest_match),
                    }
                });
                
                // init new search with the current literal
                const remaining = self.search_progress - longest_match;
                self.search_progress = remaining;
                self.search_index += longest_match;
                
            } else if (longest_match == max_lookahead_window) {
                // max window length reached, stop search and emit candidate
                const dist = self.ring_buffer.getDistance(best_candidate_index) - self.search_progress + 1; // distance from starting symbol index, not current literal index + 1 because the literal is included in the reference!
                
                try self.packager.add(.{
                    .match = .{
                        .length = longest_match,
                        .distance_symbol = try pc.PrefixCodes.getDistanceLookupCode(@intCast(dist)),
                        .length_symbol = try pc.PrefixCodes.getLengthCode(longest_match),
                    }
                });

                // start new search on next literal
                self.search_progress = 0;
                self.search_index += longest_match;
            }
        }
    }

    /// no data will be added anymore to the buffer
    /// run through the rest of the lookahead data and then package
    pub fn finish(self: *LZSS) !void {
        std.log.info("finish LZSS encoding", .{});
        // if there is search progress, just emit literals for testing now...
        // TODO should also check for current candidates later
        for (0..self.search_progress) |i| {
            const literal = self.ring_buffer.getAt(self.search_index + i);
            try self.packager.add(.{ .literal = literal });
        }

        // package data and clear candidates buffer
        try self.packager.package(true);
    }

    /// bit-packed direct hash
    /// creates a hash that fits into u16
    /// does not avoid collisions but is good enough for LZSS
    fn hash3(a: u8, b: u8, c: u8) u16 {
        return hashSingle(
            (@as(u32, a) << 16) |
            (@as(u32, b) << 8) |
            @as(u32, c)
        );
    }

    /// bit-packed direct hash
    /// (value & 0xFFFFFF) => only use least significant 24 bits
    /// (*% 0x1E35A7BD) => mix the value with wrapped multiplication
    /// (>> 17) extract upper 15 bits
    fn hashSingle(value: u32) u16 {
        return @truncate(((value & 0xFFFFFF) *% 0x1E35A7BD) >> 17);
    }
};
