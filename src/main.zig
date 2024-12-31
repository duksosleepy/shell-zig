const std = @import("std");

const mem = std.mem;

const ArrayList = std.ArrayList;

const CommandFn = *const fn ([]const u8, std.fs.File.Writer) anyerror!void;

const Command = struct {

    name: []const u8,

    handler: CommandFn,

};

fn check_known_command(command: []const u8) ?*const Command {

    for (&commands) |*cmd| {

        if (mem.eql(u8, cmd.name, command)) return cmd;

    }

    return null;

}

fn echo_handler(args: []const u8, stdout: std.fs.File.Writer) !void {

    try stdout.print("{s}\n", .{args});

}

fn exit_handler(args: []const u8, stdout: std.fs.File.Writer) !void {

    _ = stdout;

    const exit_code: u8 = if (args.len > 0) std.fmt.parseInt(u8, args, 10) catch 0 else 0;

    std.process.exit(exit_code);

}

const CommandLocation = struct {

    found: bool,

    path: ?[]const u8,

};

// User must deinit the returned arraylist

fn get_env_path(allocator: std.mem.Allocator) !ArrayList([]const u8) {

    var locations = ArrayList([]const u8).init(allocator);

    var env = try std.process.getEnvMap(allocator);

    defer env.deinit();

    if (env.get("PATH")) |path_env| {

        var it = mem.tokenizeScalar(u8, path_env, ':');

        while (it.next()) |path| {

            const owned_path = try allocator.dupe(u8, path);

            try locations.append(owned_path);

        }

    }

    return locations;

}

// could return an optional error of potential issues along with bool

fn command_in_path(command_name: []const u8) !CommandLocation {

    // Validate input

    if (command_name.len == 0) return error.EmptyCommandName;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const allocator = gpa.allocator();

    const env_path = get_env_path(allocator) catch |err| {

        std.debug.print("Failed to get PATH: {}\n", .{err});

        return error.EnvPathError;

    };

    defer env_path.deinit();

    for (env_path.items) |path| {

        // skip relative paths

        if (!std.fs.path.isAbsolute(path)) continue;

        if (!std.fs.path.isAbsolute(path)) {

            std.debug.print("> [warning] skipping relative path: {s}\n", .{path});

            continue;

        }

        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| {

            if (err == error.FileNotFound) continue;

            std.debug.print("> [error] cannot open directory={s}, err={}\n", .{ path, err });

            continue;

        };

        defer dir.close();

        var walker = try dir.walk(allocator);

        defer walker.deinit();

        while (try walker.next()) |entry| {

            if (mem.eql(u8, entry.basename, command_name)) return CommandLocation{ .path = path, .found = true };

        }

    }

    return CommandLocation{ .path = null, .found = false };

}

fn type_handler(args: []const u8, stdout: std.fs.File.Writer) !void {

    var it = mem.tokenizeScalar(u8, args, ' ');

    // Change to a while loop to check for every arg

    if (it.next()) |arg| {

        for (commands) |builtin_cmd| {

            if (mem.eql(u8, arg, builtin_cmd.name)) {

                try stdout.print("{s} is a shell builtin\n", .{arg});

                return;

            }

        }

        const result = try command_in_path(arg);

        if (result.found) {

            try stdout.print("{s} is {?s}/{s}\n", .{ arg, result.path, arg });

            return;

        }

        try stdout.print("{s}: not found\n", .{arg});

    }

}

fn pwd_handler(args: []const u8, stdout: std.fs.File.Writer) !void {

    _ = args;

    var buffer: [std.fs.max_path_bytes]u8 = undefined;

    const path = std.fs.cwd().realpath(".", &buffer);

    // obv no errors are checked here

    try stdout.print("{!s}\n", .{path});

}

fn cd_handler(args: []const u8, stdout: std.fs.File.Writer) !void {

    // idc about best practices mem bullshit fk u future me :D

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const allocator = gpa.allocator();

    var first_path_arg = mem.tokenizeScalar(u8, args, ' ');

    if (first_path_arg.next()) |new_path| {

        var stack = std.ArrayList([]const u8).init(allocator);

        var is_relative_path: bool = false;

        if (new_path[0] != std.fs.path.sep) is_relative_path = true;

        if (is_relative_path) {

            // Will add the current path to the stack as context

            const cur_path = try std.fs.cwd().realpathAlloc(allocator, ".");

            var cur_it = mem.tokenizeScalar(u8, cur_path, std.fs.path.sep);

            // load the current path seperated into stack

            while (cur_it.next()) |cur| {

                try stack.append(cur);

            }

        }

        // worst name in the world

        var paths_it = mem.tokenizeScalar(u8, new_path, std.fs.path.sep);

        while (paths_it.next()) |loc| {

            if (mem.eql(u8, loc, ".")) continue;

            if (mem.eql(u8, loc, "..")) {

                _ = stack.pop();

                continue;

            }

            try stack.append(loc);

        }

        // rejoins paths into single string, always includes sep at beg which isn't ideal

        const resulting_path = try mem.join(allocator, std.fs.path.sep_str, stack.items);

        const res_with_sep = try std.fmt.allocPrint(allocator, "{s}{s}", .{ std.fs.path.sep_str, resulting_path });

        std.posix.chdir(res_with_sep) catch |err| switch (err) {

            error.AccessDenied => {

                try stdout.print("Access Denied to directory\n", .{});

            },

            error.FileSystem => {

                try stdout.print("File system error\n", .{});

            },

            error.SymLinkLoop => {

                try stdout.print("A symlink loop occured\n", .{});

            },

            error.NameTooLong => {

                try stdout.print("The name was too lone\n", .{});

            },

            error.FileNotFound => {

                try stdout.print("cd: {s}: No such file or directory\n", .{res_with_sep});

            },

            error.NotDir => {

                try stdout.print("Path was not a directory\n", .{});

            },

            error.BadPathName => {

                try stdout.print("Bad Path Name\n", .{});

            },

            else => {

                try stdout.print("An error occured\n", .{});

            },

        };

    }

}

fn execute_command(command: []const u8, args: []const u8, allocator: mem.Allocator) !void {

    // needs to consider path too?

    if (args.len == 0) {

        var child = std.process.Child.init(&[_][]const u8{command}, allocator);

        _ = try child.spawnAndWait();

        return;

    }

    var child = std.process.Child.init(&[_][]const u8{ command, args }, allocator);

    _ = try child.spawnAndWait();

}

const commands = [_]Command{

    .{ .name = "echo", .handler = echo_handler },

    .{ .name = "exit", .handler = exit_handler },

    .{ .name = "type", .handler = type_handler },

    .{ .name = "pwd", .handler = pwd_handler },

    .{ .name = "cd", .handler = cd_handler },

};

pub fn main() !void {

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    const stdin = std.io.getStdIn().reader();

    var buffer: [1024]u8 = undefined;

    repl: while (true) {

        try stdout.print("$ ", .{});

        const user_input = try stdin.readUntilDelimiter(&buffer, '\n');

        var it = mem.tokenizeScalar(u8, user_input, ' ');

        if (it.next()) |command| {

            if (check_known_command(command)) |known_cmd| {

                var args_buffer: [1024]u8 = undefined;

                var args_len: usize = 0;

                // loop to ``

                while (it.next()) |arg| {

                    if (args_len > 0) {

                        args_buffer[args_len] = ' ';

                        args_len += 1;

                    }

                    @memcpy(args_buffer[args_len..][0..arg.len], arg);

                    args_len += arg.len;

                }

                const args = args_buffer[0..args_len];

                try known_cmd.handler(args, stdout);

                continue :repl;

            } else {

                const command_loc = try command_in_path(command);

                // check if found then path, this is nasty

                if (command_loc.found) {

                    if (command_loc.path) |path| {

                        _ = path;

                        // RUN THE BINARY HERE!!!!!

                        try execute_command(command, it.rest(), allocator);

                    }

                } else {

                    try stdout.print("{s}: command not found\n", .{command});

                }

            }

        }

    }

}
