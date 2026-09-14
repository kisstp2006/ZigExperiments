const std = @import("std");

const print = std.debug.print;

const flush = std.debug.flush;

const GettingInputTerminal = @import("GettingInputTerminal");

pub fn main() !void {
    flush();

    print("Please enter your name: ", .{});
}
