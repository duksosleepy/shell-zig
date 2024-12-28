const std = @import("std");

pub fn main() !void {

    const stdout = std.io.getStdOut().writer();

    const stdin = std.io.getStdIn().reader();

    while (true) {

        try stdout.print("$ ", .{});

        var buffer: [1024]u8 = undefined;

        const user_input = try stdin.readUntilDelimiter(&buffer, '\n');

        var iter = std.mem.splitScalar(u8, user_input, ' ');

        const command = iter.next();

        if (command) |c| {

            if (std.mem.eql(u8, c, "exit")) {
                const exit_code = try std.fmt.parseInt(u8, iter.next() orelse "0", 10);

                std.process.exit(exit_code);

            } else {

                try stdout.print("{s}: command not found\n", .{c});

            }

        } else {

            // Do nothing

        }

    }

}
