//! Z-machine header (Z-Machine Standard 1.1, section 11).
//! Story files are versions 1-8; syzigy targets versions 1-5 with an eye
//! toward v3 (Zork I, Adventure) as the primary target.

const std = @import("std");

pub const Header = struct {
    version: u8,
    flags1: u8,
    high_mem_base: u16,
    initial_pc: u16,
    dictionary_addr: u16,
    object_table_addr: u16,
    globals_addr: u16,
    static_mem_base: u16,
    flags2: u16,
    abbreviations_addr: u16,
    file_length: u32,
    checksum: u16,

    pub fn parse(mem: []const u8) !Header {
        if (mem.len < 0x40) return error.StoryTooSmall;

        const version = mem[0x00];
        if (version < 1 or version > 8) return error.UnsupportedVersion;

        var h = Header{
            .version = version,
            .flags1 = mem[0x01],
            .high_mem_base = readWord(mem, 0x04),
            .initial_pc = readWord(mem, 0x06),
            .dictionary_addr = readWord(mem, 0x08),
            .object_table_addr = readWord(mem, 0x0A),
            .globals_addr = readWord(mem, 0x0C),
            .static_mem_base = readWord(mem, 0x0E),
            .flags2 = readWord(mem, 0x10),
            .abbreviations_addr = readWord(mem, 0x18),
            .file_length = readWord(mem, 0x1A),
            .checksum = readWord(mem, 0x1C),
        };

        // File length is stored divided by a version-dependent factor.
        const factor: u32 = switch (version) {
            1, 2, 3 => 2,
            4, 5 => 4,
            else => 8,
        };
        h.file_length *= factor;
        return h;
    }

    fn readWord(mem: []const u8, addr: usize) u16 {
        return (@as(u16, mem[addr]) << 8) | @as(u16, mem[addr + 1]);
    }

    /// Set the "interpreter knows about..." flags/interpreter id fields
    /// that a well-behaved interpreter should fill in before starting the
    /// game (spec 11.1). Kept minimal: identify as a generic interpreter,
    /// no fancy fonts/colours/sound.
    pub fn writeInterpreterInfo(mem: []u8) void {
        if (mem.len <= 0x20) return;
        mem[0x1E] = 'S'; // interpreter number field is version-specific;
        // For v4+, byte 0x1E is interpreter number, 0x1F interpreter version.
        // For v3 these bytes are unused by the spec but harmless to leave.
        if (mem[0x00] >= 4) {
            mem[0x1E] = 6; // arbitrary "IBM PC" interpreter number
            mem[0x1F] = 'Z';
        }
        // Screen dimensions (rows/cols) at 0x20/0x21, used by v4+.
        if (mem.len > 0x21) {
            mem[0x20] = 25;
            mem[0x21] = 80;
        }
    }
};
