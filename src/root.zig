//! zchomptic — a Zig re-implementation of the bubbletea TUI framework.
//!
//! Elm architecture: Model → Update → View
//!
//! Quick start:
//!
//!   const tea = @import("zchomptic");
//!
//!   const MyModel = struct {
//!       count: i32 = 0,
//!
//!       pub fn init(self: *MyModel) ?tea.Cmd { _ = self; return null; }
//!
//!       pub fn update(self: *MyModel, m: tea.Msg) ?tea.Cmd {
//!           switch (m) {
//!               .key_press => |k| switch (k.key) {
//!                   .ctrl => |c| if (c == 3) return tea.cmd.quit,  // ctrl+c
//!                   .code => |code| switch (code) {
//!                       .up   => self.count += 1,
//!                       .down => self.count -= 1,
//!                       else  => {},
//!                   },
//!                   else => {},
//!               },
//!               else => {},
//!           }
//!           return null;
//!       }
//!
//!       pub fn view(self: *MyModel, writer: std.io.AnyWriter) !void {
//!           try writer.print("Count: {d}\nPress ↑/↓ to change, Ctrl+C to quit.\n", .{self.count});
//!       }
//!   };
//!
//!   var m = MyModel{};
//!   var prog = tea.Program.init(allocator, tea.model(&m));
//!   defer prog.deinit();
//!   try prog.run();

const std = @import("std");

pub const key = @import("key.zig");
pub const mouse = @import("mouse.zig");
pub const msg = @import("msg.zig");
pub const cmd = @import("cmd.zig");
pub const terminal = @import("terminal.zig");
pub const input = @import("input.zig");
pub const renderer = @import("renderer.zig");

const tea = @import("tea.zig");

pub const Msg = tea.Msg;
pub const Cmd = tea.Cmd;
pub const Model = tea.Model;
pub const Program = tea.Program;

/// Create a Model interface from a pointer to any struct that implements
/// `init`, `update`, and `view`.
pub const model = tea.model;
