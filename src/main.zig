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
    writer: std.fs.File.Writer,
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

fn nextInput(reader: anytype, buffer: []u8) ?[]const u8 {
    const line = reader.readUntilDelimiterOrEof(buffer, '\n') catch {
        return null;
    };

    if (line) |l| {
        if (Pal.trim_cr) {
            return mem.trimRight(u8, l, "\r");
        } else {
            return l;
        }
    } else {
        return null;
    }
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
    } else if (resolveFileSymbol(ctx, symbol_name)) |file| {
        return Symbol{ .file = file };
    } else {
        return Symbol{ .unknown = UnknownSymbol{ .name = symbol_name } };
    }
}

fn handleExitCommand(args: []const u8) !Result {
    const code_text, _ = util.splitAtNext(args, " ");
    const code = try std.fmt.parseInt(u8, code_text, 10);

    return Result.exit(code);
}

fn handleEchoCommand(ctx: Context, args: []const u8) !Result {
    try ctx.writer.print("{s}\n", .{args});

    return Result.cont();
}

fn handleTypeCommand(ctx: Context, args: []const u8) !Result {
    const type_text, _ = util.splitAtNext(args, " ");
    const symbol = resolveSymbol(ctx, type_text);

    const builtin = "{s} is a shell builtin\n";
    const is_program = "{s} is {s}\n";
    const not_found = "{s}: not found\n";
    switch (symbol) {
        .builtin => |builtin_symbol| try ctx.writer.print(builtin, .{builtin_symbol.name}),
        .file => |file_symbol| try ctx.writer.print(is_program, .{ file_symbol.name, file_symbol.path }),
        .unknown => try ctx.writer.print(not_found, .{type_text}),
    }

    return Result.cont();
}

fn handlePwdCommand(ctx: Context) !Result {
    const cwd = try std.fs.cwd().realpathAlloc(ctx.allocator, ".");

    try ctx.writer.print("{s}\n", .{cwd});

    return Result.cont();
}

fn handleCdCommand(ctx: Context, args: []const u8) !Result {
    const dir_path = if (mem.eql(u8, args, "~"))
        ctx.env_map.get("HOME") orelse ""
    else
        args;

    const dir = std.fs.cwd().openDir(dir_path, .{}) catch {
        try ctx.writer.print("cd: {s}: No such file or directory\n", .{args});
        return Result.cont();
    };

    try dir.setAsCwd();
    return Result.cont();
}

fn tryHandleBuiltin(ctx: Context, input: []const u8) !?Result {
    const cmd, const args = util.splitAtNext(input, " ");

    if (resolveBuiltinSymbol(cmd)) |builtin| {
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

fn tryHandleRunProcess(ctx: Context, input: []const u8) !?Result {
    const run_prefix = "";

    if (!mem.startsWith(u8, input, run_prefix)) {
        return null;
    }

    const cmd, const args = util.splitAtNext(input, " ");
    const process_name = cmd[run_prefix.len..];

    if (resolveFileSymbol(ctx, process_name)) |file| {
        const argv = [_][]const u8{ file.path, args };
        var proc = std.process.Child.init(&argv, ctx.allocator);

        const term = try proc.spawnAndWait();

        return switch (term) {
            .Exited => |code| if (code == 0) Result.cont() else Result.exit(1),
            else => Result.exit(1),
        };
    } else {
        return null;
    }
}

fn handleUnknown(ctx: Context, input: []const u8) !Result {
    const cmd, _ = util.splitAtNext(input, " ");

    try ctx.writer.print("{s}: command not found\n", .{cmd});
    return Result.cont();
}

fn handleInput(ctx: Context, input: []const u8) !Result {
    if (try tryHandleBuiltin(ctx, input)) |result| {
        return result;
    } else if (try tryHandleRunProcess(ctx, input)) |result| {
        return result;
    } else {
        return try handleUnknown(ctx, input);
    }
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

    var ctx = Context{ .allocator = gpa.allocator(), .env_map = env_map, .writer = stdout };
    var buffer: [1024]u8 = undefined;

    while (true) {
        try stdout.print("$ ", .{});

        @memset(&buffer, 0);
        const user_input = nextInput(stdin, &buffer);

        if (user_input) |command| {
            var arena = std.heap.ArenaAllocator.init(gpa.allocator());
            defer arena.deinit();

            ctx.allocator = arena.allocator();

            const result = try handleInput(ctx, command);

            switch (result) {
                .cont => {},
                .exit => |code| return code,
            }
        }
    }
}
