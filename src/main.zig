const std = @import("std");
const Header = @import("zmachine/header.zig").Header;
const Memory = @import("zmachine/memory.zig").Memory;
const Screen = @import("zmachine/screen.zig").Screen;
const CPU = @import("zmachine/cpu.zig").CPU;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_it.deinit();
    _ = arg_it.next(); // program name

    const path = arg_it.next() orelse {
        std.debug.print("usage: syzigy <story-file.z3|.z5>\n", .{});
        return;
    };
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024)) catch |err| {
        std.debug.print("could not read '{s}': {s}\n", .{ path, @errorName(err) });
        return;
    };
    defer allocator.free(bytes);

    const header = Header.parse(bytes) catch |err| {
        std.debug.print("'{s}' does not look like a valid Z-machine story file: {s}\n", .{ path, @errorName(err) });
        return;
    };

    if (header.version > 5) {
        std.debug.print("warning: version {d} story files are only partially supported (this interpreter targets v1-5, primarily v3)\n", .{header.version});
    }

    Header.writeInterpreterInfo(bytes);

    const mem = Memory.init(bytes, header.version);
    var screen = try Screen.init(allocator, io);
    defer screen.deinit();
    var cpu = try CPU.init(allocator, io, mem, header, &screen);
    defer cpu.deinit();

    try cpu.run();
}
