const std = @import("std");

const print = std.debug.print;

const HelloWorld = @import("HelloWorld");

pub fn main() !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    print("Hello, {s}!\n", .{"World"});

    print("Well , thats all", .{});
}
