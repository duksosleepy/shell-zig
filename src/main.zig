const std = @import("std");

const stdout = std.io.getStdOut().writer();

const stdin = std.io.getStdIn().reader();

const btv = std.mem.bytesToValue;

const buildins = [_]*const [4:0]u8{ "exit", "echo", "type" };

pub fn main() !void {

    try stdout.print("$ ", .{});

    var buffer: [1024]u8 = undefined;

    while (stdin.readUntilDelimiter(&buffer, '\n')) |line| {

        const ret = try handleUserInput(line);

        if (ret == 0) {

            break;

        }

        try stdout.print("$ ", .{});

    } else |err| {

        try stdout.print("Error: {s}\n", .{@errorName(err)});

    }

}

fn handleUserInput(line: []u8) !u8 {

    if (line.len == 0) {

        return 1;

    }

    var tokens = std.mem.splitSequence(u8, line, " ");

    const command = tokens.first();

    const args = tokens.rest();

    switch (btv(u32, command)) {

        btv(u32, "exit") => return 0,

        btv(u32, "echo") => {

            try stdout.print("{s}\n", .{args});

        },

        btv(u32, "type") => {

            try handleTypeBuitin(args);

        },

        else => {

            try stdout.print("{s}: command not found\n", .{line});

        },

    }

    return 1;

}

fn handleTypeBuitin(args: []const u8) !void {

    for (buildins) |buildin| {

        if (std.mem.eql(u8, buildin, args)) {

            try stdout.print("{s} is a shell builtin\n", .{args});

            return;

        }

    }

    try stdout.print("{s}: not found\n", .{args});

}
