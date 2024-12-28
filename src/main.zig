const std = @import("std");

const io = std.io;

pub fn main() !void {

    const stdout = io.getStdOut().writer();

    try stdout.print("$ ", .{});

    const stdin = io.getStdIn().reader();

    var buffer: [1024]u8 = undefined;

    const user_input = try stdin.readUntilDelimiter(&buffer, '\n');

    try stdout.print("{s}: command not found\n", .{user_input});

    while (true) {

        try stdout.print("$ ", .{});

        var buffer: [1024]u8 = undefined;

        const user_input = try stdin.readUntilDelimiter(&buffer, '\n');

        try stdout.print("{s}: command not found\n", .{user_input});
    }

}
