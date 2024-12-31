const std = @import("std");
const mem = std.mem;
const util = @import("util.zig");
const Pal = @import("pal.zig").Current;

const debug = true;

fn trace(comptime format: []const u8, args: anytype) void {
    if (debug) {
        const writer = std.io.getStdOut().writer();
        writer.print("  TRACE | ", .{}) catch unreachable;
        writer.print(format, args) catch unreachable;
        writer.print("\n", .{}) catch unreachable;
    }
}

const Target = union(enum) {
    stdout: void,
    stderr: void,
    file: std.fs.File,

    pub fn deinit(self: *const Target) void {
        switch (self.*) {
            .file => |handle| {
                handle.close();
            },
            else => {},
        }
    }

    pub fn fileTruncate(path: []const u8) !Target {
        const file = try std.fs.cwd().createFile(path, .{
            .read = false,
            .truncate = true,
        });

        return Target{ .file = file };
    }

    pub fn fileAppend(path: []const u8) !Target {
        const file = try std.fs.cwd().createFile(path, .{
            .read = false,
            .truncate = false,
        });

        try file.seekFromEnd(0);

        return Target{ .file = file };
    }
};
const Input = struct {
    tokens: []const []const u8,
    out_target: Target,
    err_target: Target,

    pub fn deinit(self: *Input) void {
        self.out_target.deinit();
        self.err_target.deinit();
    }

    pub fn empty() Input {
        return Input{
            .tokens = &[0][]const u8{},
            .out_target = .stdout,
            .err_target = .stderr,
        };
    }
};
const Result = union(enum) {
    exit: u8,
    cont,

    pub fn cont() Result {
        return Result{ .cont = {} };
    }
    pub fn exit(code: u8) Result {
        return Result{ .exit = code };
    }
};
const Context = struct {
    allocator: std.mem.Allocator,
    env_map: std.process.EnvMap,
    out: std.io.BufferedWriter(4096, std.fs.File.Writer).Writer,
    err: std.io.BufferedWriter(4096, std.fs.File.Writer).Writer,
};

const BuiltinSymbolKind = enum { exit, echo, type, pwd, cd };
const BuiltinSymbol = struct { name: []const u8, kind: BuiltinSymbolKind };
const FileSymbol = struct { name: []const u8, path: []const u8 };
const UnknownSymbol = struct { name: []const u8 };
const SymbolType = enum { builtin, file, unknown };
const Symbol = union(SymbolType) {
    builtin: BuiltinSymbol,
    file: FileSymbol,
    unknown: UnknownSymbol,
};

fn nextInput(allocator: std.mem.Allocator, reader: anytype, buffer: []u8) !Input {
    const line = reader.readUntilDelimiterOrEof(buffer, '\n') catch {
        return Input.empty();
    } orelse return Input.empty();

    const trimmed_line = if (Pal.trim_cr)
        mem.trimRight(u8, line, "\r")
    else
        line;

    var token_iter = util.tokenize(allocator, trimmed_line);
    var input = std.ArrayList([]const u8).init(allocator);
    var out_target = Target{ .stdout = {} };
    var err_target = Target{ .stderr = {} };
    defer input.deinit();

    while (try token_iter.next()) |token| {
        if (mem.eql(u8, token, ">") or mem.eql(u8, token, "1>")) {
            if (try token_iter.next()) |file| {
                out_target = try Target.fileTruncate(file);
            }
            break;
        }

        if (mem.eql(u8, token, ">>") or mem.eql(u8, token, "1>>")) {
            if (try token_iter.next()) |file| {
                out_target = try Target.fileAppend(file);
            }
            break;
        }

        if (mem.eql(u8, token, "2>")) {
            if (try token_iter.next()) |file| {
                err_target = try Target.fileTruncate(file);
            }
            break;
        }

        if (mem.eql(u8, token, "2>>")) {
            if (try token_iter.next()) |file| {
                err_target = try Target.fileAppend(file);
            }
            break;
        }

        try input.append(token);
    }

    return Input{
        .tokens = try input.toOwnedSlice(),
        .out_target = out_target,
        .err_target = err_target,
    };
}

fn resolveBuiltinSymbol(symbol_name: []const u8) ?BuiltinSymbol {
    if (mem.eql(u8, symbol_name, "exit")) {
        return BuiltinSymbol{ .name = symbol_name, .kind = .exit };
    } else if (mem.eql(u8, symbol_name, "echo")) {
        return BuiltinSymbol{ .name = symbol_name, .kind = .echo };
    } else if (mem.eql(u8, symbol_name, "type")) {
        return BuiltinSymbol{ .name = symbol_name, .kind = .type };
    } else if (mem.eql(u8, symbol_name, "pwd")) {
        return BuiltinSymbol{ .name = symbol_name, .kind = .pwd };
    } else if (mem.eql(u8, symbol_name, "cd")) {
        return BuiltinSymbol{ .name = symbol_name, .kind = .cd };
    } else {
        return null;
    }
}

fn resolveFileSymbol(ctx: Context, symbol_name: []const u8) ?FileSymbol {
    const path = ctx.env_map.get("PATH") orelse "";
    const cwd = std.fs.cwd();

    var search_dirs = std.mem.split(u8, path, Pal.path_separator);
    while (search_dirs.next()) |dir_path| {
        const dir = cwd.openDir(dir_path, .{ .iterate = true }) catch continue;

        var files = dir.iterate();
        while (files.next() catch null) |entry| {
            if (@as(?std.fs.Dir.Entry, entry)) |file| {
                if (mem.eql(u8, file.name, symbol_name)) {
                    const program_path = util.join_path(ctx.allocator, dir_path, symbol_name);

                    return FileSymbol{ .name = symbol_name, .path = program_path };
                }
            }
        }
    }

    return null;
}

fn resolveSymbol(ctx: Context, symbol_name: []const u8) Symbol {
    if (resolveBuiltinSymbol(symbol_name)) |builtin| {
        return Symbol{ .builtin = builtin };
    }

    if (resolveFileSymbol(ctx, symbol_name)) |file| {
        return Symbol{ .file = file };
    }

    return Symbol{ .unknown = UnknownSymbol{ .name = symbol_name } };
}

fn handleExitCommand(args: []const []const u8) !Result {
    const code = try std.fmt.parseInt(u8, args[0], 10);

    return Result.exit(code);
}

fn handleEchoCommand(ctx: Context, args: []const []const u8) !Result {
    var first = true;

    for (args) |arg| {
        if (!first) try ctx.out.print(" ", .{});
        first = false;

        try ctx.out.print("{s}", .{arg});
    }

    try ctx.out.writeAll("\n");
    return Result.cont();
}

fn handleTypeCommand(ctx: Context, args: []const []const u8) !Result {
    const arg = args[0];
    const symbol = resolveSymbol(ctx, arg);

    const builtin = "{s} is a shell builtin";
    const is_program = "{s} is {s}";
    const not_found = "{s}: not found";
    switch (symbol) {
        .builtin => |builtin_symbol| try ctx.out.print(builtin, .{builtin_symbol.name}),
        .file => |file_symbol| try ctx.out.print(is_program, .{ file_symbol.name, file_symbol.path }),
        .unknown => try ctx.out.print(not_found, .{arg}),
    }

    try ctx.out.writeAll("\n");
    return Result.cont();
}

fn handlePwdCommand(ctx: Context) !Result {
    const cwd = try std.fs.cwd().realpathAlloc(ctx.allocator, ".");

    try ctx.out.print("{s}\n", .{cwd});

    return Result.cont();
}

fn handleCdCommand(ctx: Context, args: []const []const u8) !?Result {
    const arg = args[0];
    const dir_path = if (mem.eql(u8, arg, "~"))
        ctx.env_map.get("HOME") orelse ""
    else
        arg;

    const dir = std.fs.cwd().openDir(dir_path, .{}) catch {
        try ctx.out.print("cd: {s}: No such file or directory\n", .{arg});
        return Result.cont();
    };

    try dir.setAsCwd();
    return Result.cont();
}

fn tryHandleBuiltin(ctx: Context, input: []const []const u8) !?Result {
    if (input.len < 1) {
        return null;
    }

    if (resolveBuiltinSymbol(input[0])) |builtin| {
        const args = input[1..];

        return switch (builtin.kind) {
            .exit => try handleExitCommand(args),
            .echo => try handleEchoCommand(ctx, args),
            .type => try handleTypeCommand(ctx, args),
            .pwd => try handlePwdCommand(ctx),
            .cd => try handleCdCommand(ctx, args),
        };
    } else {
        return null;
    }
}

fn tryHandleRunProcess(ctx: Context, input: []const []const u8) !?Result {
    if (input.len < 1) {
        return null;
    }

    if (resolveFileSymbol(ctx, input[0])) |file| {
        var argv = std.ArrayList([]const u8).init(ctx.allocator);
        defer argv.deinit();

        try argv.append(file.path);
        try argv.appendSlice(input[1..]);

        var proc = std.process.Child.init(argv.items, ctx.allocator);
        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Pipe;

        try proc.spawn();
        try util.forward(proc.stderr.?, ctx.err);
        try util.forward(proc.stdout.?, ctx.out);
        _ = try proc.wait();

        return Result.cont();
    } else {
        return null;
    }
}

fn handleUnknown(ctx: Context, input: []const []const u8) !Result {
    const cmd = if (input.len > 0) input[0] else "";

    try ctx.out.print("{s}: command not found\n", .{cmd});
    return Result.cont();
}

fn handleInput(ctx: Context, input: []const []const u8) !Result {
    if (try tryHandleBuiltin(ctx, input)) |result| {
        return result;
    } else if (try tryHandleRunProcess(ctx, input)) |result| {
        return result;
    } else {
        return try handleUnknown(ctx, input);
    }
}

fn createWriter(target: Target) std.io.BufferedWriter(4096, std.fs.File.Writer) {
    return switch (target) {
        .stdout => std.io.bufferedWriter(std.io.getStdOut().writer()),
        .stderr => std.io.bufferedWriter(std.io.getStdErr().writer()),
        .file => |file| std.io.bufferedWriter(file.writer()),
    };
}

pub fn main() !u8 {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) std.testing.expect(false) catch @panic("TEST FAIL");
    }

    var env_map = try std.process.getEnvMap(gpa.allocator());
    defer env_map.deinit();

    var buffer: [4096]u8 = undefined;

    while (true) {
        try stdout.writeAll("$ ");

        var arena = std.heap.ArenaAllocator.init(gpa.allocator());
        defer arena.deinit();

        @memset(&buffer, 0);
        var input = try nextInput(arena.allocator(), stdin, &buffer);
        defer input.deinit();

        var out = createWriter(input.out_target);
        var err = createWriter(input.err_target);

        const ctx = Context{
            .allocator = arena.allocator(),
            .env_map = env_map,
            .out = out.writer(),
            .err = err.writer(),
        };

        const result = try handleInput(ctx, input.tokens);
        try out.flush();
        try err.flush();

        switch (result) {
            .cont => {},
            .exit => |code| return code,
        }
    }
}
