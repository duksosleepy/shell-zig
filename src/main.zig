const std = @import("std");

fn find_on_path(alloc: std.mem.Allocator, name: []const u8) !?[]const u8 {

    const path = std.posix.getenv("PATH") orelse "";

    var iter = std.mem.tokenizeScalar(u8, path, ':');

    while (iter.next()) |dirname| {

        const joined = try std.fs.path.join(alloc, &[_][]const u8{ dirname, name });

        if (std.fs.cwd().access(joined, std.fs.File.OpenFlags{})) {

            return joined;

        } else |_| {} // XXX probably nicer syntax for this?

        alloc.free(joined);

    }

    return null;

}

pub fn main() !void {

    const stdout = std.io.getStdOut().writer();

    const stdin = std.io.getStdIn().reader();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const alloc = gpa.allocator();

    var buffer: [1024]u8 = undefined;

    while (true) {

        try stdout.print("$ ", .{});

        const user_input_or_err = stdin.readUntilDelimiter(&buffer, '\n');

        if (user_input_or_err == error.EndOfStream) {

            try stdout.print("\n", .{});

            break;

        }

        const user_input = try user_input_or_err;

        var it = std.mem.splitScalar(u8, user_input, ' ');

        const cmd = it.first();

        const rest = it.rest();

        if (std.mem.eql(u8, cmd, "exit")) {

            var exit_code: u8 = 0;

            // bash prints an error and exits with 255 if the arg is not

            // an int, no matter how many arguments.

            // zsh prints an error and refuses to exit if there is more than

            // one arg, but exits with 0 if the one arg is not an int.

            // This just always exits with 0 if the number conversion fails.

            if (rest.len > 0)

                exit_code = std.fmt.parseInt(u8, rest, 10) catch 0;

            std.process.exit(exit_code);

        }

        if (std.mem.eql(u8, cmd, "echo")) {

            try stdout.print("{s}\n", .{rest});

            continue;

        }

        if (std.mem.eql(u8, cmd, "type")) {

            if (std.mem.eql(u8, rest, "exit") or

                std.mem.eql(u8, rest, "echo") or


                std.mem.eql(u8, rest, "type"))

            {

                try stdout.print("{s} is a shell builtin\n", .{rest});

            } else {

                const path = try find_on_path(alloc, rest);

                if (path) |p| {

                    defer alloc.free(p);

                    try stdout.print("{s} is {s}\n", .{ rest, p });

                } else {

                    try stdout.print("{s}: not found\n", .{rest});

                }

            }

            continue;

        }

        // TODO: Handle user input

        try stdout.print("{s}: not found\n", .{cmd});

    }

}
