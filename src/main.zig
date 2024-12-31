const std = @import("std");

fn replace_multiple_spaces(s: []const u8) []u8 {

    var allocator = std.heap.page_allocator;

    var buffer: []u8 = allocator.alloc(u8, s.len) catch unreachable;

    var write_index: usize = 0;

    var in_space: bool = false;

    for (s) |c| {

        if (c == ' ') {

            if (!in_space) {

                buffer[write_index] = c; // Write the first space

                write_index += 1;

                in_space = true; // Set the flag to indicate we're in a space

            }

        } else {

            buffer[write_index] = c; // Write the non-space character

            write_index += 1;

            in_space = false; // Reset the flag

        }

    }

    // Resize the buffer to the actual written size

    return buffer[0..write_index];

}

pub fn main() !void {

    const stdout = std.io.getStdOut().writer();

    const stdin = std.io.getStdIn().reader();

    const allocator = std.heap.page_allocator;

    // Get PATH environment variable

    const path = try std.process.getEnvVarOwned(allocator, "PATH");

    defer allocator.free(path);

    while (true) {

        try stdout.print("$ ", .{});

        var buffer: [1024]u8 = undefined;

        const user_input = try stdin.readUntilDelimiter(&buffer, '\n');

        // Check if the command is "cd"

        if (std.mem.startsWith(u8, user_input, "cd ")) {

            const dir_path = std.mem.trim(u8, user_input[3..], " ");

            if (std.mem.eql(u8, dir_path, "~")) {

                const home = try std.process.getEnvVarOwned(allocator, "HOME");

                defer allocator.free(home);

                if (std.posix.chdir(home)) {} else |_| {

                    try stdout.print("cd: {s}: No such file or directory\n", .{home});

                }

            } else {

                if (std.posix.chdir(dir_path)) {} else |_| {

                    try stdout.print("cd: {s}: No such file or directory\n", .{dir_path});

                }

            }

            continue;

        }

        // Check if the command is "pwd"

        if (std.mem.eql(u8, user_input, "pwd")) {

            var pwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

            const pwd = try std.fs.cwd().realpath(".", &pwd_buf);

            try stdout.print("{s}\n", .{pwd});

            continue;

        }

        // Check if the command is "type"

        if (std.mem.startsWith(u8, user_input, "type ")) {

            const command = std.mem.trim(u8, user_input[5..], " ");

            // First check if it's a builtin

            if (std.mem.eql(u8, command, "echo") or

                std.mem.eql(u8, command, "exit") or

                std.mem.eql(u8, command, "type") or

                std.mem.eql(u8, command, "pwd") or

                std.mem.eql(u8, command, "cd"))

            {

                try stdout.print("{s} is a shell builtin\n", .{command});

                continue;

            }

            // Search in PATH

            var found = false;

            var path_it = std.mem.split(u8, path, ":");

            while (path_it.next()) |dir| {

                var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

                const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, command });

                const file = std.fs.openFileAbsolute(full_path, .{}) catch continue;

                file.close();

                try stdout.print("{s} is {s}\n", .{ command, full_path });

                found = true;

                break;

            }

            if (!found) {

                try stdout.print("{s}: not found\n", .{command});

            }

            continue;

        }

        // Check if the command is "echo"

        if (std.mem.startsWith(u8, user_input, "echo ")) {

            var args = std.ArrayList([]const u8).init(allocator);

            defer args.deinit();

            var result = std.ArrayList(u8).init(allocator);

            defer result.deinit();

            var i: usize = 5; // Skip "echo "

            var in_quotes = false;

            var quote_char: u8 = 0;

            var escaped = false;

            while (i < user_input.len) {

                const c = user_input[i];

                if (escaped) {


                    if (!in_quotes or quote_char == '"') {

                        if (quote_char == '"' and c == ' ') {

                            try result.append('\\');

                        }


                    } else {

                        // In single quotes, preserve the backslash and the character

                        try result.append('\\');

                        try result.append(c);

                    }

                    try result.append(c);

                    escaped = false;

                } else {

                    switch (c) {

                        '\\' => {

                            if (!in_quotes or quote_char == '"') {

                                escaped = true;

                            } else {

                                // In single quotes, treat backslash as literal

                                try result.append(c);

                            }

                        },

                        '\'' => {

                            if (in_quotes and quote_char == '"') {

                                // If we're in double quotes, treat single quote as literal

                                try result.append(c);

                            } else if (!in_quotes) {

                                if (result.items.len > 0) {

                                    try args.append(try allocator.dupe(u8, result.items));

                                    result.clearRetainingCapacity();

                                }

                                in_quotes = true;

                                quote_char = '\'';

                            } else if (quote_char == '\'') {

                                if (result.items.len > 0) {

                                    try args.append(try allocator.dupe(u8, result.items));

                                }

                                result.clearRetainingCapacity();

                                in_quotes = false;

                            }

                        },

                        '"' => {

                            if (in_quotes and quote_char == '\'') {

                                // Inside single quotes, treat double quote as literal

                                try result.append(c);

                            } else if (!in_quotes) {

                                if (result.items.len > 0) {

                                    try args.append(try allocator.dupe(u8, result.items));

                                    result.clearRetainingCapacity();

                                }

                                in_quotes = true;

                                quote_char = '"';

                            } else if (quote_char == '"') {

                                if (result.items.len > 0) {

                                    try args.append(try allocator.dupe(u8, result.items));

                                }

                                result.clearRetainingCapacity();

                                in_quotes = false;

                            }

                        },

                        ' ' => {

                            if (!in_quotes) {

                                if (result.items.len > 0) {

                                    try args.append(try allocator.dupe(u8, result.items));

                                    result.clearRetainingCapacity();

                                }

                            } else {

                                try result.append(c);

                            }

                        },

                        else => try result.append(c),

                    }

                }

                i += 1;

            }

            // Append any remaining content

            if (result.items.len > 0) {

                try args.append(try allocator.dupe(u8, result.items));

            }

            // Print all arguments with a single space between them

            for (args.items, 0..) |arg, index| {

                try stdout.print("{s}", .{arg});

                if (index < args.items.len - 1) {

                    try stdout.print(" ", .{});

                }

            }

            try stdout.print("\n", .{});

            continue;

        }

        // Check if the command is "exit"

        if (std.mem.startsWith(u8, user_input, "exit")) {

            // Get the exit code if provided

            var exit_code: u8 = 0;

            if (user_input.len > 4) {

                const code_str = std.mem.trim(u8, user_input[4..], " ");

                exit_code = std.fmt.parseInt(u8, code_str, 10) catch 0;

            }

            std.process.exit(exit_code);

        } else {

            var args = std.ArrayList([]const u8).init(allocator);

            defer args.deinit();

            var i: usize = 0;

            var start: usize = 0;

            var in_quotes = false;

            var quote_char: u8 = 0;

            var escaped = false;

            while (i < user_input.len) {

                if (escaped) {

                    i += 1;

                    escaped = false;

                    continue;

                }

                switch (user_input[i]) {

                    '\\' => {

                        if (!in_quotes or quote_char == '"') {

                            escaped = true;

                        }

                    },

                    '\'' => {

                        if (!in_quotes) {

                            if (start < i) try args.append(user_input[start..i]);

                            start = i + 1;

                            in_quotes = true;

                            quote_char = '\'';

                        } else if (quote_char == '\'') {

                            try args.append(user_input[start..i]);

                            start = i + 1;

                            in_quotes = false;

                        }

                    },

                    '"' => {

                        if (!in_quotes) {

                            if (start < i) try args.append(user_input[start..i]);

                            start = i + 1;

                            in_quotes = true;

                            quote_char = '"';

                        } else if (quote_char == '"') {

                            try args.append(user_input[start..i]);

                            start = i + 1;

                            in_quotes = false;

                        }

                    },

                    ' ' => {

                        if (!in_quotes and !escaped) {

                            if (start < i) {

                                try args.append(user_input[start..i]);

                            }

                            start = i + 1;

                        }

                    },

                    else => {},

                }

                i += 1;

            }

            // Append any remaining content before searching PATH

            if (start < user_input.len) {

                try args.append(user_input[start..]);

            }

            if (args.items.len == 0) continue;

            // Search in PATH

            var found = false;

            var path_it = std.mem.split(u8, path, ":");

            while (path_it.next()) |dir| {

                var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

                const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, args.items[0] });

                const file = std.fs.openFileAbsolute(full_path, .{}) catch continue;

                file.close();

                // Create a new array for the full command (including the full path)

                var cmd = std.ArrayList([]const u8).init(allocator);

                defer cmd.deinit();

                // Add the full path as the first argument

                try cmd.append(full_path);

                // Add all the remaining arguments

                for (args.items[1..]) |arg| {

                    try cmd.append(arg);

                }

                // Found the executable, try to run it

                var child = std.process.Child.init(cmd.items, allocator);

                child.stdin_behavior = .Inherit;

                child.stdout_behavior = .Inherit;

                child.stderr_behavior = .Inherit;

                try child.spawn();

                _ = try child.wait();

                found = true;

                break;

            }

            if (!found) {

                try stdout.print("{s}: command not found\n", .{args.items[0]});

            }

        }

    }

}
