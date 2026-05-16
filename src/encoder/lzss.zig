const std = @import("std");
const model = @import("model.zig");
const packager = @import("packager.zig");
const RingBuffer = @import("ring-buffer.zig").RingBuffer;
const BitWriter = @import("bit-writer.zig").BitWriter;
const pc = @import("prefix-codes.zig");

pub const max_lookahead_window: u16 = 258;
pub const search_buffer_size: u16 = 32768;

const search_buffer_mask: u16 = search_buffer_size - 1;
const max_lookback_distance: u16 = search_buffer_size - max_lookahead_window;
const hash_size: u32 = 65536;
const max_candidate_depth: u8 = 12;
const max_candidates: u8 = 8;

const LZSSRingBuffer = RingBuffer(search_buffer_size);

pub const LZSS = struct {
    allocator: std.mem.Allocator,
    packager: packager.Packager = undefined,
    ring_buffer: LZSSRingBuffer,
    
    processed_bytes: u64 = 0,
    search_index: usize = 2, // start at the 3rd symbol

    candidate_depth_limit: u8 = max_candidate_depth,
    candidate_save_limit: u8 = max_candidates,
    best_candidate_index: u16 = 0,
    candidate_indices: [max_candidate_depth]?u16 = @splat(null),
    candidates: u8 = 0,
    
    hash: u32 = 0,
    hash_head: [hash_size]?u64 = @splat(null),
    hash_prev: [search_buffer_size]?u64 = @splat(null),
    
    literal_colunter: u16 = 0,
    length_reference_counter: u16 = 0,
    
    pub fn init(io: std.Io, allocator: std.mem.Allocator, bit_writer: *BitWriter) LZSS {
        return .{
            .ring_buffer = .{},
            .packager = try packager.Packager.init(io, allocator, bit_writer),
            .allocator = allocator
        };
    }

    pub fn processLiteral(self: *LZSS, literal: u8) !void {
        self.ring_buffer.add(literal);
        self.processed_bytes += 1;

        try self.emitLiteral(literal);
    }
    
    pub fn processChunk(self: *LZSS, chunk: []u8) !void {
        self.literal_colunter = 0;
        self.length_reference_counter = 0;

        for (chunk) |literal| {
            try self.process(literal);
        }
        
        // check length to literal encoding ratio and adapt candidate search depth accordingly
        const ratio = @as(f16, @floatFromInt(self.length_reference_counter)) / @as(f16, @floatFromInt(self.literal_colunter));
        if (ratio < 0.01) {
            self.candidate_depth_limit = 1;
            self.candidate_save_limit = 1;
        } else if (ratio < 0.02) {
            self.candidate_depth_limit = 2;
            self.candidate_save_limit = 2;
        } else if (ratio < 0.05) {
            self.candidate_depth_limit = 4;
            self.candidate_save_limit = 4;
        } else if (ratio < 0.1) {
            self.candidate_depth_limit = 8;
            self.candidate_save_limit = 8;
        } else {
            self.candidate_depth_limit = max_candidate_depth;
            self.candidate_save_limit = max_candidates;
        }
    }
    
    fn process(self: *LZSS, literal: u8) !void {
        self.ring_buffer.add(literal);
        self.processed_bytes += 1;

        // compute hashes
        self.hash = ((self.hash << 8) | literal) & 0xFFFFFF; // rolling 3-byte hash, (& 0xFFFFFF) limits to 24 bits
        const hash = hashSingle(self.hash);
        const hash_index = self.processed_bytes - 3; // - 3 because we have three symbols
        const prev_index = hash_index & search_buffer_mask; // works the same as (% ring_buffer_size)
        self.hash_prev[prev_index] = self.hash_head[hash];
        self.hash_head[hash] = hash_index;

        // count search length
        const search_progress: u16 = @intCast(self.processed_bytes - self.search_index);
        if (search_progress < 3) {
            return;
        }
        
        // we have long enough search, check candidates
        const search_buffer_index: u16 = @intCast(self.search_index & search_buffer_mask);
        const search_hash = hashSingle(self.ring_buffer.getTri(search_buffer_index));
        const candidate_index = self.hash_head[search_hash];
        
        // no candidates for this 3-char search
        if (candidate_index == null) {
            // emit first search char and advance search_index
             try self.emitLiteral(self.ring_buffer.buffer[search_buffer_index]);
            self.search_index += 1;
            return;
        }

        var has_match = false;

        if (search_progress == 3) {
            has_match = self.findCandidates(candidate_index.?, search_progress, search_buffer_index);
        } else {
            // more than 3-byte search, check existing candidates
            for (0..self.candidates) |i| {
                if (self.candidate_indices[i]) |buffer_idx| {
                    if (self.ring_buffer.buffer[buffer_idx + search_progress - 1] == literal) {
                        has_match = true;
                        self.best_candidate_index = buffer_idx;
                    } else {
                        self.candidate_indices[i] = null;
                    }
                }
            }
        }
        
        try self.checkBackReferenceCandidates(has_match, search_progress, search_buffer_index);
    }
    
    /// finds all candidates until either `candidate_depth` is reached or `max_candidates` are found
    fn findCandidates(self: *LZSS, start_candidate_index: u64, search_progress: u16, search_buffer_index: u16) bool {
        var has_match = false;
        var candidate_depth: u8 = 0;
        var candidate_index: ?u64 = start_candidate_index;
        
        while (candidate_index) |idx| {
            if (candidate_depth >= self.candidate_depth_limit) {
                break;
            }

            const global_dist = self.processed_bytes - idx;
            const buffer_idx: u16 = @intCast(idx & search_buffer_mask);

            // cache is outside the search_buffer => skip
            // cache is inside current search => skip
            if (global_dist < max_lookback_distance and global_dist > search_progress) {
                // check if the candidate matches
                const matches = self.ring_buffer.matches(search_buffer_index, buffer_idx, search_progress);
                if (matches) {
                    self.candidate_indices[self.candidates] = buffer_idx;
                    self.candidates += 1;

                    has_match = true;
                    self.best_candidate_index = buffer_idx;

                    // we have enough candidates
                    if (self.candidates == self.candidate_save_limit) {
                        break;
                    }
                }
            }

            // next candidate
            candidate_index = self.hash_prev[buffer_idx];
            candidate_depth += 1;
        }
        
        return has_match;
    }
    
    fn checkBackReferenceCandidates(self: *LZSS, has_match: bool, search_progress: u16, search_buffer_index: u16) !void {
        // no candidate and we are at smallest search, emit first literal and advance search index by 1
        if (!has_match and search_progress == 3) {
            // emit first search char and shift others to left, then wait for next literal
            try self.emitLiteral(self.ring_buffer.buffer[search_buffer_index]);
            self.search_index += 1;
            self.candidates = 0;
        } else if (!has_match) {
            // no matches anymore but search is > 3
            // we have at least one candidate from the last iteration that had a full match
            const dist = self.ring_buffer.getDistance(self.best_candidate_index) - search_progress + 1; // distance from starting symbol index (go back search_progress + 1), not current literal index
            try self.emitBackReference(@intCast(dist), search_progress - 1);

            // init new search with the current literal
            self.search_index = self.processed_bytes - 1;
            self.candidates = 0;
        } else if (search_progress == max_lookahead_window) {
            @branchHint(.cold);
            // max window length reached, stop search and emit candidate
            // distance from starting symbol index, not current literal, index + 1 because the current literal is included in the reference!
            const dist = self.ring_buffer.getDistance(self.best_candidate_index) - search_progress + 1;
            try self.emitBackReference(@intCast(dist), max_lookahead_window);

            // start new search on next literal
            self.search_index += max_lookahead_window;
            self.candidates = 0;
        }
    }
    
    fn emitLiteral(self: *LZSS, literal: u8) !void {
        self.literal_colunter += 1;
        try self.packager.add(.{ .literal = literal });
    }

    fn emitBackReference(self: *LZSS, dist: u32, length: u16) !void {
        self.length_reference_counter += length;
        try self.packager.add(.{
            .match = .{
                .length = length,
                .distance_symbol = try pc.PrefixCodes.getDistanceLookupCode(dist),
                .length_symbol = try pc.PrefixCodes.getLengthCode(length),
            }
        });
    }

    /// no data will be added anymore to the buffer
    /// run through the rest of the lookahead data and then package
    pub fn finish(self: *LZSS) !void {
        std.log.info("finish LZSS encoding", .{});

        if (self.processed_bytes > 2) {
            const search_progress: u16 = @intCast(self.processed_bytes - self.search_index);
            const search_buffer_index: u16 = @intCast(self.search_index & search_buffer_mask);

            // there is an ongoing search and there must have been a full match in the last emitted literal
            // otherwise search progress would be < 3
            if (search_progress >= 3) {
                const dist = self.ring_buffer.getDistance(self.best_candidate_index) - search_progress + 1;
                try self.emitBackReference(@intCast(dist), search_progress);
            } else {
                // just emit literals
                for (0..search_progress) |i| {
                    const literal = self.ring_buffer.buffer[search_buffer_index + i];
                    try self.packager.add(.{ .literal = literal });
                }
            }
        }
        
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
