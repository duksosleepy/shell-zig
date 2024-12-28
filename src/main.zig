const std = @import("std");

pub fn main() !void {

    // Uncomment this block to pass the first stage

    const stdout = std.io.getStdOut().writer();

    try stdout.print("$ ", .{});

    const stdin = std.io.getStdIn().reader();

    var buffer: [1024]u8 = undefined;

    const user_input = try stdin.readUntilDelimiter(&buffer, '\n');

    // TODO: Handle user input

    _ = user_input;

    var it = std.mem.split(u8, user_input, " ");

    const command = it.next().?;

    stdout.print("{s}: command not found\n", .{command}) catch {};

}
