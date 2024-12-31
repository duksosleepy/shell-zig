const std = @import("std");

const Command = enum {
    exit,
    echo,
    type,
    pwd,
    cd,
};

pub fn main() !void {
    // Uncomment this block to pass the first stage
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    var buffer: [1024]u8 = undefined;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    while (true) {
        try stdout.print("$ ", .{});
        const user_input = try stdin.readUntilDelimiter(&buffer, '\n');
        var commands = try parse_command(allocator, user_input);

        const command_maybe = std.meta.stringToEnum(Command, commands.items[0]);
        if (command_maybe) |command| {
            switch (command) {
                .exit => {
                    std.process.exit(0);
                },
                .echo => {
                    const joined = try std.mem.join(allocator, " ", commands.items[1..]);
                    defer allocator.free(joined);
                    try stdout.print("{s}\n", .{joined});
                },
                .type => {
                    const comm = commands.items[1];
                    if (is_builtin(comm)) |_| {
                        try stdout.print("{s} is a shell builtin\n", .{comm});
                    } else {
                        if (try check_path(allocator, comm)) |p| {
                            try stdout.print("{s} is {s}\n", .{ comm, p });
                        } else {
                            try stdout.print("{s}: not found\n", .{comm});
                        }
                    }
                },
                .pwd => {
                    var buff: [1024]u8 = undefined;
                    _ = try std.fs.cwd().realpath(".", &buff);
                    try stdout.print("{s}\n", .{buff});
                },
                .cd => {
                    var path = commands.items[1];
                    if (std.mem.eql(u8, path, "~")) {
                        path = std.posix.getenv("HOME").?;
                    }
                    std.posix.chdir(path) catch {
                        try stdout.print("cd: {s}: No such file or directory\n", .{path});
                    };
                },
            }
        } else {
            if (try check_path(allocator, commands.items[0])) |_| {
                try run_program(&commands, allocator);
            } else {
                try stdout.print("{s}: command not found\n", .{commands.items[0]});
            }
        }
    }
}

fn is_builtin(command: []const u8) ?Command {
    return std.meta.stringToEnum(Command, command);
}

fn check_path(allocator: std.mem.Allocator, command: []const u8) !?[]const u8 {
    const path = std.posix.getenv("PATH").?;
    var itr = std.mem.splitScalar(u8, path, ':');
    while (itr.next()) |pathc| {
        const bin = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ pathc, "/", command });
        std.fs.accessAbsolute(bin, .{}) catch continue;
        return bin;
    }
    return null;
}

fn run_program(commands: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    var child = std.process.Child.init(commands.*.items, allocator);
    _ = try child.spawnAndWait();
}

fn parse_command(allocator: std.mem.Allocator, command: []const u8) !std.ArrayList([]const u8) {
    var tokens = std.mem.splitScalar(u8, command, ' ');
    var commands = std.ArrayList([]const u8).init(allocator);
    try commands.append(try allocator.dupe(u8, tokens.first()));
    const rest = tokens.rest();
    var in_quote = false;
    var in_double_quote = false;

    var currBuffer = std.ArrayList(u8).init(allocator);
    defer currBuffer.deinit();

    for (rest) |token| {
        if (token == ' ' and !in_quote) {
            if (currBuffer.items.len > 0) {
                try commands.append(try currBuffer.toOwnedSlice());
                currBuffer.clearRetainingCapacity();
            }
            continue;
        }
        if (token == '\'') {
            in_quote = !in_quote;
            continue;
        }

        if (token == '"') {
            in_double_quote = !in_double_quote;
            continue;
        }
        try currBuffer.append(token);
    }

    if (currBuffer.items.len > 0) {
        try commands.append(try currBuffer.toOwnedSlice());
    }

    return commands;
}

test "test parse command" {
    const allocator = std.testing.allocator;
    var commands = try parse_command(allocator, "echo 'hello  world' 'hmm'");
    defer {
        for (commands.items) |command| {
            allocator.free(command);
        }
        commands.deinit();
    }

    try std.testing.expectEqualStrings("echo", commands.items[0]);
    try std.testing.expectEqualStrings(
        "hello  world",
        commands.items[1],
    );
    try std.testing.expectEqualStrings("hmm", commands.items[2]);
}
