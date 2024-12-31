const std = @import("std");

/// Shell implementation

///

/// Provides a basic shell interface with support for:

/// - Built-in commands

/// - External command execution

/// - Environment variables (todo)

/// - Command history (todo)

const Shell = struct {

    stdout: std.fs.File.Writer,

    stdin: std.fs.File.Reader,

    pub fn init() !Shell {

        return Shell{

            .stdout = std.io.getStdOut().writer(),

            .stdin = std.io.getStdIn().reader(),

        };

    }

    pub fn run(self: *Shell) !void {

        while (true) {

            try self.prompt();

            try self.processCommand();

        }

    }

    fn prompt(self: *Shell) !void {

        try self.stdout.print("$ ", .{});

    }

    fn processCommand(self: *Shell) !void {

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

        defer arena.deinit();

        const allocator = arena.allocator();

        const user_input = try self.stdin.readUntilDelimiterAlloc(allocator, '\n', 1024);

        defer allocator.free(user_input);

        if (user_input.len == 0) return;

        var it = std.mem.splitAny(u8, user_input, " ");

        const cmd = it.next().?;

        const args = it.rest();

        if (BuiltinCommands.isBuiltin(cmd)) {

            const builtin = BuiltinCommands.get(cmd).?;

            try builtin.handler(args, self.stdout);

            return;

        }

        const path = std.posix.getenv("PATH").?;

        const full_path = find_in_path(path, cmd);

        if (full_path != null) {

            try handle_exec(full_path.?, args, self.stdout);

            return;

        }

        try self.stdout.print("{s}: command not found\n", .{user_input});

    }

};

// UNUSED!

const Environment = struct {

    vars: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) Environment {

        return Environment{

            .vars = std.StringHashMap([]const u8).init(allocator),

        };

    }

    pub fn get(self: *const Environment, key: []const u8) ?[]const u8 {

        return self.vars.get(key);

    }

    pub fn set(self: *Environment, key: []const u8, value: []const u8) !void {

        try self.vars.put(key, value);

    }

};

const Command = struct {

    kind: Builtin,

    handler: *const fn ([]const u8, std.fs.File.Writer) anyerror!void,

};

const Builtin = enum {

    exit,

    echo,

    type_,

    pwd,

    cd,

    // Map enum values to their string representations

    pub const map = std.StaticStringMap(Builtin).initComptime(.{

        .{ "exit", .exit },

        .{ "echo", .echo },

        .{ "type", .type_ },

        .{ "pwd", .pwd },

        .{ "cd", .cd },

    });

    // Get enum from string

    pub fn fromString(s: []const u8) ?Builtin {

        return map.get(s);

    }

    // Get string from enum

    pub fn toString(self: Builtin) []const u8 {

        return switch (self) {

            .exit => "exit",

            .echo => "echo",

            .type_ => "type",

            .pwd => "pwd",

            .cd => "cd",

        };

    }

};

const BuiltinCommands = struct {

    // Define commands with their handlers at compile time

    const commands = [_]Command{

        .{ .kind = .exit, .handler = &handle_exit },

        .{ .kind = .echo, .handler = &handle_echo },

        .{ .kind = .type_, .handler = &handle_type },

        .{ .kind = .pwd, .handler = &handle_pwd },

        .{ .kind = .cd, .handler = &handle_cd },

    };

    pub fn isBuiltin(string: []const u8) bool {

        return Builtin.map.has(string);

    }

    pub fn get(name: []const u8) ?Command {

        // First convert string to enum

        const builtin = Builtin.fromString(name) orelse return null;

        // Then find matching command

        for (commands) |cmd| {

            if (cmd.kind == builtin) {

                return cmd;

            }

        }

        return null;

    }

};

/// Searches for a command in the system PATH.

///

/// Parameters:

///   - `path`: A string slice representing the PATH environment variable.

///   - `command`: The command name to search for.

///

/// Returns:

///   - An optional slice of bytes representing the full path to the command if found.

fn find_in_path(path: []const u8, command: []const u8) ?[]u8 {

    var iterator = std.mem.splitScalar(u8, path, std.fs.path.delimiter);

    while (iterator.next()) |dir_path| {

        // TODO: This does not handle relative paths

        const dir = std.fs.openDirAbsolute(dir_path, .{}) catch continue;

        const file_status = dir.statFile(command) catch continue;

        if (file_status.mode == 0) {

            continue;

        }

        return std.fs.path.join(std.heap.page_allocator, &[_][]const u8{ dir_path, command }) catch null;

    }

    return null;

}

fn handle_echo(rest: []const u8, stdout: std.fs.File.Writer) !void {

    try stdout.print("{s}\n", .{rest});

}

/// Prints working directory

fn handle_pwd(_: []const u8, stdout: std.fs.File.Writer) !void {

    // allocate a large enough buffer to store the cwd

    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

    // getcwd writes the path of the cwd into buf and returns a slice of buf with the len of cwd

    const cwd = try std.posix.getcwd(&buf);

    // const pwd = std.posix.getenv("PWD").?;

    // print out results

    try stdout.print("{s}\n", .{cwd});

}

fn handle_exit(rest: []const u8, _: std.fs.File.Writer) !void {

    const exit_code = std.fmt.parseInt(u8, std.mem.trim(u8, rest, " "), 10) catch 0;

    std.posix.exit(exit_code);

}

fn handle_cd(rest: []const u8, stdout: std.fs.File.Writer) !void {

    const dest = blk: {

        if (rest.len == 0 or (rest.len == 1 and rest[0] == '~')) {

            const home = std.posix.getenv("HOME") orelse unreachable;

            break :blk home;

        }

        break :blk rest;

    };

    // zig std.posix.chdir handles both absolute and relative paths correctly

    std.posix.chdir(dest) catch try stdout.print("cd: {s}: No such file or directory\n", .{rest});

}

fn handle_type(rest: []const u8, stdout: std.fs.File.Writer) !void {

    if (BuiltinCommands.isBuiltin(rest)) {

        try stdout.print("{s} is a shell builtin\n", .{rest});

        return;

    }

    const path = std.posix.getenv("PATH") orelse unreachable;

    const file_path = find_in_path(path, rest);

    if (file_path != null) { // no single letter commands (0-terminated strings)

        try stdout.print("{s} is {s}\n", .{ rest, file_path.? });

        return;

    }

    try stdout.print("{s}: not found\n", .{rest});

}

fn handle_exec(command: []const u8, args: []const u8, stdout: std.fs.File.Writer) !void {

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    defer arena.deinit();

    const allocator = arena.allocator();

    var argv = std.ArrayList([]const u8).init(allocator);

    try argv.append(command);

    // split args string into individual arguments

    var args_iterator = std.mem.splitScalar(u8, args, ' ');

    while (args_iterator.next()) |arg| {

        if (arg.len > 0) { // Only append non-empty arguments

            try argv.append(arg);

        }

    }

    // Convert ArrayList to slice for ChildProcess

    const argv_slice = try argv.toOwnedSlice();

    // spawn the process

    const result = try std.process.Child.run(.{

        .allocator = allocator,

        .argv = argv_slice,

        .max_output_bytes = 1024 * 1024,

    });

    if (result.stdout.len > 0) {

        try stdout.print("{s}", .{result.stdout});

    }

}

pub fn main() !void {

    var shell = try Shell.init();

    try shell.run();

}

const testing = std.testing;

test "find_in_path finds command" {

    const path = "/usr/bin:/bin"; // Example PATH, adjust as needed for your environment

    const command = "ls"; // Assuming 'ls' exists in one of these directories

    const result = find_in_path(path, command);

    // Check if the result is not null, assuming the command exists in PATH

    try testing.expect(result.?.len > 0);

    // Optional: Check if the result path contains the command name

    try testing.expect(std.mem.indexOf(u8, result.?, command) != null);

}

test "find_in_path command not found" {

    const path = "/usr/bin:/bin"; // Example PATH where 'non_existent_command' does not exist

    const command = "non_existent_command";

    // Expecting the error 'CommandNotFound'

    try testing.expectEqual(null, find_in_path(path, command));

}

test "shell command execution" {

    var shell = try Shell.init();

    defer shell.deinit();

    try testing.expectEqual(try shell.executeCommand("echo hello"), 0);

    // Add more test cases

}
