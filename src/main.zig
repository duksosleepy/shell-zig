const std = @import("std");

const ShellState = struct {

    should_exit: bool = false,

    exit_code: u8 = 0,

    executables: std.StringHashMap(Executable),

    env_path: []const u8,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ShellState {

        return .{

            .should_exit = false,

            .exit_code = 0,

            .env_path = "",

            .executables = std.StringHashMap(Executable).init(allocator),

            .allocator = allocator,

        };

    }

    pub fn deinit(self: *ShellState) void {

        var it = self.executables.iterator();

        while (it.next()) |entry| {

            entry.value_ptr.deinit();

        }

        self.executables.deinit();

    }

};

const Command = struct {

    name: []const u8,

    handler: *const fn (args: []const u8, writer: std.fs.File.Writer, state: *ShellState) anyerror!void,

};

const echo_command = Command{

    .name = "echo",

    .handler = struct {

        fn handler(args: []const u8, writer: std.fs.File.Writer, state: *ShellState) anyerror!void {

            var parsed_args = try parseQuotedArgs(state.allocator, args);

            defer {

                // for (parsed_args.items) |item| {

                //     state.allocator.free(item);

                // }

                parsed_args.deinit();

            }

            // std.debug.print("Parsed arguments:\n", .{});

            // for (parsed_args.items, 0..) |arg, i| {

            //     std.debug.print("  arg[{d}]: '{s}'\n", .{ i, arg });

            // }

            for (parsed_args.items, 0..) |arg, i| {

                if (i > 0) try writer.print(" ", .{});

                try writer.print("{s}", .{arg});

            }

            try writer.print("\n", .{});

        }

    }.handler,

};

fn parseQuotedArgs(allocator: std.mem.Allocator, args: []const u8) !std.ArrayList([]const u8) {

    var result = std.ArrayList([]const u8).init(allocator);

    errdefer result.deinit();

    if (args.len == 0) return result;

    var current_arg = std.ArrayList(u8).init(allocator);

    defer current_arg.deinit();

    var arg_index: usize = 0;

    while (arg_index < args.len) {

        // Skip spaces between arguments

        while (arg_index < args.len and args[arg_index] == ' ') {

            // We hit a space, so if we have an argument, add it

            if (current_arg.items.len > 0) {

                try result.append(try allocator.dupe(u8, current_arg.items));

                current_arg.clearRetainingCapacity();

            }

            arg_index += 1;

        }

        if (arg_index >= args.len) break;

        // Process the next part of input based on what we find

        if (args[arg_index] == '\'') {

            // Single quotes - everything is literal

            arg_index += 1;

            const quote_end = std.mem.indexOf(u8, args[arg_index..], "'") orelse return error.UnterminatedQuote;

            try current_arg.appendSlice(args[arg_index .. arg_index + quote_end]);

            arg_index += quote_end + 1;

        } else if (args[arg_index] == '"') {

            // Double quotes - only process specific escapes

            arg_index += 1;

            while (arg_index < args.len) {

                if (args[arg_index] == '"') {

                    arg_index += 1;

                    break;

                } else if (args[arg_index] == '\\' and arg_index + 1 < args.len) {

                    if (args[arg_index + 1] == '\\' or args[arg_index + 1] == '"') {

                        try current_arg.append(args[arg_index + 1]);

                        arg_index += 2;

                    } else {

                        try current_arg.append('\\');

                        arg_index += 1;

                    }

                } else {

                    try current_arg.append(args[arg_index]);

                    arg_index += 1;

                }

            }

        } else {

            // Unquoted - process until space or quote

            while (arg_index < args.len) {

                if (args[arg_index] == ' ') break;

                if (args[arg_index] == '\\' and arg_index + 1 < args.len) {

                    arg_index += 1;

                    try current_arg.append(args[arg_index]);

                } else {

                    try current_arg.append(args[arg_index]);

                }

                arg_index += 1;

            }

        }

    }

    // Don't forget to add the last argument if we have one

    if (current_arg.items.len > 0) {

        try result.append(try allocator.dupe(u8, current_arg.items));

    }

    return result;

}

const pwd_command = Command{

    .name = "pwd",

    .handler = struct {

        fn handler(_: []const u8, writer: std.fs.File.Writer, _: *ShellState) anyerror!void {

            var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

            _ = try std.posix.getcwd(&buf);

            try writer.print("{s}\n", .{buf});

        }

    }.handler,

};

const exit_command = Command{

    .name = "exit",

    .handler = struct {

        fn handler(args: []const u8, _: std.fs.File.Writer, state: *ShellState) anyerror!void {

            state.should_exit = true;

            state.exit_code = if (args.len > 0)

                try std.fmt.parseInt(u8, args, 10)

            else

                0;

        }

    }.handler,

};

const type_command = Command{

    .name = "type",

    .handler = struct {

        fn handler(args: []const u8, writer: std.fs.File.Writer, state: *ShellState) anyerror!void {

            if (commands.has(args)) {

                try writer.print("{s} is a shell builtin\n", .{args});

            } else {

                var new_iter = std.mem.splitScalar(u8, state.env_path, ':');

                while (new_iter.next()) |path| {

                    if (try commandInDir(state.allocator, path, args)) |exe| {

                        try writer.print("{s} is {s}/{s}\n", .{ args, exe.path, args });

                        exe.deinit();

                        return;

                    }

                }

                try writer.print("{s}: not found\n", .{args});

            }

        }

    }.handler,

};

const cd_command = Command{

    .name = "cd",

    .handler = struct {

        fn handler(args: []const u8, writer: std.fs.File.Writer, _: *ShellState) anyerror!void {

            var new_dir = args;

            if (args.len == 0 or std.mem.eql(u8, args, "~")) {

                const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;

                new_dir = home;

            } else if (!std.mem.startsWith(u8, args, "/")) {

                var cwdBuf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

                const cwd = try std.posix.getcwd(&cwdBuf);

                if (std.mem.eql(u8, args, "./")) {

                    new_dir = cwd;

                } else if (std.mem.eql(u8, args, "../")) {

                    const last_slash = std.mem.lastIndexOf(u8, cwd, "/").?;

                    new_dir = cwd[0..last_slash];

                }

            }

            std.posix.chdir(new_dir) catch |err| switch (err) {

                error.FileNotFound => {

                    try writer.print("cd: {s}: No such file or directory\n", .{args});

                },

                else => return err,

            };

        }

    }.handler,

};

const commands_array = [_]Command{

    echo_command,

    exit_command,

    type_command,

    pwd_command,

    cd_command,

};

const commands = blk: {

    var commands_map_entries: [commands_array.len]struct { []const u8, Command } = undefined;

    for (commands_array, 0..) |cmd, i| {

        commands_map_entries[i] = .{ cmd.name, cmd };

    }

    break :blk std.StaticStringMap(Command).initComptime(commands_map_entries);

};

pub fn main() !u8 {

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const allocator = gpa.allocator();

    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const arena_allocator = arena.allocator();

    const stdout = std.io.getStdOut().writer();

    var shell_state = ShellState.init(arena_allocator);

    defer shell_state.deinit();

    var env_vars = try std.process.getEnvMap(allocator);

    defer env_vars.deinit();

    const env_path = env_vars.get("PATH") orelse return error.PathNotSet;

    shell_state.env_path = env_path;

    // try stdout.print("Welcome to the meh interactive shell\n", .{});

    // try stdout.print("May your computing be prosperous\n", .{});

    // try stdout.print("------------------------------------\n", .{});

    while (true) {

        try stdout.print("$ ", .{});

        const stdin = std.io.getStdIn().reader();

        var buffer: [1024]u8 = undefined;

        const user_input = stdin.readUntilDelimiter(&buffer, '\n') catch |err| switch (err) {

            error.EndOfStream => break,

            else => return err,

        };


        const ParsingState = enum { normal, in_single_quote, in_double_quote };

        var i: usize = 0;

        var command_buffer = std.ArrayList(u8).init(allocator);

        defer command_buffer.deinit();

        var parsing_state = ParsingState.normal;

        for (user_input) |c| {

            switch (c) {

                ' ' => {

                    if (parsing_state == ParsingState.normal) {

                        break;

                    } else {

                        try command_buffer.append(c);

                    }

                },

                '"' => {

                    switch (parsing_state) {

                        ParsingState.in_double_quote => parsing_state = ParsingState.normal,

                        ParsingState.normal => parsing_state = ParsingState.in_double_quote,

                        else => try command_buffer.append(c),

                    }

                },

                '\'' => {

                    switch (parsing_state) {

                        ParsingState.in_single_quote => parsing_state = ParsingState.normal,

                        ParsingState.normal => parsing_state = ParsingState.in_single_quote,

                        else => try command_buffer.append(c),

                    }

                },

                else => try command_buffer.append(c),

            }

            i += 1;

        }

        const command = command_buffer.items;

        var args: []u8 = "";

        if (i < user_input.len) {

            args = user_input[i + 1 ..];

        }

        //         var inputs = std.mem.splitAny(u8, user_input, " ");

        //         const command = inputs.first();

        //         const args = inputs.rest();

        //

        // std.debug.print("command: {s}\n", .{command});

        // std.debug.print("args: {s}\n", .{args});

        if (commands.get(command)) |cmd| {

            try cmd.handler(args, stdout, &shell_state);

        } else {

            var is_complete = false;

            var new_iter = std.mem.splitScalar(u8, shell_state.env_path, ':');

            while (new_iter.next()) |path| {

                if (try commandInDir(shell_state.allocator, path, command)) |exe| {

                    is_complete = true;

                    const full_path = try std.fs.path.join(allocator, &.{ exe.path, exe.name });

                    defer allocator.free(full_path);

                    var argv = std.ArrayList([]const u8).init(allocator);

                    defer argv.deinit();

                    try argv.append(full_path);

                    var parsed_args = try parseQuotedArgs(shell_state.allocator, args);

                    defer {

                        // Clean up all our allocations when we're done

                        // for (parsed_args.items) |item| {

                        //     shell_state.allocator.free(item);

                        // }

                        parsed_args.deinit();

                    }

                    for (parsed_args.items) |arg| {

                        try argv.append(arg);

                    }

                    // Before executing the command:

                    // std.debug.print("Arguments for {s}:\n", .{command});

                    // for (argv.items, 0..) |arg, i| {

                    //     std.debug.print("  arg[{d}]: '{s}'\n", .{ i, arg });

                    // }

                    var child = std.process.Child.init(argv.items, allocator);

                    _ = try child.spawnAndWait();

                    defer exe.deinit();

                    break;

                }

            }

            if (!is_complete) {

                try stdout.print("{s}: command not found\n", .{user_input});

            }

        }

        if (shell_state.should_exit) {

            return shell_state.exit_code;

        }

    }

    try stdout.print("Exiting shell... Thanks for playing.\n", .{});

    return 1;

}

const Executable = struct {

    name: []const u8,

    path: []const u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *const Executable) void {

        self.allocator.free(self.name);

        self.allocator.free(self.path);

    }

};

fn commandInDir(allocator: std.mem.Allocator, path: []const u8, command: []const u8) !?Executable {

    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| switch (err) {

        error.FileNotFound => return null,

        else => return null,

    };

    defer dir.close();

    var iter = dir.iterate();

    while (try iter.next()) |entry| {

        const name = try allocator.dupe(u8, entry.name);

        errdefer allocator.free(name);

        if (std.mem.eql(u8, name, command)) {

            return Executable{ .name = name, .path = try allocator.dupe(u8, path), .allocator = allocator };

        }

        // If we didn't find a match, free the name we allocated

        allocator.free(name);

    }

    return null;

}

fn processPathDir(allocator: std.mem.Allocator, path: []const u8, state: *ShellState) !void {

    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| switch (err) {

        error.FileNotFound => {

            // std.debug.print("Directory not found: {s}\n", .{path});

            return;

        },

        else => {

            // std.debug.print("Error opening directory {s}: {any}\n", .{ path, err });

            return;

        },

    };

    defer dir.close();

    // Iterate over all entries

    var iter = dir.iterate();

    while (try iter.next()) |entry| {

        // if (entry.kind == .file or entry.kind == .sym_link) {

        // const file_stat = try dir.statFile(entry.name);

        // const is_executable = (file_stat.mode & std.os.linux.S.IXUSR) != 0 or

        //     (file_stat.mode & std.os.linux.S.IXGRP) != 0 or

        //     (file_stat.mode & std.os.linux.S.IXOTH) != 0;

        // if (is_executable) {

        const name = try allocator.dupe(u8, entry.name);

        errdefer allocator.free(name);

        if (!state.executables.contains(name)) {

            try state.executables.put(name, .{

                .name = name,

                .path = try allocator.dupe(u8, path),

                .allocator = allocator,

            });

        } else {

            allocator.free(name);

        }

        // }

        // }

    }

}
