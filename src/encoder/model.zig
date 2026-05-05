
/// .gz file header.
pub const GzHeader = packed struct {
    id1: u8 = 0x1f, // fixed magic number of .gz
    id2: u8 = 0x8b, // fixed magic number of .gz
    cm: u8 = 0x08, // deflate, no other compression supported
    flags: u8 = 0x00, // all flags disabled by default
    mtime: u32 = 0x00000000, // no modification time by default
    xfl: u8 = 0x00, // all extra flags disabled by default
    os: u8 = 0x03, // defaults to unix
};

/// .gz file footer
pub const GzFooter = packed struct {
    crc32: u32,
    isize: u32,
};

/// block type 00
pub const UncompressedBlockHeader = packed struct {
    bfinal: bool, // true if last block 
    btype: u2 = 0x0, // 0 = uncompressed
    padding: u5 = 0x0, // fixed 5 bits zero padding
    len: u16, // length of the data
    nlen: u16, // complement of length
};

/// block type 01 and 01
pub const CompressedBlockHeader = packed struct {
    bfinal: u1, // true if last block 
    btype: u2 = 0x0, // 0 = uncompressed
};

pub const LDCode = struct {
    code: u16,
    offset: u32,
    extra_bits: u4
};

pub const CodeLookup = struct {
    min: u32,
    max: u32,
    base_code: u16,
    extra_bits: u4
};

pub const PrefixCode = struct {
    length: u4,
    code: u16,
};

pub const LZToken = union(enum) {
    literal: u8,
    match: struct {
        len: u16,
        dist: u16,
    }
};