const std = @import("std");

fn findBinPath(allocator: std.mem.Allocator, path: ?[]const u8, name: []const u8) !?[]const u8 {

    if (path) |p| {

        var it = std.mem.tokenizeScalar(u8, p, ':');

        while (it.next()) |entry| {

            const bin = try std.fs.path.join(allocator, &.{ entry, name });

            std.fs.accessAbsolute(bin, .{}) catch continue;

            return bin;

        }

    }

    return null;

}

pub fn main() !void {

    const stdout = std.io.getStdOut().writer();

    const stdin = std.io.getStdIn().reader();

    var global_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    var loop_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    const allocator = loop_arena.allocator();

    const env = try std.process.getEnvMap(global_arena.allocator());

    const env_path = env.get("PATH");

    while (true) {

        _ = loop_arena.reset(.retain_capacity);

        try stdout.print("$ ", .{});

        var buffer: [1024]u8 = undefined;

        const user_input = try stdin.readUntilDelimiter(&buffer, '\n');

        const input = std.mem.trim(u8, user_input, &std.ascii.whitespace);

        var args = std.ArrayList([]const u8).init(allocator);

        var it = std.mem.tokenizeScalar(u8, input, ' ');

        while (it.next()) |arg| {

            try args.append(arg);

        }

        if (args.items.len > 0) {

            const cmd = args.items[0];

            if (std.mem.eql(u8, cmd, "exit")) {

                var code: u8 = 0;

                if (args.items.len > 1) code = try std.fmt.parseInt(u8, args.items[1], 10);

                std.process.exit(code);

            } else if (std.mem.eql(u8, cmd, "echo")) {

                const slice = args.items[1..];

                for (slice, 0..) |arg, i| {

                    try stdout.print("{s}", .{arg});

                    if (i != slice.len - 1) try stdout.print(" ", .{});

                }

                try stdout.print("\n", .{});

            } else if (std.mem.eql(u8, cmd, "type")) {

                if (args.items.len > 1) {

                    const arg = args.items[1];

                    if (std.mem.eql(u8, arg, "exit") or

                        std.mem.eql(u8, arg, "echo") or

                        std.mem.eql(u8, arg, "type"))

                    {

                        try stdout.print("{s} is a shell builtin\n", .{arg});

                    } else if (try findBinPath(allocator, env_path, arg)) |bin| {

                        try stdout.print("{s} is {s}\n", .{ arg, bin });

                    } else {

                        try stdout.print("{s}: not found\n", .{arg});

                    }

                }

            } else if (try findBinPath(allocator, env_path, cmd)) |bin| {

                const pid = try std.posix.fork();

                if (pid == 0) {

                    const bin_z = try allocator.dupeZ(u8, bin);

                    var args_z = std.ArrayList(?[*:0]const u8).init(allocator);

                    for (args.items) |arg| {

                        try args_z.append(try allocator.dupeZ(u8, arg));

                    }

                    try args_z.append(null);

                    const envp: [*:null]const ?[*:0]const u8 = &.{null};

                    std.posix.execveZ(bin_z, @ptrCast(args_z.items.ptr), envp) catch {};

                    std.process.exit(1);

                }

                _ = std.posix.waitpid(pid, 0);

            } else {

                try stdout.print("{s}: command not found\n", .{cmd});

            }

        }

    }

}
