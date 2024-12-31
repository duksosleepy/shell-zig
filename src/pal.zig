const Pal = struct {
    path_separator: []const u8,
    dir_separator: []const u8,
    trim_cr: bool,
};

const WindowsPal = Pal{
    .path_separator = ";",
    .dir_separator = "\\",
    .trim_cr = true,
};
const DefaultPal = Pal{
    .path_separator = ":",
    .dir_separator = "/",
    .trim_cr = false,
};

pub const Current = if (@import("builtin").os.tag == .windows) WindowsPal else DefaultPal;
