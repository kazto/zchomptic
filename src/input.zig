/// ANSI/VT100 input parser.
/// Converts raw bytes from stdin into Msg values.
const std = @import("std");
const posix = std.posix;
const msg = @import("msg.zig");
const key = @import("key.zig");

/// Parse up to one Msg from the given byte slice.
/// Returns the Msg and the number of bytes consumed.
pub fn parseOne(buf: []const u8) struct { m: msg.Msg, consumed: usize } {
    if (buf.len == 0) return .{ .m = .{ .key_press = .{ .key = .{ .char = 0 } } }, .consumed = 0 };

    const b0 = buf[0];

    // ESC sequences
    if (b0 == 0x1b) {
        if (buf.len == 1) {
            // Bare ESC
            return .{ .m = .{ .key_press = .{ .key = .{ .code = .escape } } }, .consumed = 1 };
        }
        const b1 = buf[1];
        // ESC O x  — SS3 sequences (F1-F4)
        if (b1 == 'O' and buf.len >= 3) {
            const km = parseSS3(buf[2]);
            if (km) |k| return .{ .m = .{ .key_press = k }, .consumed = 3 };
        }
        // ESC [ ...  — CSI sequences
        if (b1 == '[' and buf.len >= 3) {
            const result = parseCSI(buf[2..]);
            if (result.consumed > 0) {
                return .{ .m = .{ .key_press = result.km }, .consumed = 2 + result.consumed };
            }
        }
        // ALT + key: ESC followed by a regular byte
        if (b1 >= 0x20 and b1 <= 0x7e) {
            const inner = parsePrintable(b1);
            var km = inner;
            km.mod.alt = true;
            return .{ .m = .{ .key_press = km }, .consumed = 2 };
        }
        // Unrecognised escape sequence — consume ESC only
        return .{ .m = .{ .key_press = .{ .key = .{ .code = .escape } } }, .consumed = 1 };
    }

    // Ctrl+C → interrupt
    if (b0 == 0x03) return .{ .m = .interrupt, .consumed = 1 };
    // Ctrl+D → EOF / quit
    if (b0 == 0x04) return .{ .m = .quit, .consumed = 1 };

    // Control characters 0x01..0x1A (except already handled)
    if (b0 >= 0x01 and b0 <= 0x1a) {
        return .{ .m = .{ .key_press = .{ .key = .{ .ctrl = b0 } } }, .consumed = 1 };
    }

    // Enter
    if (b0 == 0x0d or b0 == 0x0a) {
        return .{ .m = .{ .key_press = .{ .key = .{ .code = .enter } } }, .consumed = 1 };
    }
    // Tab
    if (b0 == 0x09) {
        return .{ .m = .{ .key_press = .{ .key = .{ .code = .tab } } }, .consumed = 1 };
    }
    // Backspace (DEL)
    if (b0 == 0x7f) {
        return .{ .m = .{ .key_press = .{ .key = .{ .code = .backspace } } }, .consumed = 1 };
    }

    // Printable ASCII
    if (b0 >= 0x20 and b0 <= 0x7e) {
        return .{ .m = .{ .key_press = parsePrintable(b0) }, .consumed = 1 };
    }

    // Multi-byte UTF-8
    const seq_len = std.unicode.utf8ByteSequenceLength(b0) catch 1;
    if (buf.len >= seq_len) {
        const codepoint = std.unicode.utf8Decode(buf[0..seq_len]) catch '?';
        return .{ .m = .{ .key_press = .{ .key = .{ .char = codepoint } } }, .consumed = seq_len };
    }

    // Unknown byte — skip
    return .{ .m = .{ .key_press = .{ .key = .{ .char = b0 } } }, .consumed = 1 };
}

/// Parse all Msgs from the buffer, appending to `out`.
pub fn parseAll(buf: []const u8, out: *std.ArrayList(msg.Msg), allocator: std.mem.Allocator) !void {
    var rest = buf;
    while (rest.len > 0) {
        const result = parseOne(rest);
        if (result.consumed == 0) break;
        try out.append(allocator, result.m);
        rest = rest[result.consumed..];
    }
}

// ---- Internal helpers ----

fn parsePrintable(b: u8) key.KeyMsg {
    var mod = key.KeyMod{};
    var ch: u21 = b;
    if (b >= 'A' and b <= 'Z') {
        mod.shift = true;
        ch = b;
    }
    return .{ .key = .{ .char = ch }, .mod = mod };
}

fn parseSS3(b: u8) ?key.KeyMsg {
    const code: key.KeyCode = switch (b) {
        'P' => .f1,
        'Q' => .f2,
        'R' => .f3,
        'S' => .f4,
        'H' => .home,
        'F' => .end,
        else => return null,
    };
    return .{ .key = .{ .code = code } };
}

const CSIResult = struct { km: key.KeyMsg, consumed: usize };

fn parseCSI(rest: []const u8) CSIResult {
    // Collect parameter digits and intermediate bytes until a final byte
    var i: usize = 0;
    var param_buf: [32]u8 = undefined;
    var param_len: usize = 0;

    while (i < rest.len) {
        const c = rest[i];
        if (c >= 0x30 and c <= 0x3f) {
            // Parameter bytes
            if (param_len < param_buf.len) {
                param_buf[param_len] = c;
                param_len += 1;
            }
            i += 1;
        } else if (c >= 0x40 and c <= 0x7e) {
            // Final byte
            i += 1;
            const params = param_buf[0..param_len];
            const km = csiToKey(params, c) orelse
                return .{ .km = .{ .key = .{ .code = .escape } }, .consumed = 0 };
            return .{ .km = km, .consumed = i };
        } else {
            break;
        }
    }
    return .{ .km = .{ .key = .{ .code = .escape } }, .consumed = 0 };
}

fn csiToKey(params: []const u8, final: u8) ?key.KeyMsg {
    // Simple 1-param sequences
    switch (final) {
        'A' => return .{ .key = .{ .code = .up } },
        'B' => return .{ .key = .{ .code = .down } },
        'C' => return .{ .key = .{ .code = .right } },
        'D' => return .{ .key = .{ .code = .left } },
        'H' => return .{ .key = .{ .code = .home } },
        'F' => return .{ .key = .{ .code = .end } },
        'Z' => return .{ .key = .{ .code = .back_tab }, .mod = .{ .shift = true } },
        '~' => {
            const n = parseParamN(params, 0);
            const code: key.KeyCode = switch (n) {
                1 => .home,
                2 => .insert,
                3 => .delete,
                4 => .end,
                5 => .page_up,
                6 => .page_down,
                11 => .f1,
                12 => .f2,
                13 => .f3,
                14 => .f4,
                15 => .f5,
                17 => .f6,
                18 => .f7,
                19 => .f8,
                20 => .f9,
                21 => .f10,
                23 => .f11,
                24 => .f12,
                else => return null,
            };
            return .{ .key = .{ .code = code } };
        },
        else => return null,
    }
}

fn parseParamN(params: []const u8, default: u32) u32 {
    if (params.len == 0) return default;
    return std.fmt.parseUnsigned(u32, params, 10) catch default;
}

// --- Poll helper for escape sequence timeout ---

/// Returns true if stdin has data available within `timeout_ms` milliseconds.
pub fn pollStdin(timeout_ms: i32) bool {
    var pfd = [1]posix.pollfd{.{
        .fd = posix.STDIN_FILENO,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const n = posix.poll(&pfd, timeout_ms) catch return false;
    return n > 0;
}
