//! Flat story-file memory with the byte/word helpers and packed-address
//! math defined in the Z-Machine Standard (sections 1.2, 4.5, 11).

const std = @import("std");
const Header = @import("header.zig").Header;

pub const Memory = struct {
    bytes: []u8,
    version: u8,

    pub fn init(bytes: []u8, version: u8) Memory {
        return .{ .bytes = bytes, .version = version };
    }

    pub fn readByte(self: *const Memory, addr: u32) u8 {
        return self.bytes[addr];
    }

    pub fn writeByte(self: *Memory, addr: u32, val: u8) void {
        self.bytes[addr] = val;
    }

    pub fn readWord(self: *const Memory, addr: u32) u16 {
        return (@as(u16, self.bytes[addr]) << 8) | @as(u16, self.bytes[addr + 1]);
    }

    pub fn writeWord(self: *Memory, addr: u32, val: u16) void {
        self.bytes[addr] = @truncate(val >> 8);
        self.bytes[addr + 1] = @truncate(val & 0xFF);
    }

    /// Unpack a packed routine/string address (spec 1.2.3).
    pub fn unpackAddr(self: *const Memory, packed_addr: u16) u32 {
        return switch (self.version) {
            1, 2, 3 => @as(u32, packed_addr) * 2,
            4, 5 => @as(u32, packed_addr) * 4,
            6, 7 => @as(u32, packed_addr) * 4, // ignoring routine/string offsets
            8 => @as(u32, packed_addr) * 8,
            else => @as(u32, packed_addr) * 2,
        };
    }
};
