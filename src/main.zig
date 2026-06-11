/// Simple counter example — demonstrates the zchomptic TUI framework.
///
///   ↑ / k   increment
///   ↓ / j   decrement
///   q        quit
///   Ctrl+C   quit
const std = @import("std");
const tea = @import("zchomptic");

const Counter = struct {
    count: i32 = 0,

    pub fn init(self: *Counter) ?tea.Cmd {
        _ = self;
        return null;
    }

    pub fn update(self: *Counter, m: tea.Msg) ?tea.Cmd {
        switch (m) {
            .key_press => |k| {
                switch (k.key) {
                    .char => |c| switch (c) {
                        'q', 'Q' => return tea.cmd.quit,
                        'k' => self.count += 1,
                        'j' => self.count -= 1,
                        else => {},
                    },
                    .code => |code| switch (code) {
                        .up => self.count += 1,
                        .down => self.count -= 1,
                        else => {},
                    },
                    .ctrl => |c| {
                        // ctrl+c = 3
                        if (c == 3) return tea.cmd.quit;
                    },
                }
            },
            .interrupt => return tea.cmd.quit,
            else => {},
        }
        return null;
    }

    pub fn view(self: *Counter, writer: *std.Io.Writer) !void {
        try writer.print(
            \\Counter: {d}
            \\
            \\  ↑ / k   increment
            \\  ↓ / j   decrement
            \\  q        quit
            \\
        , .{self.count});
    }
};

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var counter = Counter{};
    var prog = tea.Program.init(allocator, init.io, tea.model(&counter));
    defer prog.deinit();

    try prog.run();
}
