//! Minimal terminal screen model. Real Z-machine screen handling (windows,
//! fonts, colours) is elaborate (spec chapter 8); syzigy only implements
//! what v3 games actually rely on: a scrolling main window plus a status
//! line showing location/score-or-time (spec 8.2, opcode show_status).
//!
//! `out_buf`/`in_buf` are heap-allocated (not embedded array fields) so
//! that `std.Io.File.Writer`/`Reader`'s internal buffer slice stays valid
//! even though `Screen` itself is returned by value from `init` (an
//! embedded-array buffer's address would move with the struct and the
//! writer/reader would end up pointing at stale stack memory).

const std = @import("std");

pub const Screen = struct {
    allocator: std.mem.Allocator,
    out_buf: []u8,
    in_buf: []u8,
    out: std.Io.File.Writer,
    in: std.Io.File.Reader,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Screen {
        const out_buf = try allocator.alloc(u8, 4096);
        errdefer allocator.free(out_buf);
        const in_buf = try allocator.alloc(u8, 256);
        errdefer allocator.free(in_buf);
        const stdout = std.Io.File.stdout();
        const stdin = std.Io.File.stdin();
        return .{
            .allocator = allocator,
            .out_buf = out_buf,
            .in_buf = in_buf,
            .out = stdout.writer(io, out_buf),
            .in = stdin.reader(io, in_buf),
        };
    }

    pub fn deinit(self: *Screen) void {
        self.allocator.free(self.out_buf);
        self.allocator.free(self.in_buf);
    }

    pub fn print(self: *Screen, s: []const u8) void {
        self.out.interface.writeAll(s) catch {};
    }

    pub fn printChar(self: *Screen, c: u8) void {
        self.out.interface.writeByte(c) catch {};
    }

    pub fn printNum(self: *Screen, n: i16) void {
        self.out.interface.print("{d}", .{n}) catch {};
    }

    pub fn newline(self: *Screen) void {
        self.out.interface.writeByte('\n') catch {};
    }

    pub fn flush(self: *Screen) void {
        self.out.interface.flush() catch {};
    }

    /// Show a v3-style status line: " Location    Score: N  Moves: N" (or
    /// a time-of-day variant), printed inline above the prompt since we
    /// don't implement a real split-window/terminal-control layer.
    pub fn showStatus(self: *Screen, location: []const u8, right: []const u8) void {
        self.out.interface.print("\n[{s} | {s}]\n", .{ location, right }) catch {};
        self.flush();
    }

    /// Swallow the rest of a `\r\n` (or `\n\r`) pair so the second byte
    /// doesn't leak into the next read as a spurious blank line/keystroke.
    /// Windows consoles send `\r\n` for Enter; consuming only the first
    /// byte left the `\n` buffered for whatever read call came next, which
    /// then fired instantly without waiting for real input.
    ///
    /// Only inspects bytes *already* sitting in the reader's buffer
    /// (`buffered()`/`bufferedLen()`, no I/O) rather than `peekByte()`,
    /// which performs a real (blocking) read when the buffer is empty —
    /// using it here would hang waiting for a keystroke that isn't coming
    /// once the actual terminator pair has already been consumed.
    fn consumeLineEnding(self: *Screen) void {
        if (self.in.interface.bufferedLen() == 0) return;
        const b = self.in.interface.buffered();
        if (b.len > 0 and (b[0] == '\n' or b[0] == '\r')) {
            self.in.interface.toss(1);
        }
    }

    /// Read one line of input, lowercased, truncated to `buf.len` bytes.
    /// Returns the number of bytes written into `buf`.
    pub fn readLine(self: *Screen, buf: []u8) usize {
        self.flush();
        var i: usize = 0;
        while (i < buf.len) {
            const byte = self.in.interface.takeByte() catch break;
            if (byte == '\n' or byte == '\r') break;
            buf[i] = std.ascii.toLower(byte);
            i += 1;
        }
        self.consumeLineEnding();
        return i;
    }

    /// Read a single character (spec VAR:246 `read_char`), lowercased.
    /// Since stdin here is line-buffered rather than raw keystroke input,
    /// the Enter key that submits the character still shows up as a
    /// trailing CR/LF in the stream; that's consumed here too.
    pub fn readChar(self: *Screen) u8 {
        self.flush();
        const byte = self.in.interface.takeByte() catch return 0;
        self.consumeLineEnding();
        return std.ascii.toLower(byte);
    }
};
