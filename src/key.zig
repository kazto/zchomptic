const std = @import("std");

pub const KeyMod = struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    meta: bool = false,
};

pub const KeyCode = enum {
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    enter,
    backspace,
    delete,
    insert,
    tab,
    back_tab,
    escape,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

pub const Key = union(enum) {
    /// Printable Unicode character
    char: u21,
    /// Special key (arrows, function keys, etc.)
    code: KeyCode,
    /// Control character (ctrl+a=1 ... ctrl+z=26)
    ctrl: u8,
};

pub const KeyMsg = struct {
    key: Key,
    mod: KeyMod = .{},

    pub fn format(
        self: KeyMsg,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (self.mod.ctrl) try writer.writeAll("ctrl+");
        if (self.mod.alt) try writer.writeAll("alt+");
        if (self.mod.shift) try writer.writeAll("shift+");
        switch (self.key) {
            .char => |c| {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &buf) catch 0;
                try writer.writeAll(buf[0..len]);
            },
            .code => |c| try writer.print("{s}", .{@tagName(c)}),
            .ctrl => |c| try writer.print("ctrl+{c}", .{c + 'a' - 1}),
        }
    }
};
