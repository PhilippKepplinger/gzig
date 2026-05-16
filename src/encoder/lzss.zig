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
const max_candidate_depth: u8 = 8;
const max_candidates: u8 = 4;

const LZSSRingBuffer = RingBuffer(search_buffer_size);

pub const LZSS = struct {
    allocator: std.mem.Allocator,
    packager: packager.Packager = undefined,
    ring_buffer: LZSSRingBuffer,
    
    processed_bytes: u64 = 0,
    search_index: usize = 2, // start at the 3rd symbol

    best_candidate_index: u16 = 0,
    candidate_indices: [max_candidates]?u16 = @splat(null),
    candidates: u8 = 0,
    
    hash: u32 = 0,
    hash_head: [hash_size]?u64 = @splat(null),
    hash_prev: [search_buffer_size]?u64 = @splat(null),
    
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

        try self.packager.add(.{ .literal = literal });
    }
    
    pub fn processChunk(self: *LZSS, chunk: []u8) !void {
        for (chunk) |literal| {
            try self.process(literal);
        }
    }
    
    fn process(self: *LZSS, literal: u8) !void {
        self.ring_buffer.add(literal);
        self.processed_bytes += 1;

        // compute hashes
        self.hash = ((self.hash << 8) | literal) & 0xFFFFFF; // rolling 3-byte hash, (& 0xFFFFFF) limits to 24 bits
        const hash = hashSingle(self.hash);
        const hash_index = self.processed_bytes - 3; // - 3 because we have three symbols
        const prev_index = hash_index & search_buffer_mask; // works the same as (% ring_buffer.len)
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
        var candidate_index = self.hash_head[search_hash];
        
        // no candidates for this 3-char search
        if (candidate_index == null) {
            // emit first search char and advance search_index
            try self.packager.add(.{ .literal = self.ring_buffer.buffer[search_buffer_index] });
            self.search_index += 1;
            return;
        }

        var has_match = false;
        var candidate_depth: u8 = 0;
        
        // new full 3-byte search, find candidates
        if (search_progress == 3) {
            // find all candidates
            while (candidate_index != null and candidate_depth < max_candidate_depth) {
                candidate_depth += 1;

                const global_dist = self.processed_bytes - candidate_index.?;
                const buffer_idx: u16 = @intCast(candidate_index.? & search_buffer_mask);

                // cache is outside the search_buffer => skip
                // cache inside current search => skip
                if (global_dist >= max_lookback_distance or global_dist <= search_progress) {
                    candidate_index = self.hash_prev[buffer_idx];
                    continue;
                }

                // check if the candidate matches
                const matches = self.ring_buffer.matches(search_buffer_index, buffer_idx, search_progress);
                if (matches) {
                    self.candidate_indices[self.candidates] = buffer_idx;
                    self.candidates += 1;
                    
                    // we have enough candidates
                    if (self.candidates == max_candidates) {
                        break;
                    }
                }

                // next candidate
                candidate_index = self.hash_prev[buffer_idx];
            }
        } else {
            // more than 3-byte search, check existing candidates
            for (0..self.candidates) |i| {
                if (self.candidate_indices[self.candidates - i - 1]) |buffer_idx| {
                    if (self.ring_buffer.buffer[buffer_idx + search_progress] == literal) {
                        has_match = true;
                        self.best_candidate_index = buffer_idx;
                    } else {
                        self.candidate_indices[i] = null;
                    }
                }
            }
        }
        
        // no candidate and we are at smallest search, emit first literal and advance search index by 1
        if (!has_match and search_progress == 3) {
            // emit first search char and shift others to left, then wait for next literal
            try self.packager.add(.{ .literal = self.ring_buffer.buffer[search_buffer_index] });
            self.search_index += 1;
            self.candidates = 0;
        } else if (!has_match) {
            // no matches anymore but search is > 3
            // we have at least one candidate from the last iteration that had a full match
            const dist = self.ring_buffer.getDistance(self.best_candidate_index) - search_progress + 1; // distance from starting symbol index (go back search_progress + 1), not current literal index

            try self.packager.add(.{ 
                .match = .{
                    .length = search_progress - 1,
                    .distance_symbol = try pc.PrefixCodes.getDistanceLookupCode(@intCast(dist)),
                    .length_symbol = try pc.PrefixCodes.getLengthCode(search_progress - 1),
                }
            });
            
            // init new search with the current literal
            self.search_index = self.processed_bytes - 1;
            self.candidates = 0;
        } else if (search_progress == max_lookahead_window) {
            @branchHint(.cold);
            // max window length reached, stop search and emit candidate
            // distance from starting symbol index, not current literal, index + 1 because the current literal is included in the reference!
            const dist = self.ring_buffer.getDistance(self.best_candidate_index) - search_progress + 1;
            
            try self.packager.add(.{
                .match = .{
                    .length = max_lookahead_window,
                    .distance_symbol = try pc.PrefixCodes.getDistanceLookupCode(@intCast(dist)),
                    .length_symbol = try pc.PrefixCodes.getLengthCode(max_lookahead_window),
                }
            });

            // start new search on next literal
            self.search_index += max_lookahead_window;
        }
    }

    /// no data will be added anymore to the buffer
    /// run through the rest of the lookahead data and then package
    pub fn finish(self: *LZSS) !void {
        std.log.info("finish LZSS encoding", .{});
        // if there is search progress, just emit literals for testing now...
        // TODO should also check for current candidates later
        if (self.processed_bytes > 2) {
            const search_progress = self.processed_bytes - self.search_index;
            const search_buffer_index = self.search_index & search_buffer_mask;
            for (0..search_progress) |i| {
                const literal = self.ring_buffer.buffer[search_buffer_index + i];
                try self.packager.add(.{ .literal = literal });
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
