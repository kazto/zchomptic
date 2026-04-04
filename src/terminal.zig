const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const TerminalState = struct {
    original_termios: posix.termios,
    tty_fd: posix.fd_t,

    /// Enable raw mode. Returns the previous terminal state.
    pub fn init() !TerminalState {
        const tty_fd: posix.fd_t = blk: {
            if (posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0)) |fd| {
                break :blk fd;
            } else |_| {
                break :blk posix.STDIN_FILENO;
            }
        };

        const original = try posix.tcgetattr(tty_fd);
        var raw = original;

        // Input flags: disable BREAK signal, CR-to-NL, parity, strip, flow control
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        // Output flags: disable post-processing
        raw.oflag.OPOST = false;

        // Control flags: 8-bit characters
        raw.cflag.CSIZE = .CS8;

        // Local flags: no echo, no canonical mode, no signals, no extended
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        // Timing: read at least 1 byte, no timeout
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        try posix.tcsetattr(tty_fd, .FLUSH, raw);
        return .{ .original_termios = original, .tty_fd = tty_fd };
    }

    /// Restore the original terminal state.
    pub fn deinit(self: TerminalState) void {
        posix.tcsetattr(self.tty_fd, .FLUSH, self.original_termios) catch {};
        if (self.tty_fd != posix.STDIN_FILENO) {
            posix.close(self.tty_fd);
        }
    }

    pub const Size = struct { width: u16, height: u16 };

    /// Query the current terminal dimensions via TIOCGWINSZ.
    pub fn getSize() Size {
        var ws = std.mem.zeroes(linux.winsize);
        const rc = linux.ioctl(posix.STDOUT_FILENO, linux.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc != 0 or ws.ws_col == 0) return .{ .width = 80, .height = 24 };
        return .{ .width = ws.ws_col, .height = ws.ws_row };
    }
};
