//! Z-character text encoding/decoding (Z-Machine Standard section 3).
//! Handles the three alphabet tables, abbreviations, and the 10-bit
//! ZSCII escape used for characters outside the alphabets.

const std = @import("std");
const Memory = @import("memory.zig").Memory;

const alphabet_a0 = "abcdefghijklmnopqrstuvwxyz";
const alphabet_a1 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
// Index 0 (z-char 6) is the ZSCII-escape trigger and never printed literally.
const alphabet_a2 = " \n0123456789.,!?_#'\"/\\-:()";

pub const DecodeResult = struct { text: []u8, end: u32 };

/// Decode a Z-encoded string starting at `addr`. `abbrev_addr` is the
/// header's abbreviations-table address (0 to disable abbreviation
/// expansion, used when decoding an abbreviation string itself since the
/// spec forbids abbreviations from referencing other abbreviations).
pub fn decode(mem: *const Memory, allocator: std.mem.Allocator, addr: u32, abbrev_addr: u16) !DecodeResult {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var a: u32 = addr;
    var alphabet: u8 = 0;
    const shift_lock_capable = mem.version == 1;
    var shift_lock: bool = false;
    var pending_abbrev: u8 = 0; // 1-3 while waiting for abbrev index char
    var zscii_state: u8 = 0; // 0=none, 1=have top 5 bits, 2=complete
    var zscii_top: u5 = 0;

    outer: while (true) {
        const word = mem.readWord(a);
        a += 2;
        const chars = [3]u5{
            @truncate((word >> 10) & 0x1F),
            @truncate((word >> 5) & 0x1F),
            @truncate(word & 0x1F),
        };

        for (chars) |zc| {
            if (zscii_state == 1) {
                zscii_top = zc;
                zscii_state = 2;
                continue;
            }
            if (zscii_state == 2) {
                const code = (@as(u16, zscii_top) << 5) | @as(u16, zc);
                try out.append(allocator, @truncate(code));
                zscii_state = 0;
                continue;
            }
            if (pending_abbrev != 0) {
                const index = (@as(u16, pending_abbrev) - 1) * 32 + @as(u16, zc);
                pending_abbrev = 0;
                if (abbrev_addr != 0) {
                    const entry_addr = @as(u32, abbrev_addr) + @as(u32, index) * 2;
                    const str_word_addr = mem.readWord(entry_addr);
                    const str_addr = @as(u32, str_word_addr) * 2;
                    const sub = try decode(mem, allocator, str_addr, 0);
                    defer allocator.free(sub.text);
                    try out.appendSlice(allocator, sub.text);
                }
                continue;
            }

            switch (zc) {
                0 => try out.append(allocator, ' '),
                1, 2, 3 => pending_abbrev = @intCast(zc),
                4 => {
                    alphabet = 1;
                    if (shift_lock_capable) shift_lock = true;
                },
                5 => {
                    alphabet = 2;
                    if (shift_lock_capable) shift_lock = true;
                },
                else => {
                    if (alphabet == 2 and zc == 6) {
                        zscii_state = 1;
                    } else {
                        const table = switch (alphabet) {
                            0 => alphabet_a0,
                            1 => alphabet_a1,
                            else => alphabet_a2,
                        };
                        try out.append(allocator, table[zc - 6]);
                    }
                    if (!shift_lock) alphabet = 0;
                },
            }
        }

        if (word & 0x8000 != 0) break :outer;
    }

    return .{ .text = try out.toOwnedSlice(allocator), .end = a };
}

/// Map a lowercase ASCII character to its A2-table z-char, if present.
fn a2Index(c: u8) ?u5 {
    for (alphabet_a2, 0..) |ch, i| {
        if (ch == c) return @intCast(6 + i);
    }
    return null;
}

/// Encode `text` (ASCII, case-sensitive) into `num_words` big-endian
/// Z-machine words of packed z-characters, per spec 3.7 (used to build
/// dictionary lookup keys from typed player input). `num_words` is 2 for
/// versions 1-3 (6 z-chars) and 3 for versions 4+ (9 z-chars), per the
/// dictionary's declared entry format. Extra slots are padded with z-char 5.
pub fn encode(text: []const u8, num_words: usize, out: []u16) void {
    var zchars: [9]u5 = undefined;
    var n: usize = 0;
    const max = @min(num_words * 3, zchars.len);

    const push = struct {
        fn call(arr: *[9]u5, len: *usize, limit: usize, v: u5) void {
            if (len.* < limit) {
                arr[len.*] = v;
                len.* += 1;
            }
        }
    }.call;

    for (text) |raw| {
        if (n >= max) break;
        const c = std.ascii.toLower(raw);
        if (c >= 'a' and c <= 'z') {
            push(&zchars, &n, max, @intCast(6 + (c - 'a')));
        } else if (a2Index(c)) |idx| {
            push(&zchars, &n, max, 5);
            push(&zchars, &n, max, idx);
        } else {
            // ZSCII escape: shift to A2, escape z-char 6, then top5/bottom5.
            push(&zchars, &n, max, 5);
            push(&zchars, &n, max, 6);
            push(&zchars, &n, max, @intCast((c >> 5) & 0x1F));
            push(&zchars, &n, max, @intCast(c & 0x1F));
        }
    }
    while (n < max) push(&zchars, &n, max, 5);

    var w: usize = 0;
    while (w < num_words) : (w += 1) {
        const c0: u16 = zchars[w * 3];
        const c1: u16 = zchars[w * 3 + 1];
        const c2: u16 = zchars[w * 3 + 2];
        var word: u16 = (c0 << 10) | (c1 << 5) | c2;
        if (w == num_words - 1) word |= 0x8000;
        out[w] = word;
    }
}

test "encode pads short words" {
    var out: [2]u16 = undefined;
    encode("go", 2, &out);
    // 'g'=6+6=12, 'o'=6+14=20, then pad(5) x4
    try std.testing.expectEqual(@as(u16, (12 << 10) | (20 << 5) | 5), out[0]);
    try std.testing.expectEqual(@as(u16, 0x8000 | (5 << 10) | (5 << 5) | 5), out[1]);
}
