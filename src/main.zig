const std = @import("std");

const io = std.io;

const mem = std.mem;

const process = std.process;

pub fn main() !void {

    const stdout = io.getStdOut().writer();

    const stdin = io.getStdIn().reader();

    while (true) {

        try stdout.print("$ ", .{});

        var buffer: [1024]u8 = undefined;

        const user_input = try stdin.readUntilDelimiter(&buffer, '\n');

        var commands = mem.splitSequence(u8, user_input, " ");

        const command = commands.first();

        const args = commands.rest();

        if (mem.eql(u8, command, "exit")) {

            process.exit(args[0] - '0'); //example '5'(ASCII value of 53) - '0'(ASCII value of 48) = 5

        } else if (mem.eql(u8, command, "echo")) {

            _ = try stdout.write(args);

            _ = try stdout.write("\n");

        } else {

            try stdout.print("{s}: command not found\n", .{user_input});

        }

    }

}
