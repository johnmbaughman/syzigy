//! Instruction decode/execute loop (Z-Machine Standard chapters 4-15).
//! Targets versions 1-3 primarily (Zork I, Adventure). A handful of v4+
//! opcodes are present only as no-ops so later story files at least limp
//! along instead of crashing the interpreter.
//!
//! Save/restore uses a small ad-hoc binary format, not Quetzal — good
//! enough to save/restore within this interpreter, but not portable to
//! other Z-machine interpreters. See README for details.

const std = @import("std");
const Memory = @import("memory.zig").Memory;
const Header = @import("header.zig").Header;
const ObjectTable = @import("object.zig").ObjectTable;
const Dictionary = @import("dictionary.zig").Dictionary;
const Screen = @import("screen.zig").Screen;
const text = @import("text.zig");

const Frame = struct {
    locals: [15]u16 = @splat(0),
    num_locals: u8 = 0,
    return_pc: u32 = 0,
    store_var: ?u8 = null,
    stack_base: usize = 0,
    num_args: u8 = 0,
};

const OperandType = enum { large, small, variable, omitted };
const OpKind = enum { op2, op1, op0, varop };

const Branch = struct { on_true: bool, offset: i16 };

fn signed(v: u16) i16 {
    return @bitCast(v);
}
fn unsigned(v: i16) u16 {
    return @bitCast(v);
}

fn writeIntLE(w: *std.Io.Writer, comptime T: type, val: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, val, .little);
    try w.writeAll(&buf);
}

fn readIntLE(r: *std.Io.Reader, comptime T: type) !T {
    const arr = try r.takeArray(@sizeOf(T));
    return std.mem.readInt(T, arr, .little);
}

const debug_trace = false; // set true to print each decoded instruction to stderr

fn randomSeed(io: std.Io) u64 {
    var buf: [8]u8 = undefined;
    std.Io.random(io, &buf);
    return std.mem.readInt(u64, &buf, .little);
}

pub const CPU = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mem: Memory,
    header: Header,
    obj: ObjectTable,
    dict: Dictionary,
    screen: *Screen,
    orig_bytes: []u8,
    pc: u32,
    value_stack: std.ArrayList(u16),
    frames: std.ArrayList(Frame),
    rng: std.Random.DefaultPrng,
    running: bool = true,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, mem: Memory, header: Header, screen: *Screen) !CPU {
        const orig = try allocator.dupe(u8, mem.bytes);
        var cpu = CPU{
            .allocator = allocator,
            .io = io,
            .mem = mem,
            .header = header,
            .obj = undefined,
            .dict = undefined,
            .screen = screen,
            .orig_bytes = orig,
            .pc = header.initial_pc,
            .value_stack = .empty,
            .frames = .empty,
            .rng = std.Random.DefaultPrng.init(randomSeed(io)),
        };
        cpu.obj = ObjectTable.init(header.object_table_addr);
        cpu.dict = Dictionary.init(&cpu.mem, header.dictionary_addr);
        // Spec 5.5: execution starts "as if" the main routine had been
        // called by the interpreter with 0 arguments. Main is compiled
        // with no locals of its own, but a frame must still exist so
        // that a stray rtrue/ret at the outermost level (and doReturn's
        // bookkeeping in general) has something to pop.
        try cpu.frames.append(allocator, .{ .num_locals = 0, .return_pc = 0, .store_var = null, .stack_base = 0, .num_args = 0 });
        return cpu;
    }

    pub fn deinit(self: *CPU) void {
        self.value_stack.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        self.allocator.free(self.orig_bytes);
    }

    pub fn run(self: *CPU) !void {
        while (self.running) {
            try self.step();
        }
        self.screen.flush();
    }

    // ---- Variable access (spec 4.2.2, 6.3.4) ----

    fn readVar(self: *CPU, num: u8) u16 {
        if (num == 0) return self.value_stack.pop() orelse 0;
        if (num < 16) return self.frames.items[self.frames.items.len - 1].locals[num - 1];
        return self.mem.readWord(@as(u32, self.header.globals_addr) + @as(u32, num - 16) * 2);
    }

    fn writeVar(self: *CPU, num: u8, val: u16) void {
        if (num == 0) {
            self.value_stack.append(self.allocator, val) catch {};
            return;
        }
        if (num < 16) {
            self.frames.items[self.frames.items.len - 1].locals[num - 1] = val;
            return;
        }
        self.mem.writeWord(@as(u32, self.header.globals_addr) + @as(u32, num - 16) * 2, val);
    }

    /// `load`/`store` peek/poke the stack top in place instead of
    /// pushing/popping (spec 6.3.4's exception for these two opcodes).
    fn readVarIndirect(self: *CPU, num: u8) u16 {
        if (num == 0) {
            const items = self.value_stack.items;
            return if (items.len == 0) 0 else items[items.len - 1];
        }
        return self.readVar(num);
    }

    fn writeVarIndirect(self: *CPU, num: u8, val: u16) void {
        if (num == 0) {
            const items = self.value_stack.items;
            if (items.len == 0) {
                self.value_stack.append(self.allocator, val) catch {};
            } else {
                items[items.len - 1] = val;
            }
            return;
        }
        self.writeVar(num, val);
    }

    fn storeResult(self: *CPU, sv: ?u8, val: u16) void {
        if (sv) |s| self.writeVar(s, val);
    }

    // ---- Fetch helpers ----

    fn fetchByte(self: *CPU) u8 {
        const b = self.mem.readByte(self.pc);
        self.pc += 1;
        return b;
    }

    fn fetchWord(self: *CPU) u16 {
        const w = self.mem.readWord(self.pc);
        self.pc += 2;
        return w;
    }

    fn readOperand(self: *CPU, t: OperandType) u16 {
        return switch (t) {
            .large => self.fetchWord(),
            .small => self.fetchByte(),
            .variable => self.readVar(self.fetchByte()),
            .omitted => 0,
        };
    }

    fn readBranch(self: *CPU) Branch {
        const b1 = self.fetchByte();
        const on_true = (b1 & 0x80) != 0;
        if (b1 & 0x40 != 0) {
            return .{ .on_true = on_true, .offset = @intCast(b1 & 0x3F) };
        }
        const b2 = self.fetchByte();
        const raw: u16 = (@as(u16, b1 & 0x3F) << 8) | b2;
        const off: i16 = if (raw & 0x2000 != 0) @as(i16, @intCast(raw)) - 0x4000 else @intCast(raw);
        return .{ .on_true = on_true, .offset = off };
    }

    fn wantsStore(kind: OpKind, opcode: u8) bool {
        return switch (kind) {
            .op2 => switch (opcode) {
                8, 9, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24 => true,
                else => false,
            },
            .op1 => switch (opcode) {
                1, 2, 3, 4, 14, 15 => true,
                else => false,
            },
            .op0 => false,
            .varop => switch (opcode) {
                224, 231, 236, 246, 247 => true, // call, random, call_vs2, read_char, scan_table
                else => false,
            },
        };
    }

    fn wantsBranch(kind: OpKind, opcode: u8) bool {
        return switch (kind) {
            .op2 => switch (opcode) {
                1, 2, 3, 4, 5, 6, 7, 10 => true,
                else => false,
            },
            .op1 => switch (opcode) {
                0, 1, 2 => true,
                else => false,
            },
            .op0 => switch (opcode) {
                5, 6, 13 => true, // save, restore, verify
                else => false,
            },
            .varop => false,
        };
    }

    fn wantsText(kind: OpKind, opcode: u8) bool {
        return kind == .op0 and (opcode == 2 or opcode == 3);
    }

    fn step(self: *CPU) !void {
        const opening = self.pc;
        const opbyte = self.fetchByte();
        var operand_buf: [8]u16 = undefined;
        var noperands: usize = 0;
        var opcode: u8 = undefined;
        var kind: OpKind = undefined;

        if (opbyte & 0xC0 == 0xC0) {
            const raw = opbyte & 0x1F;
            kind = if (opbyte & 0x20 == 0) .op2 else .varop;
            // 2OP-via-variable-form shares the long form's 1-31 numbering,
            // but VAR-form opcodes are conventionally numbered 224-255
            // (i.e. the raw 5-bit field plus 224) — match execVar/
            // wantsStore/wantsBranch, which switch on that absolute number.
            opcode = if (kind == .varop) raw + 224 else raw;
            const types_byte = self.fetchByte();
            var shift: i8 = 6;
            while (shift >= 0) : (shift -= 2) {
                const t: OperandType = switch ((types_byte >> @intCast(shift)) & 0x3) {
                    0 => .large,
                    1 => .small,
                    2 => .variable,
                    else => .omitted,
                };
                if (t == .omitted) break;
                operand_buf[noperands] = self.readOperand(t);
                noperands += 1;
            }
        } else if (opbyte & 0x80 == 0x80) {
            opcode = opbyte & 0x0F;
            const t: OperandType = switch ((opbyte >> 4) & 0x3) {
                0 => .large,
                1 => .small,
                2 => .variable,
                else => .omitted,
            };
            if (t == .omitted) {
                kind = .op0;
            } else {
                kind = .op1;
                operand_buf[noperands] = self.readOperand(t);
                noperands += 1;
            }
        } else {
            opcode = opbyte & 0x1F;
            kind = .op2;
            const t1: OperandType = if (opbyte & 0x40 != 0) .variable else .small;
            const t2: OperandType = if (opbyte & 0x20 != 0) .variable else .small;
            operand_buf[0] = self.readOperand(t1);
            operand_buf[1] = self.readOperand(t2);
            noperands = 2;
        }

        var store_var: ?u8 = null;
        if (wantsStore(kind, opcode)) store_var = self.fetchByte();

        var branch: ?Branch = null;
        if (wantsBranch(kind, opcode)) branch = self.readBranch();

        var literal: ?[]u8 = null;
        if (wantsText(kind, opcode)) {
            const d = try text.decode(&self.mem, self.allocator, self.pc, self.header.abbreviations_addr);
            self.pc = d.end;
            literal = d.text;
        }
        defer if (literal) |l| self.allocator.free(l);

        if (debug_trace) std.debug.print("pc={x} opbyte={x} kind={t} opcode={d} nops={d}\n", .{ opening, opbyte, kind, opcode, noperands });

        try self.dispatch(kind, opcode, operand_buf[0..noperands], store_var, branch, literal);
    }

    fn doBranch(self: *CPU, br: ?Branch, cond: bool) void {
        const b = br orelse return;
        if (cond != b.on_true) return;
        if (b.offset == 0) {
            self.doReturn(0);
        } else if (b.offset == 1) {
            self.doReturn(1);
        } else {
            self.pc = @intCast(@as(i64, self.pc) + b.offset - 2);
        }
    }

    fn doReturn(self: *CPU, val: u16) void {
        const frame = self.frames.pop() orelse {
            self.running = false;
            return;
        };
        self.value_stack.shrinkRetainingCapacity(frame.stack_base);
        if (self.frames.items.len == 0) {
            // Popped the synthetic outermost frame: the "main routine"
            // itself returned, which normally shouldn't happen (games
            // end via `quit`), but treat it as termination rather than
            // resuming at a bogus PC.
            self.running = false;
            return;
        }
        self.pc = frame.return_pc;
        self.storeResult(frame.store_var, val);
    }

    fn callRoutine(self: *CPU, packed_addr: u16, args: []const u16, store_var: ?u8) !void {
        if (packed_addr == 0) {
            self.storeResult(store_var, 0);
            return;
        }
        const addr = self.mem.unpackAddr(packed_addr);
        const num_locals = self.mem.readByte(addr);
        var frame = Frame{
            .num_locals = num_locals,
            .return_pc = self.pc,
            .store_var = store_var,
            .stack_base = self.value_stack.items.len,
            .num_args = @intCast(@min(args.len, 255)),
        };
        var raddr: u32 = addr + 1;
        var i: usize = 0;
        while (i < num_locals) : (i += 1) {
            var v: u16 = 0;
            if (self.header.version <= 4) {
                v = self.mem.readWord(raddr);
                raddr += 2;
            }
            if (i < args.len) v = args[i];
            frame.locals[i] = v;
        }
        try self.frames.append(self.allocator, frame);
        self.pc = raddr;
    }

    // ---- Save/restore (ad-hoc format, see module doc) ----

    fn doSave(self: *CPU) bool {
        var file = std.Io.Dir.cwd().createFile(self.io, "syzigy.sav", .{}) catch return false;
        defer file.close(self.io);
        var buf: [4096]u8 = undefined;
        var fw = file.writer(self.io, &buf);
        const w = &fw.interface;
        writeIntLE(w, u32, self.pc) catch return false;
        writeIntLE(w, u32, @intCast(self.header.static_mem_base)) catch return false;
        w.writeAll(self.mem.bytes[0..self.header.static_mem_base]) catch return false;
        writeIntLE(w, u32, @intCast(self.value_stack.items.len)) catch return false;
        for (self.value_stack.items) |v| writeIntLE(w, u16, v) catch return false;
        writeIntLE(w, u32, @intCast(self.frames.items.len)) catch return false;
        for (self.frames.items) |f| {
            for (f.locals) |l| writeIntLE(w, u16, l) catch return false;
            writeIntLE(w, u8, f.num_locals) catch return false;
            writeIntLE(w, u32, f.return_pc) catch return false;
            writeIntLE(w, u16, if (f.store_var) |s| @as(u16, s) else 0xFFFF) catch return false;
            writeIntLE(w, u32, @intCast(f.stack_base)) catch return false;
            writeIntLE(w, u8, f.num_args) catch return false;
        }
        w.flush() catch return false;
        return true;
    }

    fn doRestore(self: *CPU) bool {
        var file = std.Io.Dir.cwd().openFile(self.io, "syzigy.sav", .{}) catch return false;
        defer file.close(self.io);
        var buf: [4096]u8 = undefined;
        var fr = file.reader(self.io, &buf);
        const r = &fr.interface;
        const pc = readIntLE(r, u32) catch return false;
        const dyn_len = readIntLE(r, u32) catch return false;
        if (dyn_len > self.mem.bytes.len) return false;
        r.readSliceAll(self.mem.bytes[0..dyn_len]) catch return false;
        const stack_len = readIntLE(r, u32) catch return false;
        self.value_stack.clearRetainingCapacity();
        var si: u32 = 0;
        while (si < stack_len) : (si += 1) {
            const v = readIntLE(r, u16) catch return false;
            self.value_stack.append(self.allocator, v) catch return false;
        }
        const nframes = readIntLE(r, u32) catch return false;
        self.frames.clearRetainingCapacity();
        var fi: u32 = 0;
        while (fi < nframes) : (fi += 1) {
            var f = Frame{};
            for (&f.locals) |*l| l.* = readIntLE(r, u16) catch return false;
            f.num_locals = readIntLE(r, u8) catch return false;
            f.return_pc = readIntLE(r, u32) catch return false;
            const sv = readIntLE(r, u16) catch return false;
            f.store_var = if (sv == 0xFFFF) null else @intCast(sv);
            f.stack_base = readIntLE(r, u32) catch return false;
            f.num_args = readIntLE(r, u8) catch return false;
            self.frames.append(self.allocator, f) catch return false;
        }
        self.pc = pc;
        return true;
    }

    fn doRestart(self: *CPU) void {
        @memcpy(self.mem.bytes, self.orig_bytes);
        self.value_stack.clearRetainingCapacity();
        self.frames.clearRetainingCapacity();
        self.frames.append(self.allocator, .{ .num_locals = 0, .return_pc = 0, .store_var = null, .stack_base = 0, .num_args = 0 }) catch {};
        self.pc = self.header.initial_pc;
    }

    // ---- sread / show_status helpers ----

    fn doRead(self: *CPU, text_buf: u16, parse_buf: u16) !void {
        const max_len = self.mem.readByte(text_buf);
        var tmp: [256]u8 = undefined;
        const cap = @min(max_len, tmp.len);
        const n = self.screen.readLine(tmp[0..cap]);

        var i: usize = 0;
        while (i < n) : (i += 1) self.mem.writeByte(@as(u32, text_buf) + 1 + @as(u32, @intCast(i)), tmp[i]);
        self.mem.writeByte(@as(u32, text_buf) + 1 + @as(u32, @intCast(n)), 0);

        if (parse_buf == 0) return;
        const tokens = try self.dict.tokenize(&self.mem, tmp[0..n], self.allocator);
        defer self.allocator.free(tokens);
        const max_tokens = self.mem.readByte(parse_buf);
        const count: u8 = @intCast(@min(tokens.len, max_tokens));
        self.mem.writeByte(@as(u32, parse_buf) + 1, count);
        var t: usize = 0;
        while (t < count) : (t += 1) {
            const entry = @as(u32, parse_buf) + 2 + @as(u32, @intCast(t)) * 4;
            self.mem.writeWord(entry, tokens[t].dict_addr);
            self.mem.writeByte(entry + 2, @intCast(tokens[t].len));
            self.mem.writeByte(entry + 3, @intCast(tokens[t].start + 1));
        }
    }

    fn doShowStatus(self: *CPU) !void {
        const loc = self.readVar(16);
        const name = if (loc != 0) blk: {
            const sn = self.obj.shortNameAddr(&self.mem, loc);
            break :blk try text.decode(&self.mem, self.allocator, sn.addr, self.header.abbreviations_addr);
        } else null;
        defer if (name) |n| self.allocator.free(n.text);

        var buf: [32]u8 = undefined;
        const is_time = (self.header.flags1 & 0x02) != 0;
        const v1 = signed(self.readVar(17));
        const v2 = signed(self.readVar(18));
        const right = if (is_time)
            std.fmt.bufPrint(&buf, "Time: {d}:{d:0>2}", .{ v1, v2 }) catch "Time"
        else
            std.fmt.bufPrint(&buf, "Score: {d}  Moves: {d}", .{ v1, v2 }) catch "Score";
        self.screen.showStatus(if (name) |n| n.text else "", right);
    }

    // ---- Dispatch ----

    fn dispatch(self: *CPU, kind: OpKind, opcode: u8, ops: []const u16, store_var: ?u8, branch: ?Branch, literal: ?[]const u8) !void {
        switch (kind) {
            .op2 => try self.exec2op(opcode, ops, store_var, branch),
            .op1 => try self.exec1op(opcode, ops, store_var, branch),
            .op0 => try self.exec0op(opcode, store_var, branch, literal),
            .varop => try self.execVar(opcode, ops, store_var),
        }
    }

    fn exec2op(self: *CPU, opcode: u8, ops: []const u16, sv: ?u8, br: ?Branch) !void {
        switch (opcode) {
            1 => { // je
                var cond = false;
                if (ops.len >= 2) {
                    for (ops[1..]) |o| {
                        if (o == ops[0]) {
                            cond = true;
                            break;
                        }
                    }
                }
                self.doBranch(br, cond);
            },
            2 => self.doBranch(br, signed(ops[0]) < signed(ops[1])),
            3 => self.doBranch(br, signed(ops[0]) > signed(ops[1])),
            4 => { // dec_chk
                const varnum: u8 = @truncate(ops[0]);
                const v = signed(self.readVar(varnum)) -% 1;
                self.writeVar(varnum, unsigned(v));
                self.doBranch(br, v < signed(ops[1]));
            },
            5 => { // inc_chk
                const varnum: u8 = @truncate(ops[0]);
                const v = signed(self.readVar(varnum)) +% 1;
                self.writeVar(varnum, unsigned(v));
                self.doBranch(br, v > signed(ops[1]));
            },
            6 => self.doBranch(br, self.obj.parent(&self.mem, ops[0]) == ops[1]),
            7 => self.doBranch(br, (ops[0] & ops[1]) == ops[1]),
            8 => self.storeResult(sv, ops[0] | ops[1]),
            9 => self.storeResult(sv, ops[0] & ops[1]),
            10 => self.doBranch(br, self.obj.testAttr(&self.mem, ops[0], @intCast(ops[1] & 0x1F))),
            11 => self.obj.setAttr(&self.mem, ops[0], @intCast(ops[1] & 0x1F)),
            12 => self.obj.clearAttr(&self.mem, ops[0], @intCast(ops[1] & 0x1F)),
            13 => self.writeVarIndirect(@truncate(ops[0]), ops[1]),
            14 => self.obj.insert(&self.mem, ops[0], ops[1]),
            15 => self.storeResult(sv, self.mem.readWord(@as(u32, ops[0]) + @as(u32, ops[1]) * 2)),
            16 => self.storeResult(sv, self.mem.readByte(@as(u32, ops[0]) + ops[1])),
            17 => self.storeResult(sv, self.obj.getProp(&self.mem, ops[0], @intCast(ops[1]))),
            18 => self.storeResult(sv, self.obj.getPropAddr(&self.mem, ops[0], @intCast(ops[1]))),
            19 => self.storeResult(sv, self.obj.getNextProp(&self.mem, ops[0], @intCast(ops[1]))),
            20 => self.storeResult(sv, unsigned(signed(ops[0]) +% signed(ops[1]))),
            21 => self.storeResult(sv, unsigned(signed(ops[0]) -% signed(ops[1]))),
            22 => self.storeResult(sv, unsigned(signed(ops[0]) *% signed(ops[1]))),
            23 => self.storeResult(sv, unsigned(@divTrunc(signed(ops[0]), signed(ops[1])))),
            24 => self.storeResult(sv, unsigned(@rem(signed(ops[0]), signed(ops[1])))),
            else => {}, // call_2s/call_2n/set_colour/throw (v4+): unsupported, ignored
        }
    }

    fn exec1op(self: *CPU, opcode: u8, ops: []const u16, sv: ?u8, br: ?Branch) !void {
        switch (opcode) {
            0 => self.doBranch(br, ops[0] == 0),
            1 => {
                const v = self.obj.sibling(&self.mem, ops[0]);
                self.storeResult(sv, v);
                self.doBranch(br, v != 0);
            },
            2 => {
                const v = self.obj.child(&self.mem, ops[0]);
                self.storeResult(sv, v);
                self.doBranch(br, v != 0);
            },
            3 => self.storeResult(sv, self.obj.parent(&self.mem, ops[0])),
            4 => self.storeResult(sv, self.obj.getPropLen(&self.mem, ops[0])),
            5 => {
                const varnum: u8 = @truncate(ops[0]);
                self.writeVar(varnum, unsigned(signed(self.readVar(varnum)) +% 1));
            },
            6 => {
                const varnum: u8 = @truncate(ops[0]);
                self.writeVar(varnum, unsigned(signed(self.readVar(varnum)) -% 1));
            },
            7 => {
                const d = try text.decode(&self.mem, self.allocator, ops[0], self.header.abbreviations_addr);
                defer self.allocator.free(d.text);
                self.screen.print(d.text);
            },
            9 => self.obj.unlink(&self.mem, ops[0]),
            10 => {
                const sn = self.obj.shortNameAddr(&self.mem, ops[0]);
                const d = try text.decode(&self.mem, self.allocator, sn.addr, self.header.abbreviations_addr);
                defer self.allocator.free(d.text);
                self.screen.print(d.text);
            },
            11 => self.doReturn(ops[0]),
            12 => self.pc = @intCast(@as(i64, self.pc) + signed(ops[0]) - 2),
            13 => {
                const addr = self.mem.unpackAddr(ops[0]);
                const d = try text.decode(&self.mem, self.allocator, addr, self.header.abbreviations_addr);
                defer self.allocator.free(d.text);
                self.screen.print(d.text);
            },
            14 => self.storeResult(sv, self.readVarIndirect(@truncate(ops[0]))),
            15 => self.storeResult(sv, ~ops[0]),
            else => {}, // call_1s (v4+): unsupported, ignored
        }
    }

    fn exec0op(self: *CPU, opcode: u8, sv: ?u8, br: ?Branch, literal: ?[]const u8) !void {
        _ = sv;
        switch (opcode) {
            0 => self.doReturn(1),
            1 => self.doReturn(0),
            2 => self.screen.print(literal.?),
            3 => {
                self.screen.print(literal.?);
                self.screen.newline();
                self.doReturn(1);
            },
            4 => {},
            5 => self.doBranch(br, self.doSave()),
            6 => self.doBranch(br, self.doRestore()),
            7 => self.doRestart(),
            8 => self.doReturn(self.value_stack.pop() orelse 0),
            9 => _ = self.value_stack.pop(),
            10 => self.running = false,
            11 => self.screen.newline(),
            12 => try self.doShowStatus(),
            13 => self.doBranch(br, true), // verify: assume checksum OK
            else => {},
        }
    }

    fn execVar(self: *CPU, opcode: u8, ops: []const u16, sv: ?u8) !void {
        switch (opcode) {
            224 => try self.callRoutine(ops[0], ops[1..], sv),
            225 => self.mem.writeWord(@as(u32, ops[0]) + @as(u32, ops[1]) * 2, ops[2]),
            226 => self.mem.writeByte(@as(u32, ops[0]) + ops[1], @truncate(ops[2])),
            227 => self.obj.putProp(&self.mem, ops[0], @intCast(ops[1]), ops[2]),
            228 => try self.doRead(ops[0], if (ops.len > 1) ops[1] else 0),
            229 => self.screen.printChar(@truncate(ops[0])),
            230 => self.screen.printNum(signed(ops[0])),
            231 => { // random
                const n = signed(ops[0]);
                if (n > 0) {
                    const v = self.rng.random().intRangeAtMost(i16, 1, n);
                    self.storeResult(sv, unsigned(v));
                } else if (n < 0) {
                    self.rng = std.Random.DefaultPrng.init(@intCast(-@as(i32, n)));
                    self.storeResult(sv, 0);
                } else {
                    self.rng = std.Random.DefaultPrng.init(randomSeed(self.io));
                    self.storeResult(sv, 0);
                }
            },
            232 => self.value_stack.append(self.allocator, ops[0]) catch {},
            233 => {
                const v = self.value_stack.pop() orelse 0;
                self.writeVarIndirect(@truncate(if (ops.len > 0) ops[0] else 0), v);
            },
            246 => self.storeResult(sv, self.screen.readChar()), // read_char
            236, 247 => self.storeResult(sv, 0), // call_vs2/scan_table (v4+): unimplemented, but must still store *something*
            234, 235, 237, 238, 239, 240, 241, 242, 243, 244, 245 => {}, // screen/stream ops: no-op stubs
            else => {}, // call_vn/call_vn2/tokenise/encode_text/copy_table/print_table/check_arg_count (v5+)
        }
    }
};
