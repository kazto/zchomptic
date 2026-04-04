const msg = @import("msg.zig");

/// A command is a function that produces a Msg, or null (no-op).
pub const Cmd = ?*const fn () msg.Msg;

/// Predefined quit command.
fn quitFn() msg.Msg {
    return .quit;
}
pub const quit: Cmd = quitFn;

/// No-op command.
pub const none: Cmd = null;
