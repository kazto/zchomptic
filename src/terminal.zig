const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

pub const TerminalState = struct {
    io: std.Io,
    original_termios: if (is_windows) u32 else posix.termios,
    tty_fd: if (is_windows) std.os.windows.HANDLE else posix.fd_t,

    /// Enable raw mode. Returns the previous terminal state.
    pub fn init(io: std.Io) !TerminalState {
        if (is_windows) {
            const K32 = struct {
                const STD_INPUT_HANDLE: std.os.windows.DWORD = 0xfffffff6;
                const STD_OUTPUT_HANDLE: std.os.windows.DWORD = 0xfffffff5;
                extern "kernel32" fn GetStdHandle(nStdHandle: std.os.windows.DWORD) callconv(.winapi) ?std.os.windows.HANDLE;
                extern "kernel32" fn GetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, lpMode: *std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
                extern "kernel32" fn SetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, dwMode: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
            };
            const h = K32.GetStdHandle(K32.STD_INPUT_HANDLE) orelse return error.GetStdHandleFailed;
            var mode: std.os.windows.DWORD = undefined;
            if (!K32.GetConsoleMode(h, &mode).toBool()) return error.GetConsoleModeFailed;

            // Win32 Console Mode constants
            const ENABLE_PROCESSED_INPUT: u32 = 0x0001;
            const ENABLE_LINE_INPUT: u32 = 0x0002;
            const ENABLE_ECHO_INPUT: u32 = 0x0004;
            const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x0200;

            var raw_mode = mode & ~(ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT);
            // Enable VT processing for ANSI escapes on input if supported
            raw_mode |= ENABLE_VIRTUAL_TERMINAL_INPUT;

            if (!K32.SetConsoleMode(h, raw_mode).toBool()) {
                // If VT input failed, just try without it
                raw_mode &= ~ENABLE_VIRTUAL_TERMINAL_INPUT;
                if (!K32.SetConsoleMode(h, raw_mode).toBool()) return error.SetConsoleModeFailed;
            }

            // Also ensure VT processing is enabled for STDOUT
            const h_out = K32.GetStdHandle(K32.STD_OUTPUT_HANDLE) orelse h;
            var out_mode: std.os.windows.DWORD = undefined;
            if (K32.GetConsoleMode(h_out, &out_mode).toBool()) {
                const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;
                _ = K32.SetConsoleMode(h_out, out_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
            }

            return .{ .io = io, .original_termios = mode, .tty_fd = h };
        }

        const tty_fd: posix.fd_t = blk: {
            if (posix.openat(posix.AT.FDCWD, "/dev/tty", .{ .ACCMODE = .RDWR }, 0)) |fd| {
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
        return .{ .io = io, .original_termios = original, .tty_fd = tty_fd };
    }

    /// Restore the original terminal state.
    pub fn deinit(self: TerminalState) void {
        if (is_windows) {
            const K32 = struct {
                extern "kernel32" fn SetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, dwMode: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
            };
            _ = K32.SetConsoleMode(self.tty_fd, self.original_termios);
            return;
        }
        posix.tcsetattr(self.tty_fd, .FLUSH, self.original_termios) catch {};
        if (self.tty_fd != posix.STDIN_FILENO) {
            const tty_file: std.Io.File = .{ .handle = self.tty_fd, .flags = .{ .nonblocking = false } };
            tty_file.close(self.io);
        }
    }

    pub const Size = struct { width: u16, height: u16 };

    /// Query the current terminal dimensions.
    pub fn getSize() Size {
        if (is_windows) {
            const SMALL_RECT = extern struct {
                Left: std.os.windows.SHORT,
                Top: std.os.windows.SHORT,
                Right: std.os.windows.SHORT,
                Bottom: std.os.windows.SHORT,
            };
            const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
                dwSize: std.os.windows.COORD,
                dwCursorPosition: std.os.windows.COORD,
                wAttributes: std.os.windows.WORD,
                srWindow: SMALL_RECT,
                dwMaximumWindowSize: std.os.windows.COORD,
            };
            const K32 = struct {
                const STD_OUTPUT_HANDLE: std.os.windows.DWORD = 0xfffffff5;
                extern "kernel32" fn GetStdHandle(nStdHandle: std.os.windows.DWORD) callconv(.winapi) ?std.os.windows.HANDLE;
                extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: std.os.windows.HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) std.os.windows.BOOL;
            };
            const h = K32.GetStdHandle(K32.STD_OUTPUT_HANDLE) orelse return .{ .width = 80, .height = 24 };
            var csbi: CONSOLE_SCREEN_BUFFER_INFO = undefined;
            if (K32.GetConsoleScreenBufferInfo(h, &csbi).toBool()) {
                return .{
                    .width = @intCast(csbi.srWindow.Right - csbi.srWindow.Left + 1),
                    .height = @intCast(csbi.srWindow.Bottom - csbi.srWindow.Top + 1),
                };
            }
            return .{ .width = 80, .height = 24 };
        }

        var ws = std.mem.zeroes(std.posix.winsize);
        const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.system.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc != 0 or ws.col == 0) return .{ .width = 80, .height = 24 };
        return .{ .width = ws.col, .height = ws.row };
    }
};
