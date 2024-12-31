const std = @import("std");
const mem = std.mem;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const pal = @import("pal.zig").Current;

pub const SplitResult = struct { []const u8, []const u8 };

pub fn splitAtNext(text: []const u8, separator: []const u8) SplitResult {
    const separator_index = mem.indexOf(u8, text, separator);
    if (separator_index) |index| {
        return SplitResult{ text[0..index], text[(index + 1)..] };
    } else {
        return SplitResult{ text, "" };
    }
}

test "splitAtNext [separator in middle]" {
    const token, const remainder = splitAtNext("first second third", " ");

    try expectEqualStrings("first", token);
    try expectEqualStrings("second third", remainder);
}

test "splitAtNext [separator at start]" {
    const token, const remainder = splitAtNext(" first second", " ");

    try expectEqualStrings("", token);
    try expectEqualStrings("first second", remainder);
}

test "splitAtNext [separator at end]" {
    const token, const remainder = splitAtNext("first ", " ");

    try expectEqualStrings("first", token);
    try expectEqualStrings("", remainder);
}

pub const TokenIterator = struct {
    allocator: std.mem.Allocator,
    rest: []const u8,
    single_quote: bool,
    double_quote: bool,

    fn new(allocator: std.mem.Allocator, text: []const u8) TokenIterator {
        return TokenIterator{
            .allocator = allocator,
            .rest = text,
            .single_quote = false,
            .double_quote = false,
        };
    }

    pub fn next(self: *TokenIterator) !?[]const u8 {
        const text = self.rest;

        if (text.len == 0) {
            return null;
        }

        var token = std.ArrayList(u8).init(self.allocator);
        defer token.deinit();

        if (text[0] == '\'') self.single_quote = true;
        if (text[0] == '\"') self.double_quote = true;

        var i: usize = 0;
        var start: usize = 0;

        while (i < text.len) {
            if (self.single_quote) {
                i += 1;
                start += 1;

                while (i < text.len and text[i] != '\'') {
                    try token.append(text[i]);
                    i += 1;
                }

                if (i < text.len) {
                    i += 1;
                    self.single_quote = false;
                }
            } else if (self.double_quote) {
                i += 1;
                start += 1;

                while (i < text.len and text[i] != '\"') {
                    if (text[i] == '\\' and (i + 1) < text.len) {
                        const next_char = text[i + 1];
                        if (next_char == '\\' or next_char == '\"') {
                            i += 1;
                        }
                    }

                    try token.append(text[i]);
                    i += 1;
                }

                if (i < text.len) {
                    i += 1;
                    self.double_quote = false;
                }
            } else if (text[i] == ' ') {
                break;
            } else {
                if (text[i] == '\\') {
                    i += 1;
                }

                try token.append(text[i]);
                i += 1;
            }
        }

        self.rest = if (i < text.len) text[(i + 1)..] else &[0]u8{};
        return try token.toOwnedSlice();
    }
};

pub const NonEmptyTokenIterator = struct {
    iter: TokenIterator,

    fn new(allocator: std.mem.Allocator, text: []const u8) NonEmptyTokenIterator {
        return NonEmptyTokenIterator{ .iter = TokenIterator.new(allocator, text) };
    }

    pub fn next(self: *NonEmptyTokenIterator) !?[]const u8 {
        while (try self.iter.next()) |item| {
            if (item.len > 0) {
                return item;
            }
        }

        return null;
    }
};

pub fn tokenize(allocator: std.mem.Allocator, input: []const u8) NonEmptyTokenIterator {
    return NonEmptyTokenIterator.new(allocator, input);
}

test "tokenize with escaped double quote inside double quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var iter = tokenize(arena.allocator(), "echo \"hello\\\"insidequotes\"script\\\"");

    try expectEqualStrings("echo", (try iter.next()).?);
    try expectEqualStrings("hello\"insidequotesscript\"", (try iter.next()).?);
    try expect(try iter.next() == null);
}

test "tokenize with backslash inside double quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var iter = tokenize(arena.allocator(), "echo \"hello'script'\\\\n'world");

    try expectEqualStrings("echo", (try iter.next()).?);
    try expectEqualStrings("hello'script'\\n'world", (try iter.next()).?);
    try expect(try iter.next() == null);
}

test "tokenize with backslash inside single quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var iter = tokenize(arena.allocator(), "echo 'shell\\\\\\nscript'");

    try expectEqualStrings("echo", (try iter.next()).?);
    try expectEqualStrings("shell\\\\\\nscript", (try iter.next()).?);
    try expect(try iter.next() == null);
}

test "tokenize with escaped whitespace outside quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var iter = tokenize(arena.allocator(), "echo world\\ \\ \\ \\ \\ \\ script");

    try expectEqualStrings("echo", (try iter.next()).?);
    try expectEqualStrings("world      script", (try iter.next()).?);
    try expect(try iter.next() == null);
}

test "tokenize with single quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var iter = tokenize(arena.allocator(), "cat '/tmp/file name' '/tmp/file name with spaces'");

    try expectEqualStrings("cat", (try iter.next()).?);
    try expectEqualStrings("/tmp/file name", (try iter.next()).?);
    try expectEqualStrings("/tmp/file name with spaces", (try iter.next()).?);
    try expect(try iter.next() == null);
}

test "tokenize with double quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var iter = tokenize(arena.allocator(), "cat \"/tmp/file name\" \"/tmp/file name with spaces\"");

    try expectEqualStrings("cat", (try iter.next()).?);
    try expectEqualStrings("/tmp/file name", (try iter.next()).?);
    try expectEqualStrings("/tmp/file name with spaces", (try iter.next()).?);
    try expect(try iter.next() == null);
}

test "tokenize with mixed quotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var iter = tokenize(arena.allocator(), "cat 'test1.txt' test2.txt");

    try expectEqualStrings("cat", (try iter.next()).?);
    try expectEqualStrings("test1.txt", (try iter.next()).?);
    try expectEqualStrings("test2.txt", (try iter.next()).?);
    try expect(try iter.next() == null);
}

pub fn join(allocator: mem.Allocator, parts: []const []const u8) []u8 {
    var total_length: usize = 0;
    for (parts) |part| {
        total_length += part.len;
    }

    const result = allocator.alloc(u8, total_length) catch unreachable;
    var index: usize = 0;
    for (parts) |part| {
        @memcpy(result[index .. index + part.len], part);
        index += part.len;
    }

    return result;
}

pub fn join_path(allocator: mem.Allocator, path1: []const u8, path2: []const u8) []u8 {
    const left = mem.trimRight(u8, path1, pal.dir_separator);
    const separator = pal.dir_separator;
    const right = path2;

    return join(allocator, &[_]([]const u8){ left, separator, right });
}

pub fn forward(source: anytype, target: anytype) !void {
    var buffer: [1024]u8 = undefined;

    while (true) {
        const bytes_read = try source.read(&buffer);
        if (bytes_read > 0) {
            try target.writeAll(buffer[0..bytes_read]);
        } else {
            return;
        }
    }
}
