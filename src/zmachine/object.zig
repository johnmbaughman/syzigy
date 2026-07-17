//! Object table access: attributes, parent/sibling/child tree, and
//! properties (Z-Machine Standard section 12). Implements the v1-3 layout
//! (32 attributes, 9-byte entries) — v4+'s wider layout is not yet
//! supported.
//!
//! Methods take the `Memory` to operate on as an explicit parameter
//! rather than storing a pointer to it, since the owning `CPU` (and its
//! `Memory` field) may be moved after this table is constructed.

const std = @import("std");
const Memory = @import("memory.zig").Memory;

pub const ObjectTable = struct {
    base: u32, // header object-table address
    obj_base: u32, // base of object entries, after 31 property defaults

    const num_attrs_v3 = 32;
    const entry_size_v3 = 9;
    const prop_defaults_v3 = 31;

    pub fn init(header_obj_addr: u16) ObjectTable {
        const base = @as(u32, header_obj_addr);
        return .{
            .base = base,
            .obj_base = base + prop_defaults_v3 * 2,
        };
    }

    fn entryAddr(self: *const ObjectTable, obj: u16) u32 {
        std.debug.assert(obj != 0);
        return self.obj_base + @as(u32, obj - 1) * entry_size_v3;
    }

    pub fn testAttr(self: *const ObjectTable, mem: *const Memory, obj: u16, attr: u5) bool {
        std.debug.assert(attr < num_attrs_v3);
        const addr = self.entryAddr(obj) + attr / 8;
        const bit: u3 = @intCast(7 - (attr % 8));
        return (mem.readByte(addr) >> bit) & 1 != 0;
    }

    pub fn setAttr(self: *const ObjectTable, mem: *Memory, obj: u16, attr: u5) void {
        const addr = self.entryAddr(obj) + attr / 8;
        const bit: u3 = @intCast(7 - (attr % 8));
        const v = mem.readByte(addr) | (@as(u8, 1) << bit);
        mem.writeByte(addr, v);
    }

    pub fn clearAttr(self: *const ObjectTable, mem: *Memory, obj: u16, attr: u5) void {
        const addr = self.entryAddr(obj) + attr / 8;
        const bit: u3 = @intCast(7 - (attr % 8));
        const v = mem.readByte(addr) & ~(@as(u8, 1) << bit);
        mem.writeByte(addr, v);
    }

    pub fn parent(self: *const ObjectTable, mem: *const Memory, obj: u16) u16 {
        return mem.readByte(self.entryAddr(obj) + 4);
    }
    pub fn sibling(self: *const ObjectTable, mem: *const Memory, obj: u16) u16 {
        return mem.readByte(self.entryAddr(obj) + 5);
    }
    pub fn child(self: *const ObjectTable, mem: *const Memory, obj: u16) u16 {
        return mem.readByte(self.entryAddr(obj) + 6);
    }
    pub fn setParent(self: *const ObjectTable, mem: *Memory, obj: u16, v: u16) void {
        mem.writeByte(self.entryAddr(obj) + 4, @truncate(v));
    }
    pub fn setSibling(self: *const ObjectTable, mem: *Memory, obj: u16, v: u16) void {
        mem.writeByte(self.entryAddr(obj) + 5, @truncate(v));
    }
    pub fn setChild(self: *const ObjectTable, mem: *Memory, obj: u16, v: u16) void {
        mem.writeByte(self.entryAddr(obj) + 6, @truncate(v));
    }

    fn propTableAddr(self: *const ObjectTable, mem: *const Memory, obj: u16) u32 {
        return mem.readWord(self.entryAddr(obj) + 7);
    }

    /// Address of the (encoded) short name and its length in words.
    pub fn shortNameAddr(self: *const ObjectTable, mem: *const Memory, obj: u16) struct { addr: u32, len_words: u8 } {
        const p = self.propTableAddr(mem, obj);
        const len_words = mem.readByte(p);
        return .{ .addr = p + 1, .len_words = len_words };
    }

    fn propListStart(self: *const ObjectTable, mem: *const Memory, obj: u16) u32 {
        const p = self.propTableAddr(mem, obj);
        const len_words = mem.readByte(p);
        return p + 1 + @as(u32, len_words) * 2;
    }

    /// A decoded property-list entry header.
    const PropEntry = struct { number: u8, size: u8, data_addr: u32, next_addr: u32 };

    fn readPropEntry(mem: *const Memory, addr: u32) ?PropEntry {
        const size_byte = mem.readByte(addr);
        if (size_byte == 0) return null;
        const number: u8 = @intCast(size_byte & 0x1F);
        const size: u8 = @intCast((size_byte >> 5) + 1);
        return .{ .number = number, .size = size, .data_addr = addr + 1, .next_addr = addr + 1 + size };
    }

    /// Get a property's value (1 or 2 byte properties per spec 12.4.1).
    /// Falls back to the property-defaults table if the object doesn't
    /// define it.
    pub fn getProp(self: *const ObjectTable, mem: *const Memory, obj: u16, prop: u8) u16 {
        var addr = self.propListStart(mem, obj);
        while (readPropEntry(mem, addr)) |e| {
            if (e.number == prop) {
                if (e.size == 1) return mem.readByte(e.data_addr);
                return mem.readWord(e.data_addr);
            }
            if (e.number < prop) break;
            addr = e.next_addr;
        }
        // Property defaults table: 31 words at self.base.
        return mem.readWord(self.base + @as(u32, prop - 1) * 2);
    }

    pub fn putProp(self: *const ObjectTable, mem: *Memory, obj: u16, prop: u8, value: u16) void {
        var addr = self.propListStart(mem, obj);
        while (readPropEntry(mem, addr)) |e| {
            if (e.number == prop) {
                if (e.size == 1) {
                    mem.writeByte(e.data_addr, @truncate(value));
                } else {
                    mem.writeWord(e.data_addr, value);
                }
                return;
            }
            addr = e.next_addr;
        }
        // Per spec, put_prop on an undefined property is a game error;
        // ignored here rather than crashing the interpreter.
    }

    /// Address of a property's data, or 0 if the object has no such
    /// property (spec 2OP:18 get_prop_addr).
    pub fn getPropAddr(self: *const ObjectTable, mem: *const Memory, obj: u16, prop: u8) u16 {
        var addr = self.propListStart(mem, obj);
        while (readPropEntry(mem, addr)) |e| {
            if (e.number == prop) return @truncate(e.data_addr);
            if (e.number < prop) break;
            addr = e.next_addr;
        }
        return 0;
    }

    pub fn getPropLen(self: *const ObjectTable, mem: *const Memory, data_addr: u16) u8 {
        _ = self;
        if (data_addr == 0) return 0;
        const size_byte = mem.readByte(@as(u32, data_addr) - 1);
        return @intCast((size_byte >> 5) + 1);
    }

    /// Next property number after `prop` (0 to start iteration), or 0 when
    /// there are no more (spec 2OP:19 get_next_prop).
    pub fn getNextProp(self: *const ObjectTable, mem: *const Memory, obj: u16, prop: u8) u8 {
        var addr = self.propListStart(mem, obj);
        if (prop == 0) {
            return if (readPropEntry(mem, addr)) |e| e.number else 0;
        }
        while (readPropEntry(mem, addr)) |e| {
            if (e.number == prop) {
                return if (readPropEntry(mem, e.next_addr)) |next| next.number else 0;
            }
            addr = e.next_addr;
        }
        return 0;
    }

    /// Detach `obj` from its parent's sibling chain.
    pub fn unlink(self: *const ObjectTable, mem: *Memory, obj: u16) void {
        const p = self.parent(mem, obj);
        if (p == 0) return;
        const first = self.child(mem, p);
        if (first == obj) {
            self.setChild(mem, p, self.sibling(mem, obj));
        } else {
            var s = first;
            while (s != 0) {
                const next = self.sibling(mem, s);
                if (next == obj) {
                    self.setSibling(mem, s, self.sibling(mem, obj));
                    break;
                }
                s = next;
            }
        }
        self.setParent(mem, obj, 0);
        self.setSibling(mem, obj, 0);
    }

    /// Move `obj` to be the first child of `dest` (spec 2OP:14 insert_obj).
    pub fn insert(self: *const ObjectTable, mem: *Memory, obj: u16, dest: u16) void {
        self.unlink(mem, obj);
        self.setSibling(mem, obj, self.child(mem, dest));
        self.setChild(mem, dest, obj);
        self.setParent(mem, obj, dest);
    }
};
