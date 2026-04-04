/// Simple full-redraw renderer.
/// On each render it moves the cursor to the previously rendered region,
/// overwrites with new content, then clears any leftover lines.
const std = @import("std");

pub const Renderer = struct {
    stdout: std.fs.File,
    prev_line_count: usize = 0,
    /// Internal scratch buffer for building escape sequences.
    scratch: [4096]u8 = undefined,

    pub fn init(_: std.mem.Allocator) Renderer {
        return .{ .stdout = std.fs.File.stdout() };
    }

    pub fn deinit(_: *Renderer) void {}

    /// Render the content string to the terminal.
    /// `content` should be plain text with embedded ANSI sequences.
    pub fn render(self: *Renderer, content: []const u8) void {
        var fbs = std.io.fixedBufferStream(&self.scratch);
        const w = fbs.writer();

        // Move cursor up by the number of lines rendered last time
        if (self.prev_line_count > 0) {
            for (0..self.prev_line_count) |_| {
                w.writeAll("\x1b[A") catch return;
            }
            w.writeByte('\r') catch return;
        }

        // Flush preamble (cursor movements)
        _ = self.stdout.write(fbs.getWritten()) catch {};

        // Write new content directly
        _ = self.stdout.write(content) catch {};

        // Ensure content ends with newline
        if (content.len == 0 or content[content.len - 1] != '\n') {
            _ = self.stdout.write("\n") catch {};
        }

        // Clear from cursor to end of screen
        _ = self.stdout.write("\x1b[J") catch {};

        self.prev_line_count = countLines(content);
    }

    /// Clear the rendered region (used at program exit).
    pub fn clear(self: *Renderer) void {
        if (self.prev_line_count > 0) {
            for (0..self.prev_line_count) |_| {
                _ = self.stdout.write("\x1b[A") catch {};
            }
            _ = self.stdout.write("\r\x1b[J") catch {};
        }
        self.prev_line_count = 0;
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
