/// Simple full-redraw renderer.
/// On each render it moves the cursor to the previously rendered region,
/// overwrites with new content, then clears any leftover lines.
const std = @import("std");

pub const Renderer = struct {
    io: std.Io,
    stdout: std.Io.File,
    prev_line_count: usize = 0,
    /// Internal scratch buffer for building escape sequences.
    scratch: [4096]u8 = undefined,

    pub fn init(io: std.Io, _: std.mem.Allocator) Renderer {
        return .{ .io = io, .stdout = .stdout() };
    }

    pub fn deinit(_: *Renderer) void {}

    /// Render the content string to the terminal.
    /// `content` should be plain text with embedded ANSI sequences.
    pub fn render(self: *Renderer, content: []const u8) void {
        var writer: std.Io.Writer = .fixed(&self.scratch);

        // Move cursor up by the number of lines rendered last time
        if (self.prev_line_count > 0) {
            for (0..self.prev_line_count) |_| {
                writer.writeAll("\x1b[A") catch return;
            }
            writer.writeByte('\r') catch return;
        }

        // Flush preamble (cursor movements)
        self.writeAll(writer.buffered());

        // Write new content directly
        self.writeAll(content);

        // Ensure content ends with newline
        if (content.len == 0 or content[content.len - 1] != '\n') {
            self.writeAll("\n");
        }

        // Clear from cursor to end of screen
        self.writeAll("\x1b[J");

        self.prev_line_count = countLines(content);
    }

    /// Clear the rendered region (used at program exit).
    pub fn clear(self: *Renderer) void {
        if (self.prev_line_count > 0) {
            for (0..self.prev_line_count) |_| {
                self.writeAll("\x1b[A");
            }
            self.writeAll("\r\x1b[J");
        }
        self.prev_line_count = 0;
    }

    fn writeAll(self: *Renderer, bytes: []const u8) void {
        var buffer: [4096]u8 = undefined;
        var writer = self.stdout.writerStreaming(self.io, &buffer);
        writer.interface.writeAll(bytes) catch return;
        writer.interface.flush() catch {};
    }
};

fn countLines(s: []const u8) usize {
    if (s.len == 0) return 0;
    var count: usize = 0;
    for (s) |c| {
        if (c == '\n') count += 1;
    }
    // If the string doesn't end with '\n', the last partial line still counts
    if (s[s.len - 1] != '\n') count += 1;
    return count;
}
