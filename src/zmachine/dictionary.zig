//! Dictionary lookup and the lexical-analysis step of `sread`/`tokenise`
//! (Z-Machine Standard sections 13, 15.3, 15.20).
//!
//! Like `ObjectTable`, this stores addresses/values computed at `init`
//! time plus a separators slice (which points into the story-file byte
//! buffer, not into the `Memory` struct, so it stays valid even if the
//! owning `CPU` moves) — but it takes `*const Memory` as an explicit
//! parameter for lookups rather than storing a pointer to it.

const std = @import("std");
const Memory = @import("memory.zig").Memory;
const text = @import("text.zig");

pub const Dictionary = struct {
    addr: u32,
    separators: []const u8,
    entry_len: u8,
    num_entries: u16,
    sorted: bool, // spec 13.4: a negative entry count means unsorted -> linear scan
    entries_addr: u32,
    entry_text_words: usize, // 2 for v1-3, 3 for v4+

    pub fn init(mem: *const Memory, header_dict_addr: u16) Dictionary {
        const addr: u32 = header_dict_addr;
        const n_sep = mem.readByte(addr);
        const sep_addr = addr + 1;
        const entry_len_addr = sep_addr + n_sep;
        const entry_len = mem.readByte(entry_len_addr);
        const raw_count: i16 = @bitCast(mem.readWord(entry_len_addr + 1));
        return .{
            .addr = addr,
            .separators = mem.bytes[sep_addr .. sep_addr + n_sep],
            .entry_len = entry_len,
            .num_entries = if (raw_count < 0) @intCast(-raw_count) else @intCast(raw_count),
            .sorted = raw_count >= 0,
            .entries_addr = entry_len_addr + 3,
            .entry_text_words = if (mem.version <= 3) 2 else 3,
        };
    }

    fn entryAddr(self: *const Dictionary, i: u16) u32 {
        return self.entries_addr + @as(u32, i) * self.entry_len;
    }

    fn isSeparator(self: *const Dictionary, c: u8) bool {
        for (self.separators) |s| if (s == c) return true;
        return false;
    }

    /// Binary search the (alphabetically sorted, per spec 13.4) dictionary
    /// for `word`. Returns the dictionary entry's byte address, or 0 if
    /// not found.
    pub fn lookup(self: *const Dictionary, mem: *const Memory, word: []const u8) u16 {
        var key: [3]u16 = undefined;
        text.encode(word, self.entry_text_words, key[0..self.entry_text_words]);
        const keyslice = key[0..self.entry_text_words];

        if (!self.sorted) {
            var i: u16 = 0;
            while (i < self.num_entries) : (i += 1) {
                const a = self.entryAddr(i);
                if (self.compareKey(mem, a, keyslice) == 0) return @intCast(a);
            }
            return 0;
        }

        var lo: i32 = 0;
        var hi: i32 = @as(i32, self.num_entries) - 1;
        while (lo <= hi) {
            const mid: i32 = @divFloor(lo + hi, 2);
            const a = self.entryAddr(@intCast(mid));
            const cmp = self.compareKey(mem, a, keyslice);
            if (cmp == 0) return @intCast(a);
            if (cmp < 0) lo = mid + 1 else hi = mid - 1;
        }
        return 0;
    }

    fn compareKey(self: *const Dictionary, mem: *const Memory, entry_addr: u32, key: []const u16) i32 {
        _ = self;
        var i: usize = 0;
        while (i < key.len) : (i += 1) {
            const w = mem.readWord(entry_addr + @as(u32, @intCast(i)) * 2);
            if (w != key[i]) return if (w < key[i]) -1 else 1;
        }
        return 0;
    }

    pub const Token = struct { start: usize, len: usize, dict_addr: u16 };

    /// Split `input` into tokens on whitespace and dictionary separators
    /// (which are themselves emitted as one-character tokens), per spec
    /// 13.6.1. `input` is assumed already lowercased; tokens reference
    /// byte offsets into `input`.
    pub fn tokenize(self: *const Dictionary, mem: *const Memory, input: []const u8, allocator: std.mem.Allocator) ![]Token {
        var tokens: std.ArrayList(Token) = .empty;
        errdefer tokens.deinit(allocator);

        var i: usize = 0;
        while (i < input.len) {
            const c = input[i];
            if (c == ' ') {
                i += 1;
                continue;
            }
            if (self.isSeparator(c)) {
                try tokens.append(allocator, .{ .start = i, .len = 1, .dict_addr = self.lookup(mem, input[i .. i + 1]) });
                i += 1;
                continue;
            }
            const start = i;
            while (i < input.len and input[i] != ' ' and !self.isSeparator(input[i])) : (i += 1) {}
            try tokens.append(allocator, .{ .start = start, .len = i - start, .dict_addr = self.lookup(mem, input[start..i]) });
        }
        return tokens.toOwnedSlice(allocator);
    }
};
