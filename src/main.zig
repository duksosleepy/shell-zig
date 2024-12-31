const std = @import("std");

const process = std.process;

const stdout = std.io.getStdOut().writer();

const mem = std.mem;

const fmt = std.fmt;

const fs = std.fs;

const allocator = std.heap.page_allocator;

const BuiltIn = enum {

    echo,

    exit,

    type,

    pwd,

};

const BuiltInHandler = *const fn (args: []const u8) anyerror!void;

var handlers = std.AutoHashMap(BuiltIn, BuiltInHandler).init(allocator);

pub fn main() !void {

    var buffer: [1024]u8 = undefined;

    defer handlers.deinit();

    try handlers.put(.exit, handle_exit);

    try handlers.put(.echo, handle_echo);

    try handlers.put(.type, handle_type);

    try handlers.put(.pwd, handle_pwd);

    while (true) {

        try stdout.print("$ ", .{});

        const stdin = std.io.getStdIn().reader();

        const user_input = try stdin.readUntilDelimiter(&buffer, '\n');

        try handle_command(user_input);

    }

}

fn handle_command(input: []const u8) !void {

    var input_slices = mem.splitScalar(u8, input, ' ');

    const cmd_str = input_slices.first();

    const args = input_slices.rest();

    const builtin = std.meta.stringToEnum(BuiltIn, cmd_str);

    if (builtin) |bi| {

        const handler = handlers.get(bi).?;

        try handler(args);

    } else {

        try handle_default(cmd_str, args);

    }

}

fn handle_echo(args: []const u8) !void {

    try stdout.print("{s}\n", .{args});

}

fn handle_exit(args: []const u8) !void {

    const exit_code = fmt.parseInt(u8, args, 10) catch 0;

    process.exit(exit_code);

}

fn handle_type(args: []const u8) !void {

    const builtin = std.meta.stringToEnum(BuiltIn, args);

    if (builtin) |bi| {

        try stdout.print("{s} is a shell builtin\n", .{@tagName(bi)});

        return;

    }

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const arena_alloc = arena.allocator();

    if (try lookup_command(args, arena_alloc)) |path| {

        try stdout.print("{s} is {s}\n", .{ args, path });

    } else {

        try stdout.print("{s}: not found\n", .{args});

    }

}

fn handle_pwd(_: []const u8) !void {

    const path = try fs.cwd().realpathAlloc(allocator, ".");

    defer allocator.free(path);

    try stdout.print("{s}\n", .{path});

}

fn handle_default(cmd: []const u8, args: []const u8) !void {

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const arena_alloc = arena.allocator();

    const path = try lookup_command(cmd, arena_alloc) orelse {

        try stdout.print("{s}: command not found\n", .{cmd});

        return;

    };

    var argv = std.ArrayList([]const u8).init(arena_alloc);

    try argv.append(path);

    var args_iter = mem.splitScalar(u8, args, ' ');

    while (args_iter.next()) |arg| {

        try argv.append(arg);

    }

    var proc = process.Child.init(argv.items, arena_alloc);

    _ = try proc.spawnAndWait();

}

fn lookup_command(cmd: []const u8, alloc: std.mem.Allocator) !?[]const u8 {

    const path_var = try process.getEnvVarOwned(alloc, "PATH");

    var path_iter = mem.splitScalar(u8, path_var, fs.path.delimiter);

    while (path_iter.next()) |dir_path| {

        const dir = fs.openDirAbsolute(dir_path, .{}) catch continue;

        const file_stat = dir.statFile(cmd) catch continue;

        if (file_stat.mode & std.c.S.IXUSR == 0) {

            continue;

        }

        return try fmt.allocPrint(alloc, "{s}{c}{s}", .{ dir_path, fs.path.sep, cmd });

    }

    return null;

}
