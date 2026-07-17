const std = @import("std");

test {
    std.testing.refAllDecls(@import("zmachine/text.zig"));
    _ = @import("zmachine/header.zig");
    _ = @import("zmachine/memory.zig");
    _ = @import("zmachine/object.zig");
    _ = @import("zmachine/dictionary.zig");
}
