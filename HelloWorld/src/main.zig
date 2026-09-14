const std = @import("std");

const print = std.debug.print;

const HelloWorld = @import("HelloWorld");

const flush = std.debug.flush;

pub fn main() !void {
    flush();
    // Prints to stderr, unbuffered, ignoring potential errors.
    print("Hello, {s}!\n", .{"World"});

    print("Well , thats all", .{});
}
