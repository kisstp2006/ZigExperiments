const std = @import("std");

const GettingInputTerminal = @import("GettingInputTerminal");

pub fn main(init: std.process.Init) !void {
    // "Juicy Main": a ready-made Io implementation is handed to us.
    const io = init.io;

    // On Windows, make sure the terminal treats ANSI escape codes as such.
    // This fails with error.NotTerminalDevice when output is redirected,
    // which is fine since clearing the screen only matters on a terminal.
    std.Io.File.stdout().enableAnsiEscapeCodes(io) catch {};

    // Clear the console: erase the whole screen and move the cursor home.
    try std.Io.File.stdout().writeStreamingAll(io, "\x1b[2J\x1b[H");

    // Type out the prompt.
    try std.Io.File.stdout().writeStreamingAll(io, "Please enter your name: ");

    // Read one line of input, including the trailing newline.
    var stdin_buffer: [256]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &stdin_buffer);
    const line = try stdin.interface.takeDelimiterInclusive('\n');

    // Trim the trailing "\r\n" (Windows) or "\n".
    const name = std.mem.trim(u8, line, "\r\n");

    // If only Enter was pressed, say so.
    if (name.len == 0) {
        try std.Io.File.stdout().writeStreamingAll(io, "No input received.\n");
        return;
    }

    const bestname = "TIGames";

    // Slices cannot be compared with ==; use std.mem.eql instead.
    if (std.mem.eql(u8, name, bestname)) {
        try std.Io.File.stdout().writeStreamingAll(io, "You are the best!\n");
    }

    // Print the greeting through the imported module.
    var stdout_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    try GettingInputTerminal.printGreeting(&stdout.interface, name);
    try stdout.flush();
}
