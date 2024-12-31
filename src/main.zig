const std = @import("std");

pub fn main() !void {

    const stdout = std.io.getStdOut().writer();

    const stdin = std.io.getStdIn().reader();

    while (true) {

        try stdout.print("$ ", .{});

        var buffer: [1024]u8 = undefined;

        const user_input = try stdin.readUntilDelimiter(&buffer, '\n');

        var it = std.mem.split(u8, user_input, " ");

        const command = it.next().?;

        if (std.mem.eql(u8, command, "exit")) {

            _ = it.next().?;

            std.process.exit(0);

        } else if (std.mem.eql(u8, command, "echo")) {

            const arg = it.next().?;

            try stdout.print("{s}", .{arg});

            while (it.next()) |a| {

                try stdout.print(" {s}", .{a});

            }

            try stdout.print("\n", .{});

        } else if (std.mem.eql(u8, command, "type")) {

            const arg = it.next().?;

            if (std.mem.eql(u8, arg, "echo")) {

                try stdout.print("echo is a shell builtin\n", .{});

            } else if (std.mem.eql(u8, arg, "exit")) {

                try stdout.print("exit is a shell builtin\n", .{});

            } else if (std.mem.eql(u8, arg, "type")) {

                try stdout.print("type is a shell builtin\n", .{});

            } else if (std.mem.eql(u8, arg, "pwd")) {

                try stdout.print("pwd is a shell builtin\n", .{});

            } else if (std.mem.eql(u8, arg, "cd")) {

                try stdout.print("cd is a shell builtin\n", .{});

            } else {

                const command_path = find_in_path(arg) catch {

                    try stdout.print("{s}: not found\n", .{arg});

                    continue;

                };

                try stdout.print("{s} is {s}\n", .{ arg, command_path });

            }

        } else if (std.mem.eql(u8, command, "pwd")) {

            var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

            const cwd = try std.process.getCwd(&buf);

            try stdout.print("{s}\n", .{cwd});

        } else if (std.mem.eql(u8, command, "cd")) {

            const arg = it.next().?;

            // try std.process.chdir(arg);

            var dir = std.fs.cwd().openDir(arg, .{}) catch {

                try stdout.print("cd: {s}: No such file or directory\n", .{arg});

                continue;

            };

            defer dir.close();

            try dir.setAsCwd();

        } else {

            _ = find_in_path(command) catch {

                try stdout.print("{s}: command not found\n", .{command});

                continue;

            };

            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

            defer arena.deinit();

            const allocator = arena.allocator();

            var arg_list = std.ArrayList([]const u8).init(allocator);

            defer arg_list.deinit();

            try arg_list.append(command);

            while (it.next()) |arg| {

                try arg_list.append(arg);

            }

            var childArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

            defer childArena.deinit();

            const childAllocator = childArena.allocator();

            var child = std.process.Child.init(arg_list.items, childAllocator);

            try child.spawn();

            _ = try child.wait();

        }

    }

}

fn find_in_path(command: []const u8) ![]const u8 {

    const allocator = std.heap.page_allocator;

    const memory = try allocator.alloc(u8, 100);

    defer allocator.free(memory);

    const env = try std.process.getEnvMap(allocator);

    const path = std.process.EnvMap.get(env, "PATH").?;

    var dirs = std.mem.split(u8, path, ":");

    while (dirs.next()) |dir| {

        var files = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch continue;

        defer files.close();

        var fs_iter = files.iterate();

        while (try fs_iter.next()) |f| {

            if (std.mem.eql(u8, f.name, command)) {

                const memory2 = try allocator.alloc(u8, 100);

                defer allocator.free(memory2);

                const joined = try std.fs.path.join(allocator, &[_][]const u8{ dir, f.name });

                return joined;

            }

        }

    }

    return error.Oops;

}
